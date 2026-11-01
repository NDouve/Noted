// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  List<Map<String, Object?>> blocks(String md) => markdownToNoteBlocks(md);
  Map<String, Object?> data(Map<String, Object?> b) =>
      b['data']! as Map<String, Object?>;

  test('blank markdown gives no blocks', () {
    expect(blocks(''), isEmpty);
    expect(blocks('  \n\n'), isEmpty);
  });

  test('headings, paragraphs, quotes and dividers', () {
    final b = blocks('# Title\n\nSome **bold** text\n\n> quoted\n\n---\n');
    expect(b.map((e) => e['type']), [
      'heading',
      'paragraph',
      'quote',
      'divider',
    ]);
    expect(data(b[0])['level'], 1);
    final delta = data(b[1])['delta']! as List;
    expect((delta[1] as Map)['attributes'], {'bold': true});
  });

  test('lists, check lists and nesting', () {
    final b = blocks('- a\n- b\n  - c\n\n1. one\n2. two\n\n- [ ] t\n- [x] d\n');
    expect(b.map((e) => e['type']), [
      'bulleted_list',
      'bulleted_list',
      'numbered_list',
      'numbered_list',
      'todo_list',
      'todo_list',
    ]);
    expect((b[1]['children']! as List).single['type'], 'bulleted_list');
    expect(data(b[4])['checked'], false);
    expect(data(b[5])['checked'], true);
  });

  test('a block equation becomes a math_equation block', () {
    final b = blocks('before\n\n\$\$\nE=mc^2\n\$\$\n\nafter');
    expect(b.map((e) => e['type']), ['paragraph', 'math_equation', 'paragraph']);
    expect(data(b[1])['formula'], 'E=mc^2');
  });

  test('an inline equation takes the character the note stores', () {
    final b = blocks('x is \$x^2\$ here');
    final delta = data(b.single)['delta']! as List;
    final op = delta[1] as Map;
    expect(op['insert'], String.fromCharCode(0xFFFC));
    expect((op['attributes'] as Map)['formula'], 'x^2');
  });

  test('a table keeps its cells and size', () {
    final b = blocks('| a | b |\n| --- | --- |\n| 1 | 2 |\n');
    final table = b.single;
    expect(table['type'], 'table');
    expect(data(table)['rowsLen'], 2);
    expect(data(table)['colsLen'], 2);
    expect((table['children']! as List), hasLength(4));
    // Cells run column by column, header first.
    expect(aiBlockText(table), 'a\n1\nb\n2');
  });

  test('images are dropped, whatever the address', () {
    for (final src in [
      'https://example.com/a.png',
      r'\\server\share\a.png',
      'file:///C:/a.png',
    ]) {
      final b = blocks('before\n\n![alt]($src)\n\nafter\n\n- ![x]($src)');
      expect(b.map((e) => e['type']).toSet().difference({'paragraph', 'bulleted_list'}), isEmpty);
      expect(jsonEncode(b), isNot(contains('image')));
      expect(jsonEncode(b), isNot(contains('server')));
    }
  });

  List<String> texts(String md) => [
    for (final e in blocks(md))
      ((data(e)['delta']! as List).map((o) => (o as Map)['insert']).join()),
  ];

  test('a fenced code block is one paragraph, lines kept, nothing interpreted', () {
    final b = blocks('a\n\n```dart\nvar x = 1;\n\n  **y**();\n```\n\nb');
    expect(b.map((e) => e['type']), ['paragraph', 'paragraph', 'paragraph']);
    expect(texts('a\n\n```dart\nvar x = 1;\n\n  **y**();\n```\n\nb'), [
      'a',
      'var x = 1;\n\n  **y**();',
      'b',
    ]);
    expect((data(b[1])['delta']! as List).single, {'insert': 'var x = 1;\n\n  **y**();'});
    // Tilde fences, a longer fence with a shorter one inside, CRLF, no end.
    expect(texts('~~~\na\n~~~'), ['a']);
    expect(texts('````\n```\nx\n```\n````'), ['```\nx\n```']);
    expect(texts('```\r\na\r\nb\r\n```\r\n'), ['a\nb']);
    expect(texts('```\nunclosed\n\nmore'), ['unclosed\n\nmore']);
    expect(blocks('```\n```'), isEmpty);
  });

  test('an indented code block is one paragraph, minus the indent', () {
    expect(texts('a\n\n    one\n      two\n\n    three\n\nb'), [
      'a',
      'one\n  two\n\nthree',
      'b',
    ]);
    expect(texts('a\n\n\ttabbed'), ['a', 'tabbed']);
    // Indented text after a list item belongs to the item, and a line that
    // continues a paragraph is not code.
    expect(blocks('- a\n\n    more').map((e) => e['type']), ['bulleted_list']);
    expect(texts('para\n    lazy'), hasLength(1));
  });

  test('inline HTML stays literal text', () {
    final b = blocks('before <b>bold</b> and <img src="http://x/y.png"> after');
    expect(b.map((e) => e['type']), ['paragraph']);
    expect(texts('before <b>bold</b> and <img src="http://x/y.png"> after'), [
      'before <b>bold</b> and <img src="http://x/y.png"> after',
    ]);
    expect(jsonEncode(b), isNot(contains('"image"')));
  });

  test('a raw HTML block is one paragraph of its literal text', () {
    expect(texts('a\n\n<div class="x">\n  <p>hi *there*</p>\n</div>\n\nb'), [
      'a',
      '<div class="x">\n  <p>hi *there*</p>\n</div>',
      'b',
    ]);
    final img = blocks('<img src="http://x/y.png">');
    expect(img.map((e) => e['type']), ['paragraph']);
    expect(texts('<img src="http://x/y.png">'), ['<img src="http://x/y.png">']);
    expect(texts('x\n\n<!-- one\n\ntwo -->\n\ny'), ['x', '<!-- one\n\ntwo -->', 'y']);
    expect(texts('x\n\n<script>\nalert(1)\n\n</script>\n\ny'), [
      'x',
      '<script>\nalert(1)\n\n</script>',
      'y',
    ]);
    // An autolink is not an HTML block: it goes to the decoder.
    expect(blocks('<https://example.com>'), isNotEmpty);
  });

  test('a fence indented 1 to 3 spaces is code, minus that indent', () {
    expect(texts('a\n\n  ```\n  x\n    y\n  ```\n\nb'), ['a', 'x\n  y', 'b']);
  });

  test('block HTML interrupts a paragraph, except a lone inline tag', () {
    expect(texts('para\n<div>x</div>'), ['para', '<div>x</div>']);
    expect(texts('para\n<!-- c -->\nmore'), ['para', '<!-- c -->', 'more']);
    expect(texts('para\n<script>a</script>'), ['para', '<script>a</script>']);
    // A tag alone on its line (condition 7) needs a blank line before it.
    expect(texts('para\n<span>'), ['para\n<span>']);
    expect(texts('para\n\n<span>'), ['para', '<span>']);
  });

  test('inline tags at the start of a line and autolinks go to the decoder', () {
    final b = blocks('<b>Note</b>: see [docs](https://x.example)');
    expect(b.map((e) => e['type']), ['paragraph']);
    final delta = data(b.single)['delta']! as List;
    expect(
      delta.any((o) => (o as Map)['attributes'] is Map && (o['attributes'] as Map)['href'] == 'https://x.example'),
      isTrue,
      reason: 'the link is still a link',
    );
    for (final md in ['<foo@bar.com>', '<https://example.com>']) {
      expect(blocks(md), isNotEmpty, reason: md);
      expect(texts('$md\n\nz').last, 'z');
    }
  });
  test('indented HTML under a list item stays in the list', () {
    final b = blocks('- item\n   <div>x</div>\n  more');
    expect(b.map((e) => e['type']), ['bulleted_list']);
  });

  test('large input with many fence-like lines is read in linear time', () {
    final md = '- a\n${'\n   ```\n   x' * 80000}';
    expect(md.length, greaterThan(400000));
    final sw = Stopwatch()..start();
    blocks(md);
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
  });
  test('unknown blocks never pass', () {
    final b = blocks('a\n\n```\ncode\n```\n\n<img src="http://x/y.png">\n\n<div>h</div>\n\nb');
    const allowed = {
      'paragraph', 'heading', 'todo_list', 'bulleted_list', 'numbered_list',
      'quote', 'divider', 'table', 'math_equation',
    };
    expect(b.every((e) => allowed.contains(e['type'])), isTrue);
  });

  test('links keep http, https and mailto only', () {
    String? href(String md) {
      final delta = (blocks(md).single['data']! as Map)['delta']! as List;
      for (final op in delta) {
        final a = (op as Map)['attributes'];
        if (a is Map && a.containsKey('href')) return a['href'] as String;
      }
      return null;
    }

    expect(href('[a](https://example.com)'), 'https://example.com');
    expect(href('[a](http://example.com)'), 'http://example.com');
    expect(href('[a](mailto:x@example.com)'), 'mailto:x@example.com');
    expect(href('[a](file:///C:/x)'), isNull);
    expect(href(r'[a](\\server\share)'), isNull);
    expect(href('[a](javascript:alert(1))'), isNull);
    expect(href('[a](relative/path)'), isNull);
    // The text stays.
    expect(jsonEncode(blocks('[a](file:///x)')), contains('"a"'));
  });

  test('unsafe links are stripped in table cells and nested list items', () {
    final b = blocks(
      '| [c](file:///C:/x) | ok |\n| --- | --- |\n| [d](https://example.com) | z |\n\n'
      '- top\n  - [n](file:///C:/y)\n',
    );
    final text = jsonEncode(b);
    expect(text, isNot(contains('file:')));
    // The safe link in the table survives, and the texts stay.
    expect(text, contains('https://example.com'));
    for (final t in ['"c"', '"n"', '"d"']) {
      expect(text, contains(t));
    }
    expect(b.map((e) => e['type']), contains('table'));
    expect(b.last['children'], isNotEmpty);
  });

  test('the blocks are fresh maps', () {
    final a = blocks('hi');
    final b = blocks('hi');
    expect(identical(a.single, b.single), isFalse);
    (a.single['data']! as Map)['x'] = 1;
    expect(data(b.single).containsKey('x'), isFalse);
  });

  test('the exact block shapes the note module stores', () {
    expect(blocks('# T'), [
      {
        'type': 'heading',
        'data': {
          'delta': [
            {'insert': 'T'},
          ],
          'level': 1,
        },
      },
    ]);
    expect(blocks('---'), [
      {'type': 'divider'},
    ]);
    // A numbered list that starts at 3 keeps the number; one at 1 has none.
    expect(blocks('3. a\n4. b').map((e) => data(e)['number']), [3, 3]);
    expect(blocks('1. a').single['data'], {
      'delta': [
        {'insert': 'a'},
      ],
    });
    expect(blocks('- [x] done\n  - sub').single, {
      'type': 'todo_list',
      'children': [
        {
          'type': 'bulleted_list',
          'data': {
            'delta': [
              {'insert': 'sub'},
            ],
          },
        },
      ],
      'data': {
        'checked': true,
        'delta': [
          {'insert': 'done'},
        ],
      },
    });
    final cell = ((blocks('| a |\n| - |\n| 1 |\n').single['children']! as List).first as Map);
    expect(cell, {
      'type': 'table/cell',
      'children': [
        {
          'type': 'paragraph',
          'data': {
            'delta': [
              {'insert': 'a'},
            ],
          },
        },
      ],
      'data': {'colPosition': 0, 'rowPosition': 0, 'height': 40.0, 'width': 160.0},
    });
    expect(data(blocks('| a |\n| - |\n| 1 |\n').single), {
      'colsLen': 1,
      'rowsLen': 2,
      'colDefaultWidth': 160.0,
      'rowDefaultHeight': 40.0,
      'colMinimumWidth': 40.0,
    });
    // A header with no body rows is not a table.
    expect(blocks('| a |\n| - |\n'), isEmpty);
  });

  test('inline styles, hard breaks and underline', () {
    final b = blocks('*i* **b** ~~s~~ `c` <u>u</u>\\\nnext');
    expect(b.map((e) => e['type']), ['paragraph', 'paragraph']);
    final keys = [
      for (final op in data(b.first)['delta']! as List)
        if ((op as Map)['attributes'] != null) (op['attributes'] as Map).keys.single,
    ];
    expect(keys, ['italic', 'bold', 'strikethrough', 'code', 'underline']);
  });

  test('an equation block alone is math_equation, with the formula', () {
    expect(blocks('\$\$ a+b \$\$').single, {
      'type': 'math_equation',
      'data': {'formula': 'a+b'},
    });
  });
}
