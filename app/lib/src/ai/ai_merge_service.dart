// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';

import 'package:noted_core/noted_core.dart';

import 'ai_access_service.dart';
import 'page_ai_merge_types.dart';

/// How long a merge request waits for the page AI.
const Duration aiMergeExpiry = Duration(minutes: 10);

/// A page code counts as "connected" when it was used this recently.
const Duration aiMergeConnectedWithin = Duration(minutes: 15);

/// The most UTF-8 bytes of markdown one version of a merge may have; larger
/// boxes aren't offered to the page AI (the link carries one line of at most
/// [aiLinkMaxRequestBytes]).
const int aiMergeMaxVersionBytes = 100000;

/// The plain note box's type (the other mergeable type is the AI box).
const String _noteTypeId = 'noted.note';

/// A merge request that failed or ended without a proposal; [message] is fit
/// to show the user.
class AiMergeException implements Exception {
  const AiMergeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What the merge service needs from the notebook.
abstract interface class AiMergeHost {
  /// The ids of the pages [target] covers that an AI may read: Open or
  /// Privileged by effective access, never Guarded, never a locked binder.
  List<String> aiReadablePages(AiCodeTarget target);

  /// The page as saved in its file (after pending saves have landed); null if
  /// it can't be read. Never the live editor (invariant 4).
  Future<NotedPage?> aiSavedPage(String pageId);

  /// The type of box [boxId] on the open page [pageId] (the page whose
  /// conflict the user is looking at), or null.
  String? aiOpenBoxType(String pageId, String boxId);

  /// The codec of [typeId] if its module is on.
  BoxCodec<Object?>? aiMergeCodec(String typeId);
}

class _Version {
  _Version(this.json, this.link);

  /// The box data as stored.
  final Map<String, Object?> json;
  final AiLinkMergeVersion link;
}

class _Request {
  _Request({
    required this.id,
    required this.pageId,
    required this.boxId,
    required this.typeId,
    required this.mine,
    required this.theirs,
    required this.codec,
  });

  final String id;
  final String pageId;
  final String boxId;
  final String typeId;
  final _Version mine;
  final _Version theirs;
  final BoxCodec<Object?> codec;
  final Completer<AiMergeProposal> done = Completer<AiMergeProposal>();
  Timer? timer;

