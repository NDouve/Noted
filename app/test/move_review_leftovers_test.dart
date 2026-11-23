// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// What the rename move's review left (design 2026-11-14-02, revision 5.4): a
// binder held between two pages of a move, the damaged-target branch of 2c with
// a rollback, N4 (a stamp is recorded only where a read was applied), R5 (the
// landing of kept files skips busy pages), N10 (a listed id equal to a
// set-aside's stem keeps it) and the recovery hand-off from an in-place
// set-aside.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

// A store whose new files and deletes of the pages named can be made to fail.
class _FailStore extends PageStore {
  _FailStore(super.directory);

  final Set<String> failDelete = {};
  final Set<String> failNew = {};

  @override
  Future<bool> saveNewText(
    NotedPage page,
    String text, {
    Future<void> Function()? beforePublish,
    void Function(FileStamp?)? onPublishStamp,
  }) {
    if (failNew.contains(page.id)) throw const FileSystemException('destination gone');
    return super.saveNewText(page, text, beforePublish: beforePublish, onPublishStamp: onPublishStamp);
  }

  @override
  Future<DeleteResult> deleteIfUnchanged(
    String pageId,
    String expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    Future<void> Function()? beforeDelete,
    void Function()? beforeRestore,
    Future<void> Function(String path)? beforeAsideDelete,
    Future<void> Function(String path)? beforeFinalCheck,
    Future<void> Function(String path)? afterFinalRead,
  }) {
    if (failDelete.contains(pageId)) throw const FileSystemException('source gone');
    return super.deleteIfUnchanged(
      pageId,
      expectedText,
      beforeMoveAside: beforeMoveAside,
      afterRead: afterRead,
      beforeDelete: beforeDelete,
      beforeRestore: beforeRestore,
      beforeAsideDelete: beforeAsideDelete,
      beforeFinalCheck: beforeFinalCheck,
      afterFinalRead: afterFinalRead,
    );
  }
}

