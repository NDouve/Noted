// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';

import 'package:noted_canvas/noted_canvas.dart' show AiMergeProposal, PageAiMerge;
import 'package:noted_core/noted_core.dart';

import 'ai_access_service.dart';

/// How long a merge request waits for the page AI.
const Duration aiMergeExpiry = Duration(minutes: 10);

/// A page code counts as "connected" when it was used this recently.
const Duration aiMergeConnectedWithin = Duration(minutes: 15);

/// The most UTF-8 bytes of markdown one version of a merge may have; larger
/// boxes aren't offered to the page AI. `noted_mcp` applies the same limit
/// when it renders the versions.
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
  /// it can't be read.
  Future<NotedPage?> aiSavedPage(String pageId);

  /// Box [boxId] on the open page [pageId] (the page whose conflict the user
  /// is looking at), or null.
  BoxRecord? aiOpenBox(String pageId, String boxId);

  /// Whether box type [typeId] is allowed on page [pageId] (0111).
  bool aiMergeTypeAllowed(String pageId, String typeId);

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
}

// One ask, from the click to its end. It exists while the saved page is still
// being read ([request] null), so a cancel in that time wins.
class _Ask {
  _Ask(this.key);

  final String key;
  final Completer<AiMergeProposal> done = Completer<AiMergeProposal>();
  Timer? timer;
  _Request? request;
}