  String get key => '$pageId/$boxId';
}

/// Asking the page AI to merge a sync conflict (run 2026-11-01-04).
///
/// The user asks from the conflict dialog ([ask]). The request lives in
/// memory only: one per box, gone after [expiry], when the user withdraws it
/// ([cancel]) or when the app quits. The MCP server lists the requests its
/// code covers and answers one with a proposal through the link
/// ([pendingFor], [propose]); the app checks the code first
/// (`AiLinkAuthority`).
///
/// What the AI receives is built from the saved page file's conflict record,
/// never from the live editor (invariant 4): [ask] reads the page with
/// [AiMergeHost.aiSavedPage]. A proposal is only handed back to the dialog;
/// nothing changes until the user accepts it.
class AiMergeService implements PageAiMerge {
  AiMergeService({
    required this.access,
    required this.host,
    this.expiry = aiMergeExpiry,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AiAccessService access;
  final AiMergeHost host;
  final Duration expiry;
  final DateTime Function() _now;

  final Map<String, _Request> _byKey = {};
  int _nextId = 0;

  /// Withdraws every request (the app is closing).
  void dispose() {
    for (final r in _byKey.values.toList()) {
      _end(r, const AiMergeException('Noted was closed.'));
    }
  }

  // Availability --------------------------------------------------------------

  /// Whether [code] is a page or binder Reader code that is approved, not
  /// expired or revoked.
  bool _usable(AiCode code, DateTime now) {
    final kind = code.target.kind;
    if (kind != AiCodeTargetKind.page && kind != AiCodeTargetKind.binder) return false;
    if (code.role != AiCodeRole.reader) return false;
    if (!code.isApproved || code.isExpired(now)) return false;
    // A revoked code keeps its record.
    if (code.isRevoked) return false;
    return true;
  }

  /// A page or binder Reader code that covers [pageId], is usable and was used
  /// in the last [aiMergeConnectedWithin]; null if none.
  AiCode? _connectedCode(String pageId) {
    final now = _now().toUtc();
    final List<AiCode> codes;
    try {
      codes = access.store.codes();
    } on AiAccessUnreadable {
      return null;
    }
    for (final c in codes) {
      if (!_usable(c, now)) continue;
      final used = c.lastUsed;
      if (used == null || now.difference(used) > aiMergeConnectedWithin) continue;
      if (host.aiReadablePages(c.target).contains(pageId)) return c;
    }
    return null;
  }

  @override
  bool available(String pageId, String boxId) {
    final type = host.aiOpenBoxType(pageId, boxId);
    if (type != _noteTypeId && type != aiBoxTypeId) return false;
    return _connectedCode(pageId) != null;
  }

  // The user's side -----------------------------------------------------------

  @override
  Future<AiMergeProposal> ask(String pageId, String boxId) async {
    final key = '$pageId/$boxId';
    final already = _byKey[key];
    if (already != null) return already.done.future;
    if (!available(pageId, boxId)) {
      throw const AiMergeException('No page AI is connected to this page right now.');
    }
    final page = await host.aiSavedPage(pageId);
    final request = page == null ? null : _build(page, pageId, boxId);
    final again = _byKey[key];
    if (again != null) return again.done.future; // asked twice at once
    if (request == null) {
      throw const AiMergeException("The page AI can't be asked about this box.");
    }
    _byKey[key] = request;
    // Nobody may be listening when it ends (the dialog closed): that is not
    // an unhandled error.
    request.done.future.ignore();
    request.timer = Timer(expiry, () {
      _end(request, const AiMergeException('The page AI did not answer in time.'));
    });
    return request.done.future;
  }

  @override
  void cancel(String pageId, String boxId) {
    final r = _byKey['$pageId/$boxId'];
    if (r != null) _end(r, const AiMergeException('The request was withdrawn.'));
  }

  void _end(_Request r, AiMergeException error) {
    r.timer?.cancel();
    if (identical(_byKey[r.key], r)) _byKey.remove(r.key);
    if (!r.done.isCompleted) r.done.completeError(error);
  }

  // Building a request from the saved page ------------------------------------

  _Request? _build(NotedPage page, String pageId, String boxId) {
    final box = page.node(boxId);
    if (box is! BoxRecord) return null;
    final typeId = box.typeId;
    if (typeId != _noteTypeId && typeId != aiBoxTypeId) return null;
    if (_isEncrypted(box)) return null;
    final codec = host.aiMergeCodec(typeId);
    if (codec == null || box.dataVersion > codec.dataVersion) return null;
    final conflict = box.conflicts.where((c) => !c.deleted && c.node != null).firstOrNull;
    if (conflict == null) return null;
    final other = readNode(conflict.node!, fallbackId: boxId);
    if (other is! BoxRecord || other.typeId != typeId || other.dataVersion > codec.dataVersion) return null;
    if (_isEncrypted(other)) return null;
    final mine = _version(box, box.editedAt ?? 0, box.device);
    final theirs = _version(other, conflict.at, conflict.device ?? other.device);
    if (mine == null || theirs == null) return null;
    return _Request(
      id: 'm${_now().microsecondsSinceEpoch.toRadixString(36)}${(_nextId++).toRadixString(36)}',
      pageId: pageId,
      boxId: boxId,
      typeId: typeId,
      mine: mine,
      theirs: theirs,
      codec: codec,
    );
  }

  // A saved box's data as markdown; null if it can't be read or is too big.
  _Version? _version(BoxRecord box, int at, String? device) {
    final Object? json;
    try {
      json = box.data?.decode();
    } on FormatException {
      return null;
    }
    if (json is! Map<String, Object?> || json['document'] is! Map) return null;
    final markdown = noteToMarkdown(json, markAi: box.typeId == aiBoxTypeId);
    if (utf8.encode(markdown).length > aiMergeMaxVersionBytes) return null;
    return _Version(json, AiLinkMergeVersion(markdown: markdown, at: at, device: device));
  }

  static bool _isEncrypted(BoxRecord box) =>
      box.typeId.contains('encrypt') || box.noted.containsKey('encrypted') || box.noted.containsKey('cipher');

  // The AI's side (through the link) -----------------------------------------

  // Whether [code] may see and answer [r]: a usable page or binder code whose
  // pages include the request's page.
  bool _reaches(AiCode code, _Request r) {
    if (!_usable(code, _now().toUtc())) return false;
    return host.aiReadablePages(code.target).contains(r.pageId);
  }

  /// The pending requests [code] covers, as the link lists them. Stops before
  /// the answer would be longer than the link allows.
  List<AiLinkMergeItem> pendingFor(AiCode code) {
    final out = <AiLinkMergeItem>[];
    var size = 0;
    for (final r in _byKey.values) {
      if (!_reaches(code, r)) continue;
      final item = AiLinkMergeItem(
        id: r.id,
        page: r.pageId,
        box: r.boxId,
        type: r.typeId,
        mine: r.mine.link,
        theirs: r.theirs.link,
      );
      size += utf8.encode(jsonEncode(item.toJson())).length;
      if (size > aiLinkMaxRequestBytes - 4096) break;
      out.add(item);
    }
    return out;
  }

  /// The AI's merged [markdown] for request [requestId], as [code] sent it:
  /// attaches it to the request and wakes the dialog. `no_request` if the
  /// request is gone or [code] doesn't cover its page.
  AiLinkResponse propose(AiCode code, String requestId, String markdown) {
    _Request? r;
    for (final x in _byKey.values) {
      if (x.id == requestId) r = x;
    }
    if (r == null || !_reaches(code, r)) return AiLinkResponse.error(AiLinkCode.noRequest);
    if (markdown.trim().isEmpty) {
      return AiLinkResponse.error(AiLinkCode.badRequest, 'The merge is empty. Send the whole merged box as markdown.');
    }
    final AiMergeProposal proposal;
    try {
      proposal = _proposal(r, markdown);
    } on Object {
      return AiLinkResponse.error(AiLinkCode.badRequest, "The merge couldn't be read as markdown for this box.");
    }
    r.timer?.cancel();
    _byKey.remove(r.key);
    if (!r.done.isCompleted) r.done.complete(proposal);
    return AiLinkResponse.proposed(request: r.id);
  }

  // The box's data for the proposal, built for the box type: the note's
  // document with the markdown's blocks; for an AI box the same, with the
  // blocks the AI wrote marked as AI-written.
  AiMergeProposal _proposal(_Request r, String markdown) {
    final Map<String, Object?> json;
    if (r.typeId == aiBoxTypeId) {
      json = _aiBoxJson(r.mine.json, markdown);
    } else {
      final blocks = markdownToNoteBlocks(markdown);
      json = _withBlocks(r.mine.json, blocks);
    }
    final data = r.codec.decode(json, r.codec.dataVersion);
    return AiMergeProposal(markdown: markdown, data: data, dataVersion: r.codec.dataVersion);
  }

  static final RegExp _open = RegExp(r'^\s*<ai-written>\s*$');
  static final RegExp _close = RegExp(r'^\s*</ai-written>\s*$');

  // With `<ai-written>` lines (as the AI saw the box), the text inside them is
  // marked AI-written and the rest is not. Without any, the whole merge is
  // written as the AI's, as `write_box` with mode `replace` does.
  static Map<String, Object?> _aiBoxJson(Map<String, Object?> mine, String markdown) {
    final lines = markdown.split(RegExp(r'\r?\n'));
    final chunks = <({String text, bool ai})>[];
    var seen = false;
    var inside = false;
    var buf = <String>[];
    void flush() {
      if (buf.any((l) => l.trim().isNotEmpty)) chunks.add((text: buf.join('\n'), ai: inside));
      buf = [];
    }

    for (final line in lines) {
      if (_open.hasMatch(line)) {
        flush();
        inside = true;
        seen = true;
      } else if (_close.hasMatch(line)) {
        flush();
        inside = false;
        seen = true;
      } else {
        buf.add(line);
      }
    }
    flush();
    if (!seen) {
      return applyAiWrite(
        mine,
        AiWrite(connectionId: '', content: markdown, mode: AiWriteMode.replace),
      );
    }
    final blocks = <Map<String, Object?>>[];
    for (final c in chunks) {
      for (final b in markdownToNoteBlocks(c.text)) {
        blocks.add(c.ai ? markAiWritten(b) : b);
      }
    }
    return _withBlocks(mine, blocks);
  }

  // [json] (`{"document": {...}}` and any other keys) with [blocks] as the
  // document's children; an empty list gives one empty paragraph.
  static Map<String, Object?> _withBlocks(Map<String, Object?> json, List<Map<String, Object?>> blocks) {
    final doc = json['document'];
    final root = doc is Map
        ? <String, Object?>{for (final e in doc.entries) e.key.toString(): e.value}
        : <String, Object?>{'type': 'page'};
    return {
      ...json,
      'document': {
        ...root,
        'children': blocks.isEmpty
            ? [
                {
                  'type': 'paragraph',
                  'data': {'delta': <Object?>[]},
                },
              ]
            : blocks,
      },
    };
  }
}
