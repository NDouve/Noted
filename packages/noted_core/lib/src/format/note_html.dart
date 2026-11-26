// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'export_links.dart';

/// A note box's saved document (appflowy_editor's JSON, as the note module
/// stores it) as one standalone HTML page, for export.
///
/// The page has fixed inline CSS (no colour comes from the data), no script
/// and no external resource (a content security policy forbids both). All
/// text is escaped; a link keeps its target only for `http`, `https` and
/// `mailto` ([exportLinkTarget]), after [linkTarget] (null keeps only the
/// text). Equations are their LaTeX in `<code>`; a formula cell shows its
/// value.
String noteToHtml(
  Object? data, {
  String title = '',
  String? Function(String href)? linkTarget,
}) {
  final w = _Html(linkTarget ?? (h) => h);
  if (data is Map && data['document'] is Map) {
    w.blocks(_children(data['document']! as Map<Object?, Object?>));
  }
  return '<!DOCTYPE html>\n'
      '<html lang="en">\n'
      '<head>\n'
      '<meta charset="utf-8">\n'
      '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'">\n'
      '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
      '<title>${escapeHtml(title)}</title>\n'
      '<style>$_css</style>\n'
      '</head>\n'
      '<body>\n'
      '${w.result()}'
      '</body>\n'
      '</html>\n';
}

const String _css =
    'body{font-family:system-ui,sans-serif;font-size:16px;line-height:1.5;'
    'max-width:48rem;margin:2rem auto;padding:0 1rem;color:#202124;background:#fff}'
    'h1,h2,h3,h4,h5,h6{line-height:1.25}'
    'blockquote{margin:1em 0;padding-left:1em;border-left:3px solid #ccc}'
    'code,pre{font-family:ui-monospace,monospace;background:#f3f3f3}'
    'pre{padding:.5em;overflow:auto}'
    'table{border-collapse:collapse}'
    'td,th{border:1px solid #bbb;padding:.25em .5em;text-align:left}'
    'hr{border:0;border-top:1px solid #ccc}'
    'ul.todo{list-style:none;padding-left:1em}';

/// [s] with `&`, `<`, `>`, `"` and `'` escaped, for text and attribute values.
String escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

/// The one character an inline equation takes in its text run.
const String _inlineMath = '￼';

List<Map<Object?, Object?>> _children(Map<Object?, Object?> node) {
  final c = node['children'];
  return c is List ? c.whereType<Map<Object?, Object?>>().toList() : const [];
}

Map<Object?, Object?> _data(Map<Object?, Object?> node) {
  final d = node['data'];
  return d is Map ? d : const {};
}

const Set<String> _listTypes = {'bulleted_list', 'numbered_list', 'todo_list'};

final class _Html {
  _Html(this.linkTarget);

  final String? Function(String href) linkTarget;
  final StringBuffer _b = StringBuffer();

  String result() => _b.toString();

  void blocks(List<Map<Object?, Object?>> nodes) {
    var i = 0;
    while (i < nodes.length) {
      final type = nodes[i]['type'];
      if (_listTypes.contains(type)) {
        // A run of items of one kind is one list.
        var j = i;
        while (j < nodes.length && nodes[j]['type'] == type) {
          j++;
        }
        _list(type! as String, nodes.sublist(i, j));
        i = j;
      } else {
        block(nodes[i]);
        i++;
      }
    }
  }

  void _list(String type, List<Map<Object?, Object?>> items) {
    final tag = type == 'numbered_list' ? 'ol' : 'ul';
    _b.write(type == 'todo_list' ? '<ul class="todo">\n' : '<$tag>\n');
    for (final item in items) {
      final data = _data(item);
      final box = type == 'todo_list' ? (data['checked'] == true ? '☑ ' : '☐ ') : '';
      _b.write('<li>$box${inline(data['delta'])}');
      final kids = _children(item);
      if (kids.isNotEmpty) {
        _b.write('\n');
        blocks(kids);
      }
      _b.write('</li>\n');
    }
    _b.write(type == 'todo_list' ? '</ul>\n' : '</$tag>\n');
  }

  void block(Map<Object?, Object?> node) {
    final type = node['type'];
    final data = _data(node);
    switch (type) {
      case 'heading':
        final level = data['level'] is int ? (data['level']! as int).clamp(1, 6) : 1;
        _b.write('<h$level>${inline(data['delta'])}</h$level>\n');
      case 'quote':
        _b.write('<blockquote>${inline(data['delta'])}</blockquote>\n');
      case 'divider':
        _b.write('<hr>\n');
      case 'math_equation':
        _b.write('<pre><code>${escapeHtml('${data['formula'] ?? ''}')}</code></pre>\n');
      case 'table':
        _table(node);
        return;
      case 'paragraph':
        final text = inline(data['delta']);
        if (text.trim().isNotEmpty) _b.write('<p>$text</p>\n');
      default:
        final text = inline(data['delta']);
        _b.write('<p>${text.isEmpty ? escapeHtml('[$type]') : text}</p>\n');
    }
    final kids = _children(node);
    if (kids.isNotEmpty) blocks(kids);
  }

  /// A text run list (`delta`) as inline HTML.
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
        b.write('<code>${escapeHtml('${attrs['formula']}')}</code>');
        continue;
      }
      var t = escapeHtml(text).replaceAll('\n', '<br>');
      if (attrs['code'] == true) {
        t = '<code>$t</code>';
      } else {
        if (attrs['bold'] == true) t = '<strong>$t</strong>';
        if (attrs['italic'] == true) t = '<em>$t</em>';
        if (attrs['strikethrough'] == true) t = '<s>$t</s>';
      }
      final href = attrs['href'];
      if (href is String) {
        final mapped = linkTarget(href);
        final target = mapped == null ? null : exportLinkTarget(mapped);
        if (target != null) t = '<a href="${escapeHtml(target)}" rel="noopener noreferrer">$t</a>';
      }
      b.write(t);
    }
    return b.toString();
  }

  void _table(Map<Object?, Object?> node) {
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
          if (_data(p)['formulaValue'] case final String v) escapeHtml(v) else inline(_data(p)['delta']),
      ];
      cells[(r, c)] = parts.where((s) => s.isNotEmpty).join('<br>');
    }
    if (rows == 0 || cols == 0) return;
    _b.write('<table>\n');
    for (var r = 0; r < rows; r++) {
      final tag = r == 0 ? 'th' : 'td';
      _b.write('<tr>');
      for (var c = 0; c < cols; c++) {
        _b.write('<$tag>${cells[(r, c)] ?? ''}</$tag>');
      }
      _b.write('</tr>\n');
    }
    _b.write('</table>\n');
  }
}
