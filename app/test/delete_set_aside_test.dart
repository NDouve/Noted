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

    test('delete:createRefused: a refused create of the folder for the rename (N4, C2) is busy: nothing moves, nothing is copied', () async {
      final (nb, a, keep) = await world();
      // The create of `deleted-attachments/<id>` is one write on `deleted-attachments`.
      final refuser = _Refuser(
        (w) => w.intents.length == 1 && w.intents.single.kind == CoordinationKind.write && w.intents.single.path.endsWith('deleted-attachments'),
      );
      registerCoordinator(root.path, refuser);
      addTearDown(() => unregisterCoordinator(root.path));
      final deleted = await nb.delete(a);
      expect(refuser.calls.where((w) => w.intents.single.path.endsWith('deleted-attachments')), isNotEmpty);
      expect(inPlace(a), isEmpty, reason: 'no rename beside the page either: the folder was busy');
      expect(trashDir().existsSync() ? trashDir().listSync() : const [], isEmpty);
      expect(live(a, 1).readAsBytesSync(), bytesOf(1), reason: 'the folder stays as <p>.assets, untouched');
      nb.discardDeleted(deleted);
      await quiet();
      expect(live(a, 1).existsSync(), isTrue, reason: 'no record, so the expiry deletes nothing there');
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

    test('delete:expiryHeld at file 2: the gate is taken per file; the first goes, the second is kept', () async {
      final nb = make();
      await nb.load();
      final folder = await Directory('${root.path}/Work').create();
      final s = await nb.addBinder(folder.path);
      final a = await nb.createPage(binderPath: s.path);
      await nb.createPage(binderPath: s.path);
      await nb.flush();
      giveAssets(a, 2, dir: folder);
      final deleted = await nb.delete(a);
      expect(trashFiles(), hasLength(2));
      var n = 0;
      hook = (point, path) async {
        if (point == 'expiry-file' && ++n == 2) {
          File('${folder.path}/$binderFileName').writeAsStringSync(Binder.create(title: 'Other', color: binderPalette[2]).write());
        }
      };
      nb.discardDeleted(deleted);
      await until(() => n >= 2, what: 'the second file');
      await quiet();
      hook = null;
      expect(trashFiles(), hasLength(1), reason: 'the first file went before the hold; the gate refused the second');
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

    test('another page\'s file replaced after the snapshot, at the final check, by one holding the page', () async {
      final (nb, a, _) = await world();
      final other = await nb.createPage();
      await nb.flush();
      final held = File('${pages.path}/$a.canvas').readAsStringSync();
      final deleted = await nb.delete(a);
      hook = (point, path) async {
        if (point != 'expiry-final-check') return;
        final f = File('${pages.path}/$other.canvas');
        f.writeAsStringSync(held);
        f.setLastModifiedSync(DateTime.now().add(const Duration(hours: 3)));
      };
      nb.discardDeleted(deleted);
      await quiet();
      hook = null;
      expect(trashFiles(), hasLength(1), reason: 'the replaced file may be the deleted page: kept');
    });

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
      // The first file's check takes 6 s (a slow hash): the file in flight finishes,
      // and the next file is not started (its turn's own limit would stop it too, but
      // only after the hook and the lock wait that the between-files check spares).
      var starts = 0, finals = 0;
      hook = (point, path) async {
        if (point == 'expiry-file') starts++;
        if (point == 'expiry-final-check' && ++finals == 1) t = t.add(const Duration(seconds: 6));
      };
      await nb.discardPendingDelete();
      hook = null;
      expect(deleted.pages, isNotEmpty);
      expect(starts, 1, reason: 'no second file was started after the limit');
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

  // A subpage of `a` whose file is in the other standalone folder (as another
  // device's move leaves it): the standalone folders share one tree.
  Future<(Notebook, String, String)> splitTree() async {
    final nb = make();
    await nb.load();
    await nb.addStandaloneFolder(extra.path);
    final a = await nb.createPage();
    final sub = await nb.createPage(parentId: a);
    await nb.flush();
    File('${pages.path}/$sub.canvas').renameSync('${extra.path}/$sub.canvas');
    await nb.checkFile('${pages.path}/$sub.canvas');
    await nb.checkFile('${extra.path}/$sub.canvas');
    expect(nb.tree.childrenOf(a).map((m) => m.id), [sub], reason: 'the subpage is still under a');
    return (nb, a, sub);
  }

  group('a standalone page whose subpage is stored in the other standalone folder', () {
    test('is deleted with it, each read and removed in its own folder; Undo brings both back', () async {
      final (nb, a, sub) = await splitTree();
      giveAssets(a, 1);
      giveAssets(sub, 1, dir: extra);
      expect(File('${extra.path}/$sub.canvas').existsSync(), isTrue, reason: 'the subpage is stored in the other folder');
      final deleted = await nb.delete(a);
      expect(File('${pages.path}/$a.canvas').existsSync(), isFalse);
      expect(File('${extra.path}/$sub.canvas').existsSync(), isFalse, reason: 'deleted from its own folder');
      expect(trashFiles(), hasLength(2), reason: 'each folder of attachments was set aside');
      expect(deleted.pages.map((p) => p.id), containsAll([a, sub]));
      nb.discardDeleted(deleted);
      await until(() => trashFiles().isEmpty, what: 'the expiry');
      await reloadAgrees(nb, listed: {...idsOf(nb)});
    });

    test('a delete that is undone puts both pages back', () async {
      final (nb, a, sub) = await splitTree();
      final keep = {...idsOf(nb)}..removeAll({a, sub});
      final deleted = await nb.delete(a);
      await nb.undoDelete(deleted);
      expect(File('${pages.path}/$a.canvas').existsSync(), isTrue, reason: 'the page is back in its folder');
      expect(File('${extra.path}/$sub.canvas').existsSync(), isTrue, reason: 'the subpage is back in the folder it was stored in');
      expect(File('${pages.path}/$sub.canvas').existsSync(), isFalse);
      expect(File('${extra.path}/$a.canvas').existsSync(), isFalse);
      await reloadAgrees(nb, listed: {...keep, a, sub});
    });

    test('Undo puts each page and its attachments back in the folder it was deleted from', () async {
      final (nb, a, sub) = await splitTree();
      giveAssets(a, 1);
      giveAssets(sub, 1, dir: extra);
      final deleted = await nb.delete(a);
      await nb.undoDelete(deleted);
      expect(File('${pages.path}/$a.canvas').existsSync(), isTrue);
      expect(File('${extra.path}/$sub.canvas').existsSync(), isTrue, reason: 'the subpage is back in its own folder');
      expect(File('${pages.path}/$sub.canvas').existsSync(), isFalse);
      expect(File('${extra.path}/$a.canvas').existsSync(), isFalse);
      expect(live(a, 1).existsSync(), isTrue);
      expect(live(sub, 1, extra).existsSync(), isTrue, reason: 'its attachments too');
      expect(live(sub, 1).existsSync(), isFalse);
      expect(trashFiles(), isEmpty);
      await reloadAgrees(nb, listed: {...idsOf(nb)});
    });

    test('a subpage whose own folder was removed from Noted after the delete is restored into the root\'s folder', () async {
      final (nb, a, sub) = await splitTree();
      final deleted = await nb.delete(a);
      await nb.removeStandaloneFolder(extra.path);
      await nb.undoDelete(deleted);
      expect(File('${pages.path}/$a.canvas').existsSync(), isTrue);
      expect(File('${pages.path}/$sub.canvas').existsSync(), isTrue, reason: 'both go back into the root\'s folder');
      expect(File('${extra.path}/$sub.canvas').existsSync(), isFalse);
      expect(idsOf(nb), containsAll([a, sub]));
    });
  });

  group('review fixes: the restore, busy, the quit limit, the notices, the runs', () {
    // The page `a` was deleted and its file is back before the watcher says so;
    // [discardDeleted] then keeps the set-aside (the page may be back).
    Future<(Notebook, String, String, DeletedPages, String)> restoredButUnlisted({int files = 1}) async {
      final (nb, a, keep) = await world(files: files);
      final text = File('${pages.path}/$a.canvas').readAsStringSync();
      final deleted = await nb.delete(a);
      File('${pages.path}/$a.canvas').writeAsStringSync(text);
      return (nb, a, keep, deleted, text);
    }

    for (final inPlaceSet in [true, false]) {
      final where = inPlaceSet ? 'in place' : 'deleted-attachments';

      test('a restore refused by the gate (0184) counts as kept and is tried again ($where)', () async {
        Notebook.forceCopyMoveForTest = inPlaceSet;
        final nb = make();
        await nb.load();
        final folder = await Directory('${root.path}/Work').create();
        final s = await nb.addBinder(folder.path);
        final a = await nb.createPage(binderPath: s.path);
        await nb.createPage(binderPath: s.path);
        await nb.flush();
        giveAssets(a, 1, dir: folder);
        final text = File('${folder.path}/$a.canvas').readAsStringSync();
        final bf = File('${folder.path}/$binderFileName');
        final own = bf.readAsStringSync();
        final deleted = await nb.delete(a);
        File('${folder.path}/$a.canvas').writeAsStringSync(text); // the page is back
        nb.discardDeleted(deleted);
        await quiet();
        // The folder is held (another binder's file) while the watcher lists the page.
        bf.writeAsStringSync(Binder.create(title: 'Other', color: binderPalette[2]).write());
        await nb.checkFile('${folder.path}/$a.canvas');
        await quiet();
        expect(live(a, 1, folder).existsSync(), isFalse, reason: 'the refused restore is kept, not taken as done');
        final aside = inPlaceSet ? inPlace(a, folder).expand((d) => d.listSync()).whereType<File>() : trashFiles();
        expect(aside, hasLength(1), reason: 'the files stay in the set-aside');
        expect(notices.where((n) => n.contains('could not be put back')), isEmpty, reason: 'a refused turn is not a failure to put back');
        // The hold ends: the next check finds the record still pending and restores.
        bf.writeAsStringSync(own);
        await nb.checkBinderFile(bf.path);
        await nb.checkFile('${folder.path}/$a.canvas');
        await until(() => live(a, 1, folder).existsSync(), what: 'the restore once the folder is not held');
      });
    }

    for (final inPlaceSet in [true, false]) {
      test('a restore refused by the gate inside its own turn counts as kept and is tried again (${inPlaceSet ? 'in place' : 'deleted-attachments'})', () async {
        Notebook.forceCopyMoveForTest = inPlaceSet;
        final nb = make();
        await nb.load();
        final folder = await Directory('${root.path}/Work').create();
        final s = await nb.addBinder(folder.path);
        final a = await nb.createPage(binderPath: s.path);
        await nb.createPage(binderPath: s.path);
        await nb.flush();
        giveAssets(a, 1, dir: folder);
        final text = File('${folder.path}/$a.canvas').readAsStringSync();
        final bf = File('${folder.path}/$binderFileName');
        final own = bf.readAsStringSync();
        final deleted = await nb.delete(a);
        File('${folder.path}/$a.canvas').writeAsStringSync(text); // the page is back
        nb.discardDeleted(deleted);
        await quiet();
        // The caller's gate passes; another binder's file arrives before the turn.
        hook = (point, path) async {
          if (point != 'move-dir-before-lock') return;
          hook = null;
          bf.writeAsStringSync(Binder.create(title: 'Other', color: binderPalette[2]).write());
        };
        await nb.checkFile('${folder.path}/$a.canvas');
        await quiet();
        hook = null;
        expect(live(a, 1, folder).existsSync(), isFalse, reason: 'nothing was put back into the held folder');
        expect(notices.where((n) => n.contains('could not be put back')), isEmpty, reason: 'a refused turn is not a failure to put back');
        bf.writeAsStringSync(own);
        await nb.checkBinderFile(bf.path);
        await nb.checkFile('${folder.path}/$a.canvas');
        await until(() => live(a, 1, folder).existsSync(), what: 'the restore once the folder is not held');
      });
    }

    test('a restore whose folder lock is not got in time counts as kept (nothing moved, no notice)', () async {
      final (nb, a, _, deleted, _) = await restoredButUnlisted();
      nb.discardDeleted(deleted);
      await quiet();
      // The folder of deleted pages is the one that stalls (the page's own is read by the check).
      final gate = Completer<void>();
      unawaited(nb.folderLocks.run(trashDir(), () => gate.future));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await nb.checkFile('${pages.path}/$a.canvas');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(live(a, 1).existsSync(), isFalse);
      expect(trashFiles(), hasLength(1), reason: 'still set aside');
      expect(notices.where((n) => n.contains('could not be put back')), isEmpty);
      gate.complete();
      await nb.checkFile('${pages.path}/$a.canvas');
      await until(() => live(a, 1).existsSync(), what: 'the restore after the lock is free');
    });

    test('p busy: the restore does not run in the middle of its move; it runs when the move is over', () async {
      final (nb, a, keep, deleted, _) = await restoredButUnlisted();
      await nb.checkFile('${pages.path}/$a.canvas');
      expect(idsOf(nb), contains(a));
      final binder = await nb.addBinder(extra.path);
      var duringMove = true;
      hook = (point, path) async {
        if (point != 'move-after-rename') return;
        hook = null;
        nb.discardDeleted(deleted); // the expiry runs while a is being moved
        await quiet();
        duringMove = live(a, 1).existsSync() || live(a, 1, extra).existsSync();
      };
      await nb.moveToLocation(a, binderPath: binder.path);
      hook = null;
      expect(duringMove, isFalse, reason: 'nothing was put back while the page was busy');
      await until(() => live(a, 1, extra).existsSync(), what: 'the restore after the move');
      await reloadAgrees(nb, listed: {keep});
    });

    test('at a quit the restore is skipped: a stalled destination does not hold the quit', () async {
      Notebook.expiryQuitLimit = const Duration(milliseconds: 300);
      Notebook.pairLockLimit = const Duration(seconds: 3);
      final (nb, a, _) = await world();
      final other = await nb.createPage(folderPath: extra.path);
      await nb.flush();
      final text = File('${pages.path}/$a.canvas').readAsStringSync();
      await nb.delete(a);
      File('${extra.path}/$a.canvas').writeAsStringSync(text);
      await nb.checkFile('${extra.path}/$a.canvas'); // listed in the other folder
      expect(idsOf(nb), containsAll([a, other]));
      final gate = Completer<void>();
      unawaited(nb.folderLocks.run(extra, () => gate.future));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final sw = Stopwatch()..start();
      await nb.discardPendingDelete();
      expect(sw.elapsedMilliseconds, lessThan(2500), reason: 'the restore would wait for the stalled folder');
      expect(trashFiles(), hasLength(1), reason: 'the set-aside stays');
      gate.complete();
    });

    test('the delete that cannot rename into deleted-attachments leaves no empty folder there', () async {
      Notebook.forceCopyMoveForTest = true;
      final (nb, a, _) = await world();
      await nb.delete(a);
      expect(inPlace(a), hasLength(1));
      expect(trashDir().existsSync() ? trashDir().listSync() : <FileSystemEntity>[], isEmpty, reason: 'no empty <newId> folder');
    });

    for (final placeholder in [false, true]) {
      test('a set-aside refused by 0184\'s gate is reported as one that could not be made (${placeholder ? 'in place' : 'deleted-attachments'})', () async {
        final nb = make();
        await nb.load();
        final folder = await Directory('${root.path}/Work').create();
        final s = await nb.addBinder(folder.path);
        final a = await nb.createPage(binderPath: s.path);
        await nb.createPage(binderPath: s.path);
        await nb.flush();
        giveAssets(a, 1, dir: folder);
        if (placeholder) Notebook.placeholderMarksForTest = {fileStamp(live(a, 1, folder).path)!}; // the in-place branch
        hook = (point, path) async {
          if (point != 'binder-gate') return;
          hook = null; // another binder's file stands in the folder at the delete's first turn
          File('${folder.path}/$binderFileName').writeAsStringSync(Binder.create(title: 'Other', color: binderPalette[2]).write());
        };
        try {
          await nb.delete(a);
        } on NotebookException {
          // the held folder refuses the page's own delete too
        }
        hook = null;
        expect(notices.where((n) => n.contains('could not be set aside')), hasLength(1));
        expect(live(a, 1, folder).existsSync(), isTrue, reason: 'the folder stays as <p>.assets');
        expect(trashFiles(), isEmpty);
      });
    }

    for (final placeholder in [false, true]) {
      test('a hold planted after the caller\'s gate and before the turn refuses the set-aside (${placeholder ? 'in place' : 'deleted-attachments'})', () async {
        final nb = make();
        await nb.load();
        final folder = await Directory('${root.path}/Work').create();
        final s = await nb.addBinder(folder.path);
        final a = await nb.createPage(binderPath: s.path);
        await nb.createPage(binderPath: s.path);
        await nb.flush();
        giveAssets(a, 1, dir: folder);
        if (placeholder) Notebook.placeholderMarksForTest = {fileStamp(live(a, 1, folder).path)!}; // the in-place branch
        hook = (point, path) async {
          if (point != 'move-dir-before-lock') return;
          hook = null; // the caller's gate has passed; another binder's file arrives now
          File('${folder.path}/$binderFileName').writeAsStringSync(Binder.create(title: 'Other', color: binderPalette[2]).write());
        };
        try {
          await nb.delete(a);
        } on NotebookException {
          // the held folder refuses the page's own delete too
        }
        hook = null;
        expect(live(a, 1, folder).existsSync(), isTrue, reason: 'the rename did not run into the held folder');
        expect(trashFiles(), isEmpty);
        expect(inPlace(a, folder), isEmpty);
        expect(notices.where((n) => n.contains('could not be set aside')), hasLength(1));
      });
    }

    test('a partial set-aside says which files were left in the page\'s folder', () async {
      final (nb, a, keep) = await world(files: 2);
      // The folder can't be renamed whole, and the second file can't be moved.
      final refuser = _Refuser((w) => w.intents.any((i) => i.kind == CoordinationKind.move && (i.path.endsWith('.assets') || i.path.endsWith(hashName(2)))));
      registerCoordinator(root.path, refuser);
      addTearDown(() => unregisterCoordinator(root.path));
      await nb.delete(a);
      expect(live(a, 2).existsSync(), isTrue, reason: 'the second file stayed in the live folder');
      expect(trashFiles().single.path.endsWith(hashName(1)), isTrue, reason: 'the first file was set aside');
      expect(notices.where((n) => n.contains('were left there')), hasLength(1), reason: '$notices');
      await reloadAgrees(nb, listed: {keep});
    });

    test('three kept runs end the record: the page coming back later gets no restore', () async {
      final (nb, a, _, deleted, text) = await restoredButUnlisted();
      File('${pages.path}/$a.canvas').deleteSync(); // sync's file is a not yet listed page, named for it
      File('${pages.path}/$a-damaged.canvas').writeAsStringSync('{ not a page');
      nb.discardDeleted(deleted);
      await quiet();
      // Each check of that file is a run that sees something that may be the page.
      for (var i = 0; i < 3; i++) {
        await nb.checkFile('${pages.path}/$a-damaged.canvas');
        await quiet();
      }
      File('${pages.path}/$a.canvas').writeAsStringSync(text);
      await nb.checkFile('${pages.path}/$a.canvas');
      await quiet();
      expect(live(a, 1).existsSync(), isFalse, reason: 'the record ended after three kept runs');
      expect(trashFiles(), hasLength(1), reason: 'the folder stays where it is');
    });

    test('checks of other pages\' files do not use up the runs: p coming back after them still gets its folder', () async {
      final (nb, a, _, deleted, text) = await restoredButUnlisted();
      final other = await nb.createPage();
      await nb.flush();
      File('${pages.path}/$a.canvas').deleteSync();
      File('${pages.path}/$a-damaged.canvas').writeAsStringSync('{ not a page'); // the first run is kept
      nb.discardDeleted(deleted);
      await quiet();
      // Other pages' events and the notebook's own saves: many checks of known files.
      for (var i = 0; i < 6; i++) {
        File('${pages.path}/$other.canvas').setLastModifiedSync(DateTime.now().add(Duration(minutes: i + 1)));
        await nb.checkFile('${pages.path}/$other.canvas');
        await quiet();
      }
      File('${pages.path}/$a-damaged.canvas').deleteSync();
      File('${pages.path}/$a.canvas').writeAsStringSync(text);
      await nb.checkFile('${pages.path}/$a.canvas');
      await until(() => live(a, 1).existsSync(), what: 'the restore at p\'s own event');
    });

    test('a file in the set-aside changed after the delete is kept (identity mismatch), the others go', () async {
      final (nb, a, _) = await world(files: 2);
      final deleted = await nb.delete(a);
      final files = trashFiles();
      final changed = files.firstWhere((f) => f.path.endsWith(hashName(1)));
      changed.writeAsBytesSync(bytesOf(9)); // no longer what its name says, nor what was recorded
      nb.discardDeleted(deleted);
      await until(() => trashFiles().length == 1, what: 'the other file to go');
      await quiet();
      expect(trashFiles().single.path, changed.path);
      expect(trashFiles().single.readAsBytesSync(), bytesOf(9));
      expect(notices.where((n) => n.contains('were not removed')), hasLength(1));
    });
  });

  group('guards', () {
    test('nothing in notebook.dart removes a folder recursively but _removeDir, called only by the delete rollback', () {
      final text = File('lib/src/notebook.dart').readAsStringSync().replaceAll('\r\n', '\n');
      final lines = text.split('\n');
      // A line that deletes with `recursive: true` (directly, or through the
      // coordinated folder remove): the only one is inside `_removeDir`, the
      // exempt helper.
      final recursive = [
        for (var i = 0; i < lines.length; i++)
          if (RegExp(r'recursive:\s*true').hasMatch(lines[i]) &&
              (lines[i].contains('delete') || lines[i].contains('removeFolderCoordinated')))
            i,
      ];
      final helper = lines.indexWhere((l) => l.contains('static Future<void> _removeDir('));
      expect(helper, greaterThanOrEqualTo(0));
      expect(recursive, hasLength(1), reason: 'only _removeDir deletes recursively');
      expect(recursive.single, inInclusiveRange(helper, helper + 6), reason: 'and that line is in _removeDir');
      // _removeDir's one call: the rollback of a delete, on the trash folder it made.
      final calls = [
        for (final l in lines)
          if (l.contains('_removeDir(') && !l.contains('static Future<void> _removeDir(')) l.trim(),
      ];
      expect(calls, ['if (stash.isEmpty && keepTrash.isEmpty) await _removeDir(trash);']);
      expect(text.contains('_removeSetAside'), isFalse);
      expect(text.contains('removeVerifiedSources'), isFalse, reason: 'no copy-then-delete');
    });
  });
}
