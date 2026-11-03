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

  @override
  Future<bool> saveNew(NotedPage page, {Future<void> Function()? beforePublish}) async {
    final ok = await super.saveNew(page, beforePublish: beforePublish);
    if (ok && ++saves == corruptAt) {
      final f = File('${directory.path}${Platform.pathSeparator}${page.id}.canvas');
      await f.writeAsString(' ', mode: FileMode.append);
    }
    return ok;
  }
}

/// A binder page store whose deletes of [failDelete] and (when [failSave]) all
/// writes fail, like a source drive that went away.
class FlakyStore extends PageStore {
  FlakyStore(super.directory);

  final Set<String> failDelete = {};
  bool failSave = false;

  /// Pages whose writes fail (the others can be written).
  final Set<String> failSaveIds = {};

  /// Pages whose file can't be read back, like a file locked by another program.
  final Set<String> failRead = {};

  /// Runs when a delete of one of [failDelete] is attempted, before it fails.
  void Function(String pageId)? onFailedDelete;

  /// Makes writes fail from the first successful delete on.
  bool failSaveAfterDelete = false;

  @override
  Future<void> save(NotedPage page) async {
    if (failSave || failSaveIds.contains(page.id)) {
      onFailedSave?.call(page.id);
      throw const FileSystemException('drive gone');
    }
    saves.update(page.id, (n) => n + 1, ifAbsent: () => 1);
    await super.save(page);
  }

  @override
  Future<bool> saveNewText(
    NotedPage page,
    String text, {
    Future<void> Function()? beforePublish,
  }) async {
    if (failSave || failSaveIds.contains(page.id)) {
      onFailedSave?.call(page.id);
      throw const FileSystemException('drive gone');
    }
    final ok = await super.saveNewText(page, text, beforePublish: beforePublish);
    if (ok) saves.update(page.id, (n) => n + 1, ifAbsent: () => 1);
    return ok;
  }

  /// How often each page was written.
  final Map<String, int> saves = {};

  @override
  Future<String> readText(String pageId) {
    if (failRead.contains(pageId)) throw const FileSystemException('locked');
    final n = reads.update(pageId, (n) => n + 1, ifAbsent: () => 1);
    onRead?.call(pageId, n);
    return super.readText(pageId);
  }

  /// How often each page's text was read, and a hook run before each read
  /// (with the page and the count including this read).
  final Map<String, int> reads = {};
  void Function(String pageId, int count)? onRead;

  @override
  Future<void> delete(String pageId) async {
    if (failDelete.contains(pageId)) {
      onFailedDelete?.call(pageId);
      throw const FileSystemException('drive gone');
    }
    await super.delete(pageId);
    if (failSaveAfterDelete) failSave = true;
  }

  /// Pages whose compare-and-delete runs the two seam hooks below (the
  /// move-aside and the read of the set-aside file).
  final Set<String> seamIds = {};
  void Function()? seamBeforeMoveAside;
  void Function()? seamAfterRead;
  Future<void> Function()? seamBeforeDelete;

  /// Runs at the start of a compare-and-delete of a page, before the check.
  void Function(String pageId)? beforeDeleteIfUnchanged;

