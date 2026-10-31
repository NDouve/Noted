// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core_read.dart';
import 'package:noted_mcp/noted_mcp.dart';

import 'fixture.dart';

void main() {
  late Directory root;
  late NotedTools tools;

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('noted_mcp');
    tools = NotedTools(await NotedLibrary.load(writeFixture(root)));
  });
  tearDownAll(() => root.deleteSync(recursive: true));

  List<Map<String, Object?>> listed() =>
      (jsonDecode(tools.listPages().text)['pages'] as List).cast<Map<String, Object?>>();

  group('AI settings, inherited and overridden', () {
    test('each page gets its own, its parent\'s, its binder\'s or Off', () {
      AiSetting ai(String id) => tools.library.page(id)!.ai;
      expect(ai(Ids.public), AiSetting.wholePage, reason: 'own');
      expect(ai(Ids.publicChild), AiSetting.wholePage, reason: 'inherited');
      expect(ai(Ids.hidden), AiSetting.off, reason: 'own Off under Whole page');
      expect(ai(Ids.hiddenChild), AiSetting.off, reason: 'inherited Off');
      expect(ai(Ids.boxUnderHidden), AiSetting.boxOnly, reason: 'own Box only under Off');
      expect(ai(Ids.plain), AiSetting.off, reason: 'the default');
      expect(ai(Ids.plainChild), AiSetting.wholePage, reason: 'own Whole page under the default');
      expect(ai(Ids.boxy), AiSetting.boxOnly);
      expect(ai(Ids.unknown), AiSetting.off, reason: 'an unknown value follows the parent');
      expect(ai(Ids.binderPage), AiSetting.wholePage, reason: 'from the binder');
      expect(ai(Ids.binderOff), AiSetting.off, reason: 'own Off in the binder');
      expect(tools.library.page(Ids.locked), isNull, reason: 'a locked binder is not read');
    });
  });

  group('list_pages', () {
    test('lists only pages that aren\'t Off, with id, title, parent, AI setting and place', () {
      final pages = {for (final p in listed()) p['id']: p};
      expect(pages.keys.toSet(), {Ids.public, Ids.publicChild, Ids.boxUnderHidden, Ids.plainChild, Ids.boxy, Ids.binderPage});
      expect(pages[Ids.public], {'id': Ids.public, 'title': 'Public plans', 'parent': null, 'ai': 'page', 'location': 'Pages'});
      expect(pages[Ids.publicChild]!['parent'], Ids.public);
      expect(pages[Ids.boxy]!['ai'], 'box');
      expect(pages[Ids.binderPage]!['location'], 'Trips');
    });

    test('a page under an Off page shows its nearest visible ancestor as parent', () {
      final pages = {for (final p in listed()) p['id']: p};
      expect(pages[Ids.boxUnderHidden]!['parent'], Ids.public, reason: 'the Off page between is skipped');
      expect(pages[Ids.plainChild]!['parent'], isNull, reason: 'no visible ancestor');
    });
  });

  group('read_page', () {
    test('Whole page: title, then every box in reading order with its type', () {
      final out = tools.readPage(Ids.public);
      expect(out.isError, isFalse);
      final text = out.text;
      expect(text, startsWith('# Public plans\n'));
      final order = ['box `note`', 'box `img`', 'box `drw`', 'box `file`', 'box `enc`', 'box `odd`'];
      final at = [for (final o in order) text.indexOf(o)];
      expect(at, everyElement(greaterThan(0)));
      expect(at, orderedEquals([...at]..sort()), reason: 'top to bottom, then left to right');
      expect(text, contains('**note** · box `note`'));
      expect(text, contains('**image** · box `img`\n\n[image: A cat on a map]'));
      expect(text, contains('**drawing** · box `drw`\n\n[drawing]'));
      expect(text, contains('**file** · box `file`\n\n[file: Itinerary.pdf]'));
    });

    test('encrypted and unsupported boxes are placeholders, never their data', () {
      final text = tools.readPage(Ids.public).text;
      expect(text, contains('**encrypted** · box `enc`\n\n[encrypted box]'));
      expect(text, contains('**unsupported** · box `odd`\n\n[unsupported box]'));
      expect(text, isNot(contains(secret)), reason: 'not from data, snapshots, drawings or embedded files');
    });

    test('a note comes out as markdown: headings, styles, lists, links, equations, tables', () {
      expect(tools.readBox(Ids.public, 'note').text, '''
**note** · box `note`

## Trip plan

Pack the **zebra** tent and _maps_.

- Tickets
  - Train
1. Book
2. Pay
- [x] Passport

See hidden notes, [the child](noted:page/${Ids.publicChild}) and [the web](https://example.com).

\$\$
E = mc^2
\$\$

| Item | Cost |
| --- | --- |
| Tent | 120 |
| Total | 120 |''');
    });

    test('Box only: listed and readable by title, but no box content', () {
      final out = tools.readPage(Ids.boxy);
      expect(out.isError, isFalse);
      expect(out.text, startsWith('# Zebra boxes\n'));
      expect(out.text, contains('Box only'));
      expect(out.text, isNot(contains('giraffe')));
      expect(out.text, isNot(contains(secret)));
      expect(tools.readPage(Ids.boxUnderHidden).text, isNot(contains('kestrel')));
    });

    test('Off pages are not found, exactly like pages that don\'t exist', () {
      for (final id in offIds) {
        final out = tools.readPage(id);
        expect(out.isError, isTrue, reason: id);
        expect(out.text, noSuchPage(id), reason: id);
      }
      expect(tools.readPage('ffffffffffffffff').text, noSuchPage('ffffffffffffffff'));
    });
  });

  group('read_box', () {
    test('one box as read_page shows it; enforcement is the same', () {
      expect(tools.readBox(Ids.public, 'img').text, '**image** · box `img`\n\n[image: A cat on a map]');
      expect(tools.readBox(Ids.public, 'enc').text, '**encrypted** · box `enc`\n\n[encrypted box]');
      expect(tools.readBox(Ids.public, 'nope').isError, isTrue);
      expect(tools.readBox(Ids.boxy, 'n8').text, isNot(contains('giraffe')));
      expect(tools.readBox(Ids.hidden, 'n3').text, noSuchPage(Ids.hidden));
      expect(tools.readBox(Ids.binderPage, 'n10').text, contains('zebra binder'));
    });
  });

  group('search', () {
    List<Map<String, Object?>> results(String q) =>
        (jsonDecode(tools.search(q).text)['results'] as List).cast<Map<String, Object?>>();

    test('finds text on Whole page pages and titles on Box only pages, nothing on Off pages', () {
      final ids = results('zebra').map((r) => r['id']).toSet();
      expect(ids, {Ids.public, Ids.publicChild, Ids.plainChild, Ids.binderPage, Ids.boxy});
      // Box only: only its title matched.
      final boxy = results('zebra').firstWhere((r) => r['id'] == Ids.boxy);
      expect(boxy['matches'], ['title: Zebra boxes']);
      expect(results('giraffe'), isEmpty, reason: 'the text of a Box only page is not searched');
      expect(results('kestrel'), isEmpty);
      expect(results('diary'), isEmpty, reason: 'Off titles are not searched');
      expect(results('vault'), isEmpty, reason: 'locked binders are invisible');
    });

    test('placeholders are searched, never the data behind them', () {
      expect(results(secret), isEmpty);
      expect(results('encrypted').map((r) => r['id']), [Ids.public]);
    });

    test('a blank query is an error', () {
      expect(tools.search('  ').isError, isTrue);
    });
  });

  test('Off pages are absent from every output', () {
    final outputs = <String>[
      tools.listPages().text,
      for (final q in ['zebra', 'hidden', 'diary', 'child', 'binder', 'secret', 'plain'])
        tools.search(q).text,
      for (final p in tools.visible) tools.readPage(p.id).text,
      for (final p in tools.visible)
        for (final n in p.page.nodes) tools.readBox(p.id, n.id).text,
    ];
    for (final text in outputs) {
      for (final id in offIds) {
        expect(text, isNot(contains(id)), reason: 'id $id in:\n$text');
      }
      for (final title in offTitles) {
        expect(text, isNot(contains(title)), reason: 'title "$title" in:\n$text');
      }
      expect(text, isNot(contains(secret)));
    }
  });

  test('a library without settings or binders reads the default pages folder only', () async {
    final empty = Directory.systemTemp.createTempSync('noted_mcp_empty');
    addTearDown(() => empty.deleteSync(recursive: true));
    final lib = await NotedLibrary.load(empty);
    expect(lib.pages, isEmpty);
    expect(empty.listSync(), isEmpty, reason: 'reading never creates anything');
  });
}
