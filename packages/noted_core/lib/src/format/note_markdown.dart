// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../ai/ai_box.dart';
import 'export_links.dart';

/// Writes a note box's saved document (appflowy_editor's JSON, as the note
/// module stores it) as markdown: headings, paragraphs, bulleted, numbered
/// and check lists (nested by indenting), quotes, dividers, equations
/// (`$$…$$`, inline `$…$`), and tables as markdown tables.
///
/// [linkTarget] decides what a link becomes: the address to write, or null
/// to keep only its text (a link to a page AI can't see).
///
/// With [markAi], each run of consecutive top-level blocks an AI wrote
/// ([isAiWritten]) is wrapped in a line `<ai-written>` before it and a line
/// `</ai-written>` after it.
///
/// With [export], the markdown is for a file that leaves Noted: every text
/// is escaped (`<` as `&lt;`; `\`, `[`, `]`, `(`, `)`, `!` and the backtick
/// with a backslash), a link keeps its target only for `http`, `https` and
/// `mailto` (the target's `(`, `)`, `<`, `>`, `\`, spaces and control
/// characters are percent-encoded), and code runs, equations and formula
/// values are written as code, not escaped: adjacent ones are joined into one
/// span (grouped by their link), fenced with more backticks than the longest
/// run inside, and every line ending inside becomes a space. [markAi] is not
/// used with it.
String noteToMarkdown(
  Object? data, {
  String? Function(String href)? linkTarget,
  bool markAi = false,
  bool export = false,
}) {
  if (data is! Map) return '';
  final doc = data['document'];
  if (doc is! Map) return '';
  final out = _Writer(linkTarget ?? (h) => h, markAi && !export, export);
  out.blocks(_children(doc), 0);
  return out.result();
}

/// The one character an inline equation takes in its text run (the note
/// module's `NoteFormat.inlineMathChar`).
const String _inlineMath = '￼';

List<Map<Object?, Object?>> _children(Map<Object?, Object?> node) {
  final c = node['children'];
  return c is List ? c.whereType<Map<Object?, Object?>>().toList() : const [];
}

Map<Object?, Object?> _data(Map<Object?, Object?> node) {
  final d = node['data'];
  return d is Map ? d : const {};
}

final class _Writer {
  _Writer(this.linkTarget, this.markAi, this.export);

  final String? Function(String href) linkTarget;
  final bool markAi;
  final bool export;
  final List<String> _lines = [];

  // Whether the last block was a list item, so the next item follows it
  // without a blank line.
  bool _inList = false;

  String result() {
    while (_lines.isNotEmpty && _lines.last.isEmpty) {
      _lines.removeLast();
    }
    return _lines.join('\n');
  }

  void _gap({required bool listItem}) {
    if (_lines.isEmpty) return;
    if (listItem && _inList) return;
    if (_lines.last.isNotEmpty) _lines.add('');
  }

  void blocks(List<Map<Object?, Object?>> nodes, int depth) {
    var number = 0;
    var inAiRun = false;
    for (final node in nodes) {
      if (markAi && depth == 0) {
        final ai = isAiWritten(node);
        if (ai != inAiRun) {
          _tag(inAiRun ? '</ai-written>' : '<ai-written>');
          inAiRun = ai;
        }
      }
      final type = node['type'];
      number = type == 'numbered_list' ? number + 1 : 0;
      block(node, depth, number);
    }
    if (inAiRun) _tag('</ai-written>');
  }

  // With markAi, `<` in written text becomes `&lt;`, so no content line can
  // equal an <ai-written> marker line.
  String _esc(String s) {
    if (export) return _escapeText(s);
    return markAi ? s.replaceAll('<', '&lt;') : s;
  }

  void _tag(String tag) {
    _gap(listItem: false);
    _lines.add(tag);
    _inList = false;
  }

