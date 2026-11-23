// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The delete set-aside and its expiry (design 2026-11-14-02, revision 5.4): a
// delete's attachments are set aside by rename, in `deleted-attachments` or in
// place beside the page, and removed once the delete can no longer be undone,
// file by file against the identity recorded at delete time and only while no
// file in the page's folder may be the page. Each scenario ends by comparing the
// notebook with a fresh one loaded from the same disk (the `delete:*` kinds of
// the reload-equivalence harness).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

class _Refuser implements StorageCoordinator {
  _Refuser(this.refuse);

  bool Function(CoordinatedWrite write) refuse;
  final List<CoordinatedWrite> calls = [];

  @override
  Future<T> coordinate<T>(CoordinatedWrite write, Future<T> Function() body) {
    calls.add(write);
    if (refuse(write)) throw StorageBusy(StorageBusyReason.coordination, const []);
    return body();
  }
}

// A store whose delete of the pages in [failDelete] fails (a source that went
// away), so a multi-page delete rolls back.
class _FailStore extends PageStore {
  _FailStore(super.directory);

  final Set<String> failDelete = {};

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
  late Directory app;
  late List<Notebook> opened;
  late List<String> reads;
  late List<String> notices;
  Future<void> Function(String, String)? hook;
  late _FailStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_set_aside');
    pages = await Directory('${root.path}/pages').create();
    extra = await Directory('${root.path}/Elsewhere').create();
    app = await Directory('${root.path}/app').create();
    opened = [];
    reads = [];
    notices = [];
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
    Notebook.expiryQuitLimit = const Duration(seconds: 5);
    Notebook.placeholderMarksForTest = {};
    for (final nb in opened) {
      nb.now = DateTime.now;
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

  Notebook make() {
    final nb = Notebook(
      store,
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${app.path}/binders.json'),
    );
    nb.syncHook = (point, path) async => hook?.call(point, path);
    nb.attachmentNotices.listen(notices.add);
    opened.add(nb);
    return nb;
  }

  Uint8List bytesOf(int n) => Uint8List.fromList(List.generate(30, (i) => n * 7 + i));
  String hashName(int n) => attachmentFileName(contentHash(bytesOf(n)), 'bin');

  void giveAssets(String id, int files, {Directory? dir}) {
    final d = Directory('${(dir ?? pages).path}/${assetsFolderName(id)}')..createSync(recursive: true);
    for (var i = 1; i <= files; i++) {
      File('${d.path}/${hashName(i)}').writeAsBytesSync(bytesOf(i));
    }
  }

  // The notebook with a spare page `keep` and a page `a` with [files]
  // attachments (hash-named files, so each has an identity).
  Future<(Notebook, String, String)> world({int files = 1}) async {
    final nb = make();
    await nb.load();
    final keep = nb.currentId!;
    final a = await nb.createPage();
    await nb.open(a);
    await nb.flush();
    giveAssets(a, files);
    return (nb, a, keep);
  }

  List<Directory> inPlace(String id, [Directory? dir]) => [
    for (final e in (dir ?? pages).listSync())
      if (e is Directory && RegExp('^${RegExp.escape(id)}\\.deleted-[0-9a-f]{12}\\.assets\$').hasMatch(e.path.split(RegExp(r'[\\/]')).last)) e,
  ];

  Directory trashDir() => Directory('${app.path}/deleted-attachments');
  List<File> trashFiles() => trashDir().existsSync() ? trashDir().listSync(recursive: true).whereType<File>().toList() : [];
  File live(String id, int n, [Directory? dir]) => File('${(dir ?? pages).path}/${assetsFolderName(id)}/${hashName(n)}');

  Future<void> until(bool Function() ok, {int ms = 5000, String what = 'the condition'}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> quiet() => Future<void>.delayed(const Duration(milliseconds: 250));

  // The ids of every page the notebook lists.
  Set<String> idsOf(Notebook nb) {
    final out = <String>{};
    void walk(List<PageMeta> l) {
      for (final p in l) {
        out.add(p.id);
        walk(nb.tree.childrenOf(p.id));
      }
    }

    walk(nb.tree.roots);
    return out;
  }

  // The kind's last step: a fresh notebook loaded from the same disk lists the
  // pages this one lists, and the folders on disk are as given.
  Future<void> reloadAgrees(Notebook nb, {required Set<String> listed}) async {
    await nb.flush();
    final fresh = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${app.path}/binders.json'),
    );
    opened.add(fresh);
    await fresh.load();
    expect(idsOf(nb), listed, reason: 'the live notebook');
    expect(idsOf(fresh), listed, reason: 'a fresh notebook');
  }

  group('delete:inPlace*', () {
    test('delete:inPlaceRenamed: the folder is renamed beside the page and the expiry empties it', () async {
      Notebook.forceCopyMoveForTest = true; // the rename into deleted-attachments is cannotRename
      final (nb, a, keep) = await world(files: 2);
      final deleted = await nb.delete(a);
      final aside = inPlace(a);
      expect(aside, hasLength(1));
      expect(Directory('${pages.path}/${assetsFolderName(a)}').existsSync(), isFalse);
      expect(trashFiles(), isEmpty, reason: 'not in deleted-attachments');
      expect(aside.single.listSync(), hasLength(2));
      reads.clear();
      nb.discardDeleted(deleted);
      await until(() => inPlace(a).isEmpty, what: 'the expiry');
      expect(reads, isEmpty, reason: 'the expiry reads no page file');
      await reloadAgrees(nb, listed: {keep});
    });

    test('delete:inPlaceRenamed: a rename that is busy leaves <p>.assets with no record; nothing is ever removed from it', () async {
      Notebook.forceCopyMoveForTest = true;
      final (nb, a, keep) = await world();
      final refuser = _Refuser((w) => w.intents.any((i) => i.kind == CoordinationKind.move && i.path.endsWith('.assets')));
      registerCoordinator(root.path, refuser);
      addTearDown(() => unregisterCoordinator(root.path));
      final deleted = await nb.delete(a);
      expect(inPlace(a), isEmpty);
      expect(live(a, 1).existsSync(), isTrue, reason: 'the folder stays as <p>.assets');
      expect(trashFiles(), isEmpty);
      nb.discardDeleted(deleted);
      await quiet();
      expect(live(a, 1).existsSync(), isTrue, reason: 'the expiry deletes nothing there');
      await reloadAgrees(nb, listed: {keep});
    });

    test('delete:inPlaceUndo: Undo renames it back', () async {
      Notebook.forceCopyMoveForTest = true;
      final (nb, a, keep) = await world(files: 2);
      final deleted = await nb.delete(a);
      expect(inPlace(a), hasLength(1));
      await nb.undoDelete(deleted);
      expect(inPlace(a), isEmpty);
      expect(live(a, 1).readAsBytesSync(), bytesOf(1));
      expect(live(a, 2).readAsBytesSync(), bytesOf(2));
      await reloadAgrees(nb, listed: {keep, a});
    });

    test('delete:inPlaceUndo: into a taken name the files go one by one; leftovers stay and are kept from the expiry', () async {
      Notebook.forceCopyMoveForTest = true;
      final (nb, a, keep) = await world(files: 2);
      File('${pages.path}/${assetsFolderName(a)}/notes.txt').writeAsStringSync('mine');
      final deleted = await nb.delete(a);
      Directory('${pages.path}/${assetsFolderName(a)}').createSync();
      File('${pages.path}/${assetsFolderName(a)}/notes.txt').writeAsStringSync('theirs'); // a different file took the name
      await expectLater(nb.undoDelete(deleted), throwsA(isA<NotebookException>()));
      expect(File('${pages.path}/${assetsFolderName(a)}/notes.txt').readAsStringSync(), 'theirs', reason: 'never replaced');
      expect(live(a, 1).readAsBytesSync(), bytesOf(1), reason: 'the others went back');
      expect(live(a, 2).readAsBytesSync(), bytesOf(2));
      final left = inPlace(a).single.listSync().whereType<File>().single;
      expect(left.readAsStringSync(), 'mine');
      nb.discardDeleted(deleted);
      await quiet();
      expect(left.existsSync(), isTrue, reason: 'kept from the expiry');
      await reloadAgrees(nb, listed: {keep, a});
    });

    test('delete:inPlaceKilled: a kill before the expiry leaves the folder under its name', () async {
      Notebook.forceCopyMoveForTest = true;
      final (nb, a, keep) = await world();
      await nb.delete(a);
      final aside = inPlace(a).single.path;
      nb.dispose();
      opened.remove(nb);
      final again = make();
      await again.load();
      await quiet();
      expect(Directory(aside).existsSync(), isTrue, reason: 'nothing removes it');
      expect(File('$aside/${hashName(1)}').existsSync(), isTrue);
      expect(Directory('${pages.path}/${assetsFolderName(a)}').existsSync(), isFalse, reason: 'O leaves a .deleted- folder alone');
      await reloadAgrees(again, listed: {keep});
    });

    test('delete:inPlaceRollback: a delete that fails puts every in-place folder back by rename', () async {
      Notebook.forceCopyMoveForTest = true;
      final (nb, a, keep) = await world();
      final sub = await nb.createPage(parentId: a);
      await nb.flush();
      giveAssets(sub, 1);
      store.failDelete.add(sub);
      Object? error;
      try {
        await nb.delete(a);
      } on Object catch (e) {
        error = e;
      }
      store.failDelete.clear();
      expect(error, isNotNull);
      expect(inPlace(a), isEmpty);
      expect(inPlace(sub), isEmpty);
      expect(live(a, 1).readAsBytesSync(), bytesOf(1));
      expect(live(sub, 1).readAsBytesSync(), bytesOf(1));
      await reloadAgrees(nb, listed: {keep, a, sub});
    });

    test('under a registered root, the in-place rename names each file the folder holds', () async {
      Notebook.forceCopyMoveForTest = true;
      final (nb, a, _) = await world(files: 2);
      final rec = _Refuser((_) => false);
      registerCoordinator(root.path, rec);
      addTearDown(() => unregisterCoordinator(root.path));
      await nb.delete(a);
      final moved = [
        for (final c in rec.calls)
          for (final i in c.intents)
            if (i.kind == CoordinationKind.move) i.path.replaceAll(r'\', '/'),
      ];
      expect(moved.where((p) => p.endsWith('${assetsFolderName(a)}/${hashName(1)}')), isNotEmpty);
      expect(moved.where((p) => p.endsWith('${assetsFolderName(a)}/${hashName(2)}')), isNotEmpty);
    });

    test('a pending (busy) Undo keeps the set-aside, which the expiry then leaves alone', () async {
      Notebook.forceCopyMoveForTest = true;
      final (nb, a, keep) = await world();
      final deleted = await nb.delete(a);
      final aside = inPlace(a).single;
      final refuser = _Refuser((w) => w.intents.any((i) => i.kind == CoordinationKind.move && i.path.contains('.deleted-')));
      registerCoordinator(root.path, refuser);
      addTearDown(() => unregisterCoordinator(root.path));
      await expectLater(nb.undoDelete(deleted), throwsA(isA<NotebookException>()));
      expect(aside.existsSync(), isTrue);
      expect(File('${aside.path}/${hashName(1)}').existsSync(), isTrue);
      nb.discardDeleted(deleted);
      await quiet();
      expect(File('${aside.path}/${hashName(1)}').existsSync(), isTrue, reason: 'kept from the expiry');
      await reloadAgrees(nb, listed: {keep, a});
    });

    test('a folder holding a placeholder is set aside in place; the placeholder stays, reported once', () async {
      final (nb, a, keep) = await world(files: 2);
      Notebook.placeholderMarksForTest = {fileStamp(live(a, 2).path)!};
      final deleted = await nb.delete(a);
      expect(inPlace(a), hasLength(1), reason: 'a placeholder is never moved out of its folder');
      expect(trashFiles(), isEmpty);
      nb.discardDeleted(deleted);
      await until(() => !File('${inPlace(a).single.path}/${hashName(1)}').existsSync(), what: 'the file with an identity to go');
      await quiet();
      expect(File('${inPlace(a).single.path}/${hashName(2)}').existsSync(), isTrue, reason: 'a placeholder has no identity: kept');
      expect(notices.where((n) => n.contains('were not removed')), hasLength(1));
      await reloadAgrees(nb, listed: {keep});
    });
  });

  group('delete:crossVolumePutBackKeepsTrash', () {
    test('a put-back that answers cannotRename copies, keeps the trash folder and reports', () async {
      final (nb, a, keep) = await world();
      final deleted = await nb.delete(a);
      expect(trashFiles(), hasLength(1));
      Notebook.forcePutBackCannotRenameForTest = true;
      await expectLater(nb.undoDelete(deleted), throwsA(isA<NotebookException>()));
      Notebook.forcePutBackCannotRenameForTest = false;
      expect(live(a, 1).readAsBytesSync(), bytesOf(1), reason: 'copied');
      expect(trashFiles(), hasLength(1), reason: 'the trash folder is kept');
      nb.discardDeleted(deleted);
      await quiet();
      expect(trashFiles(), hasLength(1), reason: 'and kept from the expiry');
      await reloadAgrees(nb, listed: {keep, a});
    });
  });

  // The page comes back from sync under [name] before the watcher says so.
  for (final inPlaceSet in [true, false]) {
    for (final quit in [false, true]) {
      for (final form in ['id', 'chosen', 'conflict']) {
        final kind = '${inPlaceSet ? 'delete:restoredBefore' : 'delete:trashRestoredBefore'}Watcher${quit ? 'Quit' : 'Expiry'}';
        test('$kind ($form)', () async {
          Notebook.forceCopyMoveForTest = inPlaceSet;
          final (nb, a, keep) = await world(files: 2);
          final text = File('${pages.path}/$a.canvas').readAsStringSync();
          final deleted = await nb.delete(a);
          final name = switch (form) {
            'id' => '$a.canvas',
            'chosen' => 'My notes.canvas',
            _ => '$a-conflict-0123abcd.canvas',
          };
          File('${pages.path}/$name').writeAsStringSync(text);
          if (quit) {
            await nb.discardPendingDelete();
          } else {
            nb.discardDeleted(deleted);
            await quiet();
          }
          final stillThere = inPlaceSet
              ? inPlace(a).expand((d) => d.listSync()).whereType<File>().length
              : trashFiles().length;
          expect(stillThere, 2, reason: 'nothing was deleted: the page may be back');
          if (form == 'conflict') return;
          // The watcher's event: the page is listed, and the set-aside goes back.
          await nb.checkFile('${pages.path}/$name');
          await until(() => live(a, 1).existsSync() && live(a, 2).existsSync(), what: 'the set-aside to be restored');
          expect(inPlace(a), isEmpty);
          expect(trashFiles(), isEmpty);
          expect(idsOf(nb), contains(a));
          if (form == 'id') await reloadAgrees(nb, listed: {keep, a});
        });
      }
    }
  }

  group('delete:restoredMidExpiry', () {
    for (final inPlaceSet in [true, false]) {
      test('between two files (${inPlaceSet ? 'in place' : 'deleted-attachments'}): nothing after the restore is deleted', () async {
        Notebook.forceCopyMoveForTest = inPlaceSet;
        final (nb, a, keep) = await world(files: 3);
        final text = File('${pages.path}/$a.canvas').readAsStringSync();
        final deleted = await nb.delete(a);
        var n = 0;
        hook = (point, path) async {
          if (point == 'expiry-file' && ++n == 2) File('${pages.path}/$a.canvas').writeAsStringSync(text);
        };
        nb.discardDeleted(deleted);
        await until(() => n >= 2, what: 'the second file');
        await quiet();
        final left = inPlaceSet
            ? inPlace(a).expand((d) => d.listSync()).whereType<File>().length
            : trashFiles().length;
        expect(left, 2, reason: 'one file went before the restore, none after it');
        hook = null;
        await nb.checkFile('${pages.path}/$a.canvas');
        await until(() => live(a, 1).existsSync() || live(a, 2).existsSync() || live(a, 3).existsSync(), what: 'the restore');
        await reloadAgrees(nb, listed: {keep, a});
      });

      test('between a file\'s two stillRedundant calls (${inPlaceSet ? 'in place' : 'deleted-attachments'}): that file is kept', () async {
        Notebook.forceCopyMoveForTest = inPlaceSet;
        final (nb, a, _) = await world(files: 1);
        final text = File('${pages.path}/$a.canvas').readAsStringSync();
        final deleted = await nb.delete(a);
        hook = (point, path) async {
          if (point == 'expiry-final-check') File('${pages.path}/$a.canvas').writeAsStringSync(text);
        };
        nb.discardDeleted(deleted);
        await quiet();
        hook = null;
        final left = inPlaceSet
            ? inPlace(a).expand((d) => d.listSync()).whereType<File>().toList()
            : trashFiles();
        expect(left, hasLength(1), reason: 'the final check saw the page');
        expect(left.single.readAsBytesSync(), bytesOf(1));
      });
    }
  });

  group('delete:expiryKeptThenRestored', () {
    for (final inPlaceSet in [true, false]) {
      test('${inPlaceSet ? 'in place' : 'deleted-attachments'}: the set-aside goes back to <p>.assets once the watcher lists p', () async {
        Notebook.forceCopyMoveForTest = inPlaceSet;
        final (nb, a, keep) = await world();
        final text = File('${pages.path}/$a.canvas').readAsStringSync();
        final deleted = await nb.delete(a);
        File('${pages.path}/$a.canvas').writeAsStringSync(text);
        nb.discardDeleted(deleted);
        await quiet();
        expect(live(a, 1).existsSync(), isFalse, reason: 'kept by the first run');
        await nb.checkFile('${pages.path}/$a.canvas');
        await until(() => live(a, 1).existsSync(), what: 'the restore after the check');
        expect(live(a, 1).readAsBytesSync(), bytesOf(1));
        await reloadAgrees(nb, listed: {keep, a});
      });
    }

    test('p listed in another location: the set-aside goes into that location\'s folder', () async {
      final (nb, a, keep) = await world();
      final other = await nb.createPage(folderPath: extra.path);
      await nb.flush();
      final text = File('${pages.path}/$a.canvas').readAsStringSync();
      final deleted = await nb.delete(a);
      File('${extra.path}/$a.canvas').writeAsStringSync(text);
      await nb.checkFile('${extra.path}/$a.canvas');
      expect(idsOf(nb), contains(a));
      nb.discardDeleted(deleted);
      await until(() => live(a, 1, extra).existsSync(), what: 'the restore into the other folder');
      expect(live(a, 1).existsSync(), isFalse);
      expect(trashFiles(), isEmpty);
      expect(idsOf(nb), containsAll([keep, a, other]));
    });
  });

  group('delete:expiryHeld / expiryListingFails', () {
    test('delete:expiryHeld: a binder folder that holds another binder\'s file refuses the turn; nothing is deleted', () async {
      final nb = make();
      await nb.load();
      final folder = await Directory('${root.path}/Work').create();
      final s = await nb.addBinder(folder.path);
      final a = await nb.createPage(binderPath: s.path);
      await nb.createPage(binderPath: s.path);
      await nb.flush();
      giveAssets(a, 1, dir: folder);
      final deleted = await nb.delete(a);
      final file = trashFiles().single;
      File('${folder.path}/$binderFileName').writeAsStringSync(Binder.create(title: 'Other', color: binderPalette[2]).write());
      nb.discardDeleted(deleted);
      await quiet();
      expect(file.existsSync(), isTrue, reason: '0184\'s gate refused the turn');
    });

    test('delete:expiryListingFails: a listing that fails counts as the page', () async {
      final (nb, a, _) = await world();
      final deleted = await nb.delete(a);
      final away = Directory('${root.path}/pages-away');
      hook = (point, path) async {
        if (point == 'expiry-final-check') pages.renameSync(away.path);
      };
      nb.discardDeleted(deleted);
      await quiet();
      hook = null;
      if (away.existsSync()) away.renameSync(pages.path);
      expect(trashFiles(), hasLength(1), reason: 'kept');
    });
  });

  group('what counts as the page (B3), with no page file read', () {
    // A file in the folder after the delete; the set-aside must stay.
    Future<void> keeps(String why, void Function(String a, String other) plant) async {
      final (nb, a, _) = await world();
      final other = await nb.createPage();
      await nb.flush();
      final deleted = await nb.delete(a);
      plant(a, other);
      reads.clear();
      nb.discardDeleted(deleted);
      await quiet();
      expect(trashFiles(), hasLength(1), reason: why);
      expect(reads, isEmpty, reason: 'the presence check reads no page file');
    }

    test('an unparsable file with the page\'s id in its name', () => keeps('named for p', (a, _) {
      File('${pages.path}/$a-damaged.canvas').writeAsStringSync('{ not a page');
    }));

    test('an unreadable file with no id (new, unstamped)', () => keeps('unstamped', (a, _) {
      File('${pages.path}/something-new.canvas').writeAsStringSync('{ not a page');
    }));

    test('a changed file of another page (its stamp no longer matches)', () => keeps('changed', (a, other) {
      File('${pages.path}/$other.canvas').setLastModifiedSync(DateTime.now().add(const Duration(hours: 2)));
    }));

    test('an iCloud stub', () => keeps('a stub', (a, _) {
      File('${pages.path}/.something.canvas.icloud').writeAsStringSync('');
    }));

    test('with only known pages in the folder the expiry deletes, reading nothing', () async {
      final (nb, a, keep) = await world();
      final deleted = await nb.delete(a);
      reads.clear();
      nb.discardDeleted(deleted);
      await until(() => trashFiles().isEmpty, what: 'the expiry');
      expect(reads, isEmpty);
      expect(trashDir().existsSync() ? trashDir().listSync() : [], isEmpty, reason: 'empty folders are pruned');
      await reloadAgrees(nb, listed: {keep});
    });
  });

  group('the quit-time expiry', () {
    test('stops at 5 s, checked between files, with a fake clock', () async {
      final (nb, a, _) = await world(files: 3);
      final deleted = await nb.delete(a);
      var t = DateTime(2030);
      nb.now = () => t;
      var n = 0;
      hook = (point, path) async {
        if (point == 'expiry-file' && ++n == 2) t = t.add(const Duration(seconds: 6));
      };
      await nb.discardPendingDelete();
      hook = null;
      expect(deleted.pages, isNotEmpty);
      expect(trashFiles().length, 2, reason: 'one went, the rest stay under their set-aside name');
    });

    test('a stalled folder lock ends the quit after the limit and leaves the folder', () async {
      Notebook.expiryQuitLimit = const Duration(milliseconds: 300);
      final (nb, a, _) = await world();
      await nb.delete(a);
      final gate = Completer<void>();
      unawaited(nb.folderLocks.run(pages, () => gate.future));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final sw = Stopwatch()..start();
      await nb.discardPendingDelete();
      expect(sw.elapsedMilliseconds, lessThan(4000));
      expect(trashFiles(), hasLength(1));
      gate.complete();
    });
  });

  group('guards', () {
    test('no expiry path removes a set-aside recursively', () {
      final text = File('lib/src/notebook.dart').readAsStringSync().replaceAll('\r\n', '\n');
      final begin = text.indexOf('// --- expiry begin');
      final end = text.indexOf('// --- expiry end ---');
      expect(begin, greaterThan(0));
      expect(end, greaterThan(begin));
      final region = text.substring(begin, end);
      expect(RegExp(r'recursive:\s*true').allMatches(region).where((m) {
        final line = region.substring(region.lastIndexOf('\n', m.start) + 1, region.indexOf('\n', m.start));
        return line.contains('delete');
      }), isEmpty);
      expect(region.contains('_removeDir('), isFalse);
      expect(text.contains('_removeSetAside'), isFalse);
      expect(text.contains('removeVerifiedSources'), isFalse, reason: 'no copy-then-delete');
    });
  });
}
