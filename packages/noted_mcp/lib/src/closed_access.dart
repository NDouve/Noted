// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:noted_core/noted_core_read.dart';

import 'closed_writer.dart';
import 'library.dart';
import 'running_probe.dart';
import 'tools.dart';

/// What the AI is told for a code that the user has not approved yet.
const String approveInNotedFirst = 'Approve this code in Noted first. Open Noted: it will ask you.';

/// What the AI is told when Noted is closed and the box doesn't allow writes
/// while Noted is closed.
const String closedWritesOffText =
    "This box doesn't take writes while Noted is closed. Open Noted and try again, "
    'or ask the user to allow it in the box.';

/// What the AI is told when `ai-access.json` exists but can't be read.
const String storeUnreadableText = "Noted can't read its codes. Open Noted to fix it.";

/// What the AI is told when the running-lock file can't be opened or locked.
const String lockUnusableText =
    "Noted's running-lock file can't be opened or locked (an access or disk error), so nothing was written. "
    'Open Noted, or check its data folder, then try again.';

/// What the AI is told when the running-lock file isn't there.
const String openNotedOnceText = 'Open Noted once, then try again.';

/// The access log's `result` for a box code refused because its page has more
/// than one copy.
const String aiMcpResultAmbiguous = 'ambiguous';

/// The log result of a closed write refused because a binder file of the page's
/// folder or of a parent's folder is missing, unreadable or damaged.
const String aiMcpResultBinderUnusable = 'binder_unusable';

