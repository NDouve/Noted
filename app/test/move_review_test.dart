// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The review of a move by rename (design 2026-11-14-02): what the first build
// left out. Reads are counted by `PageStore.fileReadObserver`, so a read
// anywhere fails a "no read" test.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';
import 'support/notebook_folder.dart';

void main() {
  late Directory root;
  late Directory pages;
  late Directory extra;
  late List<Notebook> opened;
  late List<String> reads;
  Future<void> Function(String, String)? hook;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_move_review');
    pages = await Directory('${root.path}/pages').create();
    extra = await Directory('${root.path}/Elsewhere').create();
    opened = [];
    reads = [];
    hook = null;
    PageStore.fileReadObserver = reads.add;
    Notebook.pairLockLimit = const Duration(milliseconds: 150);
    Notebook.pairRetryDelay = const Duration(milliseconds: 10);
  });
  tearDown(() async {
    PageStore.fileReadObserver = null;
    noFileStampsForTest = false;
    Notebook.pairLockLimit = const Duration(seconds: 5);
    Notebook.pairRetryDelay = const Duration(milliseconds: 500);
    Notebook.placeholderMarksForTest = {};
    Notebook.syncRootOfForTest = null;
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    await deleteTestFolder(root);
  });

  Notebook make() {
    final nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
    );
    nb.syncHook = (point, path) async => hook?.call(point, path);
    opened.add(nb);
    return nb;
  }

  String text(Directory d, String id) => File('${d.path}/$id.canvas').readAsStringSync();
  bool has(Directory d, String id) => File('${d.path}/$id.canvas').existsSync();
  bool readOf(String id) => reads.any((r) => r.endsWith('$id.canvas'));
  void oneRoot() => Notebook.syncRootOfForTest = (_) => const SyncRoot(1, 1);
  void mark(String path) => Notebook.placeholderMarksForTest = {...Notebook.placeholderMarksForTest, fileStamp(path)!};

  // Changes a file's modified time only, so its stamp no longer matches.
  void touch(String path) => File(path).setLastModifiedSync(DateTime.now().add(const Duration(seconds: 90)));

  // Pages written by one notebook, then scanned by a second: the open page `a`,
  // and (`b` with a subpage `bc`, a page `x` in the other folder with two
  // subpages `s1`, `s2`) never opened by it.
  Future<({Notebook nb, String a, String b, String bc, String x, String s1, String s2})> scanned() async {
    final first = make();
    await first.load();
    final a = first.currentId!;
    final b = await first.createPage();
    final bc = await first.createPage(parentId: b);
    final x = await first.createPage(folderPath: extra.path);
    final s1 = await first.createPage(parentId: x);
    final s2 = await first.createPage(parentId: x);
    await first.open(a);
    await first.flush();
    first.dispose();
    opened.remove(first);
    final nb = make();
    await nb.load();
    reads.clear();
    return (nb: nb, a: a, b: b, bc: bc, x: x, s1: s1, s2: s2);
  }

  group('finding 2: an index for a root that is not downloaded', () {
    test('the placement is held with the index; neither the root nor a sibling is read', () async {
      final w = await scanned();
      oneRoot();
      mark('${pages.path}/${w.b}.canvas');
      expect(await w.nb.move(w.b, parentId: w.x, index: 0), isTrue);
      expect(has(extra, w.b), isTrue);
      expect(reads, isEmpty, reason: 'rule P: nothing was read, the siblings were not renumbered');
      Notebook.placeholderMarksForTest = {};
      await w.nb.open(w.b);
      await w.nb.flush();
      final meta = readPage(text(extra, w.b)).meta;
      expect(meta.parentId, w.x);
      expect(meta.order, 0, reason: 'the held placement carried the index');
    });
  });

  group('finding 3: a placeholder across sync roots never reaches a rename', () {
    test('a placeholder subpage: the page is copied, nothing was renamed', () async {
      final w = await scanned();
      Notebook.syncRootOfForTest = (path) => path.contains('Elsewhere') ? const SyncRoot(1, 2) : const SyncRoot(1, 1);
      mark('${pages.path}/${w.bc}.canvas');
      await expectLater(w.nb.move(w.b, parentId: w.x), throwsA(isA<OriginalsKeptException>()));
      expect(has(pages, w.b) && has(pages, w.bc), isTrue, reason: 'the originals stay');
      expect(has(extra, w.b) && has(extra, w.bc), isTrue);
    });
  });

  group('findings 5 and 6: the baseline and the held placement', () {
    test('a moved page whose stamp changed but whose text did not keeps its held placement', () async {
      final w = await scanned();
      await w.nb.open(w.b); // its text is known
      await w.nb.open(w.a);
      final notices = <String>[];
      final sub = w.nb.attachmentNotices.listen(notices.add);
      addTearDown(sub.cancel);
      touch('${pages.path}/${w.b}.canvas');
      oneRoot();
      mark('${pages.path}/${w.b}.canvas');
      expect(await w.nb.move(w.b, parentId: w.x), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(notices, isEmpty, reason: 'the file holds what it held when it was moved: no change');
      Notebook.placeholderMarksForTest = {};
      await w.nb.open(w.b);
      await w.nb.flush();
      expect(readPage(text(extra, w.b)).meta.parentId, w.x, reason: 'the held placement was kept');
    });

    test('a never-read page whose stamp changed is placed by step 4\'s read, not dropped', () async {
      final w = await scanned();
      final notices = <String>[];
      final sub = w.nb.attachmentNotices.listen(notices.add);
      addTearDown(sub.cancel);
      touch('${pages.path}/${w.b}.canvas');
      oneRoot();
      mark('${pages.path}/${w.b}.canvas');
      expect(await w.nb.move(w.b, parentId: w.x), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(notices, isEmpty);
      expect(readPage(text(extra, w.b)).meta.parentId, w.x, reason: 'placed once it was read');
    });

    test('a later placement of the page drops the held one', () async {
      final w = await scanned();
      oneRoot();
      mark('${pages.path}/${w.b}.canvas');
      expect(await w.nb.move(w.b, parentId: w.x), isTrue);
      Notebook.placeholderMarksForTest = {};
      expect(await w.nb.move(w.b, parentId: null), isTrue);
      await w.nb.open(w.b);
      await w.nb.flush();
      expect(readPage(text(extra, w.b)).meta.parentId, isNull, reason: 'the old held placement is gone');
    });

    test('a later move of the page drops the held placement', () async {
      final w = await scanned();
      oneRoot();
      mark('${pages.path}/${w.b}.canvas');
      expect(await w.nb.move(w.b, parentId: w.x), isTrue);
      Notebook.placeholderMarksForTest = {};
      final binder = await w.nb.createBinder(name: 'B');
      expect(await w.nb.moveToLocation(w.b, binderPath: binder.path), isTrue);
      expect(File('${binder.path}/${w.b}.canvas').existsSync(), isTrue);
      await w.nb.open(w.b);
      await w.nb.flush();
      expect(readPage(File('${binder.path}/${w.b}.canvas').readAsStringSync()).meta.parentId, isNull);
    });

    test('a page opened and closed again keeps its stamp: the move does not read it at step 4', () async {
      final w = await scanned();
      await w.nb.open(w.bc);
      await w.nb.open(w.a);
      await w.nb.flush();
      reads.clear();
      expect(await w.nb.move(w.b, parentId: w.x), isTrue);
      expect(readOf(w.bc), isFalse, reason: 'the file did not change while it was open: its stamp stood');
    });
  });

  group('finding 7: a rollback that can not put a chosen file back', () {
    test('the page stays at the target under its chosen file, still listed, not a duplicate', () async {
      final w = await scanned();
      // `b` is shown from a chosen file; its own name is a duplicate of it.
      final chosen = File('${pages.path}/chosen.canvas')..writeAsStringSync(text(pages, w.b));
      await w.nb.filesChanged([chosen.path]);
      await w.nb.adoptUnlistedPageFile(chosen.path, w.b);
      await w.nb.checkFile(chosen.path); // its stamp is recorded
      // The subpage's name is taken at the target: the move fails at it.
      var n = 0;
      hook = (point, path) async {
        // After the first page arrived: its chosen name is taken at the source, so
        // the rollback can't put it back.
        if (point == 'move-before-rename' && ++n == 2) chosen.writeAsStringSync('someone else');
      };
      File('${extra.path}/${w.bc}.canvas').writeAsStringSync('someone else');
      Object? e;
      try {
        await w.nb.move(w.b, parentId: w.x);
      } on Object catch (x) {
        e = x;
      }
      expect(e, isA<NotebookException>());
      final dups = w.nb.unreadable.where((u) => u.reason.contains('duplicate page id ${w.b}') && u.path.contains('Elsewhere'));
      expect(dups, isEmpty, reason: 'the only file of the page at the target is not a duplicate of itself');
      expect(w.nb.pageTitleOf(w.b), isNotNull, reason: 'still a listed page');
      expect(File('${extra.path}/chosen.canvas').existsSync() || has(extra, w.b), isTrue, reason: 'it stayed at the target');
    });
  });

  group('finding 8: the change feed', () {
    test('a move of a page with no carried stamp tells the feed of its arrival, from step 4\'s read', () async {
      final w = await scanned();
      final seen = <LocalChange>[];
      final sub = w.nb.localChanges.listen(seen.add);
      addTearDown(sub.cancel);
      touch('${pages.path}/${w.bc}.canvas'); // the subpage's stamp no longer matches
      expect(await w.nb.move(w.b, parentId: w.x), isTrue);
      await Future<void>.delayed(Duration.zero);
      final at = seen.where((c) => c.kind == LocalChangeKind.published && c.path.endsWith('${w.bc}.canvas'));
      expect(at, isNotEmpty, reason: 'the published event of the moved subpage');
      expect(at.first.path, contains('Elsewhere'));
    });
  });

  group('the feed when the step-4 read fails', () {
    test('a moved page whose read at the target throws is published without an identity', () async {
      final w = await scanned();
      final seen = <LocalChange>[];
      final feed = w.nb.localChanges.listen(seen.add);
      addTearDown(feed.cancel);
      touch('${pages.path}/${w.bc}.canvas'); // stamp mismatch: step 4 reads it
      hook = (point, path) async {
        if (point == 'check-read' && path.endsWith('${w.bc}.canvas') && path.contains('Elsewhere')) {
          throw const FileSystemException('held by a sync client');
        }
      };
      expect(await w.nb.move(w.b, parentId: w.x), isTrue);
      await Future<void>.delayed(Duration.zero);
      final gone = seen.indexWhere((c) => c.kind == LocalChangeKind.deleted && c.path.endsWith('${w.bc}.canvas'));
      final came = seen.indexWhere((c) => c.kind == LocalChangeKind.published && c.path.endsWith('${w.bc}.canvas') && c.path.contains('Elsewhere'));
      expect(gone, isNonNegative);
      expect(came, greaterThan(gone), reason: '$seen');
      expect(seen[came].identity, isNull);
    });
  });

  group('the feed never ends with a published page that has no file', () {
    // The last event of a path is not a `published` while no file is there.
    void expectNoOrphan(List<LocalChange> seen, Directory dir) {
      final last = <String, LocalChange>{};
      for (final c in seen) {
        last[c.path] = c;
      }
      for (final c in last.values) {
        if (c.kind == LocalChangeKind.published && c.path.startsWith(dir.path)) {
          expect(File(c.path).existsSync(), isTrue, reason: 'published without a file: $seen');
        }
      }
    }

    test('a rollback leaves no published event at the target', () async {
      final w = await scanned();
      final seen = <LocalChange>[];
      final feed = w.nb.localChanges.listen(seen.add);
      addTearDown(feed.cancel);
      touch('${pages.path}/${w.b}.canvas'); // queued at the target
      var n = 0;
      hook = (point, path) async {
        if (point == 'move-before-rename' && ++n == 2) throw StateError('boom');
      };
      try {
        await w.nb.move(w.b, parentId: w.x);
      } on Object {
        // the move ends in an error; the feed is what is looked at
      }
      hook = null;
      await Future<void>.delayed(Duration.zero);
      expect(has(pages, w.b), isTrue, reason: 'put back');
      expect(seen.where((c) => c.kind == LocalChangeKind.published && c.path.startsWith(extra.path)), isEmpty, reason: '$seen');
      expectNoOrphan(seen, extra);
    });

    test('a file that sync deleted before step 4 is not announced', () async {
      final w = await scanned();
      final seen = <LocalChange>[];
      final feed = w.nb.localChanges.listen(seen.add);
      addTearDown(feed.cancel);
      var n = 0;
      hook = (point, path) async {
        if (point == 'move-after-rename' && ++n == 2) File('${extra.path}/${w.bc}.canvas').deleteSync();
      };
      try {
        await w.nb.move(w.b, parentId: w.x);
      } on Object {
        // whatever the move reports, the feed is what is looked at
      }
      hook = null;
      await Future<void>.delayed(Duration.zero);
      expect(has(extra, w.bc), isFalse);
      expectNoOrphan(seen, extra);
    });
  });

  group('finding 10: an error that is not a NotebookException', () {
    test('a page already renamed is put back', () async {
      final w = await scanned();
      var n = 0;
      hook = (point, path) async {
        if (point == 'move-before-rename' && ++n == 2) throw StateError('boom');
      };
      Object? e;
      try {
        await w.nb.move(w.b, parentId: w.x);
      } on Object catch (x) {
        e = x;
      }
      expect(e, isA<NotebookException>());
      expect(has(pages, w.b) && has(pages, w.bc), isTrue, reason: 'both are back');
      expect(has(extra, w.b) || has(extra, w.bc), isFalse);
    });
  });

  group('finding 11: the lock limit', () {
    test('a slow read of the binder file under the lock does not count toward the limit', () async {
      final w = await scanned();
      final binder = await w.nb.createBinder(name: 'B');
      var slow = false;
      hook = (point, path) async {
        if (slow && point == 'binder-gate') {
          slow = false;
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      };
      slow = true;
      expect(await w.nb.moveToLocation(w.b, binderPath: binder.path), isTrue);
      expect(File('${binder.path}/${w.b}.canvas').existsSync(), isTrue);
    });
  });

  group('finding 13: no stamp', () {
    test('where no stamp can be taken a page still moves', () async {
      final w = await scanned();
      noFileStampsForTest = true;
      expect(await w.nb.move(w.b, parentId: w.x), isTrue);
      expect(has(extra, w.b) && has(extra, w.bc), isTrue);
      expect(has(pages, w.b), isFalse);
    });
  });

  group('the real read count', () {
    test('a check of a page being moved reads nothing: the pages are busy until the move ends', () async {
      final w = await scanned();
      final seen = <String>[];
      var before = 0;
      Future<void>? checks;
      hook = (point, path) async {
        if (point == 'move-after-rename' && checks == null) {
          // A watcher's check of the page just renamed, queued behind the move's lock.
          before = reads.length;
          touch('${extra.path}/${w.b}.canvas'); // its stamp differs: only being busy keeps a check from reading it
          checks = Future.wait([w.nb.checkFile('${extra.path}/${w.b}.canvas'), w.nb.checkFile('${pages.path}/${w.b}.canvas')]);
        } else if (point == 'move-before-rename' && checks != null && seen.isEmpty) {
          // The second page's turn: the queued checks have run by now.
          seen.addAll(reads.skip(before).where((r) => r.endsWith('${w.b}.canvas')));
          seen.add('looked');
        }
      };
      expect(await w.nb.move(w.b, parentId: w.x), isTrue);
      expect(seen, ['looked'], reason: 'the watchers checks of a busy page read nothing');
    });

    test('the open page that is moved is reopened at its new place', () async {
      final w = await scanned();
      await w.nb.open(w.b);
      expect(await w.nb.move(w.b, parentId: w.x), isTrue);
      expect(w.nb.currentId, w.b);
      expect(w.nb.current!.page.meta.parentId, w.x);
      expect(has(extra, w.b) && !has(pages, w.b), isTrue);
    });

    test('a stamped subpage is not read by a move, anywhere', () async {
      final w = await scanned();
      expect(await w.nb.move(w.b, parentId: w.x), isTrue);
      expect(readOf(w.bc), isFalse, reason: 'rule P');
      expect(readOf(w.a), isFalse);
    });
  });
}
