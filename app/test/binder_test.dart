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

  /// How often each page was written.
  final Map<String, int> saves = {};

  @override
  Future<String> readText(String pageId) {
    if (failRead.contains(pageId)) throw const FileSystemException('locked');
    return super.readText(pageId);
  }

  @override
  Future<void> delete(String pageId) async {
    if (failDelete.contains(pageId)) {
      onFailedDelete?.call(pageId);
      throw const FileSystemException('drive gone');
    }
    await super.delete(pageId);
    if (failSaveAfterDelete) failSave = true;
    if (pageId == racePage) _raceArmed = true;
  }

  /// Pages whose load fails with a raw error.
  final Set<String> failLoad = {};

  /// Runs when a write of a page is refused (see [failSave]), before it fails.
  void Function(String pageId)? onFailedSave;

  /// After [racePage] was deleted, its [raceAt]-th path lookup first writes
  /// [raceText] to that path, like another program that got there first.
  String? racePage;
  int raceAt = 0;
  String raceText = 'written elsewhere';
  bool _raceArmed = false;
  int _raceCalls = 0;

  @override
  String pathFor(String pageId) {
    final p = super.pathFor(pageId);
    if (_raceArmed && pageId == racePage && ++_raceCalls == raceAt) File(p).writeAsStringSync(raceText);
    return p;
  }

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

    test('an empty claim file that cannot be removed does not make the page "both"', () async {
      source.failDelete.add(b);
      source.failSaveAfterDelete = true;
      final claim = '${folder.path}/$a.canvas';
      // A read-only file can't be deleted on Windows.
      source.onFailedSave = (id) {
        if (id == a) Process.runSync('attrib', ['+R', claim]);
      };
      Object? error;
      try {
        await nb.moveToLocation(a);
      } on NotebookException catch (e) {
        error = e.message;
      } finally {
        Process.runSync('attrib', ['-R', claim]);
      }
      expect(error, allOf(contains('empty file was left'), contains('is now in'), isNot(contains('both places'))));
      expect(File(claim).lengthSync(), 0);
      expect(read(pages, a), contains('"pageId":"$a"'));
      expect(nb.binderOfPage(a), isNull);
    }, skip: !Platform.isWindows);

    test('a file that appears at the old path before the claim is never written over', () async {
      source.failDelete.add(b);
      source.racePage = a;
      source.raceAt = 2; // the path lookup that makes the claim
      await expectLater(
        nb.moveToLocation(a),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('kept in both places'))),
      );
      expect(File('${folder.path}/$a.canvas').readAsStringSync(), 'written elsewhere');
    });

    test('a file that fills the claim before the page is written is never written over', () async {
      source.failDelete.add(b);
      source.racePage = a;
      source.raceAt = 3; // the look at the claim just before the write
      final before = source.saves[a] ?? 0;
      addTearDown(() => expect(source.saves[a] ?? 0, before, reason: 'the page is not written into the claim'));
      await expectLater(
        nb.moveToLocation(a),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('kept in both places'))),
      );
      expect(File('${folder.path}/$a.canvas').readAsStringSync(), 'written elsewhere');
    });

    test('a raw error while reading a source is turned into a message', () async {
      source.failLoad.add(a);
      await expectLater(
        nb.moveToLocation(a),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('Could not move the page'))),
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
              contains('duplicate page id'),
              contains('original file is in Work'),
              contains('copy made by the move is in Pages'),
              contains('subpage of'),
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

    test('a source that does not round-trip byte for byte is never deleted or rewritten', () async {
      final crlf = '${read(folder, b)}\r\n';
      File('${folder.path}/$b.canvas').writeAsStringSync(crlf);
      source.failDelete.add(b);

      await expectLater(
        nb.moveToLocation(a),
        throwsA(
          isA<NotebookException>().having((e) => e.message, 'message', contains('kept in both places')),
        ),
      );
      expect(read(folder, b), crlf);
      expect(nb.binderOfPage(b), s.path);
    });

    test('a locked source (delete and read fail) stays where it is, and the page does not move', () async {
      final bBefore = read(folder, b);
      await nb.createPage(); // another page is open, so b is not reopened
      source.failDelete.add(b);
      source.failRead.add(b);

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
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            allOf(contains('partly'), contains('Pages'), contains('stayed where')),
          ),
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
            contains('original file is in Pages'),
            contains('copy made by the move is in Work'),
            contains('duplicate page id'),
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
