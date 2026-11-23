// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The rest of a move by rename (design 2026-11-14-02): placeholders (H), the
// damaged-target branch of 2c, a stray attachments folder (O) and the same-volume
// `_moveDir` on `moveExclusive`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/attachment_copy.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

class _Recorder implements StorageCoordinator {
  final List<CoordinatedWrite> calls = [];

  @override
  Future<T> coordinate<T>(CoordinatedWrite write, Future<T> Function() body) {
    calls.add(write);
    return body();
  }
}

void main() {
  late Directory root;
  late Directory pages;
  late Directory extra;
  late List<Notebook> opened;
  late List<String> reads;
  Future<void> Function(String, String)? hook;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_move_hos');
    pages = await Directory('${root.path}/pages').create();
    extra = await Directory('${root.path}/Elsewhere').create();
    opened = [];
    reads = [];
    PageStore.fileReadObserver = reads.add; // every read of a page file, anywhere
    hook = null;
    Notebook.pairLockLimit = const Duration(milliseconds: 150);
    Notebook.pairRetryDelay = const Duration(milliseconds: 10);
  });
  tearDown(() async {
    PageStore.fileReadObserver = null;
    Notebook.pairLockLimit = const Duration(seconds: 5);
    Notebook.pairRetryDelay = const Duration(milliseconds: 500);
    Notebook.placeholderMarksForTest = {};
    Notebook.unhydratableForTest = {};
    Notebook.syncRootOfForTest = null;
    Notebook.strayQuiet = const Duration(seconds: 30);
    attachmentAfterHashHook = null;
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    await root.delete(recursive: true);
  });

  Notebook make() {
    final nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
    );
    nb.syncHook = (point, path) async {
      await hook?.call(point, path);
    };
    opened.add(nb);
    return nb;
  }

  bool has(Directory d, String id) => File('${d.path}/$id.canvas').existsSync();

  // A page `a` and its subpage in the default folder and a page `x` in the other
  // folder, scanned by a fresh notebook.
  Future<(Notebook, String, String, String)> scanned() async {
    final first = make();
    await first.load();
    final a = first.currentId!;
    final ca = await first.createPage(parentId: a);
    final x = await first.createPage(folderPath: extra.path);
    await first.open(a);
    await first.flush();
    first.dispose();
    opened.remove(first);
    final nb = make();
    await nb.load();
    reads.clear();
    return (nb, a, ca, x);
  }

  // Two sync roots: the default folder is in one, the other folder in another.
  void twoRoots() {
    Notebook.syncRootOfForTest = (path) => path.contains('Elsewhere') ? const SyncRoot(1, 2) : const SyncRoot(1, 1);
  }

  void oneRoot() {
    Notebook.syncRootOfForTest = (_) => const SyncRoot(1, 1);
  }

  void mark(String path) => Notebook.placeholderMarksForTest = {...Notebook.placeholderMarksForTest, fileStamp(path)!};

  group('H: placeholders', () {
    test('a dehydrated page and its subpage move by rename within one sync root, with no read', () async {
      // Pages only scanned at launch: `b` and its subpage, neither opened.
      final first = make();
      await first.load();
      final a = first.currentId!;
      final b = await first.createPage();
      final bc = await first.createPage(parentId: b);
      final x = await first.createPage(folderPath: extra.path);
      await first.open(a);
      await first.flush();
      first.dispose();
      opened.remove(first);
      final nb = make();
      await nb.load();
      reads.clear();
      oneRoot();
      mark('${pages.path}/$b.canvas');
      mark('${pages.path}/$bc.canvas');
      expect(await nb.move(b, parentId: x), isTrue);
      expect(has(extra, b) && has(extra, bc), isTrue);
      expect(has(pages, b) || has(pages, bc), isFalse);
      expect(reads, isEmpty);
      // Its placement waits until it is opened (N8).
      expect(readPage(File('${extra.path}/$b.canvas').readAsStringSync()).meta.parentId, isNot(x));
      Notebook.placeholderMarksForTest = {};
      await nb.open(b);
      await nb.flush();
      expect(readPage(File('${extra.path}/$b.canvas').readAsStringSync()).meta.parentId, x);
    });

    test('a dehydrated page across sync roots takes the copy path: the original stays', () async {
      final (nb, a, _, x) = await scanned();
      twoRoots();
      mark('${pages.path}/$a.canvas');
      await expectLater(nb.move(a, parentId: x), throwsA(isA<OriginalsKeptException>()));
      expect(has(pages, a) && has(extra, a), isTrue);
    });

    test('an attachment that is a placeholder moves as it is within one root, not downloaded', () async {
      final (nb, a, _, x) = await scanned();
      oneRoot();
      final f = File('${pages.path}/$a.assets/cloud.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2]);
      final stamp = fileStamp(f.path)!;
      mark(f.path);
      expect(await nb.move(a, parentId: x), isTrue);
      expect(File('${extra.path}/$a.assets/cloud.bin').readAsBytesSync(), [1, 2]);
      expect(Notebook.placeholderMarksForTest, contains(stamp), reason: 'nothing hydrated it');
    });

    test('across roots an attachment is downloaded first; one that cannot be stays at the source', () async {
      final (nb, a, _, x) = await scanned();
      twoRoots();
      final dir = Directory('${pages.path}/$a.assets')..createSync();
      final h = File('${dir.path}/hydrates.bin')..writeAsBytesSync([1]);
      final u = File('${dir.path}/offline.bin')..writeAsBytesSync([2]);
      mark(h.path);
      mark(u.path);
      Notebook.unhydratableForTest = {fileStamp(u.path)!};
      await expectLater(
        nb.move(a, parentId: x),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('stayed in'))),
      );
      expect(has(extra, a), isTrue);
      expect(File('${extra.path}/$a.assets/hydrates.bin').readAsBytesSync(), [1]);
      expect(u.readAsBytesSync(), [2], reason: 'still not downloaded: stays');
      expect(File('${extra.path}/$a.assets/offline.bin').existsSync(), isFalse);
    });
  });

  group('2c: the damaged-target branch', () {
    final good = [1, 2, 3];
    final bad = [9, 9, 9];
    final name = '${contentHash(good)}.bin';
    final aside = damagedCopyName(name, contentHash(bad));

    // `a` has the good file at the source and the damaged one at the target.
    Future<(Notebook, String, String)> damaged() async {
      final (nb, a, _, x) = await scanned();
      File('${pages.path}/$a.assets/$name')
        ..createSync(recursive: true)
        ..writeAsBytesSync(good);
      File('${extra.path}/$a.assets/$name')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bad);
      return (nb, a, x);
    }

    test('the damaged file is set aside, never deleted, and the good one takes the name', () async {
      final (nb, a, x) = await damaged();
      await expectLater(
        nb.move(a, parentId: x),
        throwsA(
          isA<NotebookException>().having((e) => e.message, 'message', startsWith('The page was moved. A damaged copy')),
        ),
      );
      expect(File('${extra.path}/$a.assets/$name').readAsBytesSync(), good);
      expect(File('${extra.path}/$a.assets/$aside').readAsBytesSync(), bad);
      expect(File('${pages.path}/$a.assets/$name').existsSync(), isFalse);
    });

    test('replaced between the hash and the aside: put back, both files stay', () async {
      final (nb, a, x) = await damaged();
      hook = (point, path) async {
        if (point == 'move-before-aside') File(path).writeAsBytesSync([7, 7]);
      };
      await expectLater(nb.move(a, parentId: x), throwsA(isA<NotebookException>()));
      expect(File('${extra.path}/$a.assets/$name').readAsBytesSync(), [7, 7]);
      expect(Directory('${extra.path}/$a.assets').listSync().length, 1, reason: 'nothing left aside');
      expect(File('${pages.path}/$a.assets/$name').readAsBytesSync(), good);
    });

    test('the aside name taken: both files stay', () async {
      final (nb, a, x) = await damaged();
      File('${extra.path}/$a.assets/$aside').writeAsBytesSync([5]);
      await expectLater(nb.move(a, parentId: x), throwsA(isA<NotebookException>()));
      expect(File('${extra.path}/$a.assets/$name').readAsBytesSync(), bad);
      expect(File('${extra.path}/$a.assets/$aside').readAsBytesSync(), [5]);
      expect(File('${pages.path}/$a.assets/$name').readAsBytesSync(), good);
    });

    test('the source file a placeholder in one root: not hashed, both stay', () async {
      final (nb, a, x) = await damaged();
      oneRoot();
      mark('${pages.path}/$a.assets/$name');
      await expectLater(nb.move(a, parentId: x), throwsA(isA<NotebookException>()));
      expect(File('${extra.path}/$a.assets/$name').readAsBytesSync(), bad);
      expect(File('${pages.path}/$a.assets/$name').readAsBytesSync(), good);
      expect(Directory('${extra.path}/$a.assets').listSync().length, 1);
    });

    test('the target file a placeholder: treated as syncing, nothing set aside', () async {
      final (nb, a, x) = await damaged();
      oneRoot();
      mark('${extra.path}/$a.assets/$name');
      await expectLater(nb.move(a, parentId: x), throwsA(isA<NotebookException>()));
      expect(File('${extra.path}/$a.assets/$name').readAsBytesSync(), bad);
      expect(File('${pages.path}/$a.assets/$name').readAsBytesSync(), good);
    });

    test('the target file still syncing: the source file stays', () async {
      final (nb, a, x) = await damaged();
      final target = '${extra.path}/$a.assets/$name';
      attachmentAfterHashHook = (f) async {
        if (f.path.replaceAll(r'\', '/').contains('Elsewhere')) {
          File(target).writeAsBytesSync([...bad, 0]);
        }
      };
      await expectLater(nb.move(a, parentId: x), throwsA(isA<NotebookException>()));
      expect(File(target).readAsBytesSync(), [...bad, 0]);
      expect(File('${pages.path}/$a.assets/$name').readAsBytesSync(), good);
    });
  });

  group('O: a stray attachments folder', () {
    // `x` is at the other folder; its attachments folder is left in the default
    // folder.
    Future<(Notebook, String, Directory, List<String>)> stray() async {
      final (nb, _, _, x) = await scanned();
      final notices = <String>[];
      final sub = nb.attachmentNotices.listen(notices.add);
      addTearDown(sub.cancel);
      final dir = Directory('${pages.path}/$x.assets')..createSync();
      File('${dir.path}/one.bin').writeAsBytesSync([1]);
      return (nb, x, dir, notices);
    }

    final t0 = DateTime(2031, 1, 1);

    test('moved after 30 s without a change, not before', () async {
      final (nb, x, dir, _) = await stray();
      var t = t0;
      nb.now = () => t;
      await nb.checkFolders();
      t = t0.add(const Duration(seconds: 29));
      await nb.checkFolders();
      expect(dir.existsSync(), isTrue);
      t = t0.add(const Duration(seconds: 31));
      await nb.checkFolders();
      expect(dir.existsSync(), isFalse);
      expect(File('${extra.path}/$x.assets/one.bin').readAsBytesSync(), [1]);
    });

    test('a change inside the folder restarts the wait', () async {
      final (nb, x, dir, _) = await stray();
      var t = t0;
      nb.now = () => t;
      await nb.checkFolders();
      t = t0.add(const Duration(seconds: 20));
      File('${dir.path}/two.bin').writeAsBytesSync([2]);
      await nb.checkFolders();
      t = t0.add(const Duration(seconds: 40));
      await nb.checkFolders();
      expect(dir.existsSync(), isTrue);
      t = t0.add(const Duration(seconds: 55));
      await nb.checkFolders();
      expect(File('${extra.path}/$x.assets/two.bin').existsSync(), isTrue);
      expect(dir.existsSync(), isFalse);
    });

    test('a file in the source that may be the page keeps the folder, reported once', () async {
      final (nb, x, dir, notices) = await stray();
      File('${pages.path}/$x (conflicted copy).canvas').writeAsStringSync('half synced');
      var t = t0;
      nb.now = () => t;
      for (var i = 0; i < 4; i++) {
        t = t0.add(Duration(seconds: 40 * i));
        await nb.checkFolders();
      }
      expect(dir.existsSync(), isTrue);
      expect(Directory('${extra.path}/$x.assets').existsSync(), isFalse);
      expect(notices.where((n) => n.contains('stayed in')), hasLength(1));
    });

    test('a set-aside folder is never moved', () async {
      final (nb, x, dir, _) = await stray();
      final aside = Directory('${pages.path}/$x.deleted-0123456789ab.assets')..createSync();
      File('${aside.path}/k.bin').writeAsBytesSync([3]);
      dir.deleteSync(recursive: true);
      var t = t0;
      nb.now = () => t;
      await nb.checkFolders();
      t = t0.add(const Duration(minutes: 5));
      await nb.checkFolders();
      expect(aside.existsSync(), isTrue);
      expect(Directory('${extra.path}/$x.assets').existsSync(), isFalse);
    });

    test('a folder of a page that is listed at its own folder is not stray', () async {
      final (nb, a, _, _) = await scanned();
      File('${pages.path}/$a.assets/f.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);
      var t = t0;
      nb.now = () => t;
      await nb.checkFolders();
      t = t0.add(const Duration(minutes: 5));
      await nb.checkFolders();
      expect(File('${pages.path}/$a.assets/f.bin').existsSync(), isTrue);
    });
  });

  group('_moveDir on moveExclusive', () {
    test('a folder move under a registered root names each file it holds', () async {
      final (nb, a, _, x) = await scanned();
      final rec = _Recorder();
      registerCoordinator(root.path, rec);
      addTearDown(() => unregisterCoordinator(root.path));
      File('${pages.path}/$a.assets/one.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);
      File('${pages.path}/$a.assets/sub/two.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync([2]);
      expect(await nb.move(a, parentId: x), isTrue);
      final moved = [
        for (final c in rec.calls)
          for (final i in c.intents)
            if (i.kind == CoordinationKind.move) i.path.replaceAll(r'\', '/'),
      ];
      expect(moved.where((p) => p.endsWith('$a.assets')), isNotEmpty);
      expect(moved.where((p) => p.endsWith('$a.assets/one.bin')), isNotEmpty);
      expect(moved.where((p) => p.endsWith('$a.assets/sub/two.bin')), isNotEmpty);
    });

    test('a delete and its Undo rename the folder; a name taken at the target stays, reported', () async {
      final nb = make();
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      File('${pages.path}/$a.assets/one.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);
      File('${pages.path}/$a.assets/two.bin').writeAsBytesSync([2]);
      final deleted = await nb.delete(a);
      expect(Directory('${pages.path}/$a.assets').existsSync(), isFalse);
      // A different file took a name in the way while the page was deleted.
      File('${pages.path}/$a.assets/one.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync([9]);
      await expectLater(nb.undoDelete(deleted), throwsA(isA<NotebookException>()));
      expect(File('${pages.path}/$a.assets/one.bin').readAsBytesSync(), [9], reason: 'never replaced');
      expect(File('${pages.path}/$a.assets/two.bin').readAsBytesSync(), [2]);
    });
  });
}