void main() {
  late Directory root;
  late Directory pages;
  late Directory extra;
  late Directory rec;
  late List<Notebook> opened;
  late List<String> reads;
  late _FailStore store;
  Future<void> Function(String, String)? hook;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_move_review');
    pages = await Directory('${root.path}/pages').create();
    extra = await Directory('${root.path}/Elsewhere').create();
    rec = Directory('${root.path}/rec');
    opened = [];
    reads = [];
    hook = null;
    store = _FailStore(pages);
    PageStore.fileReadObserver = reads.add;
    Notebook.pairLockLimit = const Duration(milliseconds: 150);
    Notebook.pairRetryDelay = const Duration(milliseconds: 10);
  });
  tearDown(() async {
    PageStore.fileReadObserver = null;
    Notebook.pairLockLimit = const Duration(seconds: 5);
    Notebook.pairRetryDelay = const Duration(milliseconds: 500);
    Notebook.forceCopyMoveForTest = false;
    Notebook.forcePutBackCannotRenameForTest = false;
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    for (var attempt = 1; root.existsSync(); attempt++) {
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        if (attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  Notebook make({PageStore? pageStore}) {
    final nb = Notebook(
      pageStore ?? PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
      recoveryDirectory: rec,
    );
    nb.syncHook = (point, path) async => hook?.call(point, path);
    opened.add(nb);
    return nb;
  }

  bool has(Directory d, String id) => File('${d.path}/$id.canvas').existsSync();

  // A page `a` with a subpage and a page `x` in the other folder, written by one
  // notebook; a second notebook then scans them (each file has a stamp and
  // nothing was read since).
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

  group('a binder folder held between pages 1 and 2 of a move', () {
    test('nothing moves after the hold, each page is in one place, and the hold ends with the binder\'s own file', () async {
      final nb = make();
      await nb.load();
      final folder = await Directory('${root.path}/Work').create();
      final s = await nb.addBinder(folder.path);
      final a = await nb.createPage(binderPath: s.path);
      final ca = await nb.createPage(parentId: a);
      await nb.createPage(binderPath: s.path);
      await nb.flush();
      final bf = File('${folder.path}/$binderFileName');
      final own = bf.readAsStringSync();
      var renames = 0;
      hook = (point, path) async {
        // Another binder's file stands in the folder once the first page moved.
        if (point == 'move-after-rename' && ++renames == 1) {
          bf.writeAsStringSync(Binder.create(title: 'Other', color: binderPalette[2]).write());
        }
      };
      await expectLater(nb.moveToLocation(a), throwsA(isA<NotebookException>()));
      hook = null;
      expect(has(pages, a), isTrue, reason: 'the first page was moved before the hold');
      expect(has(folder, ca), isTrue, reason: 'the second page stayed');
      expect(has(pages, ca), isFalse, reason: 'nothing moved after the hold');
      expect(has(folder, a), isFalse, reason: 'the held folder refused the page\'s return: one place');
      expect(nb.holdOfFolder(folder.path), isNotNull);
      bf.writeAsStringSync(own);
      await nb.checkBinderFile(bf.path);
      expect(nb.holdOfFolder(folder.path), isNull, reason: 'its own file ends the hold');
    });
  });

  group('2c: the damaged-target branch on the rename path, then a rollback', () {
    test('every file survives: the damaged one is kept once, the good one is back at the source', () async {
      final (nb, a, ca, x) = await scanned();
      final good = Uint8List.fromList(List.generate(30, (i) => i + 1));
      final bad = Uint8List.fromList(List.generate(30, (i) => 200 - i));
      final name = attachmentFileName(contentHash(good), 'bin');
      File('${pages.path}/$a.assets/$name')
        ..createSync(recursive: true)
        ..writeAsBytesSync(good);
      File('${extra.path}/$a.assets/$name')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bad);
      // The subpage's name is taken at the target: it fails after the first page
      // moved, and the first page goes back.
      File('${extra.path}/$ca.canvas').writeAsStringSync('someone else');
      await expectLater(nb.move(a, parentId: x), throwsA(isA<NotebookException>()));
      expect(has(pages, a) && has(pages, ca), isTrue, reason: 'both pages are at the source');
      expect(has(extra, a), isFalse);
      expect(File('${extra.path}/$ca.canvas').readAsStringSync(), 'someone else', reason: 'never replaced');
      // Nothing was deleted or duplicated: the good file and the damaged one (under its
      // set-aside name) are the only two files of the page.
      final all = [
        for (final d in [pages, extra])
          for (final e in Directory('${d.path}/${assetsFolderName(a)}').existsSync()
              ? Directory('${d.path}/${assetsFolderName(a)}').listSync(recursive: true)
              : <FileSystemEntity>[])
            if (e is File) e,
      ];
      expect(all.map((f) => f.readAsBytesSync().join(',')).toList()..sort(), [good.join(','), bad.join(',')]..sort());
      expect(File('${pages.path}/$a.assets/$name').readAsBytesSync(), good, reason: 'the good file is at the source under its name');
      expect(
        all.where((f) => f.path.contains('.damaged-')).map((f) => f.readAsBytesSync().join(',')),
        [bad.join(',')],
        reason: 'the damaged file is kept once, under its set-aside name',
      );
    });
  });

  group('N4: a stamp is recorded only where a read was applied', () {
    test('a file that is read and listed as unreadable is read again; a file that is read and applied is not', () async {
      final (nb, _, ca, _) = await scanned();
      final path = '${pages.path}/$ca.canvas';
      final good = File(path).readAsStringSync();
      int readsOf() => reads.where((r) => r.endsWith('$ca.canvas')).length;
      // Not applied: the file can't be parsed.
      File(path).writeAsStringSync('{ not a page');
      await nb.checkFile(path);
      expect(nb.unreadable.any((u) => u.path.endsWith('$ca.canvas')), isTrue);
      final first = readsOf();
      expect(first, greaterThan(0), reason: 'a changed file is read');
      await nb.checkFile(path);
      expect(readsOf(), greaterThan(first), reason: 'no stamp was recorded for a read that was not applied');
      // Applied: a newer valid version.
      final page = readPage(good);
      File(path).writeAsStringSync(writePage(page.withMeta(page.meta.withTitle('Newer'))));
      reads.clear();
      await nb.checkFile(path);
      expect(readsOf(), 1);
      await nb.checkFile(path);
      expect(readsOf(), 1, reason: 'its stamp matches now');
      expect(nb.pageTitleOf(ca), 'Newer');
    });

    test('a file that holds a page already listed elsewhere (a duplicate) is not stamped', () async {
      final (nb, a, _, _) = await scanned();
      final copy = '${extra.path}/copy-of-$a.canvas';
      File(copy).writeAsStringSync(File('${pages.path}/$a.canvas').readAsStringSync());
      await nb.checkFile(copy);
      reads.clear();
      await nb.checkFile(copy);
      await nb.checkFile(copy);
      expect(reads.where((r) => r.endsWith('copy-of-$a.canvas')).length, 2, reason: 'a duplicate is read at each check');
    });
  });

  group('a source replaced by a page that is stored in the target folder itself', () {
    for (final shown in ['no page', 'q', 'p']) {
     test('the live notebook lists a duplicate of q as a fresh one does (open: $shown)', () async {
      final first = make();
      await first.load();
      final folder = await Directory('${root.path}/Work').create();
      final s = await first.addBinder(folder.path);
      final p = await first.createPage(binderPath: s.path);
      final q = await first.createPage();
      await first.flush();
      first.dispose();
      opened.remove(first);
      final nb = make();
      await nb.load();
      if (shown == 'q') await nb.open(q);
      if (shown == 'p') await nb.open(p);
      final qText = File('${pages.path}/$q.canvas').readAsStringSync();
      hook = (point, path) async {
        // Another page's file lands under p's name just before its rename.
        if (point == 'move-before-rename') {
          hook = null;
          File('${folder.path}/$p.canvas').writeAsStringSync(qText);
        }
      };
      Object? error;
      try {
        await nb.moveToLocation(p);
      } on Object catch (e) {
        error = e;
      }
      hook = null;
      await nb.flush();
      expect(File('${pages.path}/$p.canvas').readAsStringSync(), qText, reason: 'the replaced file moved as it was');
      Set<String> dups(Notebook n) => {
        for (final u in n.unreadable)
          if (u.reason.startsWith('duplicate page id $q')) u.path.replaceAll(r'\', '/').toLowerCase(),
      };
      final two = {
        '${pages.path}/$p.canvas'.replaceAll(r'\', '/').toLowerCase(),
        '${pages.path}/$q.canvas'.replaceAll(r'\', '/').toLowerCase(),
      };
      final fresh = make();
      await fresh.load();
      // Which of the two files is the duplicate depends on the order a scan lists
      // them in: each notebook lists exactly one of them.
      expect(dups(fresh), hasLength(1), reason: 'a fresh notebook lists one of the two files of q as the duplicate (error: $error)');
      expect(dups(nb), hasLength(1), reason: 'the live notebook lists one too (error: $error)');
      expect(two.containsAll(dups(nb)), isTrue);
      expect(nb.pageTitleOf(q), fresh.pageTitleOf(q));
      expect(nb.pageTitleOf(p) == null, fresh.pageTitleOf(p) == null, reason: 'p is listed by both or neither');
     });
    }
  });

  group('R5: the landing of kept files skips a busy page', () {
    test('a page that is moving gets nothing landed until it has moved; then they land at its new place', () async {
      final (nb, a, _, x) = await scanned();
      final kept = Directory('${rec.path}/${assetsFolderName(a)}')..createSync(recursive: true);
      File('${kept.path}/k.txt').writeAsStringSync('kept');
      var landedDuring = true;
      hook = (point, path) async {
        if (point != 'move-before-rename') return;
        hook = null;
        // A landing under way while the page is busy: it lands nothing.
        await nb.recoverNowForTest();
        landedDuring = File('${pages.path}/$a.assets/k.txt').existsSync() || File('${extra.path}/$a.assets/k.txt').existsSync();
      };
      expect(await nb.move(a, parentId: x), isTrue);
      expect(landedDuring, isFalse, reason: 'nothing landed in a folder of a page that was being moved');
      expect(File('${kept.path}/k.txt').existsSync(), isTrue, reason: 'the kept file waits');
      await nb.recoverNowForTest();
      expect(File('${extra.path}/$a.assets/k.txt').readAsStringSync(), 'kept', reason: 'landed at the page\'s place');
      expect(File('${pages.path}/$a.assets/k.txt').existsSync(), isFalse);
    });
  });

  group('the in-place set-aside', () {
    final bytes = Uint8List.fromList(List.generate(30, (i) => i * 5));
    final hashName = attachmentFileName(contentHash(bytes), 'bin');

    List<Directory> inPlace(String id, Directory dir) => [
      for (final e in dir.listSync())
        if (e is Directory && RegExp('^${RegExp.escape(id)}\\.deleted-[0-9a-f]{12}\\.assets\$').hasMatch(e.path.split(RegExp(r'[\\/]')).last)) e,
    ];

    test('N10: a listed id equal to the set-aside\'s stem keeps it from the expiry', () async {
      Notebook.forceCopyMoveForTest = true;
      final nb = make();
      await nb.load();
      await nb.addStandaloneFolder(extra.path);
      final a = await nb.createPage();
      await nb.open(a);
      await nb.flush();
      Directory('${pages.path}/${assetsFolderName(a)}').createSync();
      File('${pages.path}/${assetsFolderName(a)}/$hashName').writeAsBytesSync(bytes);
      final deleted = await nb.delete(a);
      final aside = inPlace(a, pages).single;
      final stem = aside.path.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.assets$'), '');
      // A page whose id is the stem is listed (in the other folder, so no name in the
      // page's own folder shows it).
      File('${extra.path}/$stem.canvas').writeAsStringSync(writePage(NotedPage.create(PageMeta.create(id: stem, title: 'Stem', order: 0))));
      await nb.checkFile('${extra.path}/$stem.canvas');
      expect(nb.pageTitleOf(stem), 'Stem');
      nb.discardDeleted(deleted);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(File('${aside.path}/$hashName').existsSync(), isTrue, reason: 'kept: a listed id equals the stem');
      // Without it the same expiry removes the file.
      File('${extra.path}/$stem.canvas').deleteSync();
      await nb.checkFile('${extra.path}/$stem.canvas');
      await nb.checkFile('${pages.path}/${nb.currentId}.canvas');
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (File('${aside.path}/$hashName').existsSync() && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(File('${aside.path}/$hashName').existsSync(), isFalse, reason: 'removed once no listed id equals the stem');
    });

    test('the recovery hand-off from an in-place set-aside copies and keeps the set-aside', () async {
      Notebook.forceCopyMoveForTest = true;
      final nb = make(pageStore: store);
      await nb.load();
      final a = await nb.createPage();
      final sub = await nb.createPage(parentId: a);
      await nb.open(a);
      await nb.flush();
      Directory('${pages.path}/${assetsFolderName(a)}').createSync();
      File('${pages.path}/${assetsFolderName(a)}/$hashName').writeAsBytesSync(bytes);
      // The delete of the last page fails and the first page can't be written back:
      // its folder is handed to recovery's kept files.
      store.failDelete.add(sub);
      store.failNew.add(a);
      Notebook.forcePutBackCannotRenameForTest = true; // the set-aside is in place: no rename to recovery
      Object? error;
      try {
        await nb.delete(a);
      } on Object catch (e) {
        error = e;
      }
      store.failDelete.clear();
      store.failNew.clear();
      expect(error, isNotNull, reason: 'the delete failed');
      final handed = File('${rec.path}/${assetsFolderName(a)}/$hashName');
      expect(handed.existsSync(), isTrue, reason: 'handed to recovery');
      expect(handed.readAsBytesSync(), bytes);
      // From an in-place set-aside the hand-off copies (another folder, no rename): what
      // it copied from is kept, never deleted on the strength of the copy.
      final left = [for (final d in inPlace(a, pages)) ...d.listSync().whereType<File>()];
      expect(left, hasLength(1), reason: 'the set-aside keeps its file');
      expect(left.single.readAsBytesSync(), bytes);
    });
  });
}