  void block(Map<Object?, Object?> node, int depth, int number) {
    final type = node['type'];
    final data = _data(node);
    final indent = '  ' * depth;
    switch (type) {
      case 'bulleted_list' || 'numbered_list' || 'todo_list':
        _gap(listItem: true);
        final marker = switch (type) {
          'numbered_list' => '$number.',
          'todo_list' => data['checked'] == true ? '- [x]' : '- [ ]',
          _ => '-',
        };
        _lines.add('$indent$marker ${inline(data['delta'])}'.trimRight());
        _inList = true;
        blocks(_children(node), depth + 1);
        _inList = true;
        return;
      case 'heading':
        final level = data['level'] is int ? (data['level']! as int).clamp(1, 6) : 1;
        _gap(listItem: false);
        _lines.add('${'#' * level} ${inline(data['delta'])}'.trimRight());
      case 'quote':
        _gap(listItem: false);
        _lines.add('> ${inline(data['delta'])}'.trimRight());
      case 'divider':
        _gap(listItem: false);
        _lines.add('---');
      case 'math_equation':
        _gap(listItem: false);
        if (export) {
          _lines.addAll(_mathFence('${data['formula'] ?? ''}'));
        } else {
          _lines.addAll(['\$\$', _esc('${data['formula'] ?? ''}'), '\$\$']);
        }
      case 'table':
        _gap(listItem: false);
        _lines.addAll(table(node));
      case 'paragraph':
        final text = inline(data['delta']);
        if (text.trim().isEmpty) {
          if (_lines.isNotEmpty && _lines.last.isNotEmpty) _lines.add('');
          _inList = false;
          return;
        }
        _gap(listItem: false);
        _lines.add('$indent$text');
      default:
        final text = inline(data['delta']);
        _gap(listItem: false);
        _lines.add(text.isEmpty ? _esc('[$type]') : '$indent$text');
    }
    _inList = false;
    // Children of a block that isn't a list item (rare) follow it indented.
    final kids = _children(node);
    if (kids.isNotEmpty && type != 'table') blocks(kids, depth + 1);
  }

  /// A text run list (`delta`) as inline markdown.
  String inline(Object? delta) {
    if (export) return _inlineExport(delta);
    if (delta is! List) return '';
    final b = StringBuffer();
    for (final op in delta) {
      if (op is! Map) continue;
      final text = op['insert'];
      if (text is! String) continue;
      final a = op['attributes'];
      final attrs = a is Map ? a : const {};
      if (text == _inlineMath && attrs['formula'] is String) {
        b.write('\$${_esc('${attrs['formula']}')}\$');
        continue;
      }
      var t = _esc(text);
      if (attrs['code'] == true) {
        t = '`$t`';
      } else {
        if (attrs['bold'] == true) t = '**$t**';
        if (attrs['italic'] == true) t = '_${t}_';
        if (attrs['strikethrough'] == true) t = '~~$t~~';
      }
      final href = attrs['href'];
      if (href is String) {
        final target = linkTarget(href);
        if (target != null) t = '[$t](${_esc(target)})';
      }
      b.write(t);
    }
    return b.toString();
  }

  /// The export form of a text run list: see [noteToMarkdown].
  String _inlineExport(Object? delta) {
    if (delta is! List) return '';
    // Pieces in output order. Adjacent code pieces with the same link are
    // one piece, so the longest backtick run is found over the whole span.
    final pieces = <_Piece>[];
    for (final op in delta) {
      if (op is! Map) continue;
      final text = op['insert'];
      if (text is! String) continue;
      final a = op['attributes'];
      final attrs = a is Map ? a : const {};
      final href = attrs['href'];
      final target = href is String ? _exportTarget(href) : null;
      if (text == _inlineMath && attrs['formula'] is String) {
        _addPiece(pieces, _Piece.code('${attrs['formula']}', null));
        continue;
      }
      if (attrs['code'] == true) {
        _addPiece(pieces, _Piece.code(text, target));
        continue;
      }
      var t = _escapeText(text);
      if (attrs['bold'] == true) t = '**$t**';
      if (attrs['italic'] == true) t = '_${t}_';
      if (attrs['strikethrough'] == true) t = '~~$t~~';
      if (target != null) t = '[$t](${markdownLinkTarget(target)})';
      _addPiece(pieces, _Piece.text(t));
    }
    final b = StringBuffer();
    for (final p in pieces) {
      if (!p.isCode) {
        b.write(p.value);
        continue;
      }
      final span = _codeSpan(p.value);
      final target = p.link;
      b.write(target == null ? span : '[$span](${markdownLinkTarget(target)})');
    }
    return b.toString();
  }

  // A piece that writes nothing doesn't separate its neighbours.
  void _addPiece(List<_Piece> pieces, _Piece p) {
    if (p.value.isEmpty) return;
    if (p.isCode && pieces.isNotEmpty) {
      final last = pieces.last;
      if (last.isCode && last.link == p.link) {
        pieces[pieces.length - 1] = _Piece.code(last.value + p.value, p.link);
        return;
      }
    }
    pieces.add(p);
  }

  // What the export keeps of a link: the caller's choice first, then the
  // scheme filter.
  String? _exportTarget(String href) {
    final t = linkTarget(href);
    return t == null ? null : exportLinkTarget(t);
  }

  /// A table block as a markdown table; its first row is the header row.
  List<String> table(Map<Object?, Object?> node) {
    final data = _data(node);
    final cells = <(int, int), String>{};
    var rows = data['rowsLen'] is int ? data['rowsLen']! as int : 0;
    var cols = data['colsLen'] is int ? data['colsLen']! as int : 0;
    for (final cell in _children(node)) {
      final d = _data(cell);
      final r = d['rowPosition'];
      final c = d['colPosition'];
      if (r is! int || c is! int) continue;
      rows = rows > r ? rows : r + 1;
      cols = cols > c ? cols : c + 1;
      final parts = [
        for (final p in _children(cell))
          // A formula cell shows its value, as the note does.
          if (_data(p)['formulaValue'] case final String v)
            export ? _codeSpan(v) : _esc(v)
          else
            inline(_data(p)['delta']),
      ];
      final joined = parts.where((s) => s.isNotEmpty).join('<br>');
      cells[(r, c)] = export
          ? joined.replaceAll(_lineEnding, ' ').replaceAll('|', r'\|')
          : joined.replaceAll('|', r'\|').replaceAll('\n', ' ');
    }
    if (rows == 0 || cols == 0) return const [];
    String row(int r) => '| ${[for (var c = 0; c < cols; c++) cells[(r, c)] ?? ''].join(' | ')} |';
    return [
      row(0),
      '| ${List.filled(cols, '---').join(' | ')} |',
      for (var r = 1; r < rows; r++) row(r),
    ];
  }
}

final RegExp _lineEnding = RegExp(r'\r\n|\r|\n');

/// One piece of an export's inline output: text already written as markdown,
/// or the raw text of a code span with its link target (null for none, or
/// one the export drops).
final class _Piece {
  const _Piece.text(this.value) : isCode = false, link = null;
  const _Piece.code(this.value, this.link) : isCode = true;

