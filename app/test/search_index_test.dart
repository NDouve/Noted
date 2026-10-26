// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/notebook_search.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_core/noted_core.dart';

const _codec = NoteCodec();

NoteData noteData(List<String> lines) => NoteData({
  'document': {
    'type': 'page',
    'children': [
      for (final l in lines)
        {
          'type': 'paragraph',
          'data': {
            'delta': [
              if (l.isNotEmpty) {'insert': l},
            ],
          },
        },
    ],
  },
});

BoxRecord noteBox(String id, List<String> lines, {double y = 0}) {
  final data = noteData(lines);
  return BoxRecord.create(
    id: id,
    typeId: NoteCodec.id,
    dataVersion: 1,
    bounds: Bounds(0, y, 300, 60),
    data: RawJson.encode(_codec.encode(data)),
    snapshotText: _codec.snapshotText(data),
    rev: 'r',
  );
}

NotedPage notePage(
  String id,
  String title,
  List<List<String>> boxes, {
  String? parent,
  int order = 0,
}) {
  var p = NotedPage.create(
    PageMeta.create(id: id, parentId: parent, title: title, order: order),
  );
  for (final (i, lines) in boxes.indexed) {
    p = p.insertNode(noteBox('$id-b$i', lines, y: i * 100.0));
  }
  return p;
}

/// Every file under [dir] with its size and time, to see that nothing was
/// written, created or touched.
Map<String, String> snapshotOf(Directory dir) => {
  for (final f in dir.listSync(recursive: true).whereType<File>())
    f.path: '${f.lengthSync()}@${f.lastModifiedSync().millisecondsSinceEpoch}',
};

