// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

/// A binder page store whose [corruptAt]th write is damaged after it lands.
class CorruptingStore extends PageStore {
  CorruptingStore(super.directory, {required this.corruptAt});

  final int corruptAt;
  int saves = 0;

  @override
  Future<void> save(NotedPage page) async {
    await super.save(page);
    if (++saves == corruptAt) {
      final f = File('${directory.path}${Platform.pathSeparator}${page.id}.canvas');
      await f.writeAsString(' ', mode: FileMode.append);
    }
  }
}

void main() {
  late Directory root;
  late Directory pages; // standalone pages
  late Directory folder; // a binder folder
  late File settings;
  late List<Notebook> opened;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_binders');
    pages = await Directory('${root.path}/pages').create();
    folder = await Directory('${root.path}/Work').create();
    settings = File('${root.path}/app/binders.json');
    opened = [];
  });

  tearDown(() async {
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    await root.delete(recursive: true);
  });

  Notebook make({PageStore Function(Directory)? factory, Future<String?> Function()? pick}) {
    final nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: settings,
      pickFolder: pick,
      storeFactory: factory ?? PageStore.new,
    );
    opened.add(nb);
    return nb;
  }

  List<String> canvasFiles(Directory d) =>
      d.listSync().where((f) => f.path.endsWith('.canvas')).map((f) => f.path).toList();

  String read(Directory d, String id) => File('${d.path}/$id.canvas').readAsStringSync();

  Future<Binder> binderFile(Directory d) async =>
      (await BinderStore(d).read() as BinderFound).binder;

  List<String> listedPaths() {
    final top = RawObject.parse(settings.readAsStringSync());
    return (top['binders']!.decode() as List).cast<String>();
  }

  test('a new binder in an empty folder gets a binder file and is listed', () async {
    final nb = make();
    await nb.load();
    final section = await nb.addBinder(folder.path);
    expect(section.available, isTrue);
    expect(section.title, 'Work');
    expect(section.tree.roots, isEmpty);
    final b = await binderFile(folder);
    expect(b.title, 'Work');
    expect(b.owner, '');
    expect(binderPalette, contains(b.color));
    expect(b.created, isNotNull);
    expect(listedPaths(), [section.path]);
    // The standalone pages are untouched.
    expect(canvasFiles(pages), hasLength(1));
  });

  test('existing pages in the folder become the binder pages', () async {
    final store = PageStore(folder);
    final parent = PageMeta.create(id: 'aaaa', title: 'Parent', order: 0);
    await store.save(NotedPage.create(parent));
    await store.save(
      NotedPage.create(PageMeta.create(id: 'bbbb', parentId: 'aaaa', title: 'Child', order: 0)),
    );
    final nb = make();
    await nb.load();
    final section = await nb.addBinder(folder.path);
    expect(section.tree.roots.map((p) => p.id), ['aaaa']);
    expect(section.tree.childrenOf('aaaa').map((p) => p.id), ['bbbb']);
    expect(nb.binderOfPage('bbbb'), section.path);
    expect(nb.tree.roots.map((p) => p.id), isNot(contains('aaaa')));
    await nb.open('bbbb');
    expect(nb.currentId, 'bbbb');
  });

  test('a folder that already has a binder file is opened, not overwritten', () async {
    const text =
        '{"format":1,"binderId":"0123456789abcdef","x-future":{"k": [1,2]},'
        '"title":"Mine","description":"d","owner":"o","color":"#FF00897B","created":7}';
    File('${folder.path}/$binderFileName').writeAsStringSync(text);
    final nb = make();
    await nb.load();
    final section = await nb.addBinder(folder.path);
    expect(section.available, isTrue);
    expect(section.binder!.id, '0123456789abcdef');
    expect(section.title, 'Mine');
    expect(File('${folder.path}/$binderFileName').readAsStringSync(), text);
  });

  test('an unreadable or newer binder file is listed and never overwritten', () async {
    const text = '{"format":2,"binderId":"abc","title":"Future"}';
    File('${folder.path}/$binderFileName').writeAsStringSync(text);
    final nb = make();
    await nb.load();
    final section = await nb.addBinder(folder.path);
    expect(section.status, BinderStatus.unreadable);
    expect(section.reason, contains('newer'));
    expect(listedPaths(), [section.path]);
    await nb.updateBinder(section.path, title: 'x');
    expect(File('${folder.path}/$binderFileName').readAsStringSync(), text);
    expect(() => nb.createPage(binderPath: section.path), throwsA(isA<NotebookException>()));
  });

  test('the standalone pages folder cannot be a binder', () async {
    final nb = make();
    await nb.load();
    expect(() => nb.addBinder(pages.path), throwsA(isA<NotebookException>()));
    expect(nb.binders, isEmpty);
  });

  test('binders.json keeps the list across a new Notebook', () async {
    final second = await Directory('${root.path}/Home').create();
    final nb = make();
    await nb.load();
    final a = await nb.addBinder(folder.path);
    final b = await nb.addBinder(second.path);
    await nb.createPage(binderPath: a.path);
    expect(listedPaths(), [a.path, b.path]);
    // Fields the app doesn't know in binders.json are kept.
    final top = RawObject.parse(settings.readAsStringSync());
    settings.writeAsStringSync(top.set('x-future', RawJson.encode([1])).toRaw().text);

    final again = make();
    await again.load();
    expect(again.binders.map((s) => s.path), [a.path, b.path]);
    expect(again.binders.every((s) => s.available), isTrue);
    expect(again.binders.first.tree.roots, hasLength(1));
    await again.removeBinder(b.path);
    expect(settings.readAsStringSync(), contains('"x-future":[1]'));
    expect(listedPaths(), [a.path]);
  });

  test('a binder folder that is gone is shown as unavailable and kept', () async {
    final nb = make();
    await nb.load();
    final a = await nb.addBinder(folder.path);
    await nb.flush();
    await folder.delete(recursive: true);

    final again = make();
    await again.load();
    final s = again.binders.single;
    expect(s.path, a.path);
    expect(s.status, BinderStatus.unavailable);
    expect(folder.existsSync(), isFalse);
    // Another change to the list keeps it.
    final other = await Directory('${root.path}/Other').create();
    await again.addBinder(other.path);
    expect(listedPaths(), [a.path, again.binders.last.path]);
    expect(folder.existsSync(), isFalse);
  });

  test('pages and subpages created in a binder are saved in its folder', () async {
    final nb = make();
    await nb.load();
    final standalone = nb.currentId!;
    final s = await nb.addBinder(folder.path);
    final p = await nb.createPage(binderPath: s.path);
    final c = await nb.createPage(parentId: p);
    expect(canvasFiles(folder).map((f) => f.split(RegExp(r'[\\/]')).last).toSet(), {
      '$p.canvas',
      '$c.canvas',
    });
    expect(canvasFiles(pages).single, endsWith('$standalone.canvas'));
    expect(s.tree.childrenOf(p).single.id, c);
    expect(nb.tree.roots.single.id, standalone);
    // A subpage of a standalone page stays standalone.
    final sub = await nb.createPage(parentId: standalone);
    expect(File('${pages.path}/$sub.canvas').existsSync(), isTrue);
  });

  test('rename, move and indent work for binder pages', () async {
    final nb = make();
    await nb.load();
    final s = await nb.addBinder(folder.path);
    final a = await nb.createPage(binderPath: s.path);
    final b = await nb.createPage(binderPath: s.path);
    await nb.rename(a, 'Alpha');
    await nb.open(a);
    await nb.rename(b, 'Beta');
    expect(s.tree.roots.map((p) => p.id), [a, b]);
    expect(await nb.moveUp(b), isTrue);
    expect(await nb.indent(a), isTrue);
    await nb.flush();
    final disk = await PageStore(folder).scan();
    final tree = PageTree.build(disk.whereType<ReadablePage>().map((e) => e.meta));
    expect(tree.roots.map((p) => p.id), [b]);
    expect(tree.childrenOf(b).map((p) => p.id), [a]);
    expect(tree[b]!.title, 'Beta');
  });

  test('delete and undo work inside a binder', () async {
    final nb = make();
    await nb.load();
    final s = await nb.addBinder(folder.path);
    final p = await nb.createPage(binderPath: s.path);
    final c = await nb.createPage(parentId: p);
    final before = read(folder, c);
    final deleted = await nb.delete(p);
    expect(canvasFiles(folder), isEmpty);
    expect(s.tree.roots, isEmpty);
    // The open page was deleted, so a standalone page is open.
    expect(nb.binderOfPage(nb.currentId!), isNull);
    await nb.undoDelete(deleted);
    expect(canvasFiles(folder), hasLength(2));
    expect(read(folder, c), before);
    expect(s.tree.childrenOf(p).single.id, c);
    expect(nb.currentId, c);
  });

  group('moving pages between locations', () {
    late Notebook nb;
    late BinderSection s;
    late String q;
    late String p;
    late String c;
    late String g;

    setUp(() async {
      nb = make();
      await nb.load();
      s = await nb.addBinder(folder.path);
      q = nb.currentId!;
      p = await nb.createPage();
      c = await nb.createPage(parentId: p);
      g = await nb.createPage(parentId: c);
      await nb.flush();
    });

    test('a page with subpages moves into a binder and back out', () async {
      final pBefore = read(pages, p);
      final cBefore = read(pages, c);
      final gBefore = read(pages, g);
      expect(pBefore, contains('"order":1'));

      expect(await nb.moveToLocation(p, binderPath: s.path), isTrue);
      expect(canvasFiles(pages).single, endsWith('$q.canvas'));
      expect(canvasFiles(folder), hasLength(3));
      // The open page (g) stays open and now lives in the binder.
      expect(nb.currentId, g);
      expect(nb.binderOfPage(g), s.path);
      // Only the moved page's order changed; subpages are byte-identical.
      expect(read(folder, p), pBefore.replaceFirst('"order":1', '"order":0'));
      expect(read(folder, c), cBefore);
      expect(read(folder, g), gBefore);
      expect(s.tree.roots.map((x) => x.id), [p]);
      expect(s.tree.descendantsOf(p), [c, g]);
      expect(nb.tree.roots.map((x) => x.id), [q]);
      expect(nb.tree.descendantsOf(q), isEmpty);

      expect(await nb.moveToLocation(p), isTrue);
      expect(canvasFiles(folder), isEmpty);
      expect(canvasFiles(pages), hasLength(4));
      expect(read(pages, p), pBefore);
      expect(read(pages, c), cBefore);
      expect(read(pages, g), gBefore);
      expect(nb.currentId, g);
      expect(nb.binderOfPage(g), isNull);
      expect(nb.tree.roots.map((x) => x.id), [q, p]);
      expect(nb.tree.descendantsOf(p), [c, g]);
      // What the next start reads from disk agrees.
      final again = make();
      await again.load();
      expect(again.tree.descendantsOf(p), [c, g]);
      expect(again.binders.single.tree.roots, isEmpty);
    });

    test('dropping next to or into a page in another location', () async {
      final b1 = await nb.createPage(binderPath: s.path);
      final b2 = await nb.createPage(parentId: b1);
      await nb.flush();
      // Before a subpage: becomes its sibling, under b1.
      expect(await nb.moveRelative(p, b2, after: false), isTrue);
      expect(s.tree.childrenOf(b1).map((x) => x.id), [p, b2]);
      expect(nb.treeOfPage(c).parentIdOf(c), p);
      expect(nb.binderOfPage(g), s.path);
      expect(File('${pages.path}/$p.canvas').existsSync(), isFalse);
      // Back out, into a standalone page: its last subpage.
      expect(await nb.move(p, parentId: q), isTrue);
      expect(nb.tree.childrenOf(q).map((x) => x.id), [p]);
      expect(nb.tree.descendantsOf(q), [p, c, g]);
      expect(canvasFiles(folder), hasLength(2));
      expect(read(pages, p), contains('"parentId":"$q"'));
    });

    test('moving to a given index renumbers the target siblings', () async {
      final b1 = await nb.createPage(binderPath: s.path);
      final b2 = await nb.createPage(binderPath: s.path);
      expect(await nb.moveToLocation(p, binderPath: s.path, index: 1), isTrue);
      expect(s.tree.roots.map((x) => x.id), [b1, p, b2]);
      await nb.flush();
      final disk = await PageStore(folder).scan();
      final tree = PageTree.build(disk.whereType<ReadablePage>().map((e) => e.meta));
      expect(tree.roots.map((x) => x.id), [b1, p, b2]);
    });

    test('a failed verification leaves the sources in place', () async {
      nb.dispose();
      opened.clear();
      await Directory(folder.path).delete(recursive: true);
      await folder.create();
      settings.deleteSync();
      final bad = make(factory: (d) => CorruptingStore(d, corruptAt: 2));
      await bad.load();
      final target = await bad.addBinder(folder.path);
      await bad.open(g);
      final before = {for (final id in [p, c, g]) id: read(pages, id)};

      await expectLater(
        bad.moveToLocation(p, binderPath: target.path),
        throwsA(
          isA<NotebookException>().having((e) => e.message, 'message', contains('not copied')),
        ),
      );
      // Sources are untouched, nothing is left in the target.
      for (final id in [p, c, g]) {
        expect(read(pages, id), before[id]);
      }
      expect(canvasFiles(folder), isEmpty);
      expect(target.tree.roots, isEmpty);
      expect(bad.tree.descendantsOf(p), [c, g]);
      expect(bad.binderOfPage(p), isNull);
      // The open page is still open.
      expect(bad.currentId, g);
    });
  });

  test('cover edits are written to noted-binder.json, unknown fields kept', () async {
    File('${folder.path}/$binderFileName').writeAsStringSync(
      '{"format":1,"binderId":"0123456789abcdef","x-future":{"k": [1,2]},'
      '"title":"Mine","description":"","owner":"","color":"#FF00897B","created":7}',
    );
    final nb = make();
    await nb.load();
    final s = await nb.addBinder(folder.path);
    await nb.updateBinder(s.path, title: 'Renamed', description: 'About', owner: 'Me');
    await nb.updateBinder(s.path, color: binderPalette[4]);
    final text = File('${folder.path}/$binderFileName').readAsStringSync();
    expect(text, contains('"x-future":{"k": [1,2]}'));
    final b = await binderFile(folder);
    expect([b.title, b.description, b.owner, b.color], ['Renamed', 'About', 'Me', binderPalette[4]]);
    expect(b.id, '0123456789abcdef');
    expect(s.title, 'Renamed');
  });

  test('last edited moves forward when a page of the binder is saved', () async {
    final nb = make();
    await nb.load();
    final s = await nb.addBinder(folder.path);
    final p = await nb.createPage(binderPath: s.path);
    await nb.flush();
    final before = s.lastEdited!;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await nb.rename(p, 'Changed'); // the open page: changes through autosave
    await nb.flush();
    expect(s.lastEdited!.isAfter(before), isTrue);
    // A fresh start computes it from the files' modification times.
    final again = make();
    await again.load();
    final fromDisk = again.binders.single.lastEdited!;
    final newest = [
      File('${folder.path}/$p.canvas'),
      File('${folder.path}/$binderFileName'),
    ].map((f) => f.lastModifiedSync()).reduce((a, b) => a.isAfter(b) ? a : b);
    expect(fromDisk, newest);
  });

  test('removing a binder only unlists it', () async {
    final nb = make();
    await nb.load();
    final s = await nb.addBinder(folder.path);
    final p = await nb.createPage(binderPath: s.path);
    await nb.removeBinder(s.path);
    expect(nb.binders, isEmpty);
    expect(listedPaths(), isEmpty);
    expect(File('${folder.path}/$p.canvas').existsSync(), isTrue);
    expect(File('${folder.path}/$binderFileName').existsSync(), isTrue);
    expect(nb.binderOfPage(nb.currentId!), isNull);
  });

  test('New binder in another folder asks for a folder; cancelling does nothing', () async {
    String? answer;
    final nb = make(pick: () async => answer);
    await nb.load();
    expect(await nb.newBinderInFolder(), isNull);
    expect(nb.binders, isEmpty);
    answer = folder.path;
    final s = await nb.newBinderInFolder();
    expect(s!.available, isTrue);
    expect(nb.coverPath, s.path);
    await nb.open(nb.tree.roots.first.id);
    expect(nb.coverPath, isNull);
  });
}
