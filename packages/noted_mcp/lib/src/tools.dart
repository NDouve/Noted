// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:noted_core/noted_core_read.dart';

import 'library.dart';

/// What a tool returns: text for the AI, and whether it is an error.
typedef ToolOutput = ({String text, bool isError});

/// The text a tool gives for a page that doesn't exist or that AI can't
/// see: the same either way, so an Off page can't be told from no page.
String noSuchPage(String id) => 'No page with id "$id".';

/// The box types the server can render, by type id. Any other box
/// (unsupported, or from a newer module) is a placeholder.
const Map<String, String> boxTypeNames = {
  'noted.note': 'note',
  'noted.drawing': 'drawing',
  'noted.image': 'image',
  'noted.file': 'file',
  aiBoxTypeId: 'ai',
};

/// The tools of the read-only MCP server, over [library].
///
/// Enforced on every call, from the page AI setting (0028):
/// - Off pages are invisible: not listed, not found, not searched, and a
///   link to one keeps only its text.
/// - Box only pages are listed and their titles searched; the only box
///   content given out is the AI's own boxes (AI boxes whose owner is the
///   connection of [token]).
/// - Whole page pages can be read in full.
/// - Encrypted and unsupported boxes are always a placeholder, never their
///   data. Pages of locked binders are not in [library] at all.
///
/// The AI's identity is the connection id in [token] (`NOTED_TOKEN`), and it
/// counts only while that id is listed in `settings.json`, read afresh with
/// [library]. This process cannot check the token's secret half (no hashing
/// is allowed here, invariant 4), so reads are scoped by the id alone; the
/// app verifies the whole token on every write.
final class NotedTools {
  NotedTools(this.library, {String? token}) : connectionId = _listedId(library, token);

  final NotedLibrary library;

  /// The id of the connection this server acts as, or null: no token, a
  /// malformed one, or one whose connection is no longer listed (revoked).
  /// With null the server behaves as if it had no token.
  final String? connectionId;

  static String? _listedId(NotedLibrary library, String? token) {
    final id = token == null ? null : parseAiToken(token)?.id;
    if (id == null) return null;
    return library.connections.any((c) => c.id == id) ? id : null;
  }

  bool _isOwn(CanvasNode n) =>
      connectionId != null &&
      n is BoxRecord &&
      n.typeId == aiBoxTypeId &&
      !isEncrypted(n) &&
      aiBoxOwner(_decode(n)) == connectionId;

  /// The AI's own boxes on [p], in reading order.
  List<CanvasNode> _ownBoxes(LibraryPage p) => [
    for (final n in readingOrder(p.page.nodes))
      if (_isOwn(n)) n,
  ];

  /// The pages AI may know about.
  List<LibraryPage> get visible => [
    for (final p in library.pages)
      if (p.ai != AiSetting.off) p,
  ];

  LibraryPage? _visiblePage(String id) {
    final p = library.page(id);
    return p == null || p.ai == AiSetting.off ? null : p;
  }

  // ---------------------------------------------------------------------------
  // list_pages

  /// The page tree AI can see: each page's id, title, parent (its nearest
  /// visible ancestor, so an Off page in between is not revealed), AI
  /// setting and folder or binder, as JSON.
  ToolOutput listPages() {
    final shown = {for (final p in visible) p.id: p};
    String? parentOf(LibraryPage p) {
      final metas = {for (final q in library.pages) q.id: q.page.meta};
      final seen = <String>{p.id};
      var at = p.page.meta.parentId;
      while (at != null && seen.add(at)) {
        if (shown.containsKey(at)) return at;
        at = metas[at]?.parentId;
      }
      return null;
    }

    final pages = [
      for (final p in shown.values)
        {
          'id': p.id,
          'title': p.title,
          'parent': parentOf(p),
          'ai': p.ai.value,
          'location': p.location.name,
        },
    ];
    pages.sort((a, b) {
      final l = '${a['location']}'.compareTo('${b['location']}');
      return l != 0 ? l : '${a['title']}'.compareTo('${b['title']}');
    });
    return (text: const JsonEncoder.withIndent('  ').convert({'pages': pages}), isError: false);
  }

  // ---------------------------------------------------------------------------
  // read_page and read_box

  /// The page as markdown: its title, then each box in reading order (top
  /// to bottom, then left to right) with its type and content.
  ToolOutput readPage(String id) {
    final p = _visiblePage(id);
    if (p == null) return (text: noSuchPage(id), isError: true);
    final b = StringBuffer('# ${p.title}\n');
    if (p.ai == AiSetting.boxOnly) {
      final own = _ownBoxes(p);
      if (own.isEmpty) b.write('\n${_boxOnlyNote(p)}\n');
      for (final n in own) {
        b.write('\n${_boxBlock(n)}\n');
      }
      return (text: b.toString(), isError: false);
    }
    final nodes = readingOrder(p.page.nodes);
    if (nodes.isEmpty) b.write('\n(This page has no boxes.)\n');
    for (final n in nodes) {
      b.write('\n${_boxBlock(n)}\n');
    }
    return (text: b.toString(), isError: false);
  }

  /// One box of a page, as in [readPage].
  ToolOutput readBox(String pageId, String boxId) {
    final p = _visiblePage(pageId);
    if (p == null) return (text: noSuchPage(pageId), isError: true);
    CanvasNode? node;
    for (final n in p.page.nodes) {
      if (n.id == boxId) node = n;
    }
    if (node == null) return (text: 'No box with id "$boxId" on page "$pageId".', isError: true);
    // On a Box only page another box answers as a missing one does.
    if (p.ai == AiSetting.boxOnly && !_isOwn(node)) {
      return (text: 'No box with id "$boxId" on page "$pageId".', isError: true);
    }
    return (text: _boxBlock(node), isError: false);
  }

