// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';

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
    expect(data(b[1])[NoteFormat.formulaKey], 'E=mc^2');
  });

  test('an inline equation takes the character the note stores', () {
    final b = blocks('x is \$x^2\$ here');
    final delta = data(b.single)['delta']! as List;
    final op = delta[1] as Map;
    expect(op['insert'], NoteFormat.inlineMathChar);
    expect((op['attributes'] as Map)[NoteFormat.formulaKey], 'x^2');
  });

  test('a table keeps its cells and size', () {
    final b = blocks('| a | b |\n| --- | --- |\n| 1 | 2 |\n');
    final table = b.single;
    expect(table['type'], 'table');
    expect(data(table)['rowsLen'], 2);
    expect(data(table)['colsLen'], 2);
    expect((table['children']! as List), hasLength(4));
    // The note codec reads it back as text.
    final text = const NoteCodec().snapshotText(
      NoteData({
        'document': {'type': 'page', 'children': b},
      }),
    );
    expect(text, 'a | b\n1 | 2');
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

  test('fenced code and raw HTML are dropped; unknown blocks never pass', () {
    final b = blocks('a\n\n```\ncode\n```\n\n<img src="http://x/y.png">\n\n<div>h</div>\n\nb');
    final text = jsonEncode(b);
    expect(text, isNot(contains('code')));
    expect(text, isNot(contains('img')));
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
}
