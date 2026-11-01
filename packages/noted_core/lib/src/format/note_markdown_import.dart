// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

/// The block types an import keeps, as the note module stores them
/// (`NoteFormat` in the note package; a test there keeps them equal).
const String _mathBlockType = 'math_equation';
const String _formulaKey = 'formula';
final String _inlineMathChar = String.fromCharCode(0xFFFC);

/// Turns [markdown] into the top-level blocks of a note document (the
/// `children` of the page node of `{"document": {...}}`), in the form the
/// note module stores them.
///
/// Pure Dart on `package:markdown`, with the block mapping the note module
/// used when appflowy's markdown decoder did this: headings, paragraphs (bold, italic,
/// strikethrough, code and links), bulleted, numbered and check
/// lists (nested by indenting), quotes, dividers, and tables. On top of it:
/// a paragraph that is only `$$ … $$` becomes an equation block, and an
/// inline `$…$` equation takes the one character the note stores for it
/// (`NoteFormat.inlineMathChar`). What the decoder leaves out (fenced code
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
  final budget = _Budget();
  return [
    for (final part in _split(markdown))
      if (part.text != null) _plain(part.text!) else ..._decode(part.markdown!, budget),
  ];
}

// ---- Bounds ---------------------------------------------------------------
//
// package:markdown is not linear: an unmatched run of `*`, `_`, `<u>`, `[`,
// `![`, `~~`, or many link reference definitions, takes time that grows with
// the square of the input, and deep nesting (`>`, `- ` or `*` repeated)
// overflows the stack. The markdown the decoder gets is therefore cut at
// blank lines into chunks, and chunks are decoded in groups that stay under
// these limits. A chunk that is over a limit by itself is kept as one plain
// paragraph (its text as written, never interpreted), and so is a chunk the
// decoder fails on.

/// The most inline delimiters the decoder is given in one import, however
/// the input is grouped: this bounds the total cost. Chunks past it are kept
/// as plain paragraphs.
const int _maxImportDelimiters = 20000;

/// What is left of [_maxImportDelimiters] in one import.
class _Budget {
  int left = _maxImportDelimiters;

  /// Takes [n] delimiters from the budget; false (and takes nothing) if
  /// there aren't that many left.
  bool take(int n) {
    if (n > left) {
      left = 0; // once one chunk is refused, later ones are too
      return false;
    }
    left -= n;
    return true;
  }
}

/// The most characters in a group (and in a chunk the decoder may see).
const int _maxGroupChars = 30000;

/// The most inline delimiter characters ([_delimiter]) in a group.
const int _maxGroupDelimiters = 600;

/// The most link reference definition lines in a group.
const int _maxGroupDefinitions = 100;

/// The most block markers (`>`, bullets, numbers) one line may start with.
const int _maxLineMarkers = 16;

/// The widest indent a line may have.
const int _maxIndent = 80;

bool _delimiter(int c) =>
    c == 0x2A || // *
    c == 0x5F || // _
    c == 0x7E || // ~
    c == 0x5B || // [
    c == 0x5D || // ]
    c == 0x3C || // <
    c == 0x21 || // !
    c == 0x24 || // $
    c == 0x26 || // &
    c == 0x60; // `

/// What a chunk costs the decoder.
class _Cost {
  _Cost(this.chars, this.delimiters, this.definitions, this.deep);
  final int chars;
  final int delimiters;
  final int definitions;

  /// Some line nests deeper than the limits allow.
  final bool deep;
}

final RegExp _definition = RegExp(r'^ {0,3}\[[^\]]*\]:');

_Cost _cost(List<String> lines) {
  var chars = 0;
  var delimiters = 0;
  var definitions = 0;
  var deep = false;
  for (final line in lines) {
    chars += line.length + 1;
    for (var i = 0; i < line.length; i++) {
      if (_delimiter(line.codeUnitAt(i))) delimiters++;
    }
    if (line.isNotEmpty && line.codeUnitAt(0) != 0x20 && line.codeUnitAt(0) != 0x5B) {
      // fast path: nothing below can match
    } else if (_definition.hasMatch(line)) {
      definitions++;
    }
    if (!deep && _tooDeep(line)) deep = true;
  }
  return _Cost(chars, delimiters, definitions, deep);
}

