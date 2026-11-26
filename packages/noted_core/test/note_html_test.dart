// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

Map<String, Object?> op(String text, [Map<String, Object?>? attrs]) => {
  'insert': text,
  'attributes': ?attrs,
};

Map<String, Object?> para(List<Object?> delta, {String type = 'paragraph', Map<String, Object?> data = const {}}) => {
  'type': type,
  'data': {'delta': delta, ...data},
};

Map<String, Object?> doc(List<Map<String, Object?>> children) => {
  'document': {'type': 'page', 'children': children},
};

String html(List<Map<String, Object?>> children, {String title = ''}) =>
    noteToHtml(doc(children), title: title);

void main() {
  test('a standalone page: fixed CSS, no script, no external resource', () {
    final out = html([
      para([op('hello')]),
    ], title: 'T <1>');
    expect(out, startsWith('<!DOCTYPE html>'));
    expect(out, contains('<title>T &lt;1&gt;</title>'));
    expect(out, contains('<style>'));
    expect(out, contains("default-src 'none'"));
    expect(out, contains('<p>hello</p>'));
    expect(out, isNot(contains('<script')));
    expect(out, isNot(contains('src=')));
    expect(out, isNot(contains('<link')));
    expect(out, isNot(contains('url(')));
    expect(out, isNot(contains('@import')));
    // The only href is none: nothing is fetched.
    expect(out, isNot(contains('href=')));
  });

  test('text, attributes and quotes are escaped', () {
    final out = html([
      para([op('<script>alert("x")</script> & \'y\'')]),
    ]);
    expect(out, contains('<p>&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;y&#39;</p>'));
    expect(out, isNot(contains('<script>')));
  });

  test('inline styles, code and an equation as LaTeX in <code>', () {
    final out = html([
      para([
        op('b', {'bold': true}),
        op('i', {'italic': true}),
        op('s', {'strikethrough': true}),
        op('c<', {'code': true}),
        op('￼', {'formula': r'a<b\frac{1}{2}'}),
      ]),
    ]);
    expect(out, contains('<strong>b</strong><em>i</em><s>s</s><code>c&lt;</code><code>a&lt;b\\frac{1}{2}</code>'));
  });

  test('a block equation is its LaTeX in <pre><code>', () {
    final out = html([
      {
        'type': 'math_equation',
        'data': {'formula': 'x</script>'},
      },
    ]);
    expect(out, contains('<pre><code>x&lt;/script&gt;</code></pre>'));
  });

  test('links are filtered and escaped', () {
    String link(String href) => html([
      para([
        op('x', {'href': href}),
      ]),
    ]);
    expect(link('https://e.com/?a=1&b="2"'), contains('<a href="https://e.com/?a=1&amp;b=&quot;2&quot;" rel="noopener noreferrer">x</a>'));
    expect(link('mailto:a@e.com'), contains('<a href="mailto:a@e.com"'));
    for (final bad in ['noted:p/1', ' JavaScript:x', 'data:text/html,x', 'relative/path']) {
      final out = link(bad);
      expect(out, contains('<p>x</p>'), reason: bad);
      expect(out, isNot(contains('href=')), reason: bad);
    }
  });

  test('headings, quote, divider and lists', () {
    final out = html([
      para([op('H')], type: 'heading', data: {'level': 3}),
      para([op('Q')], type: 'quote'),
      {'type': 'divider', 'data': <String, Object?>{}},
      para([op('one')], type: 'bulleted_list'),
      para([op('two')], type: 'bulleted_list'),
      para([op('n')], type: 'numbered_list'),
      para([op('done')], type: 'todo_list', data: {'checked': true}),
    ]);
    expect(out, contains('<h3>H</h3>'));
    expect(out, contains('<blockquote>Q</blockquote>'));
    expect(out, contains('<hr>'));
    expect(out, contains('<ul>\n<li>one</li>\n<li>two</li>\n</ul>'));
    expect(out, contains('<ol>\n<li>n</li>\n</ol>'));
    expect(out, contains('☑ done'));
  });

  test('a table, with a formula cell showing its value', () {
    final out = html([
      {
        'type': 'table',
        'data': {'rowsLen': 2, 'colsLen': 2},
        'children': [
          for (final (r, c, text, value) in [
            (0, 0, 'A', null),
            (0, 1, 'B', null),
            (1, 0, '=1+2', '3<'),
            (1, 1, 'z', null),
          ])
            {
              'type': 'table/cell',
              'data': {'rowPosition': r, 'colPosition': c},
              'children': [
                {
                  'type': 'paragraph',
                  'data': {
                    'delta': [op(text)],
                    'formulaValue': ?value,
                  },
                },
              ],
            },
        ],
      },
    ]);
    expect(out, contains('<tr><th>A</th><th>B</th></tr>'));
    expect(out, contains('<tr><td>3&lt;</td><td>z</td></tr>'));
    expect(out, isNot(contains('=1+2')));
  });

  test('an unknown block and a missing document do not break the page', () {
    expect(html([{'type': 'weird<', 'data': <String, Object?>{}}]), contains('<p>[weird&lt;]</p>'));
    expect(noteToHtml(null), contains('<body>'));
  });
}
