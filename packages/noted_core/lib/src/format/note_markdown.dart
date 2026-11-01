// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../ai/ai_box.dart';

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
String noteToMarkdown(
  Object? data, {
  String? Function(String href)? linkTarget,
  bool markAi = false,
}) {
  if (data is! Map) return '';
  final doc = data['document'];
  if (doc is! Map) return '';
  final out = _Writer(linkTarget ?? (h) => h, markAi);
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
  _Writer(this.linkTarget, this.markAi);

  final String? Function(String href) linkTarget;
  final bool markAi;
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
  String _esc(String s) => markAi ? s.replaceAll('<', '&lt;') : s;

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
        _lines.addAll(['\$\$', _esc('${data['formula'] ?? ''}'), '\$\$']);
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
          if (_data(p)['formulaValue'] case final String v) _esc(v) else inline(_data(p)['delta']),
      ];
      cells[(r, c)] = parts.where((s) => s.isNotEmpty).join('<br>').replaceAll('|', r'\|').replaceAll('\n', ' ');
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
