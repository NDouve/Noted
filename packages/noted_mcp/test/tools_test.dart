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
  late NotedLibrary library;
  late NotedTools tools; // no code

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('noted_mcp');
    library = await NotedLibrary.load(writeFixture(root));
    tools = NotedTools(library);
  });
  tearDownAll(() => root.deleteSync(recursive: true));

  List<Map<String, Object?>> listed(NotedTools t) =>
      (jsonDecode(t.listPages().text)['pages'] as List).cast<Map<String, Object?>>();

  group('AI access, inherited and tightened', () {
    test('each page gets its own, its parent\'s, its binder\'s or Guarded; looser choices are ignored', () {
      AiAccess ai(String id) => library.page(id)!.access;
      expect(ai(Ids.public), AiAccess.open, reason: 'own, top-level');
      expect(ai(Ids.publicChild), AiAccess.open, reason: 'inherited');
      expect(ai(Ids.hidden), AiAccess.guarded, reason: 'own Guarded tightens Open');
      expect(ai(Ids.hiddenChild), AiAccess.guarded, reason: 'inherited Guarded');
      expect(ai(Ids.looser), AiAccess.guarded, reason: 'Open under Guarded is ignored');
      expect(ai(Ids.plain), AiAccess.guarded, reason: 'the app default');
      expect(ai(Ids.plainChild), AiAccess.guarded, reason: 'Open under the default is ignored');
      expect(ai(Ids.priv), AiAccess.privileged, reason: 'a top-level standalone page may choose any value');
      expect(ai(Ids.privChild), AiAccess.privileged);
      expect(ai(Ids.privLoose), AiAccess.privileged, reason: 'Open under Privileged is ignored');
      expect(ai(Ids.privTight), AiAccess.guarded);
      expect(ai(Ids.unknown), AiAccess.guarded, reason: 'an unknown value is Guarded');
      expect(ai(Ids.legacyPage), AiAccess.open, reason: 'legacy page');
      expect(ai(Ids.legacyBox), AiAccess.guarded, reason: 'legacy box');
      expect(ai(Ids.legacyOff), AiAccess.guarded, reason: 'legacy off');
      expect(ai(Ids.binderPage), AiAccess.open, reason: 'from the binder');
      expect(ai(Ids.binderPriv), AiAccess.privileged, reason: 'own Privileged tightens the Open binder');
      expect(ai(Ids.binderGuarded), AiAccess.guarded);
      expect(ai(Ids.privBinderPage), AiAccess.privileged, reason: 'from a Privileged binder');
      expect(ai(Ids.guardedBinderPage), AiAccess.guarded, reason: 'a binder with nothing set: the default');
    });

    test('the server agrees with the core\'s effective-access helper on a chain', () {
      final chain = [library.page(Ids.looser)!.page.meta, library.page(Ids.hidden)!.page.meta, library.page(Ids.public)!.page.meta];
      expect(effectiveAiAccess(chain).value, library.page(Ids.looser)!.access);
    });

    test('a locked binder\'s pages are kept but marked, and never visible', () {
      expect(library.page(Ids.locked)!.locked, isTrue);
      expect(tools.visible.map((p) => p.id), isNot(contains(Ids.locked)));
    });
  });

  group('broken chains and duplicate ids', () {
    Future<NotedLibrary> fresh(void Function(Directory data, Directory root) change) async {
      final r = Directory.systemTemp.createTempSync('noted_mcp_chain');
      addTearDown(() => r.deleteSync(recursive: true));
      final d = writeFixture(r);
      change(d, r);
      return NotedLibrary.load(d);
    }

    test('a page whose Guarded parent file is deleted or corrupt is not the top: its looser value is ignored', () async {
      final deleted = await fresh((d, _) => File('${d.path}/pages/${Ids.hidden}.canvas').deleteSync());
      expect(deleted.page(Ids.looser)!.access, AiAccess.guarded);
      expect(NotedTools(deleted).readPage(Ids.looser).isError, isTrue);
      final corrupt = await fresh((d, _) => File('${d.path}/pages/${Ids.hidden}.canvas').writeAsStringSync('{ not json'));
      expect(corrupt.page(Ids.looser)!.access, AiAccess.guarded);
      expect(NotedTools(corrupt).search('kestrel').text, isNot(contains(Ids.looser)));
      // A parent that is still there, and Open, still lets a page tighten but nothing else.
      expect(library.page(Ids.publicChild)!.access, AiAccess.open);
    });

    test('a page whose parent is missing and that says nothing is Guarded; one that tightens keeps it', () async {
      final lib = await fresh((d, _) => File('${d.path}/pages/${Ids.priv}.canvas').deleteSync());
      expect(lib.page(Ids.privLoose)!.access, AiAccess.guarded);
      expect(lib.page(Ids.privChild)!.access, AiAccess.guarded);
    });

    test('a page id in two standalone folders appears once, with the stricter access', () async {
      final lib = await fresh((d, r) {
        final other = Directory('${r.path}/Other')..createSync();
        final copy = page(Ids.public, 'Public plans', ai: 'guarded', nodes: [box('n99', 'noted.note', simpleNote('zebra copy'), const Bounds(0, 0, 100, 40))]);
        File('${other.path}/${Ids.public}.canvas').writeAsStringSync(writePage(copy));
        File('${d.path}/binders.json').writeAsStringSync(
          jsonEncode({
            'format': 1,
            'standaloneFolders': [other.path],
            'binders': <String>[],
          }),
        );
      });
      expect(lib.pages.where((p) => p.id == Ids.public), hasLength(1));
      expect(lib.page(Ids.public)!.access, AiAccess.guarded);
      expect(NotedTools(lib).readPage(Ids.public).isError, isTrue);
    });
  });

  group('list_pages', () {
    test('lists only Open pages, with id, title, parent, access and place', () {
      final pages = {for (final p in listed(tools)) p['id']: p};
      expect(pages.keys.toSet(), openIds);
      expect(pages[Ids.public], {'id': Ids.public, 'title': 'Public plans', 'parent': null, 'access': 'open', 'location': 'Pages'});
      expect(pages[Ids.publicChild]!['parent'], Ids.public);
      expect(pages[Ids.binderPage]!['location'], 'Trips');
    });

    test('a page under a hidden page shows its nearest visible ancestor as parent', () {
      final granted = NotedTools(library, granted: {Ids.privChild});
      // privChild's parent (priv) isn't granted: no parent shown.
      final pages = {for (final p in listed(granted)) p['id']: p};
      expect(pages[Ids.privChild]!['parent'], isNull);
      final both = NotedTools(library, granted: {Ids.priv, Ids.privChild});
      expect({for (final p in listed(both)) p['id']: p}[Ids.privChild]!['parent'], Ids.priv);
    });

    test('a grant adds its Privileged pages, never a Guarded or locked one', () {
      final t = NotedTools(library, granted: {...privilegedIds, ...guardedIds});
      final ids = listed(t).map((p) => p['id']).toSet();
      expect(ids, {...openIds, ...privilegedIds});
    });
  });

  group('read_page', () {
    test('title, then every box in reading order with its type', () {
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
      expect(tools.readBox('note').text, '''
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

    test('every box of a readable page is readable, AI boxes with their markers', () {
      final text = tools.readPage(Ids.aiOpen).text;
      expect(text, contains('**ai** · box `aiA`'));
      expect(text, contains('**ai** · box `aiB`'));
      expect(text, contains('okapi from A'));
      expect(text, contains('okapi from B'));
      expect(text, contains('<ai-written>'));
      expect(text, isNot(contains('your box')));
      expect(text, isNot(contains('9999999999999999')), reason: 'the owner field is not output');
    });

    test('hidden pages are not found, exactly like pages that don\'t exist', () {
      for (final id in [...guardedIds, ...privilegedIds]) {
        final out = tools.readPage(id);
        expect(out.isError, isTrue, reason: id);
        expect(out.text, noSuchPage(id), reason: id);
      }
      expect(tools.readPage('ffffffffffffffff').text, noSuchPage('ffffffffffffffff'));
    });

    test('a grant opens the Privileged pages it names and nothing else', () {
      final t = NotedTools(library, granted: {Ids.priv});
      expect(t.readPage(Ids.priv).text, contains('giraffe privileged text'));
      expect(t.readPage(Ids.privChild).isError, isTrue, reason: 'not in the grant');
      expect(t.readPage(Ids.hidden).text, noSuchPage(Ids.hidden));
      final wide = NotedTools(library, granted: {Ids.priv, Ids.hidden, Ids.locked});
      expect(wide.readPage(Ids.hidden).isError, isTrue, reason: 'Guarded even when named');
      expect(wide.readPage(Ids.locked).isError, isTrue, reason: 'locked binder even when named');
    });

    test('a link to a page the AI can\'t read keeps only its text', () {
      final text = tools.readBox('note').text;
      expect(text, contains('See hidden notes,'));
      expect(text, isNot(contains(Ids.hidden)));
    });
  });

  group('read_box', () {
    test('one box by id as read_page shows it; enforcement is the same', () {
      expect(tools.readBox('img').text, '**image** · box `img`\n\n[image: A cat on a map]');
      expect(tools.readBox('enc').text, '**encrypted** · box `enc`\n\n[encrypted box]');
      expect(tools.readBox('nope').isError, isTrue);
      expect(tools.readBox('n8').text, noSuchBox('n8'), reason: 'a Privileged page without a grant');
      expect(tools.readBox('n3').text, noSuchBox('n3'));
      expect(tools.readBox('n10').text, contains('zebra binder'));
      expect(NotedTools(library, granted: {Ids.priv}).readBox('n8').text, contains('giraffe'));
      // Box ids are per page: page_id narrows the read.
      expect(tools.readBox('n2', pageId: Ids.publicChild).text, contains('zebra socks'));
      expect(tools.readBox('n2', pageId: Ids.public).text, noSuchBox('n2'));
      expect(tools.readBox('n2', pageId: Ids.hidden).text, noSuchBox('n2'));
    });
  });

  group('search', () {
    List<Map<String, Object?>> results(NotedTools t, String q) =>
        (jsonDecode(t.search(q).text)['results'] as List).cast<Map<String, Object?>>();

    test('finds text and titles on Open pages only', () {
      final ids = results(tools, 'zebra').map((r) => r['id']).toSet();
      expect(ids, {Ids.public, Ids.publicChild, Ids.legacyPage, Ids.binderPage});
      expect(results(tools, 'giraffe'), isEmpty, reason: 'a Privileged page without a grant');
      expect(results(tools, 'kestrel'), isEmpty);
      expect(results(tools, 'diary'), isEmpty, reason: 'Guarded titles are not searched');
      expect(results(tools, 'vault'), isEmpty, reason: 'locked binders are invisible');
    });

    test('a grant adds the Privileged pages it names', () {
      final t = NotedTools(library, granted: {Ids.priv, Ids.privBinderPage});
      expect(results(t, 'giraffe').map((r) => r['id']), [Ids.priv]);
      expect(results(t, 'taxes').map((r) => r['id']), [Ids.privBinderPage]);
    });

    test('placeholders are searched, never the data behind them', () {
      expect(results(tools, secret), isEmpty);
      expect(results(tools, 'encrypted').map((r) => r['id']), [Ids.public]);
    });

    test('a blank query is an error', () {
      expect(tools.search('  ').isError, isTrue);
    });
  });

  test('hidden pages are absent from every output', () {
    final outputs = <String>[
      tools.listPages().text,
      for (final q in ['zebra', 'hidden', 'diary', 'child', 'binder', 'secret', 'plain', 'okapi', 'vault', 'legacy'])
        tools.search(q).text,
      for (final p in tools.visible) tools.readPage(p.id).text,
      for (final p in tools.visible)
        for (final n in p.page.nodes) tools.readBox(n.id).text,
    ];
    for (final text in outputs) {
      for (final id in [...guardedIds, ...privilegedIds]) {
        expect(text, isNot(contains(id)), reason: 'id $id in:\n$text');
      }
      for (final title in guardedTitles) {
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