/// Whether [line] starts with too many block markers or is indented too far.
bool _tooDeep(String line) {
  var i = 0;
  var indent = 0;
  var markers = 0;
  while (i < line.length) {
    final c = line.codeUnitAt(i);
    if (c == 0x20) {
      indent++;
      i++;
    } else if (c == 0x09) {
      indent += 4;
      i++;
    } else if (c == 0x3E) {
      markers++;
      i++;
    } else if ((c == 0x2D || c == 0x2A || c == 0x2B) &&
        (i + 1 >= line.length || line.codeUnitAt(i + 1) == 0x20 || line.codeUnitAt(i + 1) == 0x09)) {
      markers++;
      i++;
    } else if (c >= 0x30 && c <= 0x39) {
      var j = i;
      while (j < line.length && line.codeUnitAt(j) >= 0x30 && line.codeUnitAt(j) <= 0x39) {
        j++;
      }
      if (j < line.length &&
          (line.codeUnitAt(j) == 0x2E || line.codeUnitAt(j) == 0x29) &&
          (j + 1 >= line.length || line.codeUnitAt(j + 1) == 0x20)) {
        markers++;
        i = j + 1;
      } else {
        break;
      }
    } else {
      break;
    }
    if (markers > _maxLineMarkers || indent > _maxIndent) return true;
  }
  return false;
}

bool _fits(int chars, int delimiters, int definitions) =>
    chars <= _maxGroupChars &&
    delimiters <= _maxGroupDelimiters &&
    definitions <= _maxGroupDefinitions;

/// Decodes [markdown] within the bounds above.
List<Map<String, Object?>> _decode(String markdown, _Budget budget) {
  if (markdown.trim().isEmpty) return const [];
  // Chunks: runs of non-blank lines.
  final chunks = <List<String>>[];
  var current = <String>[];
  for (final line in markdown.split('\n')) {
    if (line.isEmpty) {
      if (current.isNotEmpty) chunks.add(current);
      current = [];
    } else {
      current.add(line);
    }
  }
  if (current.isNotEmpty) chunks.add(current);

  final out = <Map<String, Object?>>[];
  var group = <List<String>>[];
  var chars = 0, delimiters = 0, definitions = 0;
  void flush() {
    if (group.isEmpty) return;
    out.addAll(_decodeGroup(group));
    group = [];
    chars = delimiters = definitions = 0;
  }

  for (final chunk in chunks) {
    final c = _cost(chunk);
    if (c.deep || !_fits(c.chars, c.delimiters, c.definitions) || !budget.take(c.delimiters)) {
      flush();
      out.add(_plain(chunk.join('\n')));
      continue;
    }
    if (!_fits(chars + c.chars, delimiters + c.delimiters, definitions + c.definitions)) {
      flush();
    }
    group.add(chunk);
    chars += c.chars;
    delimiters += c.delimiters;
    definitions += c.definitions;
  }
  flush();
  return out;
}

/// Decodes a group of chunks together (so a list or a reference link may span
/// a blank line). If the decoder fails, each chunk is tried alone, and one
/// that fails again is kept as plain text.
List<Map<String, Object?>> _decodeGroup(List<List<String>> group) {
  try {
    return _decodeText([for (final c in group) c.join('\n')].join('\n\n'));
  } on Object {
    // fall through
  }
  return [
    for (final c in group) ..._decodeOne(c),
  ];
}

List<Map<String, Object?>> _decodeOne(List<String> chunk) {
  try {
    return _decodeText(chunk.join('\n'));
  } on Object {
    return [_plain(chunk.join('\n'))];
  }
}

List<Map<String, Object?>> _decodeText(String markdown) {
  final nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    inlineSyntaxes: [_FormulaSyntax(), _UnderlineSyntax()],
    encodeHtml: false,
  ).parse(_formatMarkdown(markdown));
  return [
    for (final n in nodes)
      for (final c in _block(n, _ListKind.none, null))
        if (_allowed.contains(c['type'])) _fix(c),
  ];
}

// ---- The block mapping, ported from appflowy_editor's markdown decoder ----

/// Puts text and an image on separate lines, as the decoder did (an image
/// is dropped later, and this decides what stays of the text around it).
String _formatMarkdown(String markdown) {
  var result = markdown.replaceAllMapped(
    RegExp(r'([^\n])\n!\[([^\]]*)\]\(([^)]+)\)', multiLine: true),
    (m) => '${m[1]}\n\n![${m[2]}](${m[3]})',
  );
  result = result.replaceAllMapped(
    RegExp(r'([^\n])!\[([^\]]*)\]\(([^)]+)\)'),
    (m) => '${m[1]}\n\n![${m[2]}](${m[3]})',
  );
  return result;
}

