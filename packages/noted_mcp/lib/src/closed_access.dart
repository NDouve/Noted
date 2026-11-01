// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:noted_core/noted_core_read.dart';

import 'closed_writer.dart';
import 'library.dart';
import 'tools.dart';

/// What the AI is told for a code that the user has not approved yet.
const String approveInNotedFirst = 'Approve this code in Noted first. Open Noted: it will ask you.';

/// What the AI is told when `ai-access.json` exists but can't be read.
const String storeUnreadableText = "Noted can't read its codes. Open Noted to fix it.";

/// The data version of an AI box this build writes.
const int _aiBoxDataVersion = 1;

final Random _random = Random.secure();

// A fresh revision id: 16 lowercase hex digits, as the app makes them.
String _newRev() {
  final b = StringBuffer();
  for (var i = 0; i < 8; i++) {
    b.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// How the server answers a code-based request while Noted is not running
/// (invariant 4, wording of run 2026-11-01-03). It checks the code itself
/// against the saved code store, `ai-access.json` (read only; the hash of the
/// key, the expiry, the approval, the role and the target), works out what
/// the code reaches from the saved page files, and logs every request to the
/// server's own access log through [ClosedWriter]. A write is allowed only
/// for an AI box that has "allow writes while Noted is closed" on, within its
/// Writer permission, and goes straight into the page file.
///
/// While Noted runs none of this is used: the app decides over the link.
final class ClosedAccess {
  ClosedAccess(this.dataDir, {this.app, DateTime Function()? clock, this.beforeReplace}) : _clock = clock ?? DateTime.now;

  final Directory dataDir;

  /// The MCP client's name (and version), as sent to the app; recorded in the
  /// log, cleaned.
  final String? app;

  final DateTime Function() _clock;

  /// Called before each try to replace the page file, with the try's number
  /// (0 or 1). Tests use it to change the file at the worst moment.
  final Future<void> Function(int attempt)? beforeReplace;

  static AiLinkError _error(AiLinkCode c) => AiLinkError(c);

  Future<AiAccessView?> _store() async {
    final f = File('${dataDir.path}${Platform.pathSeparator}$aiAccessFileName');
    try {
      // No store: no code is known (the caller says to open Noted).
      if (!await f.exists()) return null;
      return AiAccessView.parse(await f.readAsString());
    } on Object {
      // Damaged, or written by a newer app: no code is accepted.
      return null;
    }
  }

  static String _clean(String s, int max) {
    final t = s.replaceAll(RegExp(r'[\x00-\x1F\x7F-\x9F]'), ' ').trim();
    return t.length > max ? t.substring(0, max) : t;
  }

  Future<void> _log(
    ClosedWriter writer,
    AiCode code,
    AiCodeTarget target,
    String op,
    String result,
  ) => writer.appendLog(
    AiMcpLogEntry(
      time: _clock().toUtc(),
      code: code.id,
      target: target,
      op: op,
      app: _clean(app ?? '', aiLinkMaxAppLength),
      label: _clean(code.label, 200),
      result: result,
    ).encode(),
  );

  // Checks [token] up to approval. Returns the stored code and the store, or
  // the error to answer with (logged when the code is known).
  Future<({AiCode? code, AiAccessView? view, AiLinkError? error})> _check(String token, String op) async {
    ({AiCode? code, AiAccessView? view, AiLinkError? error}) no(AiLinkError e) => (code: null, view: null, error: e);
    final parsed = parseAiToken(token);
    if (parsed == null) return no(_error(AiLinkCode.badCode));
    final f = File('${dataDir.path}${Platform.pathSeparator}$aiAccessFileName');
    final view = await _store();
    if (view == null) {
      // A missing store means Noted never made a code here: ask to open it. A
      // damaged one accepts no code.
      return no(
        await f.exists()
            ? AiLinkError(AiLinkCode.busy, storeUnreadableText)
            : AiLinkError(AiLinkCode.notApproved, approveInNotedFirst),
      );
    }
    final verdict = view.verify(token, _clock());
    final writer = ClosedWriter(dataDir: dataDir, folders: const []);
    final code = verdict.code ?? view.code(parsed.id);
    if (!verdict.ok) {
      return switch (verdict.failure!) {
        AiCodeFailure.expired => () async {
          // The key matched, so the code is known; the holder is told.
          if (code != null) await _log(writer, code, code.target, op, AiLinkCode.expired.wire);
          return no(_error(AiLinkCode.expired));
        }(),
        AiCodeFailure.unreadable => no(AiLinkError(AiLinkCode.busy, storeUnreadableText)),
        AiCodeFailure.badCode => no(_error(AiLinkCode.badCode)),
      };
    }
    final c = verdict.code!;
    if (!c.isApproved) {
      await _log(writer, c, c.target, op, aiMcpResultPendingApproval);
      return no(AiLinkError(AiLinkCode.notApproved, approveInNotedFirst));
    }
    return (code: c, view: view, error: null);
  }

  // ---------------------------------------------------------------------------
  // reads

  /// What [token] reads for [action], from the saved files: an
  /// [AiLinkBoxGrant] (a box code, for `read_box` only) or an
  /// [AiLinkPagesGrant], or an [AiLinkError].
  Future<AiLinkResponse> grant(String token, AiLinkAction action, {String? target}) async {
    final op = action.wire;
    final r = await _check(token, op);
    if (r.error != null) return r.error!;
    final code = r.code!;
    // A box code asked for another box: no such box, and not worth a log line.
    if (code.target.kind == AiCodeTargetKind.box &&
        action == AiLinkAction.readBox &&
        target != null &&
        target != code.target.id) {
      return _error(AiLinkCode.noBox);
    }
    final writer = ClosedWriter(dataDir: dataDir, folders: const []);
    Future<AiLinkResponse> done(AiLinkCode c, [AiCodeTarget? target]) async {
      await _log(writer, code, target ?? code.target, op, c.wire);
      return _error(c);
    }

    if (!code.canRead) return done(AiLinkCode.wrongRole);
    final library = await NotedLibrary.load(dataDir);
    switch (code.target.kind) {
      case AiCodeTargetKind.box:
        if (action != AiLinkAction.readBox) return done(AiLinkCode.wrongRole);
        final page = _pageOfBox(library, code.target.id, code.target.page);
        if (page == null) return done(AiLinkCode.noBox);
        final target = AiCodeTarget.box(code.target.id, page: page.id);
        await _log(writer, code, target, op, aiMcpResultOk);
        return AiLinkGranted(AiLinkBoxGrant(box: code.target.id, page: page.id));
      case AiCodeTargetKind.page:
      case AiCodeTargetKind.binder:
        await _log(writer, code, code.target, op, aiMcpResultOk);
        return AiLinkGranted(AiLinkPagesGrant(pages: _covered(library, code.target)));
      case null:
        return done(AiLinkCode.wrongRole);
    }
  }

  // The page holding box [boxId]: [hint] if it has it, else the first page
  // (by id) that does.
  LibraryPage? _pageOfBox(NotedLibrary library, String boxId, String? hint) {
    bool has(LibraryPage p) => p.page.node(boxId) is BoxRecord;
    final h = hint == null ? null : library.page(hint);
    if (h != null && has(h)) return h;
    final all = [...library.pages]..sort((a, b) => a.id.compareTo(b.id));
    for (final p in all) {
      if (has(p)) return p;
    }
    return null;
  }

  // Whether two pages are in the same page tree: the app and the library keep
  // one tree for all standalone folders together, and one per binder.
  static bool _sameTree(LibraryPage a, LibraryPage b) => _treeKey(a) == _treeKey(b);

  static String? _treeKey(LibraryPage p) => p.location.binder == null ? null : p.location.path;

  // The pages a page or binder code reads: the page and its subpages (in its
  // own tree), or the binder's pages; minus Guarded pages (own,
  // inherited or tightened) and pages in locked binders.
  List<String> _covered(NotedLibrary library, AiCodeTarget target) {
    final Iterable<LibraryPage> pages;
    if (target.kind == AiCodeTargetKind.binder) {
      pages = [
        for (final p in library.pages)
          if (p.location.binder?.id == target.id) p,
      ];
    } else {
      final root = library.page(target.id);
      if (root == null) return const [];
      final same = {
        for (final p in library.pages)
          if (_sameTree(p, root)) p.id: p,
      };
      bool under(LibraryPage p) {
        final seen = <String>{p.id};
        var at = p.page.meta.parentId;
        while (at != null && seen.add(at)) {
          if (at == root.id) return true;
          at = same[at]?.page.meta.parentId;
        }
        return false;
      }

      pages = [
        for (final p in same.values)
          if (p.id == root.id || under(p)) p,
      ];
    }
    return [
      for (final p in pages)
        if (!p.locked && p.access != AiAccess.guarded) p.id,
    ];
  }

  // ---------------------------------------------------------------------------
  // writes

  /// Writes [content] (markdown) to the AI box [boxId] with the Writer code
  /// [token], straight into its page file. Every refusal is an [AiLinkError]
  /// and nothing is changed.
  Future<AiLinkResponse> write({
    required String token,
    required String boxId,
    required AiLinkMode mode,
    required String content,
  }) {
    // Closed writes in this process run one after another, so two never race
    // on the same page file.
    final run = _queue.then((_) async {
      // A second try if the file changed between reading and writing it.
      // Every check runs again on the page as it is now.
      for (var attempt = 0; attempt < 2; attempt++) {
        final r = await _writeOnce(attempt, token, boxId, mode, content);
        if (r != null) return r;
      }
      throw StateError('unreachable');
    });
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  static Future<void> _queue = Future.value();

  // One try: every check, then the write. Null: the file changed under it and
  // the caller should look again (on the last try the answer is `busy`).
  Future<AiLinkResponse?> _writeOnce(int attempt, String token, String boxId, AiLinkMode mode, String content) async {
    const op = 'write_box';
    final r = await _check(token, op);
    if (r.error != null) return r.error!;
    final code = r.code!;
    final view = r.view!;
    final writer0 = ClosedWriter(dataDir: dataDir, folders: const []);
    Future<AiLinkResponse> done(AiLinkCode c, [LibraryPage? page]) async {
      await _log(writer0, code, AiCodeTarget.box(boxId, page: page?.id ?? code.target.page), op, c.wire);
      return _error(c);
    }

    if (!code.canWriteBox) return done(AiLinkCode.wrongRole);
    if (boxId != code.target.id) return done(AiLinkCode.noBox);
    final library = await NotedLibrary.load(dataDir);
    final page = _pageOfBox(library, boxId, code.target.page);
    if (page == null || page.path == null) return done(AiLinkCode.noBox);
    // Only a box that allows it: off by default, and never with ask-first.
    if (!view.closedWrites(boxId)) return done(AiLinkCode.notRunning, page);
    if (!view.writerPermission(boxId).allows(mode)) return done(AiLinkCode.notPermitted, page);
    final box = page.page.node(boxId);
    if (box is! BoxRecord || box.typeId != aiBoxTypeId || isEncrypted(box)) return done(AiLinkCode.notWritable, page);
    final chain = _chain(library, page);
    if (!effectiveBoxTypeAllowed(box.typeId, chain, binder: page.location.binder).allowed) {
      return done(AiLinkCode.notWritable, page);
    }
    if (box.isConflicted) return done(AiLinkCode.conflict, page);
    if (page.locked) return done(AiLinkCode.locked, page);

    final writer = ClosedWriter(dataDir: dataDir, folders: library.folders);
    final aiMode = switch (mode) {
      AiLinkMode.append => AiWriteMode.append,
      AiLinkMode.replaceAi => AiWriteMode.replaceAiText,
      AiLinkMode.replace => AiWriteMode.replace,
    };
    final List<int> bytes;
    try {
      bytes = await File(page.path!).readAsBytes();
    } on Object {
      return done(AiLinkCode.noBox, page);
    }
    final next = _spliced(bytes, boxId, code.id, aiMode, content);
    if (next is AiLinkCode) return done(next, page);
    if (beforeReplace != null) await beforeReplace!(attempt);
    switch (await writer.replacePage(page.path!, expected: bytes, text: next as List<int>)) {
      case PageReplace.done:
        await _log(writer, code, AiCodeTarget.box(boxId, page: page.id), op, aiMcpResultOk);
        return AiLinkWritten(box: boxId);
      case PageReplace.changed:
        return attempt == 0 ? null : done(AiLinkCode.busy, page);
      case PageReplace.refused:
        return done(AiLinkCode.saveFailed, page);
    }
  }

  // The page's chain for module availability: the page, then its parents in
  // its own folder or binder.
  List<PageMeta> _chain(NotedLibrary library, LibraryPage page) {
    final same = {
      for (final p in library.pages)
        if (_sameTree(p, page)) p.id: p.page.meta,
    };
    final chain = <PageMeta>[page.page.meta];
    final seen = <String>{page.id};
    var at = page.page.meta.parentId;
    while (at != null && seen.add(at)) {
      final m = same[at];
      if (m == null) break;
      chain.add(m);
      at = m.parentId;
    }
    return chain;
  }

  // The new bytes of the page file [bytes] with [content] written into box
  // [boxId], or an [AiLinkCode] to refuse with. Every other byte stays.
  Object _spliced(List<int> bytes, String boxId, String codeId, AiWriteMode mode, String content) {
    final String text;
    try {
      final decoded = utf8.decode(bytes);
      // utf8.decode drops a leading byte order mark: put it back so it stays.
      final bom = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
      text = bom && !decoded.startsWith('﻿') ? '﻿$decoded' : decoded;
    } on FormatException {
      return AiLinkCode.saveFailed;
    }
    final NotedPage page;
    try {
      page = readPage(text.startsWith('﻿') ? text.substring(1) : text);
    } on Object {
      return AiLinkCode.saveFailed;
    }
    final box = page.node(boxId);
    if (box is! BoxRecord) return AiLinkCode.noBox;
    if (box.typeId != aiBoxTypeId || isEncrypted(box)) return AiLinkCode.notWritable;
    if (box.isConflicted) return AiLinkCode.conflict;
    final Map<String, Object?> json;
    try {
      final d = box.data?.decode();
      if (box.dataVersion != _aiBoxDataVersion || d is! Map || d['document'] is! Map) return AiLinkCode.notWritable;
      json = d.cast<String, Object?>();
    } on Object {
      return AiLinkCode.notWritable;
    }
    final next = applyAiWrite(json, AiWrite(connectionId: codeId, content: content, mode: mode));
    final device = _computerName();
    final spliced = spliceBoxContent(
      text,
      boxId,
      data: RawJson.encode(next),
      dataVersion: _aiBoxDataVersion,
      snapshotText: noteToMarkdown(next, markAi: true),
      newRev: _newRev(),
      device: device,
      at: device == null ? null : _clock().millisecondsSinceEpoch,
    );
    if (spliced == null) return AiLinkCode.saveFailed;
    return utf8.encode(spliced);
  }

  // The computer's name, as the app stamps it on an edit.
  static String? _computerName() {
    String? name;
    try {
      name = Platform.localHostname;
    } on Object {
      name = null;
    }
    if (name == null || name.isEmpty) name = Platform.environment['COMPUTERNAME'];
    return name == null || name.isEmpty ? null : name;
  }
}
