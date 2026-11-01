// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:noted_core/noted_core_read.dart';

import 'library.dart';

/// What a tool returns: text for the AI, and whether it is an error.
typedef ToolOutput = ({String text, bool isError});

/// The text a tool gives for a page that doesn't exist or that AI can't
/// see: the same either way, so a Privileged or Guarded page can't be told
/// from no page.
String noSuchPage(String id) => 'No page with id "$id".';

/// The text for a box that isn't there, or that the AI may not read.
String noSuchBox(String id) => 'No box with id "$id".';

/// The box types the server can render, by type id. Any other box
/// (unsupported, or from a newer module) is a placeholder.
const Map<String, String> boxTypeNames = {
  'noted.note': 'note',
  'noted.drawing': 'drawing',
  'noted.image': 'image',
  'noted.file': 'file',
  aiBoxTypeId: 'ai',
};

/// The page-reading tools of the MCP server, over [library].
///
/// Enforced on every call, from the page AI access (0100):
/// - Without a code only Open pages exist. Privileged and Guarded pages are
///   invisible: not listed, not found, not searched, and a link to one keeps
///   only its text.
/// - With a page or binder code the app answers with the pages the code
///   covers ([granted]); those Privileged pages are visible too. A Guarded
///   page is never visible, whatever [granted] holds (the app doesn't list
///   one; this is a second check).
/// - On a visible page every box can be read, AI boxes included (what an AI
///   wrote carries its marker). Encrypted and unsupported boxes are always a
///   placeholder, never their data.
/// - Pages in locked binders are never visible.
///
/// The server doesn't check codes: the app does, then gives a grant, and
/// [granted] and [readGrantedBox] only read saved files for what it granted.
final class NotedTools {
  /// [granted] are the ids of the Privileged pages the app said the code
  /// may read. With [openPages] false no page is visible at all (a box code:
  /// the AI sees that box and nothing else).
  NotedTools(this.library, {Set<String> granted = const {}, this.openPages = true})
    : granted = Set.unmodifiable(granted);

  final NotedLibrary library;
  final Set<String> granted;
  final bool openPages;

  bool _canRead(LibraryPage p) {
    if (p.locked) return false;
    return switch (p.access) {
      AiAccess.open => openPages,
      AiAccess.privileged => granted.contains(p.id),
      AiAccess.guarded => false,
    };
  }

  /// The pages AI may know about, in a stable order.
  List<LibraryPage> get visible => [
    for (final p in library.pages)
      if (_canRead(p)) p,
  ]..sort((a, b) => a.id.compareTo(b.id));

  LibraryPage? _visiblePage(String id) {
    final p = library.page(id);
    return p == null || !_canRead(p) ? null : p;
  }

  // ---------------------------------------------------------------------------
  // list_pages

  /// The page tree AI can see: each page's id, title, parent (its nearest
  /// visible ancestor, so a hidden page in between is not revealed), access
  /// and folder or binder, as JSON.
  ToolOutput listPages() {
    final shown = {for (final p in visible) p.id: p};
    final metas = {for (final q in library.pages) q.id: q.page.meta};
    String? parentOf(LibraryPage p) {
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
          'access': p.access.value,
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
    final nodes = readingOrder(p.page.nodes);
    if (nodes.isEmpty) b.write('\n(This page has no boxes.)\n');
    for (final n in nodes) {
      b.write('\n${_boxBlock(n)}\n');
    }
    return (text: b.toString(), isError: false);
  }

  /// The box [boxId] on a visible page, as [readPage] shows it. A box id is
  /// only unique on its page: with [pageId] only that page is looked at;
  /// without it, if several visible pages have the id, the first page by id
  /// answers.
  ToolOutput readBox(String boxId, {String? pageId}) {
    for (final p in visible) {
      if (pageId != null && pageId.isNotEmpty && p.id != pageId) continue;
      for (final n in p.page.nodes) {
        if (n.id == boxId) return (text: _boxBlock(n), isError: false);
      }
    }
    return (text: noSuchBox(boxId), isError: true);
  }

  /// The AI box a box code was granted, read from its saved page. Nothing of
  /// the page is given, not its title or id, and a link to a page keeps only
  /// its text. A grant for a box that isn't an AI box, or isn't on the
  /// page, answers as a missing box.
  ToolOutput readGrantedBox(AiLinkBoxGrant grant) {
    final p = library.page(grant.page);
    CanvasNode? node;
    if (p != null) {
      for (final n in p.page.nodes) {
        if (n.id == grant.box) node = n;
      }
    }
    if (node is! BoxRecord || node.typeId != aiBoxTypeId) {
      return (text: noSuchBox(grant.box), isError: true);
    }
    return (text: _boxBlock(node), isError: false);
  }

  String _boxBlock(CanvasNode n) => '**${boxType(n)}** · box `${n.id}`\n\n${boxText(n)}';

  /// The kind of box [n] is: note, drawing, image, file, ai, encrypted or
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

  /// Pages whose title or text holds every word of [query], as JSON with a
  /// snippet of each match. Only visible pages are looked at.
  ToolOutput search(String query) {
    final q = SearchQuery.parse(query);
    if (q.isEmpty) return (text: 'Give one or more words to search for.', isError: true);
    final results = <Map<String, Object?>>[];
    for (final p in visible) {
      final matches = <String>[];
      if (q.rangesIn(p.title) != null) matches.add('title: ${p.title}');
      for (final n in readingOrder(p.page.nodes)) {
        final text = boxText(n);
        final ranges = q.rangesIn(text);
        if (ranges != null) matches.add('box ${n.id}: ${snippetOf(text, ranges).text}');
      }
      if (matches.isNotEmpty) {
        results.add({'id': p.id, 'title': p.title, 'access': p.access.value, 'matches': matches});
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