/// Inline `$formula$`.
class _FormulaSyntax extends md.InlineSyntax {
  _FormulaSyntax() : super(r'(?<!\$)\$(?!\$)([\s\S]+?)(?<!\$)\$(?!\$)');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final formula = match.group(1);
    if (formula == null || formula.isEmpty) return false;
    final element = md.Element('formula', [md.Text('\$')]);
    element.attributes['formula'] = formula;
    parser.addNode(element);
    return true;
  }
}

/// Inline `<u>text</u>`.
class _UnderlineSyntax extends md.InlineSyntax {
  _UnderlineSyntax() : super('<u>(.*)</u>');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final nested = md.InlineParser(match.group(1) ?? '', parser.document).parse();
    parser.addNode(md.Element('u', nested));
    return true;
  }
}

enum _ListKind { none, ordered, unordered }

Map<String, Object?> _node(
  String type, {
  Map<String, Object?> data = const {},
  List<Map<String, Object?>> children = const [],
}) {
  // Like appflowy's Node.toJson: no empty children or data, no null values.
  final d = {
    for (final e in data.entries)
      if (e.value != null) e.key: e.value,
  };
  return {
    'type': type,
    if (children.isNotEmpty) 'children': children,
    if (d.isNotEmpty) 'data': d,
  };
}

Map<String, Object?> _textNode(
  String type,
  List<md.Node>? nodes, {
  Map<String, Object?> data = const {},
  List<Map<String, Object?>> children = const [],
}) => _node(
  type,
  data: {'delta': _delta(nodes), ...data},
  children: children,
);

/// The first parser that takes [element] wins, in the decoder's order:
/// paragraph, heading, check item, bullet list, numbered list, bullet item,
/// numbered item, quote, table, divider, image.
List<Map<String, Object?>> _block(md.Node element, _ListKind kind, int? start) {
  if (element is! md.Element) return const [];
  final tag = element.tag;
  final kids = element.children;
  if (tag == 'p') {
    if (kids != null && kids.length == 1 && kids.first is md.Element) {
      if ((kids.first as md.Element).tag == 'img') return const [];
    }
    if (kids == null || kids.isEmpty) return [_textNode('paragraph', null)];
    final groups = <List<md.Node>>[[]];
    for (final k in kids) {
      if (k is md.Element && k.tag == 'br') {
        groups.add([]);
      } else {
        groups.last.add(k);
      }
    }
    return [
      for (final g in groups)
        if (g.isNotEmpty) _textNode('paragraph', g),
    ];
  }
  if (const {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}.contains(tag)) {
    return [_textNode('heading', kids, data: {'level': int.parse(tag.substring(1))})];
  }
  if (tag == 'li' && element.attributes['class'] == 'task-list-item') {
    if (kids == null || kids.isEmpty) return const [];
    final checked = (kids[0] as md.Element).attributes['checked'] == 'true';
    md.Element? last;
    if (kids.last is md.Element) {
      final l = kids.last as md.Element;
      if (l.tag == 'ul' || l.tag == 'ol') last = l;
    }
    return [
      _textNode(
        'todo_list',
        kids.sublist(1, kids.length - (last != null ? 1 : 0)),
        data: {'checked': checked},
        children: last == null ? const [] : _blocks([last], _ListKind.none, null),
      ),
    ];
  }
  if (tag == 'ul') return _blocks(kids, _ListKind.unordered, null);
  if (tag == 'ol') {
    final s = element.attributes['start'];
    return _blocks(kids, _ListKind.ordered, s != null ? int.tryParse(s) : null);
  }
  if (tag == 'li' && element.attributes.isEmpty && kind != _ListKind.none) {
    final nested = <md.Node>[];
    if (kids != null) {
      for (final c in kids.reversed) {
        if (c is md.Element && (c.tag == 'ol' || c.tag == 'ul')) {
          nested.add(c);
        } else {
          break;
        }
      }
    }
    final text = kids?.sublist(0, kids.length - nested.length);
    final ordered = kind == _ListKind.ordered;
    return [
      _textNode(
        ordered ? 'numbered_list' : 'bulleted_list',
        text,
        data: ordered ? {'number': start} : const {},
        children: _blocks(
          nested.reversed.toList(),
          ordered ? _ListKind.ordered : _ListKind.none,
          ordered ? start : null,
        ),
      ),
    ];
  }
  if (tag == 'blockquote') return [_textNode('quote', kids)];
  if (tag == 'table') return _table(kids);
  if (tag == 'hr') return [_node('divider')];
  return const [];
}