  String _boxOnlyNote(LibraryPage p) =>
      'This page\'s AI setting is Box only: you read only your own AI boxes '
      'there, and you have none on it, so the rest of the page is not shared.';

  String _boxBlock(CanvasNode n) =>
      '**${boxType(n)}** · box `${n.id}`${_isOwn(n) ? ' · your box' : ''}\n\n${boxText(n)}';

  // ---------------------------------------------------------------------------
  // list_my_boxes

  /// The AI's own boxes on pages that aren't Off, as JSON. Without a listed
  /// token this is an error that says how to get one.
  ToolOutput listMyBoxes() {
    if (connectionId == null) {
      return (
        text:
            'No valid AI connection token. Create a connection in Noted (gear '
            'menu > AI connections) and give its token to this server as the '
            'NOTED_TOKEN environment variable. A revoked token no longer works.',
        isError: true,
      );
    }
    final boxes = [
      for (final p in visible)
        for (final n in _ownBoxes(p))
          {'page_id': p.id, 'page_title': p.title, 'box_id': n.id, 'ai': p.ai.value},
    ];
    return (text: const JsonEncoder.withIndent('  ').convert({'boxes': boxes}), isError: false);
  }

  /// The kind of box [n] is: note, drawing, image, file, encrypted or
  /// unsupported.
  String boxType(CanvasNode n) {
    if (n is! BoxRecord) return 'unsupported';
    if (isEncrypted(n)) return 'encrypted';
    return boxTypeNames[n.typeId] ?? 'unsupported';
  }

  /// The content of box [n] as text for AI: a note as markdown, a drawing
  /// as `[drawing]`, an image as `[image: alt]`, a file as `[file: name]`,
  /// and any other box as a placeholder that holds none of its data.
  String boxText(CanvasNode n) {
    switch (boxType(n)) {
      case 'encrypted':
        return '[encrypted box]';
      case 'unsupported':
        return '[unsupported box]';
      case 'drawing':
        return '[drawing]';
    }
    final box = n as BoxRecord;
    final data = _decode(box);
    switch (box.typeId) {
      case 'noted.note':
        return noteToMarkdown(data, linkTarget: _linkTarget);
      case aiBoxTypeId:
        return noteToMarkdown(data, markAi: true, linkTarget: _linkTarget);
      case 'noted.image':
        final alt = data is Map && data['alt'] is String ? (data['alt']! as String).trim() : '';
        return '[image: $alt]';
      case 'noted.file':
        final file = data is Map ? data['file'] : null;
        final name = file is Map && file['name'] is String ? file['name']! as String : '';
        return '[file: $name]';
    }
    return '[unsupported box]';
  }

  Object? _decode(BoxRecord box) {
    try {
      return box.data?.decode();
    } on Object {
      return null;
    }
  }

  // A link to a page (`noted:` address with a page id) to a page AI can't
  // see keeps only its text; other addresses are written as they are.
  String? _linkTarget(String href) {
    if (!href.startsWith('noted:')) return href;
    final id = RegExp(r'[0-9a-f]{16}').firstMatch(href)?.group(0);
    if (id == null || _visiblePage(id) == null) return null;
    return href;
  }

  // ---------------------------------------------------------------------------
  // search

  /// Pages whose title, or (Whole page only) text, holds every word of
  /// [query], as JSON with a snippet of each match.
  ToolOutput search(String query) {
    final q = SearchQuery.parse(query);
    if (q.isEmpty) return (text: 'Give one or more words to search for.', isError: true);
    final results = <Map<String, Object?>>[];
    for (final p in visible) {
      final matches = <String>[];
      if (q.rangesIn(p.title) != null) matches.add('title: ${p.title}');
      // Whole page: every box; Box only: the AI's own boxes.
      {
        final nodes = p.ai == AiSetting.wholePage ? readingOrder(p.page.nodes) : _ownBoxes(p);
        for (final n in nodes) {
          final text = boxText(n);
          final ranges = q.rangesIn(text);
          if (ranges != null) matches.add('box ${n.id}: ${snippetOf(text, ranges).text}');
        }
      }
      if (matches.isNotEmpty) {
        results.add({'id': p.id, 'title': p.title, 'ai': p.ai.value, 'matches': matches});
      }
    }
    return (text: const JsonEncoder.withIndent('  ').convert({'query': query, 'results': results}), isError: false);
  }
}

/// [nodes] in reading order: top to bottom, then left to right. Nodes
/// without a position come last, in file order.
List<CanvasNode> readingOrder(List<CanvasNode> nodes) {
  final placed = [for (final n in nodes) if (n.bounds != null) n];
  final rest = [for (final n in nodes) if (n.bounds == null) n];
  placed.sort((a, b) {
    final y = a.bounds!.y.compareTo(b.bounds!.y);
    return y != 0 ? y : a.bounds!.x.compareTo(b.bounds!.x);
  });
  return [...placed, ...rest];
}

/// Whether box [box] is encrypted (binder passwords, a later phase): an
/// encrypted box type, or a header that says so. Its data is never read.
bool isEncrypted(BoxRecord box) =>
    box.typeId.contains('encrypt') || box.noted.containsKey('encrypted') || box.noted.containsKey('cipher');
