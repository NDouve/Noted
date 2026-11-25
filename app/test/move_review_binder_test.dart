// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The move tests of the old copy-and-delete page move, rewritten for the
// rename and the copy path (design 2026-11-14-02), and the rollback's lock
// order (X1): what a failed rename move and a copy path leave behind, and what
// they say.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';
import 'support/notebook_folder.dart';

/// A store that can fail reads, or change a page's file while it is being read.
class _Store extends PageStore {
  _Store(super.directory);

  bool failReads = false;
  String? changeOnLoad;

  @override
  Future<String> readText(String pageId) {
    if (failReads) throw const FileSystemException('injected read failure');
    return super.readText(pageId);
  }

  @override
  Future<NotedPage> load(String pageId) async {
    final page = await super.load(pageId);
    if (changeOnLoad == pageId) {
      changeOnLoad = null;
      final f = File(pathFor(pageId));
      f.writeAsStringSync(writePage(page.withMeta(page.meta.withTitle('Changed while read'))));
    }
    return page;
  }
}

void main() {
  late Directory root;
  late Directory pages;
  late Directory extra;
  late List<Notebook> opened;
  late _Store store;
  late File settings;
  Future<void> Function(String, String)? hook;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_move_review_binder');
    pages = await Directory('${root.path}/pages').create();
    extra = await Directory('${root.path}/Elsewhere').create();
    settings = File('${root.path}/app/binders.json');
    opened = [];
    hook = null;
    store = _Store(pages);
    Notebook.pairLockLimit = const Duration(milliseconds: 150);
    Notebook.pairRetryDelay = const Duration(milliseconds: 10);
  });
  tearDown(() async {
    Notebook.forceCopyMoveForTest = false;
    Notebook.pairLockLimit = const Duration(seconds: 5);
    Notebook.pairRetryDelay = const Duration(milliseconds: 500);
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    await deleteTestFolder(root);
  });

  Future<Notebook> make() async {
    final nb = Notebook(store, buildModules(), saveDelay: Duration.zero, bindersFile: settings);
    nb.syncHook = (point, path) async => hook?.call(point, path);
    opened.add(nb);
    await nb.load();
    return nb;
  }

  // At the n-th rename of a move, runs [act] (before that page is renamed).
  void atRename(int n, void Function() act) {
    var calls = 0;
    hook = (point, path) async {
      if (point == 'move-before-rename' && ++calls == n) act();
    };
  }

  bool has(Directory d, String id) => File('${d.path}/$id.canvas').existsSync();

  group('a failed rename move', () {
    test('the open page that could not be put back: reopened where it is, its stranded subpage at the top level', () async {
      final nb = await make();
      final binder = await nb.createBinder(name: 'Work');
      final binderDir = Directory(binder.path);
      final a = nb.currentId!;
      final b = await nb.createPage(parentId: a);
      await nb.open(a);
      await nb.flush();
      atRename(2, () {
        File('${binderDir.path}/$b.canvas').writeAsStringSync('taken'); // the subpage can't arrive
        File('${pages.path}/$a.canvas').writeAsStringSync('taken at the source'); // the page can't go back
      });
      await expectLater(
        nb.moveToLocation(a, binderPath: binder.path),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            allOf(contains('already has a file'), contains('stayed in')),
          ),
        ),
      );
      expect(nb.currentId, a, reason: 'reopened where it now is');
      expect(nb.binderOfPage(a), binder.path);
      expect(nb.binderOfPage(b), isNull);
      expect(nb.tree.parentIdOf(b), isNull, reason: 'its parent is in another place now (0124)');
      expect(readPage(File('${pages.path}/$b.canvas').readAsStringSync()).meta.parentId, isNull);
    });

    test('a page that can not be reopened after a failed move: the message says so and nothing else escapes', () async {
      final nb = await make();
      final a = nb.currentId!;
      final b = await nb.createPage(parentId: a);
      await nb.addStandaloneFolder(extra.path);
      await nb.open(a);
      await nb.flush();
      File('${extra.path}/$b.canvas').writeAsStringSync('taken');
      atRename(1, () => store.failReads = true);
      Object? e;
      try {
        await nb.moveToFolder(a, extra.path);
      } on Object catch (x) {
        e = x;
      }
      store.failReads = false;
      expect(e, isA<NotebookException>());
      expect((e! as NotebookException).message, allOf(contains('already has a file'), contains('could not be reopened')));
      expect(nb.currentId, isNull);
    });
  });

  group('the copy path', () {
    // The page a (with its subpage b) in Pages, and a binder to copy it to.
    Future<(Notebook, BinderSection, String, String)> copied() async {
      Notebook.forceCopyMoveForTest = true;
      final nb = await make();
      final binder = await nb.createBinder(name: 'Work');
      final a = nb.currentId!;
      final b = await nb.createPage(parentId: a);
      await nb.createPage(); // another page is open
      await nb.flush();
      return (nb, binder, a, b);
    }

    test('a page kept in both places keeps its place in the tree', () async {
      final (nb, binder, a, b) = await copied();
      await expectLater(nb.moveToLocation(a, binderPath: binder.path), throwsA(isA<OriginalsKeptException>()));
      expect(nb.binderOfPage(a), binder.path);
      expect(binder.tree.parentIdOf(b), a, reason: 'the subpage keeps its place under its page');
    });

    test('the message names where the original and the copy are', () async {
      final (nb, binder, a, _) = await copied();
      await expectLater(
        nb.moveToLocation(a, binderPath: binder.path),
        throwsA(
          isA<OriginalsKeptException>().having(
            (e) => e.message,
            'message',
            allOf(contains('copied to Work'), contains('stay in Pages'), contains('Delete the original')),
          ),
        ),
      );
    });

    test('a source that changes while it is being read stops the copy before anything is written', () async {
      final (nb, binder, a, b) = await copied();
      store.changeOnLoad = b;
      await expectLater(
        nb.moveToLocation(a, binderPath: binder.path),
        throwsA(
          isA<NotebookException>().having((e) => e.message, 'message', contains('changed while it was being read')),
        ),
      );
      expect(Directory(binder.path).listSync().whereType<File>().where((f) => f.path.endsWith('.canvas')), isEmpty);
      expect(has(pages, a) && has(pages, b), isTrue);
    });

    test('after a collision, only the files this move published are removed', () async {
      final (nb, binder, a, b) = await copied();
      final binderDir = Directory(binder.path);
      File('${binderDir.path}/$b.canvas').writeAsStringSync('existing b');
      final keep = File('${binderDir.path}/$a.assets/photo.png')
        ..createSync(recursive: true)
        ..writeAsStringSync('mine');
      File('${pages.path}/$a.assets/moved.png')
        ..createSync(recursive: true)
        ..writeAsStringSync('from the source');
      await expectLater(
        nb.moveToLocation(a, binderPath: binder.path),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('already has a file'))),
      );
      expect(has(binderDir, a), isFalse, reason: 'the copy this move made is removed');
      expect(File('${binderDir.path}/$a.assets/moved.png').existsSync(), isFalse, reason: 'so is the file it copied');
      expect(File('${binderDir.path}/$b.canvas').readAsStringSync(), 'existing b');
      expect(keep.readAsStringSync(), 'mine', reason: 'a file that was already there survives the rollback');
      expect(File('${pages.path}/$a.assets/moved.png').existsSync(), isTrue);
      expect(has(pages, a) && has(pages, b), isTrue);
    });
  });

  group('X1: a rollback whose lock stalls', () {
    // Moves a (with b) to Elsewhere; b's name is taken there, so a goes back,
    // and the lock of one folder is held when the rollback needs it.
    for (final stallTarget in [true, false]) {
      test('the ${stallTarget ? 'target' : 'source'} folder busy at the rollback: the page stays, reported', () async {
        final nb = await make();
        final a = nb.currentId!;
        final b = await nb.createPage(parentId: a);
        await nb.addStandaloneFolder(extra.path);
        await nb.createPage(folderPath: extra.path); // another page is open
        await nb.flush();
        File('${extra.path}/$b.canvas').writeAsStringSync('taken');
        final gate = Completer<void>();
        Future<void>? held;
        atRename(2, () {
          // Queued behind the move's own pair: the rollback finds the folder busy.
          held = nb.folderLocks.run(stallTarget ? extra : pages, () => gate.future);
        });
        Object? e;
        try {
          await nb.moveToFolder(a, extra.path);
        } on Object catch (x) {
          e = x;
        }
        gate.complete();
        await held;
        expect(e, isA<NotebookException>());
        expect((e! as NotebookException).message, allOf(contains('stayed in'), contains('busy')));
        expect(has(extra, a), isTrue, reason: 'the page stayed at the target');
        expect(has(pages, b), isTrue);
        expect(File('${extra.path}/$b.canvas').readAsStringSync(), 'taken');
      });
    }
  });
}