List<Map<String, Object?>> _blocks(List<md.Node>? nodes, _ListKind kind, int? start) {
  final out = <Map<String, Object?>>[];
  if (nodes == null) return out;
  for (final n in nodes) {
    out.addAll(_block(n, kind, start));
  }
  return out;
}

List<md.Element> _cellsOf(List<md.Node> table, String section, String cell) {
  for (final s in table.whereType<md.Element>()) {
    if (s.tag != section) continue;
    return [
      for (final tr in (s.children ?? const <md.Node>[]).whereType<md.Element>())
        if (tr.tag == 'tr')
          for (final c in (tr.children ?? const <md.Node>[]).whereType<md.Element>())
            if (c.tag == cell) c,
    ];
  }
  return const [];
}

List<Map<String, Object?>> _table(List<md.Node>? kids) {
  if (kids == null || kids.isEmpty) return const [];
  final th = _cellsOf(kids, 'thead', 'th');
  final td = _cellsOf(kids, 'tbody', 'td');
  if (th.isEmpty || td.isEmpty) return const [];
  // Column by column, the header cell first.
  final cols = <List<md.Element>>[];
  for (var i = 0; i < th.length; i++) {
    cols.add([th[i], for (var j = i; j < td.length; j += th.length) td[j]]);
  }
  const width = 160.0, height = 40.0;
  return [
    _node(
      'table',
      data: {
        'colsLen': cols.length,
        'rowsLen': cols[0].length,
        'colDefaultWidth': width,
        'rowDefaultHeight': height,
        'colMinimumWidth': 40.0,
      },
      children: [
        for (var i = 0; i < cols.length; i++)
          for (var j = 0; j < cols[0].length; j++)
            _node(
              'table/cell',
              data: {
                'colPosition': i,
                'rowPosition': j,
                'height': height,
                'width': width,
              },
              children: [_textNode('paragraph', cols[i][j].children)],
            ),
      ],
    ),
  ];
}

/// The text runs of [nodes], with the styles of the elements around them.
List<Map<String, Object?>> _delta(List<md.Node>? nodes) {
  final runs = <Map<String, Object?>>[];
  final attrs = <String, Object?>{};
  void add(String text) {
    if (text.isEmpty) return;
    if (runs.isNotEmpty && _sameAttrs(runs.last['attributes'], attrs)) {
      runs.last['insert'] = '${runs.last['insert']}$text';
      return;
    }
    runs.add({'insert': text, if (attrs.isNotEmpty) 'attributes': {...attrs}});
  }

  void visit(md.Node n) {
    if (n is md.Text) {
      add(n.text);
      return;
    }
    if (n is! md.Element) return;
    final keys = <String>[];
    switch (n.tag) {
      case 'strong':
        attrs['bold'] = true;
        keys.add('bold');
      case 'em':
        attrs['italic'] = true;
        keys.add('italic');
      case 'code':
        attrs['code'] = true;
        keys.add('code');
      case 'del':
        attrs['strikethrough'] = true;
        keys.add('strikethrough');
      case 'a':
        attrs['href'] = n.attributes['href'];
        keys.add('href');
      case 'u':
        attrs['underline'] = true;
        keys.add('underline');
      case 'formula':
        attrs['formula'] = n.attributes['formula'];
        keys.add('formula');
      default:
        // Any other element's attributes that read as JSON are taken as
        // they are, as the decoder did.
        // Afterwards every one of its attribute keys is removed again.
        n.attributes.forEach((key, value) {
          keys.add(key);
          try {
            attrs[key] = jsonDecode(value);
          } catch (_) {}
        });
    }
    for (final c in n.children ?? const <md.Node>[]) {
      visit(c);
    }
    keys.forEach(attrs.remove);
  }

  for (final n in nodes ?? const <md.Node>[]) {
    visit(n);
  }
  return runs;
}

bool _sameAttrs(Object? a, Map<String, Object?> b) {
  final x = a is Map ? a : const {};
  if (x.length != b.length) return false;
  for (final e in b.entries) {
    if (!x.containsKey(e.key) || x[e.key] != e.value) return false;
  }
  return true;
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
  _mathBlockType,
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
          'type': _mathBlockType,
          'data': {_formulaKey: m.group(1)},
        };
      }
    }
  }
  if (data is Map<String, Object?> && data['delta'] is List) {
    for (final op in data['delta']! as List) {
      final attrs = op is Map ? op['attributes'] : null;
      if (op is Map && attrs is Map && attrs[_formulaKey] is String) {
        op['insert'] = _inlineMathChar;
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
