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
/// blocks, raw HTML) is kept as plain text instead: a top-level fenced code
/// block, indented code block or raw HTML block becomes one paragraph
/// holding its text exactly as written, with a line break (`\n`) between
/// lines. The text is never interpreted: HTML stays literal characters (an
/// `<img>` is only text, never an image) and code takes no formatting. Only
/// fences starting in column 0 are recognised, and code or HTML inside a
/// list item or quote is left to the decoder.
///
/// Each block is a fresh JSON-compatible map. Returns an empty list for
/// blank input.
List<Map<String, Object?>> markdownToNoteBlocks(String markdown) {
  if (markdown.trim().isEmpty) return const [];
  return [
    for (final part in _split(markdown))
      if (part.text != null) _plain(part.text!) else ..._decode(part.markdown!),
  ];
}

List<Map<String, Object?>> _decode(String markdown) {
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

Map<String, Object?> _plain(String text) => {
  'type': 'paragraph',
  'data': {
    'delta': [
      {'insert': text},
    ],
  },
};

/// Either markdown for the decoder or text to keep as it is.
class _Part {
  const _Part.markdown(String this.markdown) : text = null;
  const _Part.text(String this.text) : markdown = null;
  final String? markdown;
  final String? text;
}

final RegExp _fenceOpen = RegExp(r'^( {0,3})(`{3,}|~{3,})(.*)$');
final RegExp _listItem = RegExp(r'^\s*(?:[-*+]|\d{1,9}[.)])(?:\s|$)');

/// CommonMark's HTML block start conditions 1 to 5: the line that ends the
/// block is the first one containing the marker.
final RegExp _rawText = RegExp(
  r'^ {0,3}<(script|pre|style|textarea)(?:\s|>|$)',
  caseSensitive: false,
);

/// Condition 6: a block-level tag name; it may interrupt a paragraph.
final RegExp _blockTag = RegExp(
  r'^ {0,3}</?(?:address|article|aside|base|basefont|blockquote|body|caption|'
  r'center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|'
  r'figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|'
  r'li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|'
  r'section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)'
  r'(?:\s|/?>|$)',
  caseSensitive: false,
);

/// Condition 7: any other tag, alone on its line; it cannot interrupt a
/// paragraph. `<b>Note</b>: text` and autolinks are not this.
final RegExp _lineTag = RegExp(
  r'^ {0,3}(?:<[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>|</[A-Za-z][A-Za-z0-9-]*\s*>)\s*$',
);

/// The marker that ends an HTML block of condition 1 to 5 starting with
/// [line], or null if it is not one.
String? _htmlEnd(String line) {
  final t = line.trimLeft();
  final raw = _rawText.firstMatch(line);
  if (raw != null) return '</${raw.group(1)!.toLowerCase()}>';
  if (t.startsWith('<!--')) return '-->';
  if (t.startsWith('<?')) return '?>';
  if (t.startsWith('<![CDATA[')) return ']]>';
  if (RegExp(r'^<![A-Za-z]').hasMatch(t)) return '>';
  return null;
}
/// Cuts [markdown] into the stretches the decoder would drop (kept as text)
/// and the rest (for the decoder), in order.
List<_Part> _split(String markdown) {
  final lines = markdown.split(RegExp(r'\r\n|\r|\n'));
  final parts = <_Part>[];
  final rest = <String>[];
  // Whether the last column-0 line in [rest] is a list item, so indented text
  // belongs to it. Kept as a running flag: no scanning back per line.
  var inList = false;
  void flush() {
    if (rest.isEmpty) return;
    parts.add(_Part.markdown(rest.join('\n')));
    rest.clear();
    inList = false;
  }

  void keep(List<String> block) {
    flush();
    // Blank lines at either end are separators, not content.
    var a = 0;
    var b = block.length;
    while (a < b && block[a].trim().isEmpty) {
      a++;
    }
    while (b > a && block[b - 1].trim().isEmpty) {
      b--;
    }
    if (a < b) parts.add(_Part.text(block.sublist(a, b).join('\n')));
  }

  bool indented(String l) => l.startsWith('    ') || l.startsWith('\t');

  var blankBefore = true;
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final fence = _fenceOpen.firstMatch(line);
    final indent = fence?.group(1)?.length ?? 0;
    if (fence != null &&
        !(fence.group(2)!.startsWith('`') && fence.group(3)!.contains('`')) &&
        (indent == 0 || !inList)) {
      final mark = fence.group(2)!;
      final close = RegExp('^ {0,3}${RegExp.escape(mark[0])}{${mark.length},}\\s*\$');
      final body = <String>[];
      i++;
      while (i < lines.length) {
        if (close.hasMatch(lines[i])) {
          i++;
          break;
        }
        // Up to the opener's indent comes off each line.
        final l = lines[i];
        var cut = 0;
        while (cut < indent && cut < l.length && l[cut] == ' ') {
          cut++;
        }
        body.add(l.substring(cut));
        i++;
      }
      keep(body);
      blankBefore = false;
      continue;
    }
    final startsBlock = blankBefore && line.trim().isNotEmpty;
    if (startsBlock && indented(line) && !inList) {
      final body = <String>[];
      while (i < lines.length && (lines[i].trim().isEmpty || indented(lines[i]))) {
        final l = lines[i];
        body.add(l.startsWith('\t') ? l.substring(1) : l.trim().isEmpty ? '' : l.substring(4));
        i++;
      }
      keep(body);
      blankBefore = true;
      continue;
    }
    // Conditions 1 to 6 start a block even in the middle of a paragraph;
    // condition 7 only after a blank line.
    final end = _htmlEnd(line);
    final html = end != null ||
        _blockTag.hasMatch(line) ||
        (startsBlock && _lineTag.hasMatch(line));
    // Indented under a list item, HTML belongs to the item.
    if (html && line.trim().isNotEmpty && !(inList && line.startsWith(' '))) {
      final body = <String>[];
      if (end == null) {
        while (i < lines.length && lines[i].trim().isNotEmpty) {
          body.add(lines[i]);
          i++;
        }
      } else {
        while (i < lines.length) {
          body.add(lines[i]);
          i++;
          if (body.last.toLowerCase().contains(end)) break;
        }
      }
      keep(body);
      blankBefore = false;
      continue;
    }
    rest.add(line);
    if (line.trim().isNotEmpty && !line.startsWith(' ') && !line.startsWith('\t')) {
      inList = _listItem.hasMatch(line);
    }
    blankBefore = line.trim().isEmpty;
    i++;
  }
  flush();
  return parts;
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