  @override
  Future<DeleteResult> deleteIfUnchanged(
    String pageId,
    String expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    Future<void> Function()? beforeDelete,
    void Function()? beforeRestore,
  }) async {
    if (failDelete.contains(pageId)) {
      onFailedDelete?.call(pageId);
      throw const FileSystemException('drive gone');
    }
    beforeDeleteIfUnchanged?.call(pageId);
    final seam = seamIds.contains(pageId);
    final r = await super.deleteIfUnchanged(
      pageId,
      expectedText,
      beforeMoveAside: seam ? seamBeforeMoveAside : beforeMoveAside,
      afterRead: seam ? seamAfterRead : afterRead,
      beforeDelete: seam ? seamBeforeDelete : beforeDelete,
      beforeRestore: beforeRestore,
    );
    if (r.deleted && failSaveAfterDelete) failSave = true;
    return r;
  }

  /// Pages whose load fails with a raw error.
  final Set<String> failLoad = {};

  /// Runs when a write of a page is refused (see [failSave]), before it fails.
  void Function(String pageId)? onFailedSave;

  @override
  Future<NotedPage> load(String pageId) {
    if (failLoad.contains(pageId)) throw const FileSystemException('cannot read');
    return super.load(pageId);
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

  group('a move whose source deletion fails half way', () {
    late FlakyStore source;
    late Notebook nb;
    late BinderSection s;
    late String a;
    late String b;

    setUp(() async {
      nb = make(
        factory: (d) {
          final st = FlakyStore(d);
          if (d.path == folder.path) source = st;
          return st;
        },
      );
      await nb.load();
      s = await nb.addBinder(folder.path);
      a = await nb.createPage(binderPath: s.path);
      b = await nb.createPage(parentId: a);
      await nb.flush();
    });

    tearDown(() {
      source.failSaveAfterDelete = false;
      source.failSave = false;
      source.failDelete.clear();
    });

    test('keeps the copy of a page that could not be put back', () async {
      final aBefore = read(folder, a);
      final bBefore = read(folder, b);
      source.failDelete.add(b);
      // Deleting a works, deleting b fails, putting a back fails too.
      source.failSaveAfterDelete = true;

      await expectLater(
        nb.moveToLocation(a),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            allOf(contains('partly'), isNot(contains('nothing was moved')), contains('Pages')),
          ),
        ),
      );
      // a's only remaining copy is at the destination, byte-identical.
      expect(File('${folder.path}/$a.canvas').existsSync(), isFalse);
      expect(read(pages, a), contains('"pageId":"$a"'));
      expect(read(pages, a), isNot(equals(aBefore)));
      expect(File('${pages.path}/$b.canvas').existsSync(), isFalse);
      // b is intact at its source.
      expect(read(folder, b), bBefore);
      // The tree reports where each page really is.
      expect(nb.binderOfPage(a), isNull);
      expect(nb.binderOfPage(b), s.path);
      expect(nb.tree.roots.map((x) => x.id), contains(a));
    });

    test('a placement that fails after the move completed says the page was moved', () async {
      await nb.open(a);
      await nb.flush();
      final other = nb.tree.roots.single.id;
      expect(nb.currentId, a);
      // The page already in "Pages" can't be read, so renumbering it fails.
      File('${pages.path}/$other.canvas').writeAsStringSync('not a page');
      await expectLater(
        nb.moveToLocation(a, index: 0),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            allOf(startsWith('The page was moved, but it could not be put at that position'), isNot(contains('Could not move'))),
          ),
        ),
      );
      expect(nb.binderOfPage(a), isNull);
      expect(File('${folder.path}/$a.canvas').existsSync(), isFalse);
      expect(File('${pages.path}/$a.canvas').existsSync(), isTrue);
    });

    test('a file that appears at the old path just before the page is put back is never written over', () async {
      source.failDelete.add(b);
      final before = source.saves[a] ?? 0;
      nb.restoreBeforePublishHook = () async => File('${folder.path}/$a.canvas').writeAsStringSync('written elsewhere');
      await expectLater(
        nb.moveToLocation(a),
        throwsA(
          isA<NotebookException>()
              .having((e) => e.message, 'message', contains('Another file appeared at the old place'))
              .having((e) => e.needsAction, 'needsAction', isTrue),
        ),
      );
      expect(File('${folder.path}/$a.canvas').readAsStringSync(), 'written elsewhere');
      expect(source.saves[a] ?? 0, before, reason: 'the page is not written');
      expect(folder.listSync().where((f) => f.path.contains('.tmp')), isEmpty);
    });

    test('an empty file that appears at the old path just before publishing is left untouched', () async {
      source.failDelete.add(b);
      nb.restoreBeforePublishHook = () async => File('${folder.path}/$a.canvas').writeAsStringSync('');
      await expectLater(
        nb.moveToLocation(a),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('Another file appeared at the old place'))),
      );
      expect(File('${folder.path}/$a.canvas').lengthSync(), 0);
    });

    test('a raw error while reading a source is turned into a message', () async {
      source.failLoad.add(a);
      await expectLater(
        nb.moveToLocation(a),
        throwsA(
          isA<NotebookException>()
              .having((e) => e.message, 'message', 'Could not move the page.')
              .having((e) => e.needsAction, 'needsAction', isFalse),
        ),
      );
      expect(read(folder, a), contains('"pageId":"$a"'));
    });

    test('removes every copy when the sources are put back', () async {
      final aBefore = read(folder, a);
      final bBefore = read(folder, b);
      source.failDelete.add(b);

      await expectLater(
        nb.moveToLocation(a),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            contains('nothing was moved'),
          ),
        ),
      );
      expect(read(folder, a), aBefore);
      expect(read(folder, b), bBefore);
      expect(File('${pages.path}/$a.canvas').existsSync(), isFalse);
      expect(File('${pages.path}/$b.canvas').existsSync(), isFalse);
      expect(nb.binderOfPage(a), s.path);
      expect(nb.binderOfPage(b), s.path);
    });

    test('a source replaced after it was read for the copy: nothing is deleted, the copies are dropped', () async {
      late String edited;
      source.reads.clear();
      source.onRead = (id, n) {
        // The third read of b is the check of all sources before any delete.
        if (id == b && n == 3) {
          edited = read(folder, b).replaceFirst('"title":"', '"title":"Synced from elsewhere ');
          File('${folder.path}/$b.canvas').writeAsStringSync(edited);
        }
      };
      final aBefore = read(folder, a);

      await expectLater(
        nb.moveToLocation(a),
        throwsA(
          isA<NotebookException>()
              .having(
                (e) => e.message,
                'message',
                allOf(contains('Nothing was moved.'), contains('newer version'), isNot(contains('partly'))),
              )
              .having((e) => e.needsAction, 'needsAction', isTrue),
        ),
      );
      expect(read(folder, b), edited, reason: 'the newer source is kept byte for byte');
      expect(read(folder, a), aBefore, reason: 'nothing was deleted, not even the unchanged page');
      expect(File('${pages.path}/$a.canvas').existsSync(), isFalse);
      expect(File('${pages.path}/$b.canvas').existsSync(), isFalse, reason: "this move's own copies are dropped");
      expect(nb.binderOfPage(b), s.path);
    });

    test('a source replaced between the check and its delete is kept; the earlier delete is put back', () async {
      late String edited;
      source.beforeDeleteIfUnchanged = (id) {
        if (id == b) {
          edited = read(folder, b).replaceFirst('"title":"', '"title":"Synced late ');
          File('${folder.path}/$b.canvas').writeAsStringSync(edited);
        }
      };
      final aBefore = read(folder, a);

      await expectLater(
        nb.moveToLocation(a),
        throwsA(
          isA<NotebookException>()
              .having(
                (e) => e.message,
                'message',
                allOf(contains('was not moved'), contains('newer version'), contains('left there'), isNot(contains('partly'))),
              )
              .having((e) => e.needsAction, 'needsAction', isTrue),
        ),
      );
      expect(read(folder, b), edited);
      expect(read(folder, a), aBefore, reason: 'a was deleted first and is put back byte for byte');
      expect(File('${pages.path}/$a.canvas').existsSync(), isFalse);
      expect(File('${pages.path}/$b.canvas').existsSync(), isFalse);
      expect(folder.listSync().where((f) => f.path.contains('.cas-')), isEmpty);
      expect(nb.binderOfPage(a), s.path);
      expect(nb.binderOfPage(b), s.path);
    });

    test('a source that cannot be read at the check stops the move with the copies dropped', () async {
      source.reads.clear();
      source.onRead = (id, n) {
        if (id == b && n >= 2) source.failRead.add(b);
      };
      final bBefore = read(folder, b);
      await expectLater(
        nb.moveToLocation(a),
        throwsA(
          isA<NotebookException>().having((e) => e.message, 'message', contains('could not be read in Work to check it')),
        ),
      );
      source.failRead.clear();
      expect(read(folder, b), bBefore);
      expect(File('${pages.path}/$a.canvas').existsSync(), isFalse);
      expect(File('${pages.path}/$b.canvas').existsSync(), isFalse);
    });

    test('a source that changes while it is being read stops the move before anything is written', () async {
      source.reads.clear();
      source.onRead = (id, n) {
        // The second read of a is the one that follows the load.
        if (id == a && n == 2) {
          File('${folder.path}/$a.canvas').writeAsStringSync(read(folder, a).replaceFirst('"title":"', '"title":"X '));
        }
      };
      await expectLater(
        nb.moveToLocation(a),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('changed while it was being read'))),
      );
      expect(File('${pages.path}/$a.canvas').existsSync(), isFalse);
      expect(File('${pages.path}/$b.canvas').existsSync(), isFalse);
    });

    test('a restore puts back the copied bytes, not a rewritten page', () async {
      final crlf = '${read(folder, a)}\r\n';
      File('${folder.path}/$a.canvas').writeAsStringSync(crlf);
      source.failDelete.add(b);
      await expectLater(nb.moveToLocation(a), throwsA(isA<NotebookException>()));
      expect(read(folder, a), crlf, reason: 'a was deleted, then put back as it was, line ends included');
      expect(File('${pages.path}/$a.canvas').existsSync(), isFalse);
    });

    test('a newer file appearing while the source is set aside: both kept, reported', () async {
      source.seamIds.add(b);
      late String newer;
      source.seamBeforeMoveAside = () {
        newer = read(folder, b).replaceFirst('"title":"', '"title":"Newer ');
        File('${folder.path}/$b.canvas').writeAsStringSync(newer);
      };
      source.seamAfterRead = () => File('${folder.path}/$b.canvas').writeAsStringSync('arrived meanwhile');

      await expectLater(
        nb.moveToLocation(a),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('newer version'))),
      );
      expect(read(folder, b), 'arrived meanwhile', reason: 'the file at the path is never written over');
      final kept = folder.listSync().where((f) => f.path.endsWith('.cas-old')).toList();
      expect(kept, hasLength(1), reason: 'the set-aside version is kept for the next scan');
      expect(File(kept.single.path).readAsStringSync(), newer);
      expect(File('${pages.path}/$b.canvas').existsSync(), isFalse);
    });

    test('a source that vanished while being deleted: the copy is the page', () async {
      source.seamIds.add(b);
      source.seamBeforeMoveAside = () => File('${folder.path}/$b.canvas').deleteSync();
      expect(await nb.moveToLocation(a), isTrue);
      expect(File('${pages.path}/$b.canvas').existsSync(), isTrue);
      expect(File('${folder.path}/$b.canvas').existsSync(), isFalse);
      expect(nb.binderOfPage(b), isNull);
    });

    test('a source that vanishes at the check while another is stale: its copy is kept, the stale one is not moved', () async {
      source.reads.clear();
      late String edited;
      source.onRead = (id, n) {
        if (n != 3) return;
        if (id == a) File('${folder.path}/$a.canvas').deleteSync();
        if (id == b) {
          edited = read(folder, b).replaceFirst('"title":"', '"title":"Newer ');
          File('${folder.path}/$b.canvas').writeAsStringSync(edited);
        }
      };

      await expectLater(
        nb.moveToLocation(a),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            allOf(contains('no longer in Work'), contains('kept in Pages'), contains('newer version')),
          ),
        ),
      );
      expect(File('${pages.path}/$a.canvas').existsSync(), isTrue, reason: 'the only copy of a is kept');
      expect(File('${folder.path}/$a.canvas').existsSync(), isFalse, reason: 'a is not brought back');
      expect(read(folder, b), edited);
      expect(File('${pages.path}/$b.canvas').existsSync(), isFalse);
      expect(nb.binderOfPage(a), isNull);
    });

    test('a source that vanishes at the check does not stop the move; its copy is the page', () async {
      source.reads.clear();
      source.onRead = (id, n) {
        if (id == b && n == 3) File('${folder.path}/$b.canvas').deleteSync();
      };
      expect(await nb.moveToLocation(a), isTrue);
      expect(File('${pages.path}/$b.canvas').existsSync(), isTrue);
      expect(File('${folder.path}/$b.canvas').existsSync(), isFalse);
      expect(nb.binderOfPage(b), isNull);
    });

    test('a missing source folder is not mistaken for vanished pages', () async {
      source.reads.clear();
      source.onRead = (id, n) {
        if (id == a && n == 3) folder.deleteSync(recursive: true);
      };
      await expectLater(
        nb.moveToLocation(a),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('could not be read'))),
      );
      expect(canvasFiles(pages).where((f) => f.contains(a) || f.contains(b)), isEmpty);
    });

    test('a scan of the source folder waits while a source is set aside for its delete', () async {
      source.seamIds.add(b);
      var sweptDuring = false;
      Future<List<PageEntry>>? scan;
      source.seamBeforeDelete = () async {
        scan = nb.scanLocationForTest(s.path);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        // A scan that ran now would have put the set-aside file back.
        sweptDuring = File('${folder.path}/$b.canvas').existsSync();
      };
      expect(await nb.moveToLocation(a), isTrue);
      await scan;
      expect(sweptDuring, isFalse);
      expect(File('${pages.path}/$b.canvas').existsSync(), isTrue);
      expect(File('${folder.path}/$b.canvas').existsSync(), isFalse);
    });

    test('a source that cannot be read at the start is not moved', () async {
      source.failRead.add(a);
      await expectLater(
        nb.moveToLocation(a),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', 'Could not move the page.')),
      );
      source.failRead.clear();
      expect(File('${pages.path}/$a.canvas').existsSync(), isFalse);
      expect(nb.binderOfPage(a), s.path);
    });

    test('an existing destination file is never overwritten, and nothing is moved', () async {
      File('${pages.path}/$a.canvas').writeAsStringSync("someone else's newer-format page");
      final aBefore = read(folder, a);
      final bBefore = read(folder, b);
      final writesBefore = source.saves[a] ?? 0;

      await expectLater(
        nb.moveToLocation(a),
        throwsA(
          isA<NotebookException>()
              .having(
                (e) => e.message,
                'message',
                allOf(contains('Pages already has a file for this page'), contains('was not moved')),
              )
              .having((e) => e.needsAction, 'needsAction', isTrue),
        ),
      );
      expect(File('${pages.path}/$a.canvas').readAsStringSync(), "someone else's newer-format page");
      expect(read(folder, a), aBefore);
      expect(read(folder, b), bBefore);
      expect(File('${pages.path}/$b.canvas').existsSync(), isFalse);
      expect(source.saves[a] ?? 0, writesBefore);
      expect(nb.binderOfPage(a), s.path);
    });

    test('after a collision, only the files this move published are removed', () async {
      // a is published by the move (with its attachments, into a folder that
      // already holds a file of its own); b collides with an existing file.
      File('${pages.path}/$b.canvas').writeAsStringSync('existing b');
      final keep = File('${pages.path}/$a.assets/photo.png')..createSync(recursive: true);
      keep.writeAsStringSync('mine');
      File('${folder.path}/$a.assets/moved.png')
        ..createSync(recursive: true)
        ..writeAsStringSync('from the source');
      final bBefore = read(folder, b);

      await expectLater(
        nb.moveToLocation(a),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('already has a file'))),
      );
      expect(File('${pages.path}/$a.canvas').existsSync(), isFalse, reason: 'the copy this move made is removed');
      expect(File('${pages.path}/$a.assets/moved.png').existsSync(), isFalse, reason: 'so is the file it copied');
      expect(File('${pages.path}/$b.canvas').readAsStringSync(), 'existing b');
      expect(keep.readAsStringSync(), 'mine', reason: 'a file that was already there survives the rollback');
      expect(File('${folder.path}/$a.assets/moved.png').existsSync(), isTrue);
      expect(read(folder, b), bBefore);
    });

    test('a newer source found at delete time never costs a pre-existing attachments file', () async {
      final keep = File('${pages.path}/$a.assets/photo.png')..createSync(recursive: true);
      keep.writeAsStringSync('mine');
      File('${folder.path}/$a.assets/moved.png')
        ..createSync(recursive: true)
        ..writeAsStringSync('from the source');
      source.beforeDeleteIfUnchanged = (id) {
        if (id == b) {
          File('${folder.path}/$b.canvas').writeAsStringSync(read(folder, b).replaceFirst('"title":"', '"title":"Late '));
        }
      };

      await expectLater(nb.moveToLocation(a), throwsA(isA<NotebookException>()));
      expect(keep.readAsStringSync(), 'mine');
      expect(File('${pages.path}/$a.assets/moved.png').existsSync(), isFalse);
      expect(File('${pages.path}/$a.canvas').existsSync(), isFalse);
      expect(File('${folder.path}/$a.assets/moved.png').existsSync(), isTrue);
    });

    test('a source edited by someone else mid-move is left untouched and both copies are kept', () async {
      late String edited;
      source.failDelete.add(b);
      source.onFailedDelete = (id) {
        edited = read(folder, id).replaceFirst('"title":"', '"title":"Edited elsewhere ');
        File('${folder.path}/$id.canvas').writeAsStringSync(edited);
      };

      await expectLater(
        nb.moveToLocation(a),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('kept in both places'),
              contains('under "Can\'t open"'),
              contains('old file in Work'),
              contains('copy is in Pages'),
              contains('subpage of'),
              isNot(contains('duplicate page id')),
              isNot(contains('after a restart')),
            ),
          ),
        ),
      );
      // The external version is still there, byte for byte, and so is the copy.
      expect(read(folder, b), edited);
      expect(File('${pages.path}/$b.canvas').existsSync(), isTrue);
      // The page did not move: only the pages with no source do.
      expect(nb.binderOfPage(b), s.path);
      expect(File('${pages.path}/$a.canvas').existsSync(), isFalse);
      expect(nb.binderOfPage(a), s.path);
    });

    test('a source that does not round-trip byte for byte is never rewritten', () async {
      final crlf = '${read(folder, b)}\r\n';
      File('${folder.path}/$b.canvas').writeAsStringSync(crlf);
      source.failDelete.add(b);

      // The source still holds exactly the generation that was copied, so the
      // copy goes and the page stays, with its own bytes.
      await expectLater(
        nb.moveToLocation(a),
        throwsA(
          isA<NotebookException>().having((e) => e.message, 'message', contains('nothing was moved')),
        ),
      );
      expect(File('${pages.path}/$b.canvas').existsSync(), isFalse);
      expect(read(folder, b), crlf);
      expect(nb.binderOfPage(b), s.path);
    });

    test('a locked source (delete and read fail) stays where it is, and the page does not move', () async {
      final bBefore = read(folder, b);
      await nb.createPage(); // another page is open, so b is not reopened
      source.failDelete.add(b);
      // The lock comes after the page was read for the copy.
      source.reads.clear();
      source.onRead = (id, n) {
        if (id == b && n >= 3) source.failRead.add(b);
      };

      await expectLater(
        nb.moveToLocation(a),
        throwsA(
          isA<NotebookException>().having((e) => e.message, 'message', contains('kept in both places')),
        ),
      );
      source.failRead.clear();
      expect(read(folder, b), bBefore);
      expect(nb.binderOfPage(b), s.path);
      expect(nb.binderOfPage(a), s.path);
    });

    test('a file that appears at the source while it is put back is never written over', () async {
      await nb.createPage(); // another page is open
      source.failDelete.add(b);
      source.onFailedDelete = (_) => File('${folder.path}/$a.canvas').writeAsStringSync('appeared');

      await expectLater(
        nb.moveToLocation(a),
        throwsA(
          isA<NotebookException>().having((e) => e.message, 'message', contains('kept in both places')),
        ),
      );
      expect(read(folder, a), 'appeared');
      expect(nb.binderOfPage(a), s.path);
    });

    test('a page that cannot be reopened after a failed move: the error says so and nothing else escapes', () async {
      await nb.open(b);
      source.failDelete.add(b);
      // b's file becomes unreadable once its delete failed, so the page cannot be reopened.
      source.onFailedDelete = (id) => source.failRead.add(id);

      await expectLater(
        nb.moveToLocation(a),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            allOf(contains('kept in both places'), contains('could not be reopened')),
          ),
        ),
      );
      source.failRead.clear();
      expect(nb.currentId, isNull);
    });

    test('a page kept in both places keeps its place in the tree, in memory too', () async {
      await nb.createPage(); // another page is open
      source.failDelete.add(b);
      source.failSaveIds.add(a); // a cannot be put back: it moves; b stays
      source.onFailedDelete = (id) {
        final f = File('${folder.path}/$id.canvas');
        f.writeAsStringSync(f.readAsStringSync().replaceFirst('"title":"', '"title":"Edited elsewhere '));
      };

      await expectLater(nb.moveToLocation(a), throwsA(isA<NotebookException>()));
      source.failSaveIds.clear();
      expect(s.tree.roots.firstWhere((x) => x.id == b).parentId, a);
    });

    test('the partial move of the open page: it is reopened where it now is, and its stranded subpage goes to the top level', () async {
      await nb.open(a);
      source.failDelete.add(b);
      // Putting a back fails; b's file can still be written.
      source.failSaveIds.add(a);

      await expectLater(
        nb.moveToLocation(a),
        throwsA(
          isA<NotebookException>()
              .having((e) => e.message, 'message', allOf(contains('partly'), contains('Pages'), contains('stayed where')))
              .having((e) => e.needsAction, 'needsAction', isFalse),
        ),
      );
      expect(nb.currentId, a);
      expect(nb.binderOfPage(a), isNull);
      expect(nb.binderOfPage(b), s.path);
      // b's parent is in another location now: b is a top-level page of the
      // binder, in memory and in its file.
      expect(s.tree.roots.map((x) => x.id), [b]);
      expect(s.tree.parentIdOf(b), isNull);
      expect(read(folder, b), isNot(contains('"parentId":"$a"')));
    });
  });

  test('a move from Pages that keeps a page in both places names where the original and the copy are', () async {
    final src = FlakyStore(pages);
    final nb = Notebook(
      src,
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: settings,
      storeFactory: PageStore.new,
    );
    opened.add(nb);
    await nb.load();
    final s = await nb.addBinder(folder.path);
    final a = await nb.createPage();
    final b = await nb.createPage(parentId: a);
    await nb.createPage(); // another page is open
    await nb.flush();
    src.failDelete.add(b);
    src.onFailedDelete = (id) {
      final f = File('${pages.path}/$id.canvas');
      f.writeAsStringSync(f.readAsStringSync().replaceFirst('"title":"', '"title":"Edited elsewhere '));
    };
    await expectLater(
      nb.moveToLocation(a, binderPath: s.path),
      throwsA(
        isA<NotebookException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('old file in Pages'),
            contains('copy is in Work'),
            contains('under "Can\'t open"'),
          ),
        ),
      ),
    );
  });

  group('a standalone-folder move whose source deletion fails', () {
    test('goes through the same path', () async {
      final extra1 = await Directory('${root.path}/One').create();
      final extra2 = await Directory('${root.path}/Two').create();
      late FlakyStore source;
      final nb = make(
        factory: (d) {
          final st = FlakyStore(d);
          if (d.path == extra1.path) source = st;
          return st;
        },
      );
      await nb.load();
      final a = await nb.createPage(folderPath: extra1.path);
      final b = await nb.createPage(parentId: a);
      await nb.flush();
      final aBefore = read(extra1, a);
      source.failDelete.add(b);
      source.failSaveIds.add(a);

      await expectLater(
        nb.moveToFolder(a, extra2.path),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            allOf(contains('partly'), contains('stayed where')),
          ),
        ),
      );
      source.failSaveIds.clear();
      source.failDelete.clear();
      // a lives in the other folder only, b stayed intact, as a top-level page.
      expect(File('${extra1.path}/$a.canvas').existsSync(), isFalse);
      expect(read(extra2, a), contains('"pageId":"$a"'));
      expect(read(extra2, a), isNot(equals(aBefore)));
      expect(read(extra1, b), allOf(contains('"pageId":"$b"'), contains('"parentId":"$a"')));
      expect(File('${extra2.path}/$b.canvas').existsSync(), isFalse);
      expect(nb.tree.parentIdOf(b), a); // standalone folders share one tree
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
