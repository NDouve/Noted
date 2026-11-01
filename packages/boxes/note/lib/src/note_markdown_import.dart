// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart' show markdownToDocument;

import 'note_codec.dart';

/// Turns [markdown] into the top-level blocks of a note document (the
/// `children` of the page node of `{"document": {...}}`), in the form the
/// note module stores them.
///
/// appflowy's markdown decoder does the parsing: headings, paragraphs (bold,
/// italic, strikethrough, code and links), bulleted, numbered and check
/// lists (nested by indenting), quotes, dividers, and tables. On top of it:
/// a paragraph that is only `$$ … $$` becomes an equation block, and an
/// inline `$…$` equation takes the one character the note stores for it
/// ([NoteFormat.inlineMathChar]). What the decoder leaves out (fenced code
/// blocks, raw HTML) is not imported.
///
/// Each block is a fresh JSON-compatible map. Returns an empty list for
/// blank input.
List<Map<String, Object?>> markdownToNoteBlocks(String markdown) {
  if (markdown.trim().isEmpty) return const [];
  final json = markdownToDocument(markdown).toJson();
  final copy = jsonDecode(jsonEncode(json)) as Map<String, Object?>;
  final root = copy['document'];
  final children = root is Map ? root['children'] : null;
  if (children is! List) return const [];
  return [
    for (final c in children)
      if (c is Map<String, Object?> && _allowed.contains(c['type'])) _fix(c),
  ];
}

/// The block types an import keeps. Anything else is dropped, in particular
/// images: the editor would fetch an image's address (a remote URL or a
/// network path) as soon as the page opens, with no click.
const Set<Object?> _allowed = {
  'paragraph',
  'heading',
  'todo_list',
  'bulleted_list',
  'numbered_list',
  'quote',
  'divider',
  'table',
  'table/cell',
  NoteFormat.mathBlockType,
};

/// Links keep their address only for these schemes.
bool _safeHref(Object? href) {
  if (href is! String) return false;
  final m = RegExp(r'^\s*([a-zA-Z][a-zA-Z0-9+.-]*):').firstMatch(href);
  if (m == null) return false;
  return const {'http', 'https', 'mailto'}.contains(m.group(1)!.toLowerCase());
}

final RegExp _mathBlock = RegExp(r'^\$\$\s*([\s\S]*?)\s*\$\$$');

Map<String, Object?> _fix(Map<String, Object?> node) {
  final data = node['data'];
  if (node['type'] == 'paragraph' && data is Map<String, Object?>) {
    final delta = data['delta'];
    if (delta is List && delta.length == 1) {
      final op = delta.first;
      final text = op is Map ? op['insert'] : null;
      final plain = op is Map && op['attributes'] == null;
      final m = text is String && plain ? _mathBlock.firstMatch(text.trim()) : null;
      if (m != null && m.group(1)!.isNotEmpty) {
        return {
          'type': NoteFormat.mathBlockType,
          'data': {NoteFormat.formulaKey: m.group(1)},
        };
      }
    }
  }
  if (data is Map<String, Object?> && data['delta'] is List) {
    for (final op in data['delta']! as List) {
      final attrs = op is Map ? op['attributes'] : null;
      if (op is Map && attrs is Map && attrs[NoteFormat.formulaKey] is String) {
        op['insert'] = NoteFormat.inlineMathChar;
      }
      if (op is Map && attrs is Map && attrs.containsKey('href')) {
        if (!_safeHref(attrs['href'])) attrs.remove('href');
        if (attrs.isEmpty) op.remove('attributes');
      }
    }
  }
  final kids = node['children'];
  if (kids is List) {
    node['children'] = [
      for (final k in kids)
        if (k is Map<String, Object?> && _allowed.contains(k['type'])) _fix(k),
    ];
  }
  return node;
}