  final String value;
  final bool isCode;
  final String? link;
}

final RegExp _needsEscape = RegExp(r'[\\\[\]()!`]');

/// [s] as markdown text that can't start a link, an image, code or HTML.
String _escapeText(String s) =>
    s.replaceAll('<', '&lt;').replaceAllMapped(_needsEscape, (m) => '\\${m[0]}');

int _longestRun(String s) {
  var longest = 0, run = 0;
  for (var i = 0; i < s.length; i++) {
    if (s.codeUnitAt(i) == 0x60) {
      run++;
      if (run > longest) longest = run;
    } else {
      run = 0;
    }
  }
  return longest;
}

/// [raw] as an inline code span: one more backtick than the longest run
/// inside, a space on each side when it starts or ends with a backtick or a
/// space (CommonMark strips one from each side), and every line ending a
/// space. Empty gives an empty string.
String _codeSpan(String raw) {
  if (raw.isEmpty) return '';
  final s = raw.replaceAll(_lineEnding, ' ');
  final fence = '`' * (_longestRun(s) + 1);
  final pad =
      s.trim().isNotEmpty && (s.startsWith('`') || s.endsWith('`') || s.startsWith(' ') || s.endsWith(' '));
  return pad ? '$fence $s $fence' : '$fence$s$fence';
}

/// A block equation as a fenced block of at least three backticks.
List<String> _mathFence(String raw) {
  final s = raw.replaceAll(_lineEnding, '\n');
  final run = _longestRun(s) + 1;
  final fence = '`' * (run < 3 ? 3 : run);
  return ['${fence}math', ...s.split('\n'), fence];
}