/// How long a closed write may hold the running lock, from the moment it is
/// taken until the page is first changed (run 2026-11-06-02).
const Duration defaultClosedHoldLimit = Duration(seconds: 5);

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
  ClosedAccess(
    this.dataDir, {
    this.app,
    DateTime Function()? clock,
    this.beforeReplace,
    this.beforeRead,
    this.beforeHold,
    this.beforeRecheck,
    this.holdLimit = defaultClosedHoldLimit,
    this.greets,
  }) : _clock = clock ?? DateTime.now;

  final Directory dataDir;

  /// Called before each try takes the running lock, after every pre-check.
  /// Tests use it to change the world between the pre-checks and the hold.
  final Future<void> Function(int attempt)? beforeHold;

  /// Called at the start of the re-check under the hold (a test seam).
  final Future<void> Function(int attempt)? beforeRecheck;

  /// The limit on a hold, from `take()` to the first change of the page.
  final Duration holdLimit;

  /// Whether Noted's link greets (asked under the hold). Null: never.
  final Future<bool> Function()? greets;

  /// The MCP client's name (and version), as sent to the app; recorded in the
  /// log, cleaned.
  final String? app;

  final DateTime Function() _clock;

  /// Called before each try to replace the page file, with the try's number
  /// (0 or 1). Tests use it to change the file at the worst moment.
  final Future<void> Function(int attempt)? beforeReplace;

  /// Called before each try reads the page file's bytes, after the library was
  /// loaded. Tests use it to change the page between the two.
  final Future<void> Function(int attempt)? beforeRead;

  static AiLinkError _error(AiLinkCode c) => AiLinkError(c);

  Future<AiAccessView?> _store() async {
    final f = File('${dataDir.path}${Platform.pathSeparator}$aiAccessFileName');
    try {
      // No store: no code is known (the caller says to open Noted).
      if (!await f.exists()) return null;
      // Never the running-lock file itself (a synced link to it).
      final bytes = await (await LockIdentity.of(dataDir)).readBytes(f.path);
      if (bytes == null) return null;
      return AiAccessView.parse(utf8.decode(bytes));
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
    Future<AiLinkResponse> done(AiLinkCode c, [AiCodeTarget? target, String? message, String? result]) async {
      await _log(writer, code, target ?? code.target, op, result ?? c.wire);
      return message == null ? _error(c) : AiLinkError(c, message);
    }

    if (!code.canRead) return done(AiLinkCode.wrongRole);
    final library = await NotedLibrary.load(dataDir);
    switch (code.target.kind) {
      case AiCodeTargetKind.box:
        if (action != AiLinkAction.readBox) return done(AiLinkCode.wrongRole);
        final found = _pageOfBox(library, code.target.id, code.target.page);
        // A page with more than one copy: the server can't tell which one the
        // app chose, so it reads none (the hint is checked before any lookup).
        if (found.ambiguous) {
          return done(AiLinkCode.notWritable, null, ambiguousPageText, aiMcpResultAmbiguous);
        }
        final page = found.page;
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
  // (by id) that does. [ambiguous]: the hint, or the page found, has more than
  // one copy (the hint is checked first, so a hint page with copies never
  // falls back to another page that holds the same box id).
  ({LibraryPage? page, bool ambiguous}) _pageOfBox(NotedLibrary library, String boxId, String? hint) {
    bool has(LibraryPage p) => p.page.node(boxId) is BoxRecord;
    if (hint != null && library.isAmbiguous(hint)) return (page: null, ambiguous: true);
    final h = hint == null ? null : library.page(hint);
    if (h != null && has(h)) return (page: h, ambiguous: false);
    // By id, then the standalone entry before a binder's, then by folder, so
    // the result never depends on the order the library listed its pages in.
    final all = [...library.pages]
      ..sort((a, b) {
        final byId = a.id.compareTo(b.id);
        if (byId != 0) return byId;
        final byTree = (a.location.binder == null ? 0 : 1).compareTo(b.location.binder == null ? 0 : 1);
        if (byTree != 0) return byTree;
        return a.location.path.compareTo(b.location.path);
      });
    for (final p in all) {
      if (has(p)) return (page: p, ambiguous: library.isAmbiguous(p.id));
    }
    return (page: null, ambiguous: false);
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
  /// [token], straight into its page file, while holding the shared running
  /// lock (run 2026-11-06-02). Every refusal is an [AiLinkError] and nothing
  /// is changed. [ClosedWriteResult.runningNow] says Noted turned out to be
  /// running: the caller sends the write over the link instead.
  Future<ClosedWriteResult> write({
    required String token,
    required String boxId,
    required AiLinkMode mode,
    required String content,
  }) {
    // Closed writes in this process run one after another, so two never race
    // on the same page file.
    final run = _queue.then((_) async {
      // A second try if the file changed between reading and writing it.
      // Every check runs again on the page as it is now, and each try takes
      // its own hold.
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

  // One try: every pre-check, then the hold and the re-check, then the write.
  // Null: the file changed under it and the caller should look again (on the
  // last try the answer is `busy`).
  Future<ClosedWriteResult?> _writeOnce(
    int attempt,
    String token,
    String boxId,
    AiLinkMode mode,
    String content,
  ) async {
    const op = 'write_box';
    final r = await _check(token, op);
    if (r.error != null) return ClosedWriteResult.response(r.error!);
    final code = r.code!;
    final view = r.view!;
    final writer0 = ClosedWriter(dataDir: dataDir, folders: const []);
    Future<ClosedWriteResult> done(AiLinkCode c, [LibraryPage? page, String? message, String? result]) async {
      await _log(writer0, code, AiCodeTarget.box(boxId, page: page?.id ?? code.target.page), op, result ?? c.wire);
      return ClosedWriteResult.response(message == null ? _error(c) : AiLinkError(c, message));
    }

    final denied = _denied(code, view, boxId, mode, null);
    if (denied != null) return done(denied.code, null, denied.message);
    final library = await NotedLibrary.load(dataDir, keepSources: true);
    Future<ClosedWriteResult> ambiguous([LibraryPage? page]) =>
        done(AiLinkCode.notWritable, page, ambiguousPageText, aiMcpResultAmbiguous);
    final found = _pageOfBox(library, boxId, code.target.page);
    if (found.ambiguous) return ambiguous(found.page);
    final first = found.page;
    if (first == null || first.path == null) return done(AiLinkCode.noBox);
    // Whichever entry was found, work from the standalone one when the file has
    // both: its tree reaches every folder the parents may be in.
    final page = first.location.binder == null
        ? first
        : library.pages.firstWhere(
            (p) => p.path == first.path && p.location.binder == null,
            orElse: () => first,
          );
    final deniedOnPage = _denied(code, view, boxId, mode, page);
    if (deniedOnPage != null) return done(deniedOnPage.code, page, deniedOnPage.message);
    final chain = _chain(library, page);
    // A folder listed as standalone and as a binder has an entry in each tree
    // for the same file: the box type must be allowed in both.
    final others = [
      for (final p in library.pages)
        if (p.path == page.path && !identical(p, page)) (_chain(library, p), p.location.binder),
      // The same for every page above it: a parent in a folder listed both ways
      // also has its binder entry, whose binder rules reach this page too. The
      // view's metas start with the page's own, as the other views' do.
      for (final a in chain.pages.skip(1))
        for (final p in library.pages)
          if (a.path != null && p.path == a.path && !identical(p, a) && p.location.binder != null)
            (_viewBelow(page, _chain(library, p)), p.location.binder),
    ];
    // Before any hold: the page, a page above it or the page its chain ended
    // at has more than one copy, so its access, settings and bytes can't be
    // taken from the copy the server picked.
    bool chainAmbiguous(_Chain c) =>
        c.pages.any((p) => library.isAmbiguous(p.id)) || (c.endId != null && library.isAmbiguous(c.endId!));
    if (chainAmbiguous(chain) || others.any((o) => chainAmbiguous(o.$1))) return ambiguous(page);
    final box = page.page.node(boxId);
    if (box is! BoxRecord || box.typeId != aiBoxTypeId || isEncrypted(box)) return done(AiLinkCode.notWritable, page);
    if (!effectiveBoxTypeAllowed(box.typeId, chain.metas, binder: page.location.binder).allowed ||
        others.any((o) => !effectiveBoxTypeAllowed(box.typeId, o.$1.metas, binder: o.$2).allowed)) {
      return done(AiLinkCode.notWritable, page);
    }
    // A binder file that is missing, can't be read or doesn't parse leaves its
    // binder out of the library, and with it the box-type rules of that binder:
    // for the page and every page above it, a folder listed as a binder whose
    // file can't be used refuses.
    final usable = library.sources?.binderUsable;
    if (usable != null && chain.pages.any((p) => usable[NotedLibrary.binderFilePath(p.location.path)] == false)) {
      return done(AiLinkCode.notWritable, page, binderUnusableText, aiMcpResultBinderUnusable);
    }
    if (box.isConflicted) return done(AiLinkCode.conflict, page);
    if (page.locked) return done(AiLinkCode.locked, page);
    _pruneSources(library, page, chain);

    final writer = ClosedWriter(dataDir: dataDir, folders: library.folders);
    final aiMode = switch (mode) {
      AiLinkMode.append => AiWriteMode.append,
      AiLinkMode.replaceAi => AiWriteMode.replaceAiText,
      AiLinkMode.replace => AiWriteMode.replace,
    };

    // ---- The hold -------------------------------------------------------
    if (beforeHold != null) await beforeHold!(attempt);
    final hold = await LockGate.instance.take(dataDir);
    switch (hold.lockClass) {
      case LockClass.running:
      case LockClass.unusable:
        return ClosedWriteResult.running(hold.lockClass);
      case LockClass.noLockFile:
        return done(AiLinkCode.busy, page, openNotedOnceText);
      case LockClass.held:
        break;
    }
    // The limit is a timer, not only a check: at the limit the hold is let go
    // even while a read or a temp write is still blocked, unless the page has
    // been changed (committed).
    var expired = false;
    var committed = false;
    final timer = Timer(holdLimit, () {
      if (committed) return;
      expired = true;
      unawaited(hold.release());
    });
    bool mayCommit() {
      if (expired) return false;
      committed = true;
      return true;
    }

    // What happens under the hold: a result to give (already logged), a
    // refusal to log, a written marker, or null (look again).
    Future<Object?> held() async {
      final greeter = greets;
      if (greeter != null && await greeter()) return ClosedWriteResult.running(LockClass.running);
      if (expired) return _Refusal(AiLinkCode.busy, page);
      // ---- The re-check ---------------------------------------------------
      if (beforeRecheck != null) await beforeRecheck!(attempt);
      if (expired) return _Refusal(AiLinkCode.busy, page);
      final again = await _check(token, op);
      if (again.error != null) return ClosedWriteResult.response(again.error!);
      if (expired) return _Refusal(AiLinkCode.busy, page);
      final nowDenied = _denied(again.code!, again.view!, boxId, mode, page);
      if (nowDenied != null) return _Refusal(nowDenied.code, page, nowDenied.message);
      final same = await _eligibilityUnchanged(library, page, chain, () => expired);
      if (same == null) return _Refusal(AiLinkCode.busy, page);
      if (!same) return attempt == 0 ? null : _Refusal(AiLinkCode.busy, page);
      // ---- The read and the write -----------------------------------------
      final List<int> bytes;
      try {
        if (beforeRead != null) await beforeRead!(attempt);
        final read = await (await LockIdentity.of(dataDir)).readBytes(page.path!);
        if (read == null) return _Refusal(AiLinkCode.noBox, page);
        bytes = read;
      } on Object {
        return _Refusal(AiLinkCode.noBox, page);
      }
      if (expired) return _Refusal(AiLinkCode.busy, page);
      // The page's own settings are checked again on these exact bytes, which
      // are also what the replacement guard expects; its parents are from the
      // library load (and shown unchanged just now).
      final next = _spliced(
        bytes,
        boxId,
        code.id,
        aiMode,
        content,
        page.id,
        page.page.meta.parentId,
        chain.metas.skip(1).toList(),
        page.location.binder,
        [for (final o in others) (o.$1.metas.skip(1).toList(), o.$2)],
      );
      // The page moved under another parent since the library load: look again.
      if (next == null) return attempt == 0 ? null : _Refusal(AiLinkCode.busy, page);
      if (next is AiLinkCode) return _Refusal(next, page);
      if (expired) return _Refusal(AiLinkCode.busy, page);
      if (beforeReplace != null) await beforeReplace!(attempt);
      switch (await writer.replacePage(
        page.path!,
        expected: bytes,
        text: next as List<int>,
        alive: () => !expired,
        mayCommit: mayCommit,
      )) {
        case PageReplace.done:
          return _Written();
        case PageReplace.changed:
          return attempt == 0 ? null : _Refusal(AiLinkCode.busy, page);
        case PageReplace.busy:
          return _Refusal(AiLinkCode.busy, page);
        case PageReplace.refused:
          return _Refusal(AiLinkCode.saveFailed, page);
      }
    }

    final Object? outcome;
    try {
      outcome = await held();
    } finally {
      timer.cancel();
      // Right after the write, before the log (which is allowed at any time).
      await hold.release();
    }
    switch (outcome) {
      case null:
        return null;
      case ClosedWriteResult():
        return outcome;
      case _Refusal():
        return done(outcome.code, outcome.page, outcome.message);
      case _Written():
        await _log(writer, code, AiCodeTarget.box(boxId, page: page.id), op, aiMcpResultOk);
        return ClosedWriteResult.response(AiLinkWritten(box: boxId));
      default:
        throw StateError('unreachable');
    }
  }

  // Why the code may not write [boxId] now, from the saved store: the role, the
  // target, and (with [page] known) the box's closed-writes switch and Writer
  // permission. Null: allowed so far.
  ({AiLinkCode code, String? message})? _denied(
    AiCode code,
    AiAccessView view,
    String boxId,
    AiLinkMode mode,
    LibraryPage? page,
  ) {
    if (!code.canWriteBox) return (code: AiLinkCode.wrongRole, message: null);
    if (boxId != code.target.id) return (code: AiLinkCode.noBox, message: null);
    if (page == null) return null;
    // Only a box that allows it: off by default, and never with ask-first.
    if (!view.closedWrites(boxId)) return (code: AiLinkCode.notWritable, message: closedWritesOffText);
    if (!view.writerPermission(boxId).allows(mode)) return (code: AiLinkCode.notPermitted, message: null);
    return null;
  }

  // Keeps, of what the library load read, what this write's decision used:
  // the two JSON files, the page's binder file and the chain parents' files
  // (by their bytes), every binder file (by whether it could be read) and every
  // folder's listing, since a copy in any listed folder can make an id ambiguous.
  void _pruneSources(NotedLibrary library, LibraryPage page, _Chain chain) {
    final s = library.sources;
    if (s == null) return;
    final sep = Platform.pathSeparator;
    final keep = <String>{
      '${dataDir.path}${sep}settings.json',
      '${dataDir.path}${sep}binders.json',
      if (page.location.binder != null) NotedLibrary.binderFilePath(page.location.path),
      // A folder listed both ways: the binder file of the other entry too.
      for (final p in library.pages)
        if (p.path == page.path && p.location.binder != null) NotedLibrary.binderFilePath(p.location.path),
      // And the binder file of each folder a parent is listed in both ways.
      for (final a in chain.pages.skip(1))
        for (final p in library.pages)
          if (a.path != null && p.path == a.path && p.location.binder != null) NotedLibrary.binderFilePath(p.location.path),
      for (final p in chain.pages.skip(1))
        if (p.path != null) p.path!,
    };
    s.files.removeWhere((path, _) => !keep.contains(path));
  }

  static bool _sameBytes(List<int>? a, List<int>? b) {
    if (a == null || b == null) return a == null && b == null;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // Under the hold: whether every input of the eligibility decision is as the
  // pre-check read it. True: unchanged. False: a difference. Null: [expired]
  // says the hold is over. A difference is any change that could change which
  // ids are ambiguous for the page or its chain: a binder file's readability,
  // a listing's state, or a new or changed `.canvas` file in any listed folder
  // that can't be used and may carry any id, or reads as (or may be) one of the
  // chain's ids. Only new or changed files are read again.
  Future<bool?> _eligibilityUnchanged(
    NotedLibrary library,
    LibraryPage page,
    _Chain chain,
    bool Function() expired,
  ) async {
    final s = library.sources;
    if (s == null) return false;
    final identity = await LockIdentity.of(dataDir);
    for (final e in s.files.entries.toList()) {
      final now = await identity.readBytes(e.key);
      if (expired()) return null;
      if (!_sameBytes(now, e.value)) return false;
    }
    for (final e in s.binderUsable.entries.toList()) {
      final now = NotedLibrary.binderOf(await identity.readBytes(e.key)) != null;
      if (expired()) return null;
      if (now != e.value) return false;
    }
    final ids = <String>{for (final p in chain.pages) p.id, ?chain.endId};
    final own = <String>{for (final p in chain.pages) ?p.path};
    for (final e in s.listings.entries.toList()) {
      final (state, names) = await _list(Directory(e.key));
      if (expired()) return null;
      if (state != e.value.state) return false;
      if (state != FolderState.listed) continue;
      for (final (name, sig) in names) {
        // Left alone since the pre-check (same size and modified time): not looked at
        // again. A replacement that keeps both its size and its modified time is a
        // known rare gap (a sync client restoring mtimes).
        final was = e.value.carried[name];
        if (was != null && e.value.stats[name] == sig) continue;
        final bytes = await identity.readBytes(name);
        if (expired()) return null;
        // The lock file (or a link to it) is not a page file: it counts for nothing.
        final now = bytes == null && await identity.isLockFile(name)
            ? const FileIds({})
            : fileIdsOf(name, bytes, parsedId: bytes == null ? null : NotedLibrary.pageIdOf(bytes));
        if (expired()) return null;
        // A file that can't be used and may be any page.
        if (now.unknown) return false;
        // A page of the chain itself, rewritten by another writer: only a
        // change of what it is counts (the write re-reads it and guards it).
        if (own.contains(name)) {
          if (was == null || now != was) return false;
          continue;
        }
        // New or changed, and now (or before) one of the chain's ids.
        if (now.ids.any(ids.contains) || (was != null && was.ids.any(ids.contains))) return false;
      }
    }
    return true;
  }

  // The `*.canvas` paths in [dir], as the library lists them, and the listing's
  // state.
  static Future<(FolderState, List<(String, String)>)> _list(Directory dir) async {
    final names = <(String, String)>[];
    try {
      if (!await dir.exists()) return (FolderState.absent, names);
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.canvas')) names.add((e.path, await fileSignature(e.path)));
      }
    } on FileSystemException {
      return (FolderState.failed, const <(String, String)>[]);
    }
    return (FolderState.listed, names);
  }

  // The page's chain for module availability: the page, then its parents in
  // its own folder or binder; and the id the chain ended at, if that page was
  // missing.
  _Chain _viewBelow(LibraryPage page, _Chain above) =>
      _Chain([page.page.meta, ...above.metas], above.pages, above.endId);

  _Chain _chain(NotedLibrary library, LibraryPage page) {
    final same = {
      for (final p in library.pages)
        if (_sameTree(p, page)) p.id: p,
    };
    final pages = <LibraryPage>[page];
    final seen = <String>{page.id};
    var at = page.page.meta.parentId;
    String? end;
    while (at != null && seen.add(at)) {
      final m = same[at];
      if (m == null) {
        end = at;
        break;
      }
      pages.add(m);
      at = m.page.meta.parentId;
    }
    return _Chain([for (final p in pages) p.page.meta], pages, end);
  }

  // The new bytes of the page file [bytes] with [content] written into box
  // [boxId], or an [AiLinkCode] to refuse with, or null if the page's parent
  // is not the one [parents] was built for. Every other byte stays.
  Object? _spliced(
    List<int> bytes,
    String boxId,
    String codeId,
    AiWriteMode mode,
    String content,
    String pageId,
    String? parentId,
    List<PageMeta> parents,
    Binder? binder,
    List<(List<PageMeta>, Binder?)> otherViews,
  ) {
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
    if (page.meta.id != pageId) return AiLinkCode.noBox;
    if (page.meta.parentId != parentId) return null;
    final box = page.node(boxId);
    if (box is! BoxRecord) return AiLinkCode.noBox;
    if (box.typeId != aiBoxTypeId || isEncrypted(box)) return AiLinkCode.notWritable;
    if (!effectiveBoxTypeAllowed(box.typeId, [page.meta, ...parents], binder: binder).allowed ||
        otherViews.any((v) => !effectiveBoxTypeAllowed(box.typeId, [page.meta, ...v.$1], binder: v.$2).allowed)) {
      return AiLinkCode.notWritable;
    }
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

/// How a closed write ended: a response to give, or [runningNow] if Noted
/// turned out to be running (the caller sends the write over the link).
final class ClosedWriteResult {
  ClosedWriteResult.response(AiLinkResponse this.response) : runningNow = null;
  ClosedWriteResult.running(LockClass this.runningNow) : response = null;

  final AiLinkResponse? response;

  /// Why the server thinks Noted is running ([LockClass.running] or
  /// [LockClass.unusable]).
  final LockClass? runningNow;
}

class _Chain {
  _Chain(this.metas, this.pages, this.endId);

  final List<PageMeta> metas;
  final List<LibraryPage> pages;

  /// The id of the missing page the chain ended at, if it did.
  final String? endId;
}

class _Refusal {
  _Refusal(this.code, this.page, [this.message]);

  final AiLinkCode code;
  final LibraryPage page;
  final String? message;
}

class _Written {}
