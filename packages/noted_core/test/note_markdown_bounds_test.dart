// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

const int _mb = 1 << 20;

void main() {
  int textLength(List<Map<String, Object?>> blocks) =>
      blocks.fold(0, (n, b) => n + aiBlockText(b).length);

  group('hostile input is bounded and its text is kept', () {
    final cases = <String, String Function()>{
      'underscores': () => '_a' * (_mb ~/ 2),
      'stars': () => '*a' * (_mb ~/ 2),
      'star underscore': () => '*_' * (_mb ~/ 2),
      'underline open': () => '<u>' * (_mb ~/ 3),
      'underline nested': () => '${'<u>' * (_mb ~/ 7)}a${'</u>' * (_mb ~/ 7)}',
      'image open': () => '![a' * (_mb ~/ 3),
      'image format regex': () => 'a![b](' * (_mb ~/ 6),
      'image format regex 2': () => 'a\n![${']' * _mb}',      'strike': () => '~~a' * (_mb ~/ 3),
      'link open': () => '[a](' * (_mb ~/ 4),
      'brackets': () => '[' * _mb,
      'link references': () => [
        for (var i = 0; i < _mb ~/ 12; i++) '[r$i]: /u$i',
        '',
        for (var i = 0; i < _mb ~/ 12; i++) '[r$i]',
      ].join('\n'),
      'deep quote': () => '${'>' * _mb} x',
      'deep bullets on a line': () => '${'- ' * (_mb ~/ 2)}x',
      'deep indented list': () => [for (var i = 0; i < 4000; i++) '${'  ' * i}- a'].join('\n'),
      'many stars': () => '*' * _mb,
      'formula': () => r'$a ' * (_mb ~/ 3),
      'html inline': () => '<a ' * (_mb ~/ 3),
      'entities': () => '&#' * (_mb ~/ 2),
      'footnotes': () => [
        for (var i = 0; i < _mb ~/ 20; i++) '[^f$i]',
        '',
        for (var i = 0; i < _mb ~/ 20; i++) '[^f$i]: x',
      ].join('\n'),
      'delimiters spread through text': () => '*a ${'x' * 40} ' * (_mb ~/ 46),
      // Ordinary markdown, so only a quarter of the size: parsing real markup
      // costs real time, and this checks the many small groups stay linear.
      'many small paragraphs with delimiters': () => 'a *b* _c_ [d](e)\n\n' * (_mb ~/ 68),
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final md = e.value();
        final sw = Stopwatch()..start();
        final out = markdownToNoteBlocks(md);
        sw.stop();
        expect(sw.elapsed, lessThan(const Duration(seconds: 3)), reason: e.key);
        expect(out, isNotEmpty);
        expect(textLength(out), greaterThan(md.length ~/ 3), reason: 'the text is kept');
      });
    }

    test('an over-limit chunk is one plain paragraph, its text as written', () {
      final md = '${'*a' * 5000}\n\nafter *me*';
      final out = markdownToNoteBlocks(md);
      expect(out, hasLength(2));
      expect(aiBlockText(out[0]), '*a' * 5000);
      expect((out[0]['data']! as Map)['delta'], [
        {'insert': '*a' * 5000},
      ]);
      expect(aiBlockText(out[1]), 'after me');
    });

    test('ordinary documents are untouched by the limits', () {
      final md = [for (var i = 0; i < 300; i++) '## Part $i\n\nSome *text* with a [link](https://x.example) and `code`.\n\n- a\n- b\n'].join('\n');
      final out = markdownToNoteBlocks(md);
      expect(out.where((b) => b['type'] == 'heading'), hasLength(300));
      expect(out.where((b) => b['type'] == 'bulleted_list'), hasLength(600));
    });

    test('a nesting of 16 markers still imports; deeper is plain text', () {
      expect(markdownToNoteBlocks('${'> ' * 4}x').single['type'], 'quote');
      expect(markdownToNoteBlocks('${'> ' * 40}x').single['type'], 'paragraph');
    });
  });

  group('what the importer never keeps', () {
    String all(String md) => jsonEncode(markdownToNoteBlocks(md));
    List<String?> hrefs(String md) {
      final out = <String?>[];
      void walk(Object? n) {
        if (n is Map) {
          final a = n['attributes'];
          if (a is Map && a.containsKey('href')) out.add(a['href'] as String?);
          n.values.forEach(walk);
        } else if (n is List) {
          n.forEach(walk);
        }
      }

      walk(markdownToNoteBlocks(md));
      return out;
    }

    test('schemes hidden with entities, case, spaces or controls are not links', () {
      for (final md in [
        '[a](jav&#97;script:alert(1))',
        '[a](&#106;avascript:alert(1))',
        '[a](javascript&colon;alert(1))',
        '[a](JaVaScRiPt:alert(1))',
        '[a](  javascript:alert(1))',
        '[a](java\tscript:alert(1))',
        '[a](&#x6A;avascript:alert(1))',
        '[a](data:text/html;base64,PHNjcmlwdD4=)',
        '[a](vbscript:x)',
        '[a](file:///C:/x)',
        '[a](//evil.example/x)',
      ]) {
        expect(hrefs(md).whereType<String>(), isEmpty, reason: md);
        expect(all(md), contains('"a"'), reason: 'the text stays: $md');
      }
    });

    test('unsafe reference links and definitions lose the address, safe ones keep it', () {
      expect(hrefs('[a][r]\n\n[r]: javascript:alert(1)').whereType<String>(), isEmpty);
      expect(hrefs('[a][r]\n\n[r]: data:text/html,x').whereType<String>(), isEmpty);
      expect(hrefs('[a][r]\n\n[r]: file:///x').whereType<String>(), isEmpty);
      expect(hrefs('[r]\n\n[r]: javascript:alert(1)').whereType<String>(), isEmpty);
      expect(hrefs('[a][r]\n\n[r]: https://ok.example').whereType<String>(), ['https://ok.example']);
    });

    test('autolinks keep http, https and mailto only', () {
      for (final md in ['<javascript:alert(1)>', '<data:text/html,x>', '<file:///C:/x>', '<vbscript:x>']) {
        expect(hrefs(md).whereType<String>(), isEmpty, reason: md);
      }
      expect(hrefs('<https://ok.example>').whereType<String>(), ['https://ok.example']);
      expect(hrefs('<me@x.example>').whereType<String>(), ['mailto:me@x.example']);
    });

    test('images never come through: reference, heading, list, quote and link images', () {
      for (final md in [
        '![a][r]\n\n[r]: https://x.example/a.png',
        '![a][]\n\n[a]: https://x.example/a.png',
        '# ![a](https://x.example/a.png) title',
        '- ![a](https://x.example/a.png)',
        '1. ![a](https://x.example/a.png)',
        '> ![a](https://x.example/a.png)',
        '[![a](https://x.example/a.png)](https://x.example)',
        '| ![a](https://x.example/a.png) | b |\n| - | - |\n| c | d |',
        '![a](data:image/png;base64,AAAA)',
        '![a](\\\\server\\share\\a.png)',
      ]) {
        final s = all(md);
        expect(s, isNot(contains('image')), reason: md);
        expect(s, isNot(contains('"src"')), reason: md);
        expect(s, isNot(contains('x.example/a.png')), reason: md);
        expect(s, isNot(contains('server')), reason: md);
        expect(s, isNot(contains('base64')), reason: md);
      }
    });
  });
}