/// Asking the page AI to merge a sync conflict (run 2026-11-01-04).
///
/// The user asks from the conflict dialog ([ask]). The request lives in
/// memory only: one per box, gone after [expiry], when the user withdraws it
/// ([cancel]) or when the app quits. The app gives the MCP server a grant,
/// not content: [pendingFor] lists request ids, pages, boxes and the versions'
/// device and time. The server reads the saved page file's conflict record and
/// renders both versions itself, with its own checks (invariant 4). The AI
/// answers with [propose]; the app checks the code first (`AiLinkAuthority`).
/// A proposal is only handed back to the dialog; nothing changes until the
/// user accepts it.
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

  final Map<String, _Ask> _asks = {};
  int _nextId = 0;

  /// Withdraws every request (the app is closing).
  void dispose() {
    for (final a in _asks.values.toList()) {
      _end(a, const AiMergeException('Noted was closed.'));
    }
  }

  // Availability --------------------------------------------------------------

  /// Whether [code] is a page or binder Reader code that is approved, not
  /// expired and not revoked.
  bool _usable(AiCode code, DateTime now) {
    final kind = code.target.kind;
    if (kind != AiCodeTargetKind.page && kind != AiCodeTargetKind.binder) return false;
    if (code.role != AiCodeRole.reader) return false;
    return code.isApproved && !code.isExpired(now) && !code.isRevoked;
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

  // The first recorded other version that is a box, not a deletion.
  static BoxConflict? _conflictOf(BoxRecord box) {
    for (final c in box.conflicts) {
      if (!c.deleted && c.node != null) return c;
    }
    return null;
  }

  @override
  bool available(String pageId, String boxId) {
    final box = host.aiOpenBox(pageId, boxId);
    if (box == null || (box.typeId != _noteTypeId && box.typeId != aiBoxTypeId)) return false;
    // The module is on, the page allows the type (0111), and there is
    // something to merge.
    if (host.aiMergeCodec(box.typeId) == null || !host.aiMergeTypeAllowed(pageId, box.typeId)) return false;
    if (_conflictOf(box) == null) return false;
    return _connectedCode(pageId) != null;
  }

  // The user's side -----------------------------------------------------------

  @override
  Future<AiMergeProposal> ask(String pageId, String boxId) async {
    final key = '$pageId/$boxId';
    final already = _asks[key];
    if (already != null) return already.done.future;
    if (!available(pageId, boxId)) {
      throw const AiMergeException('No page AI is connected to this page right now.');
    }
    final a = _Ask(key);
    _asks[key] = a;
    // Nobody may be listening when it ends (the dialog closed): that is not
    // an unhandled error.
    a.done.future.ignore();
    a.timer = Timer(expiry, () => _end(a, const AiMergeException('The page AI did not answer in time.')));
    final NotedPage? page;
    try {
      page = await host.aiSavedPage(pageId);
    } on Object {
      _end(a, const AiMergeException("The page couldn't be read."));
      return a.done.future;
    }
    // Cancelled, closed or expired while the file was read: that stands.
    if (!identical(_asks[key], a) || a.done.isCompleted) return a.done.future;
    final request = page == null ? null : _build(page, pageId, boxId);
    if (request == null) {
      _end(a, const AiMergeException("The page AI can't be asked about this box."));
      return a.done.future;
    }
    a.request = request;
    return a.done.future;
  }

  @override
  void cancel(String pageId, String boxId) {
    final a = _asks['$pageId/$boxId'];
    if (a != null) _end(a, const AiMergeException('The request was withdrawn.'));
  }

  void _end(_Ask a, AiMergeException error) {
    a.timer?.cancel();
    if (identical(_asks[a.key], a)) _asks.remove(a.key);
    if (!a.done.isCompleted) a.done.completeError(error);
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
    final conflict = _conflictOf(box);
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

  // A saved box's data; null if it can't be read or is too big to offer.
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
    return _Version(json, AiLinkMergeVersion(at: at, device: device));
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

  /// The pending requests [code] covers, as the link lists them: a grant with
  /// no content. Every request is listed (they are small, and one per box).
  List<AiLinkMergeItem> pendingFor(AiCode code) {
    final out = <AiLinkMergeItem>[];
    for (final a in _asks.values) {
      final r = a.request;
      if (r == null || !_reaches(code, r)) continue;
      out.add(
        AiLinkMergeItem(
          id: r.id,
          page: r.pageId,
          box: r.boxId,
          type: r.typeId,
          mine: r.mine.link,
          theirs: r.theirs.link,
        ),
      );
    }
    return out;
  }

  /// The AI's merged [markdown] for request [requestId], as [code] sent it:
  /// attaches it to the request and wakes the dialog. `no_request` if the
  /// request is gone or [code] doesn't cover its page.
  AiLinkResponse propose(AiCode code, String requestId, String markdown) {
    _Ask? ask;
    for (final a in _asks.values) {
      if (a.request?.id == requestId) ask = a;
    }
    final r = ask?.request;
    if (ask == null || r == null || !_reaches(code, r)) return AiLinkResponse.error(AiLinkCode.noRequest);
    if (utf8.encode(markdown).length > 2 * aiMergeMaxVersionBytes) {
      return AiLinkResponse.error(AiLinkCode.badRequest, 'The merge is too long. Send the merged box only.');
    }
    // The AI's own <ai-written> lines carry no meaning here: marks come from
    // the two versions (see _proposal).
    final text = _stripMarkers(markdown);
    if (text.trim().isEmpty) {
      return AiLinkResponse.error(AiLinkCode.badRequest, 'The merge is empty. Send the whole merged box as markdown.');
    }
    final AiMergeProposal proposal;
    try {
      proposal = _proposal(r, text, code.label.isEmpty ? null : code.label);
    } on Object {
      return AiLinkResponse.error(AiLinkCode.badRequest, "The merge couldn't be read as markdown for this box.");
    }
    ask.timer?.cancel();
    _asks.remove(ask.key);
    if (!ask.done.isCompleted) ask.done.complete(proposal);
    return AiLinkResponse.proposed(request: r.id);
  }

  static final RegExp _marker = RegExp(r'^\s*</?ai-written>\s*$');

  static String _stripMarkers(String markdown) =>
      markdown.split(RegExp(r'\r?\n')).where((l) => !_marker.hasMatch(l)).join('\n');

  // A top-level block as markdown: two blocks that say the same thing render
  // the same.
  static String _blockText(Object? block, {String? Function(String href)? linkTarget}) => noteToMarkdown({
    'document': {
      'type': 'page',
      'children': [block],
    },
  }, linkTarget: linkTarget);

  // The server shows a link to a page the AI can't see as its text only, and
  // the importer drops links it doesn't keep (`noted:`, `file:`, other
  // schemes): an exact echo of such a block comes back without the link.
  static String? _textOnlyInternalLinks(String href) {
    final h = href.toLowerCase();
    return h.startsWith('http://') || h.startsWith('https://') || h.startsWith('mailto:') ? href : null;
  }

  // The markdown a block of the original comes back as: the ways the AI may
  // have seen it (as saved, or with internal links reduced to their text),
  // each also taken through the importer as an echo would be.
  static Set<String> _echoes(Map<String, Object?> block) {
    final out = <String>{};
    for (final seen in [_blockText(block), _blockText(block, linkTarget: _textOnlyInternalLinks)]) {
      if (seen.trim().isEmpty) continue;
      out.add(seen);
      final back = markdownToNoteBlocks(seen);
      if (back.length == 1) out.add(_blockText(back.single));
    }
    return out;
  }

  static List<Map<String, Object?>> _blocksOf(Map<String, Object?> json) {
    final doc = json['document'];
    final kids = doc is Map ? doc['children'] : null;
    return [
      if (kids is List)
        for (final k in kids)
          if (k is Map) {for (final e in k.entries) e.key.toString(): e.value},
    ];
  }

  // The box's data for the proposal. The marks come from the two versions,
  // not from the AI: a block of the proposal that says what a block of mine
  // or theirs says is that block, verbatim (its AI mark or its lack of one,
  // formulas, links and styles included; a text the two versions have in
  // different forms matches neither). A block
  // in neither is new: AI-written in an AI box, plain in a note box.
  AiMergeProposal _proposal(_Request r, String markdown, String? by) {
    // Markdown a block comes back as, to the block it is. A text that two
    // different blocks (say, one in each version, differing only in
    // formatting) share is ambiguous: it maps to null, matches neither, and
    // so the block counts as new rather than silently taking one of them.
    final known = <String, Map<String, Object?>?>{};
    final encoded = <String, String>{};
    // For an ambiguous text: whether some block it could be is the user's
    // (not AI-written). Then the block is never marked AI-written: the user's
    // own text must not become the AI's (0117's Edit could then replace it).
    final userCandidate = <String, bool>{};
    for (final v in [r.mine, r.theirs]) {
      for (final b in _blocksOf(v.json)) {
        final json = jsonEncode(b);
        final user = !isAiWritten(b);
        for (final text in _echoes(b)) {
          userCandidate[text] = (userCandidate[text] ?? false) || user;
          if (!known.containsKey(text)) {
            known[text] = b;
            encoded[text] = json;
          } else if (encoded[text] != json) {
            known[text] = null;
          }
        }
      }
    }
    final blocks = <Map<String, Object?>>[];
    for (final b in markdownToNoteBlocks(markdown)) {
      final text = _blockText(b);
      final same = known[text];
      if (same != null) {
        blocks.add(same);
      } else if (known.containsKey(text) && userCandidate[text] == true) {
        // Ambiguous, and possibly the user's: kept as plain text.
        blocks.add(b);
      } else {
        blocks.add(r.typeId == aiBoxTypeId ? markAiWritten(b) : b);
      }
    }
    final json = _withBlocks(r.mine.json, blocks);
    final data = r.codec.decode(json, r.codec.dataVersion);
    return AiMergeProposal(markdown: markdown, data: data, dataVersion: r.codec.dataVersion, by: by);
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
