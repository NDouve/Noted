// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

const String eq = '￼';

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

String export(List<Map<String, Object?>> children, {String? Function(String)? linkTarget}) =>
    noteToMarkdown(doc(children), export: true, linkTarget: linkTarget);

String exportOps(List<Object?> delta) => export([para(delta)]);

Map<String, Object?> table(List<List<List<Object?>>> rows) => {
  'type': 'table',
  'data': {'rowsLen': rows.length, 'colsLen': rows.first.length},
  'children': [
    for (var r = 0; r < rows.length; r++)
      for (var c = 0; c < rows[r].length; c++)
        {
          'type': 'table/cell',
          'data': {'rowPosition': r, 'colPosition': c},
          'children': [
            {
              'type': 'paragraph',
              'data': {'delta': rows[r][c]},
            },
          ],
        },
  ],
};

void main() {
  group('links', () {
    String link(String href) => exportOps([
      op('x', {'href': href}),
    ]);

    test('http, https and mailto keep their target', () {
      expect(link('https://example.com/a'), '[x](https://example.com/a)');
      expect(link('HTTP://example.com'), '[x](HTTP://example.com)');
      expect(link('mailto:a@example.com'), '[x](mailto:a@example.com)');
    });

    test('noted:, javascript:, data: and no scheme keep only the text', () {
      expect(link('noted:page/1'), 'x');
      expect(link(' JavaScript:x'), 'x');
      expect(link('data:text/html,<b>'), 'x');
      expect(link('/relative'), 'x');
      expect(link('java\tscript:alert(1)'), 'x');
    });

    test('a target with ) ( [ stays one encoded link', () {
      expect(
        link('https://example.com/)[y](javascript:alert(1)'),
        '[x](https://example.com/%29[y]%28javascript:alert%281%29)',
      );
    });

    test('a backslash, spaces, angle brackets and controls are percent-encoded', () {
      expect(link(r'https://e.com/a\b'), '[x](https://e.com/a%5Cb)');
      expect(link('https://e.com/a b'), '[x](https://e.com/a%20b)');
      expect(link('https://e.com/<a>'), '[x](https://e.com/%3Ca%3E)');
      expect(link('https://e.com/a\u0001b'), '[x](https://e.com/a%01b)');
    });

    test('the caller\'s own choice comes first', () {
      expect(
        export([
          para([
            op('x', {'href': 'https://hidden.example'}),
          ]),
        ], linkTarget: (_) => null),
        'x',
      );
    });
  });

  group('text is escaped at every call site', () {
    const bad = '[x](javascript:alert(1)) <img onerror=x> `c` wow!';
    const escaped = r'\[x\]\(javascript:alert\(1\)\) &lt;img onerror=x> \`c\` wow\!';

    test('inline text', () => expect(export([para([op(bad)])]), escaped));
    test('a heading', () => expect(export([para([op(bad)], type: 'heading', data: {'level': 2})]), '## $escaped'));
    test('a quote', () => expect(export([para([op(bad)], type: 'quote')]), '> $escaped'));
    test('a list item', () => expect(export([para([op(bad)], type: 'bulleted_list')]), '- $escaped'));
    test('a table cell', () {
      final out = export([
        table([
          [
            [op(bad)],
            [op('b')],
          ],
        ]),
      ]);
      expect(out.split('\n').first, '| $escaped | b |');
    });
    test('the [type] fallback', () {
      expect(
        export([
          {'type': '<img onerror=x>', 'data': <String, Object?>{}},
        ]),
        r'\[&lt;img onerror=x>\]',
      );
    });

    test('a backslash is escaped', () => expect(exportOps([op(r'a\b')]), r'a\\b'));

    test('text ending in ! before a link stays a link, not an image', () {
      final out = exportOps([
        op('Wow!'),
        op('x', {'href': 'https://example.com'}),
      ]);
      expect(out, r'Wow\![x](https://example.com)');
      // No unescaped `![`: the `!` is preceded by a backslash.
      expect(RegExp(r'(?<!\\)!\[').hasMatch(out), isFalse);
    });

    test('the AI path is unchanged', () {
      expect(noteToMarkdown(doc([para([op('a [b] <c>')])])), 'a [b] <c>');
      expect(noteToMarkdown(doc([para([op('a <c>')])]), markAi: true), 'a &lt;c>');
    });
  });

  group('code is written as code, not escaped', () {
    test('a code run holding backticks gets a longer fence', () {
      expect(exportOps([op('a`b', {'code': true})]), '``a`b``');
      expect(exportOps([op('a``b', {'code': true})]), '```a``b```');
    });

    test('a run that starts or ends with a backtick or space is padded', () {
      expect(exportOps([op('`a', {'code': true})]), '`` `a ``');
      expect(exportOps([op('a`', {'code': true})]), '`` a` ``');
      expect(exportOps([op(' a', {'code': true})]), '`  a `');
      expect(exportOps([op('a', {'code': true})]), '`a`');
    });

    test('backslash, pipe and </script> stay as they are', () {
      expect(exportOps([op(r'a\b|</script>', {'code': true})]), r'`a\b|</script>`');
    });

    test('a code run is written as code at each call site', () {
      final code = [
        op('a`</script>', {'code': true}),
      ];
      const want = '``a`</script>``';
      expect(export([para(code)]), want);
      expect(export([para(code, type: 'heading', data: {'level': 1})]), '# $want');
      expect(export([para(code, type: 'quote')]), '> $want');
      expect(export([para(code, type: 'bulleted_list')]), '- $want');
      expect(
        export([
          table([
            [code, [op('b')]],
          ]),
        ]).split('\n').first,
        '| $want | b |',
      );
    });

    test('a code run that is a link\'s text', () {
      expect(
        exportOps([
          op('a`b', {'code': true, 'href': 'https://e.com'}),
        ]),
        '[``a`b``](https://e.com)',
      );
    });

    test('a pipe in a code span in a table cell is escaped', () {
      final out = export([
        table([
          [
            [
              op('a|b', {'code': true}),
            ],
            [op('c')],
          ],
        ]),
      ]);
      expect(out.split('\n').first, r'| `a\|b` | c |');
    });

    test('line endings in a span are spaces, so no line starts a block', () {
      for (final nl in ['\n', '\r\n', '\r']) {
        final out = exportOps([op('a$nl<script>', {'code': true})]);
        expect(out, '`a <script>`', reason: nl.codeUnits.toString());
        expect(out.split(RegExp(r'\r\n|\r|\n')), hasLength(1));
      }
    });

    test('line endings in a span in a table cell', () {
      for (final nl in ['\n', '\r\n', '\r']) {
        final out = export([
          table([
            [
              [op('a$nl<script>', {'code': true})],
              [op('b')],
            ],
          ]),
        ]);
        expect(out.split('\n').first, '| `a <script>` | b |', reason: nl.codeUnits.toString());
      }
    });

    test('a table cell whose plain text holds \\r and \\r\\n', () {
      for (final nl in ['\r', '\r\n']) {
        final out = export([
          table([
            [
              [op('a${nl}b')],
              [op('c')],
            ],
          ]),
        ]);
        expect(out.split('\n').first, '| a b | c |');
        expect(out, isNot(contains('\r')));
      }
    });

    test('a formula value in a cell is a code span from the raw text', () {
      final out = export([
        {
          'type': 'table',
          'data': {'rowsLen': 1, 'colsLen': 1},
          'children': [
            {
              'type': 'table/cell',
              'data': {'rowPosition': 0, 'colPosition': 0},
              'children': [
                {
                  'type': 'paragraph',
                  'data': {'delta': <Object?>[], 'formulaValue': 'a`b|<x>'},
                },
              ],
            },
          ],
        },
      ]);
      expect(out.split('\n').first, r'| ``a`b\|<x>`` |');
    });

    test('a block equation is a math fence', () {
      expect(
        export([
          {
            'type': 'math_equation',
            'data': {'formula': 'x^2'},
          },
        ]),
        '```math\nx^2\n```',
      );
      expect(
        export([
          {
            'type': 'math_equation',
            'data': {'formula': 'a```b\\|</script>'},
          },
        ]),
        '````math\na```b\\|</script>\n````',
      );
    });

    test('an inline equation is a code span', () {
      expect(exportOps([op(eq, {'formula': r'a`\b'})]), r'``a`\b``');
    });
  });

  group('adjacent code is one span', () {
    Map<String, Object?> code(String t, [String? href]) => op(t, {'code': true, 'href': ?href});

    test('a code run then a backtick run', () {
      expect(exportOps([code('a'), code('`')]), '`` a` ``');
    });

    test('a code run next to an equation', () {
      expect(exportOps([code('a'), op(eq, {'formula': 'b'})]), '`ab`');
      expect(exportOps([op(eq, {'formula': 'a'}), op(eq, {'formula': 'b'})]), '`ab`');
    });

    test('the same link joins, different links do not', () {
      expect(exportOps([code('a', 'https://e.com'), code('b', 'https://e.com')]), '[`ab`](https://e.com)');
      final two = exportOps([code('a', 'https://e.com/1'), code('b', 'https://e.com/2')]);
      expect(two, '[`a`](https://e.com/1)[`b`](https://e.com/2)');
    });

    test('an empty run and a non-string insert between code runs do not separate them', () {
      expect(exportOps([code('a'), op(''), code('b')]), '`ab`');
      expect(
        exportOps([
          code('a'),
          {
            'insert': {'image': 'x'},
          },
          code('b'),
        ]),
        '`ab`',
      );
      expect(exportOps([code('a'), 'not a map', code('b')]), '`ab`');
    });

    test('a dropped link next to a bare code run is one span; so are two different dropped links', () {
      expect(exportOps([code('a', 'javascript:x'), code('b')]), '`ab`');
      expect(exportOps([code('a', 'javascript:x'), code('b', 'noted:y')]), '`ab`');
      expect(exportOps([code('`'), code('`', 'data:z')]), '``` `` ```');
    });

    test('a dropped link next to a kept link do not join', () {
      expect(exportOps([code('a', 'javascript:x'), code('b', 'https://e.com')]), '`a`[`b`](https://e.com)');
    });

    test('plain text between code runs separates them', () {
      expect(exportOps([code('a'), op(' '), code('b')]), '`a` `b`');
    });
  });
}