void main() {
  late Directory root;
  late Directory pages;
  late Directory binderDir;
  late Directory away;
  late List<Notebook> opened;
  late List<NotebookSearch> searches;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_search');
    pages = await Directory('${root.path}/pages').create();
    binderDir = await Directory('${root.path}/Work').create();
    away = Directory('${root.path}/Work-away');
    opened = [];
    searches = [];
  });

  tearDown(() async {
    for (final s in searches) {
      s.dispose();
    }
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Notebook make({bool watch = false}) {
    final nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
      watchFiles: watch,
      watchDebounce: const Duration(milliseconds: 40),
      folderCheckInterval: watch ? const Duration(milliseconds: 100) : Duration.zero,
    );
    opened.add(nb);
    return nb;
  }

  NotebookSearch searchOf(Notebook nb) {
    final s = NotebookSearch(nb);
    searches.add(s);
    return s;
  }

  Future<void> until(bool Function() ok, {int ms = 6000}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('condition not reached in time');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> savePage(Directory dir, NotedPage page) => PageStore(dir).save(page);

  List<String> hitIds(NotebookSearch s) => [for (final r in s.results) r.pageId];

  group('building the index', () {
    test('reads standalone pages and binder pages through the stores', () async {
      await savePage(pages, notePage('p1', 'Groceries', [['Buy apples and pears']]));
      await savePage(pages, notePage('p2', 'Other', [['Nothing here']]));
      final nb = make();
      await nb.load();
      final binder = await nb.addBinder(binderDir.path);
      await savePage(binderDir, notePage('b1', 'Recipes', [['Apple pie needs apples']]));
      // The binder was opened before b1 was written; open it again to read it.
      await nb.removeBinder(binder.path);
      final again = await nb.addBinder(binderDir.path);
      expect(again.available, isTrue);
      final s = searchOf(nb);
      await s.setText('apples');
      expect(hitIds(s).toSet(), {'p1', 'b1'});
    });

    test('results carry the page path and a snippet with the match marked', () async {
      final nb = make();
      await nb.load();
      final binder = await nb.addBinder(binderDir.path);
      final parent = await nb.createPage(binderPath: binder.path);
      await nb.rename(parent, 'Trips');
      final child = await nb.createPage(parentId: parent);
      await nb.rename(child, 'Lisbon');
      await nb.flush();
      await savePage(
        binderDir,
        notePage(child, 'Lisbon', [['Pack the umbrella for the Lisbon rain']], parent: parent),
      );
      await nb.removeBinder(binder.path);
      await nb.addBinder(binderDir.path);
      final s = searchOf(nb);
      await s.setText('umbrella');
      final r = s.results.single;
      expect(r.pageId, child);
      expect(r.path, [binder.title, 'Trips', 'Lisbon']);
      final snippet = r.boxes.single.snippet;
      expect(snippet.text, 'Pack the umbrella for the Lisbon rain');
      final h = snippet.highlights.single;
      expect(snippet.text.substring(h.start, h.end), 'umbrella');
      // Standalone pages sit under "Pages".
      await s.setText('nothing');
      expect(s.results, isEmpty);
    });

    test('matching rules apply: accents, case, whole words, phrases, AND', () async {
      await savePage(pages, notePage('p1', 'One', [['Crème brûlée recipe'], ['category list']]));
      await savePage(pages, notePage('p2', 'Two', [['The cat sat on the mat']]));
      final nb = make();
      await nb.load();
      final s = searchOf(nb);
      await s.setText('CREME BRULEE');
      expect(hitIds(s), ['p1']);
      await s.setText('cat');
      expect(hitIds(s), ['p2'], reason: 'category is not the word cat');
      await s.setText('"sat on" mat');
      expect(hitIds(s), ['p2']);
      await s.setText('cat zebra');
      expect(hitIds(s), isEmpty);
    });

    test('drawing boxes are skipped; unsupported boxes are searched by snapshot only', () async {
      var page = notePage('p1', 'Mixed', [['plain words']]);
      page = page
          .insertNode(
            BoxRecord.create(
              id: 'draw',
              typeId: 'noted.drawing',
              dataVersion: 1,
              bounds: const Bounds(0, 500, 100, 100),
              data: RawJson.parse('{"strokes":[{"note":"inkwords"}]}'),
              snapshotText: '',
              rev: 'r',
            ),
          )
          .insertNode(
            BoxRecord.create(
              id: 'vault',
              typeId: 'future.vault',
              dataVersion: 9,
              bounds: const Bounds(0, 700, 100, 100),
              // Not valid for any module, and holding a word that is not in
              // the snapshot: the index must never look at it.
              data: RawJson.parse('{"cipher":"hiddenword","garbage":[1,2]}'),
              snapshotText: 'sealed snapshot text',
              rev: 'r',
            ),
          );
      await savePage(pages, page);
      final nb = make();
      await nb.load();
      final s = searchOf(nb);
      await s.setText('inkwords');
      expect(s.results, isEmpty);
      await s.setText('hiddenword');
      expect(s.results, isEmpty);
      await s.setText('sealed snapshot');
      expect(s.results.single.boxes.single.boxId, 'vault');
      await s.setText('plain');
      expect(s.results.single.boxes.single.boxId, 'p1-b0');
      // The box is left exactly as it was.
      expect(
        File('${pages.path}/p1.canvas').readAsStringSync(),
        contains('"cipher":"hiddenword"'),
      );
    });
  });

  group('keeping it current', () {
    test('a page saved by the app is searched as saved', () async {
      await savePage(pages, notePage('p1', 'One', [['first draft']]));
      final nb = make();
      await nb.load();
      final s = searchOf(nb);
      await s.setText('revised');
      expect(s.results, isEmpty);
      final c = nb.current!;
      final box = c.page.nodes.whereType<BoxRecord>().single;
      c.commit(box.id, noteData(['revised text']));
      // Committed edits are in the page model before they are on disk.
      await s.setText('revised');
      expect(hitIds(s), ['p1'], reason: 'the open page is searched as the model holds it');
      await nb.flush();
      expect(File('${pages.path}/p1.canvas').readAsStringSync(), contains('revised'));
      await s.setText('revised');
      expect(hitIds(s), ['p1']);
      await s.setText('draft');
      expect(s.results, isEmpty);
    });

    test('a page changed on disk is picked up by the file watcher', () async {
      await savePage(pages, notePage('p1', 'One', [['open page']]));
      await savePage(pages, notePage('p2', 'Two', [['old content']], order: 1));
      final nb = make(watch: true);
      await nb.load();
      final s = searchOf(nb);
      await s.setText('old');
      expect(hitIds(s), ['p2']);
      await savePage(pages, notePage('p2', 'Two', [['brand new content']], order: 1));
      await until(() => nb.tree.roots.length == 2);
      await until(() {
        return s.index
            .search(SearchQuery.parse('brand'))
            .any((h) => h.pageId == 'p2');
      });
      await s.setText('brand');
      expect(hitIds(s), ['p2']);
      await s.setText('old');
      expect(s.results, isEmpty);
      // A new file appears.
      await savePage(pages, notePage('p3', 'Three', [['appeared later']], order: 2));
      await until(() => nb.tree.roots.length == 3);
      await until(() => s.index.containsPage('p3'));
      await s.setText('appeared');
      expect(hitIds(s), ['p3']);
    });

    test('a deleted page leaves the results', () async {
      await savePage(pages, notePage('p1', 'One', [['keep me']]));
      await savePage(pages, notePage('p2', 'Two', [['delete me']], order: 1));
      final nb = make();
      await nb.load();
      final s = searchOf(nb);
      await s.setText('me');
      expect(hitIds(s).toSet(), {'p1', 'p2'});
      await nb.delete('p2');
      await s.ensureReady();
      await s.setText('me');
      expect(hitIds(s), ['p1']);
      expect(s.index.containsPage('p2'), isFalse);
    });

    test('a file deleted on disk leaves the results', () async {
      await savePage(pages, notePage('p1', 'One', [['keep me']]));
      await savePage(pages, notePage('p2', 'Two', [['gone soon']], order: 1));
      final nb = make(watch: true);
      await nb.load();
      final s = searchOf(nb);
      await s.setText('soon');
      expect(hitIds(s), ['p2']);
      File('${pages.path}/p2.canvas').deleteSync();
      await until(() => !s.index.containsPage('p2'));
      await s.setText('soon');
      expect(s.results, isEmpty);
    });

    test('a page moved into a binder is found there', () async {
      await savePage(pages, notePage('p1', 'One', [['wanderer']]));
      await savePage(pages, notePage('p2', 'Two', [['stays']], order: 1));
      final nb = make();
      await nb.load();
      final binder = await nb.addBinder(binderDir.path);
      final s = searchOf(nb);
      await s.setText('wanderer');
      expect(s.results.single.path.first, 'Pages');
      await nb.moveToLocation('p1', binderPath: binder.path);
      await s.ensureReady();
      await s.setText('wanderer');
      expect(s.results.single.path.first, binder.title);
      expect(s.index.locationOf('p1'), binder.path);
    });
  });

  group('what is not searched', () {
    test('a binder that is away is listed with its reason; back, it is searched', () async {
      await savePage(pages, notePage('p1', 'One', [['standalone word']]));
      final nb = make(watch: true);
      await nb.load();
      final binder = await nb.addBinder(binderDir.path);
      await savePage(binderDir, notePage('b1', 'Inside', [['binder word']]));
      await nb.removeBinder(binder.path);
      await nb.addBinder(binderDir.path);
      final s = searchOf(nb);
      await s.setText('word');
      expect(hitIds(s).toSet(), {'p1', 'b1'});
      expect(s.notSearched, isEmpty);

      binderDir.renameSync(away.path);
      await until(() => nb.binders.single.missing);
      await s.ensureReady();
      await s.setText('word');
      expect(hitIds(s), ['p1']);
      expect(s.notSearched.map((n) => n.name), [nb.binders.single.title]);
      expect(s.notSearched.single.reason, contains('not found'));
      expect(s.index.containsPage('b1'), isFalse);

      away.renameSync(binderDir.path);
      await until(() => nb.binders.single.available);
      await until(() => s.index.containsPage('b1'));
      await s.setText('word');
      expect(hitIds(s).toSet(), {'p1', 'b1'});
      expect(s.notSearched, isEmpty);
    });

    test('a damaged binder is listed, and its pages are not searched', () async {
      final nb = make();
      await nb.load();
      final binder = await nb.addBinder(binderDir.path);
      await savePage(binderDir, notePage('b1', 'Inside', [['secret binder word']]));
      await nb.flush();
      await nb.removeBinder(binder.path);
      File('${binderDir.path}/$binderFileName').writeAsStringSync('{ not json');
      await nb.addBinder(binderDir.path).catchError((_) => binder);
      final s = searchOf(nb);
      await s.setText('secret');
      expect(s.results, isEmpty);
      expect(s.notSearched, isNotEmpty);
      expect(s.notSearched.first.reason, isNotEmpty);
    });

    test('an unreadable page file is listed with the reason', () async {
      await savePage(pages, notePage('p1', 'One', [['fine page']]));
      File('${pages.path}/broken.canvas').writeAsStringSync('this is not a canvas');
      final nb = make();
      await nb.load();
      final s = searchOf(nb);
      await s.setText('fine');
      expect(hitIds(s), ['p1']);
      final broken = s.notSearched.singleWhere((n) => n.name.startsWith('broken'));
      expect(broken.reason, isNotEmpty);
    });

    test('an unavailable standalone folder is listed', () async {
      final extra = await Directory('${root.path}/Extra').create();
      await savePage(extra, notePage('x1', 'Extra page', [['extra words']]));
      await savePage(pages, notePage('p1', 'One', [['plain words']]));
      final nb = make(watch: true);
      await nb.load();
      await nb.addStandaloneFolder(extra.path);
      final s = searchOf(nb);
      await s.setText('words');
      expect(hitIds(s).toSet(), {'p1', 'x1'});
      extra.renameSync('${root.path}/Extra-away');
      await until(() => nb.standaloneFolders.single.missing);
      await s.ensureReady();
      await s.setText('words');
      expect(hitIds(s), ['p1']);
      expect(s.notSearched.map((n) => n.name), ['Extra']);
    });
  });

  group('memory only', () {
    test('indexing and searching write, create and touch no file', () async {
      await savePage(pages, notePage('p1', 'One', [['write nothing']]));
      await savePage(pages, notePage('p2', 'Two', [['anywhere at all']], order: 1));
      final nb = make();
      await nb.load();
      final binder = await nb.addBinder(binderDir.path);
      await savePage(binderDir, notePage('b1', 'Inside', [['in a binder']]));
      await nb.removeBinder(binder.path);
      await nb.addBinder(binderDir.path);
      await nb.flush();

      // The data folders, the binders list's folder and the temp dir the
      // test lives in: the whole tree under root.
      final before = snapshotOf(root);

      final s = searchOf(nb);
      await s.setText('nothing');
      await s.setText('"in a binder"');
      await s.setText('anywhere zebra');
      await s.ensureReady();
      expect(s.index.pageCount, greaterThanOrEqualTo(3));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(snapshotOf(root), before);
      // No index or cache file by any name.
      final names = root
          .listSync(recursive: true)
          .map((e) => e.path.substring(root.path.length).toLowerCase());
      expect(names.where((n) => n.contains('index') || n.contains('search') || n.endsWith('.db')), isEmpty);
    });

    test('NotebookSearch and the index have no way to write a file', () {
      // The sources of the search code never import dart:io for writing:
      // the only dart:io use in notebook_search.dart is the exception type.
      final src = File('lib/src/notebook_search.dart').readAsStringSync();
      expect(src, isNot(contains('writeAs')));
      expect(src, isNot(contains('File(')));
      expect(src, isNot(contains('openWrite')));
      expect(src, isNot(contains('debugPrint')));
      expect(src, isNot(contains('print(')));
      final core = Directory('../packages/noted_core/lib/src/search')
          .listSync()
          .whereType<File>()
          .map((f) => f.readAsStringSync())
          .join();
      expect(core, isNot(contains('dart:io')));
      expect(core, isNot(contains('print(')));
    });
  });
}
