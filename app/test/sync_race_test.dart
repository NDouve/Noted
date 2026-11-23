// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Failure injection: the sync writer replaces a file at the exact moment the
// app is about to overwrite or delete it (0051, 0053).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/attachment_copy.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_lock.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted/src/save_trouble.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';
import 'support/page_save.dart';

Map<String, Object?> doc(String text) => {
  'document': {
    'type': 'page',
    'children': [
      {
        'type': 'paragraph',
        'data': {
          'delta': [
            {'insert': text},
          ],
        },
      },
    ],
  },
};

// Counts the writes that reach the folder. [beforeWrite] runs once, just
// before the next write or compare-and-swap replace: a sync client landing a
// newer version of the file at that moment.
class CountingStore extends PageStore {
  CountingStore(super.directory);
  int saves = 0;
  void Function()? beforeWrite;
  // Runs once, between the compare-and-swap replace reading the set-aside
  // original and publishing the new file.
  void Function()? beforePublishOnce;

  // Runs once, just before the next compare-and-delete.
  void Function()? beforeDeleteOnce;

  // Pages whose file can't be deleted, and pages whose restored file can't be
  // written ([onFailDelete] runs just before a delete fails).
  final Set<String> failDelete = {};
  final Set<String> failNew = {};
  // The next restore waits for [holdNew]; [reachedNew] completes when it is there.
  Completer<void>? holdNew;
  Completer<void>? reachedNew;
  void Function()? onFailDelete;

  // Called by the notebook's 'new-before-publish' hook, outside the folder
  // lock (a pause inside the store call would hold the lock).
  Future<void> pauseRestore() async {
    final gate = holdNew;
    if (gate == null) return;
    holdNew = null;
    reachedNew?.complete();
    await gate.future;
  }

  // Runs once, right after a restored page's file is published; another writer
  // landing on top of it.
  void Function()? afterNewText;

  // The next read of a page's text throws, once.
  bool failReadOnce = false;

  @override
  Future<String> readText(String pageId) {
    if (failReadOnce) {
      failReadOnce = false;
      throw const FileSystemException('read failed');
    }
    return super.readText(pageId);
  }

  @override
  Future<bool> saveNewText(NotedPage page, String text, {Future<void> Function()? beforePublish, void Function(FileStamp?)? onPublishStamp}) async {
    if (failNew.contains(page.id)) throw const FileSystemException('destination gone');
    final done = await super.saveNewText(page, text, beforePublish: beforePublish, onPublishStamp: onPublishStamp);
    if (done) {
      final f = afterNewText;
      afterNewText = null;
      f?.call();
    }
    return done;
  }

  @override
  Future<DeleteResult> deleteIfUnchanged(
    String pageId,
    String expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    Future<void> Function()? beforeDelete,
    void Function()? beforeRestore, void Function(FileStamp?)? onPublishStamp,
    Future<void> Function(String path)? beforeAsideDelete,
    Future<void> Function(String path)? beforeFinalCheck,
    Future<void> Function(String path)? afterFinalRead,
  }) {
    final f = beforeDeleteOnce;
    beforeDeleteOnce = null;
    f?.call();
    if (failDelete.contains(pageId)) {
      onFailDelete?.call();
      throw const FileSystemException('source gone');
    }
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

  void _fire() {
    final f = beforeWrite;
    beforeWrite = null;
    f?.call();
  }

  Future<void> save(NotedPage page) {
    saves++;
    _fire();
    return savePageDirect(this, page);
  }

  @override
  Future<ReplaceResult> saveIfUnchanged(
    NotedPage page,
    String? expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    void Function()? beforePublish,
    void Function()? beforeRestore, void Function(FileStamp?)? onPublishStamp,
    Future<void> Function(String path)? beforeAsideDelete,
    Future<void> Function(String path)? beforeFinalCheck,
    Future<void> Function(String path)? afterFinalRead,
  }) {
    saves++;
    _fire();
    final hook = beforePublishOnce;
    beforePublishOnce = null;
    return super.saveIfUnchanged(
      page,
      expectedText,
      beforeMoveAside: beforeMoveAside,
      afterRead: afterRead,
      beforePublish: hook ?? beforePublish,
      beforeRestore: beforeRestore,
      onPublishStamp: onPublishStamp,
      beforeAsideDelete: beforeAsideDelete,
      beforeFinalCheck: beforeFinalCheck,
      afterFinalRead: afterFinalRead,
    );
  }
}

// A store whose failing deletes first run an async step ([beforeFail]): the
// folder going away while the delete is in flight.
class _GoneStore extends CountingStore {
  _GoneStore(super.directory);

  Future<void> Function()? beforeFail;

  @override
  Future<DeleteResult> deleteIfUnchanged(
    String pageId,
    String expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    Future<void> Function()? beforeDelete,
    void Function()? beforeRestore, void Function(FileStamp?)? onPublishStamp,
    Future<void> Function(String path)? beforeAsideDelete,
    Future<void> Function(String path)? beforeFinalCheck,
    Future<void> Function(String path)? afterFinalRead,
  }) async {
    if (failDelete.contains(pageId)) {
      await beforeFail?.call();
      throw const FileSystemException('source gone');
    }
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
  late CountingStore counting;
  late Directory root;
  late Directory dir;
  late Directory rec;
  late Notebook nb;
  late PageStore other; // "the other device"
  late ModuleRegistry modules;
  final sep = Platform.pathSeparator;

  // A merged conflict copy's re-check is due [copyRetireAfter] after the merge
  // by [clock] (tests advance it), unless a test runs the real clock.
  var clock = DateTime(2026, 11, 16, 12);
  late FolderLocks locks;

  Notebook makeNotebook({
    bool withRecovery = true,
    PageStore Function(Directory)? factory,
    Duration? backoff,
    Duration? retire,
    RecoveryLock? lock,
  }) {
    clock = DateTime(2026, 11, 16, 12);
    final n = Notebook(
      counting,
      modules,
      saveDelay: const Duration(hours: 1),
      recoveryDirectory: withRecovery ? rec : null,
      backoffFirst: backoff ?? const Duration(seconds: 2),
      folderCheckInterval: Duration.zero,
      storeFactory: factory ?? PageStore.new,
      copyRetireAfter: retire ?? const Duration(hours: 1),
      recoveryLock: lock,
      folderLocks: locks,
    );
    // A test given a real wait for the re-check runs on the real clock.
    if (retire == null) n.now = () => clock;
    return n;
  }

  Future<void> start({
    bool withRecovery = true,
    PageStore Function(Directory)? factory,
    Duration? backoff,
    Duration? retire,
    RecoveryLock? lock,
  }) async {
    root = await Directory.systemTemp.createTemp('noted_race');
    dir = await Directory('${root.path}${sep}pages').create();
    rec = Directory('${root.path}${sep}rec');
    modules = buildModules();
    counting = CountingStore(dir);
    locks = FolderLocks();
    nb = makeNotebook(withRecovery: withRecovery, factory: factory, backoff: backoff, retire: retire, lock: lock);
    nb.syncHook = (point, path) => point == 'new-before-publish' ? counting.pauseRestore() : Future<void>.value();
    other = PageStore(dir);
    await nb.load();
    await nb.flush();
    await other.scan();
  }

  tearDown(() async {
    nb.dispose();
    await root.delete(recursive: true);
  });

  BoxRecord noteBox(String text, {Bounds at = const Bounds(10, 10, 200, 40)}) {
    final codec = modules.codecs.codecFor('noted.note')!;
    return commitBox(createBox(codec, at), codec, codec.decode(doc(text), 1));
  }

  String pathOf(String id) => '${dir.path}$sep$id.canvas';
  NotedPage onDisk(String id) => readPage(File(pathOf(id)).readAsStringSync());

  group('the open page file is replaced by something unreadable', () {
    // Local edit, then the file is replaced behind the app's back and the
    // autosave runs without a watcher event in between.
    Future<(String, BoxRecord)> editedPage() async {
      await start();
      final id = nb.currentId!;
      final mine = nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      return (id, mine);
    }

    void expectBlocked(String id, BoxRecord mine, String bytes) {
      // The file on disk is untouched.
      expect(File(pathOf(id)).readAsStringSync(), bytes);
      // The page is read-only with the reason shown.
      expect(nb.readOnlyReason, isNotNull);
      expect(nb.current!.readOnly, isTrue);
    }

    test('malformed text is not overwritten; edits go to recovery', () async {
      final (id, mine) = await editedPage();
      File(pathOf(id)).writeAsStringSync('{ not json');
      await nb.flush();
      expectBlocked(id, mine, '{ not json');
      expect(nb.readOnlyReason, allOf(contains("it isn't a valid page file"), contains('open another page')));
      expect(nb.readOnlyReason, isNot(contains('JSON')));
      final entries = (await nb.pendingRecovery()).entries;
      expect(entries.single.pageId, id);
      expect(entries.single.page.node(mine.id), isNotNull);
    });

    test('a newer format is not overwritten', () async {
      final (id, mine) = await editedPage();
      final newer = writePage(onDisk(id)).replaceFirst(RegExp(r'"format"\s*:\s*1'), '"format":99');
      expect(() => readPage(newer), throwsA(isA<UnsupportedPageFormatException>()));
      File(pathOf(id)).writeAsStringSync(newer);
      await nb.flush();
      expectBlocked(id, mine, newer);
      expect(nb.readOnlyReason, contains('it is from a newer version of Noted'));
      expect((await nb.pendingRecovery()).entries.single.page.node(mine.id), isNotNull);
    });

    test('a valid file of a different page is not overwritten', () async {
      final (id, mine) = await editedPage();
      final foreign = File(pathOf(id)).readAsStringSync().replaceAll(
        RegExp('"pageId"\\s*:\\s*"$id"'),
        '"pageId":"0000000000000abc"',
      );
      expect(foreign, isNot(contains(id)));
      File(pathOf(id)).writeAsStringSync(foreign);
      await nb.flush();
      expectBlocked(id, mine, foreign);
      expect(nb.readOnlyReason, contains('it holds a different page'));
      expect((await nb.pendingRecovery()).entries.single.page.node(mine.id), isNotNull);
    });

    test('a late change from a controller that was closed saves nothing', () async {
      await start();
      final first = nb.currentId!;
      final old = nb.current!;
      final second = await nb.createPage();
      await nb.flush();
      expect(nb.currentId, second);
      final before = File(pathOf(first)).readAsStringSync();
      final saves = counting.saves;
      try {
        old.createBoxAt(const Bounds(10, 10, 0, 0));
      } on Object {
        return; // a closed controller refuses edits: nothing to guard
      }
      await nb.flush();
      expect(counting.saves, saves);
      expect(File(pathOf(first)).readAsStringSync(), before);
    });

    test('text that is not UTF-8 is not overwritten', () async {
      final (id, mine) = await editedPage();
      final bytes = [0xff, 0xfe, 0xfd];
      File(pathOf(id)).writeAsBytesSync(bytes);
      await nb.flush();
      expect(File(pathOf(id)).readAsBytesSync(), bytes);
      expect(nb.readOnlyReason, isNotNull);
      expect(nb.readOnlyReason, anyOf(contains("it isn't a valid page file"), contains("it couldn't be read")));
      expect((await nb.pendingRecovery()).entries.single.page.node(mine.id), isNotNull);
    });

    test('a read error is not treated as a missing file', () async {
      final (id, mine) = await editedPage();
      File(pathOf(id)).deleteSync();
      Directory(pathOf(id)).createSync(); // present, but can't be read as a file
      final writes = counting.saves;
      await nb.flush();
      expect(counting.saves, writes); // the save gate stopped the write
      expect(Directory(pathOf(id)).existsSync(), isTrue);
      expect(nb.readOnlyReason, isNotNull);
      expect((await nb.pendingRecovery()).entries.single.page.node(mine.id), isNotNull);
    });

    test('a read error that passes is rechecked on the folder timer', () async {
      final (id, mine) = await editedPage();
      final original = File(pathOf(id)).readAsStringSync();
      File(pathOf(id)).deleteSync();
      Directory(pathOf(id)).createSync();
      await nb.flush();
      expect(nb.readOnlyReason, isNotNull);
      Directory(pathOf(id)).deleteSync();
      File(pathOf(id)).writeAsStringSync(original); // no watcher event
      await nb.checkFolders();
      expect(nb.readOnlyReason, isNull);
      expect(nb.current!.readOnly, isFalse);
      await nb.flush();
      expect(onDisk(id).node(mine.id), isNotNull);
    });

    // A sync client often deletes a file and then renames the new one in.
    for (final withCreateEvent in [true, false]) {
      for (final (label, bytes) in [
        ('malformed', '{ not json'),
        ('newer-format', null),
      ]) {
        test(
          'deleted, then put back as $label text ${withCreateEvent ? 'with' : 'without'} a create event: not overwritten',
          () async {
            final (id, mine) = await editedPage();
            final text =
                bytes ??
                writePage(onDisk(id)).replaceFirst(RegExp(r'"format"\s*:\s*1'), '"format":99');
            File(pathOf(id)).deleteSync();
            await nb.checkFile(pathOf(id)); // the delete event
            File(pathOf(id)).writeAsStringSync(text);
            if (withCreateEvent) await nb.checkFile(pathOf(id));
            final writes = counting.saves;
            await nb.flush();
            expect(counting.saves, writes);
            expectBlocked(id, mine, text);
            expect((await nb.pendingRecovery()).entries.single.page.node(mine.id), isNotNull);
          },
        );
      }
    }

    test('a file that is really absent is written', () async {
      final (id, mine) = await editedPage();
      File(pathOf(id)).deleteSync();
      await nb.checkFile(pathOf(id));
      await nb.flush();
      expect(nb.readOnlyReason, isNull);
      expect(onDisk(id).node(mine.id), isNotNull);
    });

    test('a folder that comes back holding a newer-format file is not overwritten', () async {
      await start();
      final extra = await Directory('${root.path}${sep}Elsewhere').create();
      final away = Directory('${root.path}${sep}Elsewhere-away');
      final x = await nb.createPage(folderPath: extra.path);
      await nb.flush();
      await nb.open(x);
      nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      final file = File('${extra.path}$sep$x.canvas');
      final newer = file.readAsStringSync().replaceFirst(RegExp(r'"format"\s*:\s*1'), '"format":99');
      await extra.rename(away.path);
      await nb.checkFolders();
      expect((await nb.pendingRecovery()).entries, hasLength(1));
      File('${away.path}$sep$x.canvas').writeAsStringSync(newer);
      await away.rename(extra.path);
      await nb.checkFolders();
      await nb.flush();
      expect(file.readAsStringSync(), newer);
      expect((await nb.pendingRecovery()).entries, hasLength(1)); // kept
    });

    test('a readable version later is merged and the page is editable again', () async {
      final (id, mine) = await editedPage();
      File(pathOf(id)).writeAsStringSync('{ not json');
      await nb.flush();
      expect(nb.readOnlyReason, isNotNull);
      // The same bad bytes again change nothing.
      await nb.checkFile(pathOf(id));
      expect(nb.readOnlyReason, isNotNull);

      final theirs = noteBox('from the other device', at: const Bounds(400, 10, 200, 40));
      final disk = NotedPage.create(nb.current!.page.meta).insertNode(theirs);
      await other.save(disk);
      await nb.checkFile(pathOf(id));

      expect(nb.readOnlyReason, isNull);
      expect(nb.current!.readOnly, isFalse);
      expect(nb.current!.page.node(mine.id), isNotNull);
      expect(nb.current!.page.node(theirs.id), isNotNull);
      await nb.flush();
      expect(onDisk(id).nodes.map((n) => n.id).toSet(), {mine.id, theirs.id});
      // The entry kept for the block is gone once the merged save landed.
      expect((await nb.pendingRecovery()).entries, isEmpty);
    });

    test('a recovery entry that is not the block\'s own stays', () async {
      final (id, mine) = await editedPage();
      File(pathOf(id)).writeAsStringSync('{ not json');
      await nb.flush();
      final entry = (await nb.pendingRecovery()).entries.single;
      // Someone else's newer entry for the same page replaces it.
      await RecoveryStore(rec).write(
        folder: entry.folder,
        page: nb.current!.page.insertNode(noteBox('other')),
        baseText: entry.baseText,
        time: DateTime.now(),
      );
      await other.save(NotedPage.create(nb.current!.page.meta));
      await nb.checkFile(pathOf(id));
      await nb.flush();
      expect(nb.readOnlyReason, isNull);
      expect((await nb.pendingRecovery()).entries, hasLength(1));
      expect(mine.id, isNotEmpty);
    });

    test('the file being deleted lifts the block; the next save writes the page', () async {
      final (id, mine) = await editedPage();
      File(pathOf(id)).writeAsStringSync('{ not json');
      await nb.flush();
      expect(nb.readOnlyReason, isNotNull);
      File(pathOf(id)).deleteSync();
      await nb.checkFile(pathOf(id));
      expect(nb.readOnlyReason, isNull);
      await nb.flush();
      expect(onDisk(id).node(mine.id), isNotNull);
    });
  });

  group('a delete that fails part way', () {
    // A parent with a subpage whose file can't be deleted: the parent, deleted
    // first, has to be put back.
    late String parent;
    late String child;
    late BoxRecord mine;

    Future<void> setUpTree({bool withRecovery = true}) async {
      await start(withRecovery: withRecovery);
      parent = nb.currentId!;
      mine = nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      child = await nb.createPage(parentId: parent);
      await nb.createPage(); // the page that stays open
      await nb.flush();
      counting.failDelete.add(child);
    }

    Set<String> idsOf(String path) => readPage(File(path).readAsStringSync()).nodes.map((n) => n.id).toSet();

    test('with working recovery: says the content is kept', () async {
      await setUpTree();
      counting.failNew.add(parent);

      Object? error;
      try {
        await nb.delete(parent);
      } on Object catch (e) {
        error = e;
      }

      expect(error, isA<NotebookException>());
      expect(error, isNot(isA<PagesNotRestoredException>()));
      expect((error! as NotebookException).message, contains('Recovery holds the content of'));
      expect((await nb.pendingRecovery()).entries, isNotEmpty);
    });

    test('recovery refused (no recovery folder): does not claim the content is kept, and Undo writes it back', () async {
      await setUpTree(withRecovery: false);
      counting.failNew.add(parent);

      Object? error;
      try {
        await nb.delete(parent);
      } on Object catch (e) {
        error = e;
      }

      expect(error, isA<PagesNotRestoredException>());
      final message = (error! as PagesNotRestoredException).message;
      expect(message, isNot(contains('will write it back.')));
      expect(message, isNot(contains('Recovery holds')));
      expect(message, contains('Recovery could not keep'));
      expect(File(pathOf(parent)).existsSync(), isFalse);

      // A later delete does not drop what is only held in memory.
      final held = (error as PagesNotRestoredException).deleted;
      expect(nb.isPendingDelete(held), isTrue);
      counting.failDelete.clear();
      counting.failNew.clear();
      await nb.delete(child);
      expect(nb.isPendingDelete(held), isTrue);

      await nb.undoDelete(held);

      expect(idsOf(pathOf(parent)), contains(mine.id));
      expect(nb.isPendingDelete(held), isFalse);
      final fresh = Notebook(
        PageStore(dir),
        modules,
        saveDelay: const Duration(hours: 1),
        folderCheckInterval: Duration.zero,
      );
      await fresh.load();
      expect(fresh.tree.roots.map((r) => r.id), contains(parent));
      fresh.dispose();
    });

    test('recovery write failing: does not claim the content is kept either', () async {
      await setUpTree();
      counting.failNew.add(parent);
      nb.recoveryStoreForTest!.hook = (point) async {
        if (point == 'write') throw const FileSystemException('disk full');
      };

      Object? error;
      try {
        await nb.delete(parent);
      } on Object catch (e) {
        error = e;
      }

      expect(error, isA<PagesNotRestoredException>());
      expect((error! as NotebookException).message, isNot(contains('will write it back.')));
      counting.failNew.clear();
      await nb.undoDelete((error as PagesNotRestoredException).deleted);
      expect(idsOf(pathOf(parent)), contains(mine.id));
    });

    // The deleted parent when a different file has appeared at its path.
    Future<(Object?, String, BoxRecord)> deleteWithFileInTheWay({bool withRecovery = true}) async {
      await setUpTree(withRecovery: withRecovery);
      final theirs = noteBox('from the other device', at: const Bounds(400, 10, 200, 40));
      final theirText = writePage(onDisk(parent).removeNode(mine.id).insertNode(theirs));
      counting.onFailDelete = () => File(pathOf(parent)).writeAsStringSync(theirText);
      Object? error;
      try {
        await nb.delete(parent);
      } on Object catch (e) {
        error = e;
      }
      return (error, theirText, theirs);
    }

    List<File> copies() => dir.listSync().whereType<File>().where((f) => f.path.contains('-undo-')).toList();

    test('a different file at the parent\'s path is left alone and the deleted version is kept beside it', () async {
      final (error, theirText, theirs) = await deleteWithFileInTheWay();

      expect(error, isA<NotebookException>());
      expect(error, isNot(isA<PagesNotRestoredException>()));
      final message = (error! as NotebookException).message;
      expect(message, contains('was kept beside it as'));
      expect(message, isNot(contains('Recovery holds')));
      expect(File(pathOf(parent)).readAsStringSync(), theirText, reason: 'the file that appeared is untouched');
      final beside = copies();
      expect(beside, hasLength(1));
      expect(message, contains(beside.single.uri.pathSegments.last));
      expect(idsOf(beside.single.path), contains(mine.id), reason: 'the deleted version survives');
      expect((await nb.pendingRecovery()).entries, isEmpty, reason: 'recovery would have replayed it away');
      expect(idsOf(pathOf(parent)), contains(theirs.id));
    });

    group('pages held in memory', () {
      test('at exit they are written beside their place, never over a file', () async {
        await setUpTree(withRecovery: false);
        counting.failNew.add(parent);
        Object? error;
        try {
          await nb.delete(parent);
        } on Object catch (e) {
          error = e;
        }
        expect(error, isA<PagesNotRestoredException>());
        counting.failNew.clear();
        counting.failDelete.clear();

        expect(await nb.prepareToExit(), isTrue);

        expect(File(pathOf(parent)).existsSync(), isFalse, reason: 'nothing was written at the page\'s own path');
        final beside = copies();
        expect(beside, hasLength(1));
        expect(idsOf(beside.single.path), contains(mine.id));
        expect(nb.isPendingDelete((error! as PagesNotRestoredException).deleted), isFalse);
      });

      test('at exit, when the copy cannot be written, the user is asked', () async {
        await setUpTree(withRecovery: false);
        counting.failNew.add(parent);
        Object? error;
        try {
          await nb.delete(parent);
        } on Object catch (e) {
          error = e;
        }
        expect(error, isA<PagesNotRestoredException>());
        final asked = <UserQuestion>[];
        nb.questioner = (q, title) async {
          asked.add(q);
          return false; // stay
        };
        // The folder goes away, so no copy can be written.
        final held = (error! as PagesNotRestoredException).deleted;
        final gone = Directory('${dir.path}-gone');
        dir.renameSync(gone.path);

        expect(await nb.prepareToExit(), isFalse);

        expect(asked, contains(UserQuestion.leaveAndLose));
        expect(nb.isPendingDelete(held), isTrue, reason: 'staying keeps the pages');
        gone.renameSync(dir.path);
      });

      test('Undo of a held delete that cannot write offers Undo again', () async {
        await setUpTree(withRecovery: false);
        counting.failNew.add(parent);
        Object? error;
        try {
          await nb.delete(parent);
        } on Object catch (e) {
          error = e;
        }
        final held = (error! as PagesNotRestoredException).deleted;
        // Undo finds the folder unusable.
        final gone = Directory('${dir.path}-gone');
        dir.renameSync(gone.path);
        counting.failNew.clear();
        Object? again;
        try {
          await nb.undoDelete(held);
        } on Object catch (e) {
          again = e;
        }
        gone.renameSync(dir.path);
        expect(again, isA<PagesNotRestoredException>(), reason: 'the pages are held again, with Undo offered');
        expect(nb.isPendingDelete(held), isTrue);
      });

      test('an Undo in flight at exit does not lose the page', () async {
        await setUpTree(withRecovery: false);
        counting.failNew.add(parent);
        Object? error;
        try {
          await nb.delete(parent);
        } on Object catch (e) {
          error = e;
        }
        final held = (error! as PagesNotRestoredException).deleted;
        counting.failNew.clear();
        final release = counting.holdNew = Completer<void>();
        counting.reachedNew = Completer<void>();
        final undo = nb.undoDelete(held);
        await counting.reachedNew!.future; // the write is paused

        var exited = false;
        final exit = nb.prepareToExit().then((r) {
          exited = true;
          return r;
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(exited, isFalse, reason: 'exit waits for the Undo');
        release.complete();
        await undo;

        expect(await exit, isTrue);
        expect(File(pathOf(parent)).existsSync(), isTrue);
        expect(idsOf(pathOf(parent)), contains(mine.id));
        expect(copies(), isEmpty, reason: 'the page exists once');
      });

      test('an Undo that stays stalled past the limit: the user is asked; staying loses nothing', () async {
        await setUpTree(withRecovery: false);
        counting.failNew.add(parent);
        Object? error;
        try {
          await nb.delete(parent);
        } on Object catch (e) {
          error = e;
        }
        final held = (error! as PagesNotRestoredException).deleted;
        counting.failNew.clear();
        final release = counting.holdNew = Completer<void>();
        counting.reachedNew = Completer<void>();
        final undo = nb.undoDelete(held);
        await counting.reachedNew!.future;
        final asked = <UserQuestion>[];
        nb.questioner = (q, title) async {
          asked.add(q);
          return false; // stay
        };

        expect(await nb.prepareToExit(limit: const Duration(milliseconds: 100)), isFalse);

        expect(asked, [UserQuestion.leaveAndLose]);
        release.complete();
        await undo;
        expect(idsOf(pathOf(parent)), contains(mine.id), reason: 'the Undo still finished');
        expect(copies(), isEmpty);
      });

      // Two held pages: the parent and a first subpage. Undo then restores the
      // parent but fails on the subpage; the parent is edited afterwards.
      Future<(PagesNotRestoredException, String)> partlyRestored() async {
        await setUpTree(withRecovery: false);
        final first = await nb.createPage(parentId: parent);
        final last = await nb.createPage(parentId: parent);
        await nb.flush();
        counting.failDelete
          ..clear()
          ..add(last);
        counting.failNew
          ..add(parent)
          ..add(first);
        Object? error;
        try {
          await nb.delete(parent);
        } on Object catch (e) {
          error = e;
        }
        final held = error! as PagesNotRestoredException;
        expect(held.deleted.pages.map((p) => p.id), containsAll([parent, first]));
        counting.failDelete.clear();
        counting.failNew.remove(parent); // only the subpage still fails
        Object? again;
        try {
          await nb.undoDelete(held.deleted);
        } on Object catch (e) {
          again = e;
        }
        expect(again, isA<PagesNotRestoredException>());
        expect(File(pathOf(parent)).existsSync(), isTrue);
        expect(File(pathOf(first)).existsSync(), isFalse);
        // The user removes a box from the restored parent.
        File(pathOf(parent)).writeAsStringSync(writePage(onDisk(parent).removeNode(mine.id)));
        return (again! as PagesNotRestoredException, first);
      }

      test('a retried Undo leaves a page it already restored alone', () async {
        final (held, first) = await partlyRestored();
        final edited = File(pathOf(parent)).readAsStringSync();
        counting.failNew.clear();

        await nb.undoDelete(held.deleted);

        expect(File(pathOf(parent)).readAsStringSync(), edited, reason: 'the edit is not undone');
        expect(idsOf(pathOf(parent)), isNot(contains(mine.id)));
        expect(File(pathOf(first)).existsSync(), isTrue);
        expect(copies(), isEmpty, reason: 'no copy of the parent beside it');
      });

      test('at exit only the page not restored is copied', () async {
        final (held, first) = await partlyRestored();
        counting.failNew.clear();

        expect(await nb.prepareToExit(), isTrue);

        final beside = copies();
        expect(beside, hasLength(1));
        expect(beside.single.path, contains(first));
        expect(idsOf(pathOf(parent)), isNot(contains(mine.id)));
        expect(nb.isPendingDelete(held.deleted), isFalse);
      });

      test('an exit copy that does not finish within the limit: the user is asked, and a second exit reuses the write', () async {
        await setUpTree(withRecovery: false);
        counting.failNew.add(parent);
        Object? error;
        try {
          await nb.delete(parent);
        } on Object catch (e) {
          error = e;
        }
        final held = (error! as PagesNotRestoredException).deleted;
        final reached = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete(); // never leave the write holding the folder
        });
        nb.syncHook = (point, path) async {
          if (point != 'undo-copy-before-publish') return;
          if (!reached.isCompleted) reached.complete();
          await release.future;
        };
        final asked = <UserQuestion>[];
        nb.questioner = (q, title) async {
          asked.add(q);
          return false; // stay
        };

        // The limit runs out while the copy is held at the hook: long enough
        // for the copy to get there on a slow machine, then it times out.
        final first = nb.prepareToExit(limit: const Duration(seconds: 2));
        await reached.future.timeout(const Duration(seconds: 30));
        expect(await first, isFalse);

        expect(asked, [UserQuestion.leaveAndLose]);
        expect(nb.isPendingDelete(held), isTrue);

        // A second attempt while the write is still pending waits for it.
        final second = nb.prepareToExit(limit: const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        release.complete();
        expect(await second, isTrue);

        expect(copies(), hasLength(1), reason: 'one copy, not one per attempt');
        expect(idsOf(copies().single.path), contains(mine.id));
        expect(nb.isPendingDelete(held), isFalse);
        expect(File(pathOf(parent)).existsSync(), isFalse);
      });

    });
  });

  group('a failed rollback or Undo keeps its pages until Undo ends (0141)', () {
    late String parent;
    late String child;
    late BoxRecord mine;

    Set<String> idsOf(String path) => readPage(File(path).readAsStringSync()).nodes.map((n) => n.id).toSet();
    List<File> copies() => dir.listSync().whereType<File>().where((f) => f.path.contains('-undo-')).toList();

    Future<Object?> attempt(Future<void> Function() action) async {
      try {
        await action();
      } on Object catch (e) {
        return e;
      }
      return null;
    }

    PagesNotRestoredException heldOf(Object? error) {
      expect(error, isA<PagesNotRestoredException>());
      return error! as PagesNotRestoredException;
    }

    // The open parent and its subpage, no recovery; the subpage can't be deleted.
    Future<void> openParentAndChild() async {
      await start(withRecovery: false);
      parent = nb.currentId!;
      mine = nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      child = await nb.createPage(parentId: parent);
      await nb.flush();
      await nb.open(parent);
      counting.failDelete.add(child);
    }

    // A closed parent with a box and two subpages; another page is open.
    Future<void> closedTree() async {
      await start(withRecovery: false);
      parent = nb.currentId!;
      mine = nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      child = await nb.createPage(parentId: parent);
      await nb.createPage(parentId: parent);
      await nb.createPage(); // the page that stays open
      await nb.flush();
    }

    // The parent held after a delete that failed part way (recovery is off).
    Future<PagesNotRestoredException> heldParent() async {
      await closedTree();
      counting.failDelete.add(child);
      counting.failNew.add(parent);
      final held = heldOf(await attempt(() => nb.delete(parent)));
      counting.failDelete.clear();
      counting.failNew.clear();
      return held;
    }

    test('1: the fallback fails too: the pages are held, not lost', () async {
      await openParentAndChild();
      final gone = Directory('${dir.path}-gone');
      counting.onFailDelete = () => dir.renameSync(gone.path);

      final error = await attempt(() => nb.delete(parent));

      final held = heldOf(error).deleted;
      expect(nb.isPendingDelete(held), isTrue);
      expect(nb.isHeldDelete(held), isTrue);
      expect(nb.currentId, isNull, reason: 'the fallback really failed');
      expect((error! as NotebookException).message, contains('No page could be opened'));

      gone.renameSync(dir.path);
      counting.failDelete.clear();
      await nb.undoDelete(held);
      expect(idsOf(pathOf(parent)), contains(mine.id));
      expect(nb.isPendingDelete(held), isFalse);
    });

    test('1b: the fallback throws unexpectedly with the folder in place', () async {
      await openParentAndChild();
      counting.failNew.add(parent); // not put back: the reopen has nothing to open, the fallback runs
      var fired = false;
      nb.syncHook = (point, path) async {
        if (point != 'delete-rollback-fallback') return;
        fired = true;
        throw StateError('no fallback');
      };

      final error = await attempt(() => nb.delete(parent));

      expect(fired, isTrue);
      final held = heldOf(error).deleted;
      expect(nb.isHeldDelete(held), isTrue);
      expect((error! as NotebookException).message, contains('No page could be opened'));
      nb.syncHook = null;
      counting.failNew.clear();
      counting.failDelete.clear();
      await nb.undoDelete(held);
      expect(idsOf(pathOf(parent)), contains(mine.id));
    });

    // A subtree of three: the root kept (a newer version lands), a deleted page
    // whose put-back fails, and the last page whose delete fails.
    Future<(String, String, String)> keptSubtree() async {
      await start(withRecovery: false);
      final kept = nb.currentId!;
      final lost = await nb.createPage(parentId: kept);
      final last = await nb.createPage(parentId: kept);
      await nb.createPage(); // the page that stays open
      await nb.flush();
      final theirs = noteBox('from the other device', at: const Bounds(400, 10, 200, 40));
      final base = onDisk(kept);
      counting.beforeDeleteOnce = () => File(pathOf(kept)).writeAsStringSync(writePage(base.insertNode(theirs)));
      counting.failNew.add(lost);
      counting.failDelete.add(last);
      return (kept, lost, last);
    }

    test('2: the check of a kept page throws: the pages are still held', () async {
      final (kept, lost, last) = await keptSubtree();
      var fired = false;
      nb.syncHook = (point, path) async {
        if (point != 'delete-rollback-check') return;
        fired = true;
        throw StateError('check failed');
      };

      final error = await attempt(() => nb.delete(kept));

      expect(fired, isTrue);
      final held = heldOf(error).deleted;
      expect(held.pages.map((p) => p.id), [lost]);
      expect(nb.isHeldDelete(held), isTrue);
      nb.syncHook = null;
      counting.failNew.clear();
      counting.failDelete.clear();
      await nb.undoDelete(held);
      expect(File(pathOf(lost)).existsSync(), isTrue);
      expect(File(pathOf(kept)).existsSync(), isTrue, reason: 'the kept page stays');
      expect(File(pathOf(last)).existsSync(), isTrue);
    });

    test('2b: a NotebookException while the attachments go back keeps the folders in the trash', () async {
      late _GoneStore folderStore;
      final folder2Name = 'folder2';
      await start(
        withRecovery: false,
        factory: (d) => d.path.endsWith(folder2Name) ? (folderStore = _GoneStore(d)) : PageStore(d),
      );
      final folder2 = await Directory('${root.path}$sep$folder2Name').create();
      await nb.addStandaloneFolder(folder2.path);
      final top = await nb.createPage(folderPath: folder2.path);
      final sub = await nb.createPage(parentId: top);
      await nb.createPage(); // the page that stays open
      await nb.flush();
      final assets = await Directory('${folder2.path}$sep${assetsFolderName(top)}').create();
      File('${assets.path}${sep}f.bin').writeAsBytesSync([1, 2, 3]);
      folderStore.failDelete.add(sub);
      // The folder goes away (the app forgets it) just before the delete fails.
      folderStore.beforeFail = () => nb.removeStandaloneFolder(folder2.path);
      final log = <String>[];
      final oldPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => log.add(message ?? '');
      addTearDown(() => debugPrint = oldPrint);

      final error = await attempt(() => nb.delete(top));

      expect(
        log,
        contains(allOf(contains('Putting back the attachments of page $top failed'), contains('not available'))),
        reason: 'a NotebookException was caught in the put-back loop',
      );
      final held = heldOf(error).deleted;
      expect(nb.isHeldDelete(held), isTrue);
      final inTrash = Directory(
        '${Directory.systemTemp.path}${sep}noted-app${sep}deleted-attachments',
      ).listSync(recursive: true).whereType<File>().where((f) => f.path.contains(top) && f.path.endsWith('f.bin'));
      expect(inTrash, hasLength(1), reason: 'the set-aside folder stays in the trash');
      expect(inTrash.single.readAsBytesSync(), [1, 2, 3]);
      // Let the held entry go (as the held bar's X does), so its set-aside
      // doesn't stay in the shared trash folder for other tests.
      nb.discardDeleted(held);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });

    test('3: an ordinary Undo whose write fails keeps the pages held', () async {
      await start(withRecovery: false);
      final id = nb.currentId!;
      mine = nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      await nb.createPage(); // the page that stays open
      await nb.flush();
      final deleted = await nb.delete(id);
      counting.failNew.add(id);

      final error = await attempt(() => nb.undoDelete(deleted));

      expect(heldOf(error).deleted, same(deleted));
      expect(nb.isHeldDelete(deleted), isTrue);
      expect(nb.isPendingDelete(deleted), isTrue);
      expect(File(pathOf(id)).existsSync(), isFalse);

      counting.failNew.clear();
      await nb.undoDelete(deleted);
      expect(idsOf(pathOf(id)), contains(mine.id));
      expect(nb.isPendingDelete(deleted), isFalse);
    });

    test('4: an ordinary Undo that fails on the second page holds only that page', () async {
      await closedTree();
      final deleted = await nb.delete(parent);
      expect(deleted.pages, hasLength(3));
      counting.failNew.add(child);

      final error = await attempt(() => nb.undoDelete(deleted));

      expect(heldOf(error).message, allOf(contains('"Untitled page"'), contains('held in memory only')));
      expect(nb.isHeldDelete(deleted), isTrue);
      expect(File(pathOf(parent)).existsSync(), isTrue);
      expect(File(pathOf(child)).existsSync(), isFalse);
      // The user edits the restored parent; a retry does not rewrite it.
      final edited = writePage(onDisk(parent).removeNode(mine.id));
      File(pathOf(parent)).writeAsStringSync(edited);
      counting.failNew.clear();

      await nb.undoDelete(deleted);

      expect(File(pathOf(parent)).readAsStringSync(), edited);
      expect(File(pathOf(child)).existsSync(), isTrue);
      expect(nb.isPendingDelete(deleted), isFalse);
      expect(copies(), isEmpty);
    });

    group('5: an unexpected error while publishing the copy', () {
      Future<NotedPage> fileInTheWay(String id, NotedPage deletedVersion) async {
        final theirs = noteBox('from the other device', at: const Bounds(400, 10, 200, 40));
        final page = deletedVersion.removeNode(mine.id).insertNode(theirs);
        File(pathOf(id)).writeAsStringSync(writePage(page));
        return page;
      }

      for (final held in [false, true]) {
        test(held ? 'a held entry stays held' : 'an ordinary entry becomes held', () async {
          late DeletedPages deleted;
          if (held) {
            deleted = (await heldParent()).deleted;
          } else {
            await closedTree();
            deleted = await nb.delete(parent);
          }
          final theirs = await fileInTheWay(parent, deleted.pages.first);
          final before = File(pathOf(parent)).readAsStringSync();
          var fired = false;
          nb.syncHook = (point, path) async {
            if (point != 'undo-copy-before-publish') return;
            fired = true;
            throw StateError('hook failed');
          };

          final error = await attempt(() => nb.undoDelete(deleted));

          expect(fired, isTrue);
          expect(heldOf(error).deleted, same(deleted));
          expect(nb.isHeldDelete(deleted), isTrue);
          expect(File(pathOf(parent)).readAsStringSync(), before, reason: 'the file in the place is untouched');
          expect(copies(), isEmpty);
          expect(theirs, isNotNull);
        });
      }
    });

    // A parent and a child, another page to delete meanwhile, and one that stays open.
    Future<(DeletedPages, String)> blockedUndo() async {
      await start(withRecovery: false);
      parent = nb.currentId!;
      mine = nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      child = await nb.createPage(parentId: parent);
      final newer = await nb.createPage();
      await nb.createPage(); // the page that stays open
      await nb.flush();
      final d1 = await nb.delete(parent);
      counting.failNew.add(child);
      return (d1, newer);
    }

    // Starts Undo of [d], paused at its first write.
    Future<(Future<Object?>, Completer<void>)> pausedUndo(DeletedPages d) async {
      final release = counting.holdNew = Completer<void>();
      counting.reachedNew = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final undo = attempt(() => nb.undoDelete(d));
      await counting.reachedNew!.future;
      return (undo, release);
    }

    test('6: a second delete during an Undo: the first stays held, the second stays pending', () async {
      final (d1, newer) = await blockedUndo();
      final (undo, release) = await pausedUndo(d1);

      final d2 = await nb.delete(newer);
      release.complete();
      final error = await undo;

      expect(heldOf(error).deleted, same(d1));
      expect(nb.isHeldDelete(d1), isTrue);
      expect(nb.isPendingDelete(d2), isTrue);
      expect(nb.isHeldDelete(d2), isFalse);
      expect(File(pathOf(parent)).existsSync(), isTrue);
      await nb.undoDelete(d2);
      expect(File(pathOf(newer)).existsSync(), isTrue);
      expect(nb.isPendingDelete(d2), isFalse);
    });

    test('6b: a second Undo of the entry during the first waits and reports nothing more', () async {
      final (d1, _) = await blockedUndo();
      final (undo, release) = await pausedUndo(d1);

      final second = attempt(() => nb.undoDelete(d1));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      release.complete();
      final results = [await undo, await second];

      expect(results.whereType<PagesNotRestoredException>(), hasLength(1));
      expect(results.where((r) => r != null), hasLength(1));
      expect(nb.isHeldDelete(d1), isTrue);
    });

    test('6c: quit during an ordinary Undo waits for it, and the pages it could not restore are copied', () async {
      final (d1, _) = await blockedUndo();
      final (undo, release) = await pausedUndo(d1);

      var exited = false;
      final exit = nb.prepareToExit().then((r) {
        exited = true;
        return r;
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(exited, isFalse, reason: 'exit waits for the Undo');
      release.complete();
      expect(heldOf(await undo).deleted, same(d1));

      expect(await exit, isTrue);
      expect(copies(), hasLength(1));
      expect(copies().single.path, contains(child));
      expect(idsOf(copies().single.path), isNotNull);
      expect(File(pathOf(parent)).existsSync(), isTrue);
    });

    test('6d: a discard while an Undo copies attachments leaves the set-aside alone (guard)', () async {
      await start(withRecovery: false);
      final id = nb.currentId!;
      final newer = await nb.createPage();
      await nb.createPage(); // the page that stays open
      await nb.flush();
      final assets = await Directory('${dir.path}$sep${assetsFolderName(id)}').create();
      final bytes = List<int>.generate(2000, (i) => i % 251);
      File('${assets.path}${sep}f.bin').writeAsBytesSync(bytes);
      final d1 = await nb.delete(id);
      expect(assets.existsSync(), isFalse, reason: 'set aside');
      Notebook.forcePutBackCannotRenameForTest = true;
      final reached = Completer<void>();
      final release = Completer<void>();
      attachmentBeforePublishHook = (target) async {
        if (!target.endsWith('f.bin') || !target.startsWith(dir.path)) return;
        if (!reached.isCompleted) reached.complete();
        await release.future;
      };
      addTearDown(() {
        Notebook.forcePutBackCannotRenameForTest = false;
        attachmentBeforePublishHook = null;
        if (!release.isCompleted) release.complete();
      });
      final undo = attempt(() => nb.undoDelete(d1));
      await reached.future.timeout(const Duration(seconds: 30));

      final d2 = await nb.delete(newer); // a newer delete discards D1's pending state
      expect(nb.isPendingDelete(d2), isTrue);
      await nb.discardPendingDelete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final setAside = Directory('${Directory.systemTemp.path}${sep}noted-app${sep}deleted-attachments')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.contains(id) && f.path.endsWith('f.bin'));
      expect(setAside, hasLength(1), reason: 'the Undo still copies from it');
      release.complete();
      await undo;

      expect(File('${assets.path}${sep}f.bin').readAsBytesSync(), bytes);
      expect(File(pathOf(id)).existsSync(), isTrue);
    });

    test('6e: quit while an Undo is blocked past the limit: the entry is not copied and the question names it', () async {
      final (d1, _) = await blockedUndo();
      final (undo, release) = await pausedUndo(d1);
      final asked = <(UserQuestion, String)>[];
      nb.questioner = (q, title) async {
        asked.add((q, title));
        return true; // leave
      };

      expect(await nb.prepareToExit(limit: const Duration(milliseconds: 100)), isTrue);

      expect(asked.map((a) => a.$1), [UserQuestion.leaveAndLose]);
      expect(asked.single.$2, contains('Untitled page'));
      expect(copies(), isEmpty, reason: 'the running Undo owns the pages');
      release.complete();
      await undo;
    });
  });

  group('conflict copy cleanup', () {
    Future<(String, BoxRecord)> closedPageWithBox() async {
      await start();
      final id = nb.currentId!;
      final box = noteBox('base');
      await other.save((await other.load(id)).insertNode(box));
      await nb.createPage(); // opens another page; [id] is closed
      await nb.checkFile(pathOf(id));
      return (id, box);
    }

    test('a copy replaced during the merge is merged again, not deleted', () async {
      final (id, box) = await closedPageWithBox();
      final disk = await other.load(id);
      final first = noteBox('first', at: const Bounds(400, 10, 200, 40));
      final later = noteBox('added later', at: const Bounds(400, 100, 200, 40));
      final path = '${dir.path}$sep$id-DESKTOP-ABC.canvas';
      File(path).writeAsStringSync(writePage(disk.insertNode(first)));
      var fired = false;
      nb.syncHook = (point, p) async {
        if (point != 'copy-merged' || fired) return;
        fired = true; // the sync provider replaces the copy with a newer one
        File(path).writeAsStringSync(writePage(disk.insertNode(first).insertNode(later)));
      };

      await nb.checkFile(path);

      expect(fired, isTrue);
      expect(File(path).existsSync(), isFalse);
      expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, first.id, later.id});
      expect(nb.unreadable, isEmpty);
    });

    test('a copy that keeps changing is kept and listed', () async {
      final (id, _) = await closedPageWithBox();
      final disk = await other.load(id);
      final path = '${dir.path}$sep$id-DESKTOP-ABC.canvas';
      var n = 0;
      File(path).writeAsStringSync(writePage(disk.insertNode(noteBox('0'))));
      nb.syncHook = (point, p) async {
        if (point != 'copy-merged') return;
        n++;
        File(path).writeAsStringSync(writePage(disk.insertNode(noteBox('$n'))));
      };
      await nb.checkFile(path);
      expect(File(path).existsSync(), isTrue);
      expect(nb.unreadable.map((u) => u.path), [path]);
      // Once it settles, the next pass merges and removes it.
      nb.syncHook = null;
      await nb.checkFile(path);
      expect(File(path).existsSync(), isFalse);
      expect(nb.unreadable, isEmpty);
    });

    test('an original changed after it was read is not overwritten', () async {
      final (id, box) = await closedPageWithBox();
      final disk = await other.load(id);
      final fromCopy = noteBox('from the copy', at: const Bounds(400, 10, 200, 40));
      final newer = noteBox('newer on the original', at: const Bounds(400, 100, 200, 40));
      final path = '${dir.path}$sep$id-DESKTOP-ABC.canvas';
      File(path).writeAsStringSync(writePage(disk.insertNode(fromCopy)));
      var fired = false;
      nb.syncHook = (point, p) async {
        if (point != 'original-read' || fired) return;
        fired = true; // the other device's edit lands on the original now
        await other.save(disk.insertNode(newer));
      };

      await nb.checkFile(path);

      expect(fired, isTrue);
      expect(File(path).existsSync(), isFalse);
      expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, fromCopy.id, newer.id});
    });

    test('an original replaced at the moment of the merge write is not overwritten', () async {
      final (id, box) = await closedPageWithBox();
      final disk = await other.load(id);
      final fromCopy = noteBox('from the copy', at: const Bounds(400, 10, 200, 40));
      final newer = noteBox('newer on the original', at: const Bounds(400, 100, 200, 40));
      final path = '${dir.path}$sep$id-DESKTOP-ABC.canvas';
      File(path).writeAsStringSync(writePage(disk.insertNode(fromCopy)));
      // After the reread, right before the write: only the compare-and-swap
      // replace sees this.
      counting.beforeWrite = () => File(pathOf(id)).writeAsStringSync(writePage(disk.insertNode(newer)));

      await nb.checkFile(path);

      expect(File(path).existsSync(), isFalse);
      expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, fromCopy.id, newer.id});
    });

    test('R-3: a sync writer taking the target at the publish keeps the original-only box', () async {
      final (id, box) = await closedPageWithBox(); // the original holds box A
      final disk = await other.load(id);
      final fromCopy = noteBox('from the copy', at: const Bounds(400, 10, 200, 40));
      final newer = noteBox('from the other device', at: const Bounds(400, 100, 200, 40));
      final path = '${dir.path}$sep$id-DESKTOP-ABC.canvas';
      // The copy does not have box A; the other device's newer version does not either.
      final withoutA = disk.removeNode(box.id);
      File(path).writeAsStringSync(writePage(withoutA.insertNode(fromCopy)));
      var fired = false;
      // After the original was set aside and verified, right before the merged
      // page is published: the sync writer publishes its own version.
      counting.beforePublishOnce = () {
        fired = true;
        File(pathOf(id)).writeAsStringSync(writePage(withoutA.insertNode(newer)));
      };

      await nb.checkFile(path);
      // Settle: merge every conflict copy that is left, as the folder scan would.
      for (var i = 0; i < 4; i++) {
        final copies = dir
            .listSync()
            .map((f) => f.path)
            .where((f) => f.endsWith('.canvas') && f != pathOf(id))
            .toList();
        if (copies.isEmpty) break;
        for (final c in copies) {
          await nb.checkFile(c);
        }
      }

      expect(fired, isTrue);
      final ids = onDisk(id).nodes.map((n) => n.id).toSet();
      expect(ids, containsAll({box.id, fromCopy.id, newer.id}));
    });
  });

  // Run 2026-11-16-01 (R-1 of the 2026-11-16 data-integrity audit): a merged
  // copy is kept in recovery before it is deleted, and the entry goes only once
  // a later read of the page file still holds it. A sync client putting back
  // the file it fetched before the merge has the merge done again.
  group('a merged copy is retired only after a re-check', () {
    late String id;
    late BoxRecord box;
    late BoxRecord extra;
    late String copy;
    late String before; // the original as it was before the merge

    // The closed page [id] holds [box]; the copy beside it adds [extra]
    // ([shape] changes the copy further). [originalAi]: the original's own AI
    // access.
    Future<void> withCopy({NotedPage Function(NotedPage copy)? shape, AiAccess? originalAi}) async {
      id = nb.currentId!;
      box = noteBox('base');
      var page = (await other.load(id)).insertNode(box);
      if (originalAi != null) page = page.withMeta(page.meta.withAiAccess(originalAi));
      await other.save(page);
      await nb.createPage(); // [id] is closed
      await nb.checkFile(pathOf(id));
      before = File(pathOf(id)).readAsStringSync();
      extra = noteBox('from the copy', at: const Bounds(400, 10, 200, 40));
      var c = readPage(before).insertNode(extra);
      if (shape != null) c = shape(c);
      copy = '${dir.path}$sep$id-DESKTOP-ABC.canvas';
      File(copy).writeAsStringSync(writePage(c));
    }

    // A sync client puts back the file it fetched before the merge.
    void revert([String? at]) => File(at ?? pathOf(id)).writeAsStringSync(before);

    // Someone else changes the file at [path] (sync puts the old one back), and
    // its event arrives.
    Future<void> foreign(String path) async {
      revert(path);
      await nb.checkFile(path);
    }

    // Reverts the original at the hook [point], once (or [every] time).
    void revertAt(String point, {bool every = false}) {
      var fired = false;
      final hook = nb.syncHook;
      nb.syncHook = (p, path) async {
        await hook?.call(p, path);
        if (p != point || (fired && !every)) return;
        fired = true;
        revert();
      };
    }

    Future<List<RecoveryEntry>> entries() async => (await nb.recoveryStoreForTest!.list()).entries;

    // Makes the re-check due and runs a replay pass.
    Future<void> recheck() async {
      clock = clock.add(const Duration(hours: 2));
      await nb.recoverNowForTest();
    }

    Set<String> ids([String? at]) => readPage(File(at ?? pathOf(id)).readAsStringSync()).nodes.map((n) => n.id).toSet();

    // Polls [done]; a read of a file the notebook is writing at that moment
    // (Windows refuses it) counts as not done yet.
    Future<void> until(FutureOr<bool> Function() done, String what) async {
      final end = DateTime.now().add(const Duration(seconds: 20));
      Future<bool> check() async {
        try {
          return await done();
        } on FileSystemException {
          return false;
        }
      }

      while (!await check()) {
        if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    Future<void> restart() async {
      nb.dispose();
      counting = CountingStore(dir);
      nb = makeNotebook();
      await nb.load();
      await nb.createPage(); // the page with the copy is closed
    }

    for (final point in ['copy-merged', 'copy-deleted']) {
      test('(a, b) the old original put back at $point: the re-check merges the copy again, then retires it', () async {
        await start();
        await withCopy();
        revertAt(point);
        await nb.checkFile(copy);
        expect(File(copy).existsSync(), isFalse);
        expect(ids(), {box.id}, reason: 'sync put the old file back');
        final kept = await entries();
        expect(kept.single.page.node(extra.id), isNotNull, reason: 'the copy is kept in recovery');
        expect(kept.single.baseText, isNull);
        await recheck();
        expect(ids(), {box.id, extra.id});
        expect(verifyConflictCopyMerge(onDisk(id), readPage(before), kept.single.page, topOfChain: true), isNull);
        expect(await entries(), hasLength(1), reason: 'merged again: re-checked once more');
        await recheck();
        expect(await entries(), isEmpty);
        expect(ids(), {box.id, extra.id});
      });
    }

    test('(a) with the copy\'s AI access stricter: the redo puts the stricter access back', () async {
      await start();
      await withCopy(originalAi: AiAccess.open, shape: (c) => c.withMeta(c.meta.withAiAccess(AiAccess.guarded)));
      revertAt('copy-merged');
      await nb.checkFile(copy);
      expect(onDisk(id).meta.aiAccess, AiAccess.open, reason: 'the old file is back');
      await recheck();
      expect(onDisk(id).meta.aiAccess, AiAccess.guarded);
      expect(ids(), {box.id, extra.id});
      await recheck();
      expect(await entries(), isEmpty);
    });

    test('(c) no revert: the entry is retired at the first re-check and the page file is untouched', () async {
      await start();
      await withCopy();
      await nb.checkFile(copy);
      final merged = File(pathOf(id)).readAsStringSync();
      expect(await entries(), hasLength(1));
      expect((await nb.pendingRecovery()).entries, isEmpty, reason: 'not an edit waiting');
      await nb.recoverNowForTest();
      expect(await entries(), hasLength(1), reason: 'not due yet');
      await recheck();
      expect(await entries(), isEmpty);
      expect(nb.consumedCopiesForTest, isEmpty);
      expect(File(pathOf(id)).readAsStringSync(), merged);
    });

    test('(d) recovery locked: the copy stays listed; once it is back a revert at the retry is undone', () async {
      final lock = _SwitchLock(File('${Directory.systemTemp.path}${sep}noted_race_unused.lock'));
      await start(lock: lock);
      await withCopy();
      lock.broken = true;
      await nb.checkFile(copy);
      expect(File(copy).existsSync(), isTrue);
      expect(nb.unreadable.map((u) => u.path), [copy]);
      expect(ids(), {box.id, extra.id}, reason: 'the merge itself landed; nothing was lost');
      lock.broken = false;
      revertAt('copy-merged');
      await nb.checkFile(copy); // the retry's merge writes nothing, and still keeps the copy
      expect(File(copy).existsSync(), isFalse);
      expect(ids(), {box.id});
      await recheck();
      expect(ids(), {box.id, extra.id});
    });

    test('(d2) after a restart the original already holds the merge: the copy is still kept, and a revert undone', () async {
      await start();
      await withCopy();
      // Merged before a crash: the original holds the merge, the copy is still there.
      File(pathOf(id)).writeAsStringSync(File(copy).readAsStringSync());
      nb.dispose();
      counting = CountingStore(dir);
      nb = makeNotebook();
      revertAt('copy-merged');
      await nb.load();
      await nb.createPage();
      expect(File(copy).existsSync(), isFalse);
      expect(ids(), {box.id});
      expect(await entries(), hasLength(1));
      await recheck();
      expect(ids(), {box.id, extra.id});
    });

    for (final kind in ['recorded conflict', 'landed marker']) {
      test('(d3) the box put back with the same rev and no $kind: the redo puts it back', () async {
        await start();
        late BoxRecord marked;
        await withCopy(
          shape: (c) {
            final b = c.node(box.id)! as BoxRecord;
            marked = kind == 'landed marker'
                ? b.withLanded(BoxLanded(at: 5))
                : b.withConflict(BoxConflict.other(node: noteBox('v1').toRaw(), at: 5));
            return c.replaceNode(marked);
          },
        );
        BoxRecord now() => onDisk(id).node(box.id)! as BoxRecord;
        await nb.checkFile(copy);
        expect(now().rev, marked.rev);
        revert();
        expect(now().conflicts, isEmpty);
        expect(now().landed, isNull);
        await recheck();
        if (kind == 'landed marker') {
          expect(now().landed, isNotNull);
        } else {
          expect(now().conflicts, marked.conflicts);
        }
        await recheck();
        expect(await entries(), isEmpty);
      });
    }

    test('(e) sync puts the old file back at every re-check: three rounds by the timer, parked, one more on a change', () async {
      await start(retire: const Duration(milliseconds: 300));
      await withCopy();
      // Each re-check reads the file once; sync has put the old one back each time.
      var writes = 0;
      final hook = nb.syncHook;
      nb.syncHook = (p, path) async {
        await hook?.call(p, path);
        if (p != 'copy-recheck') return;
        writes++;
        revert();
      };
      await nb.checkFile(copy);
      bool parked() => nb.consumedCopiesForTest.values.any((p) => p);
      await until(parked, 'the mark to be parked');
      expect(writes, 3);
      expect(nb.recoveryProblems.join('\n'), contains('Sync keeps putting back an older version'));
      final line = nb.recoveryDamaged.map((d) => d.reason).singleWhere((r) => r.startsWith('Sync keeps'));
      expect(line, matches(RegExp(r'^Sync keeps putting back an older version of .+\. The merged copy is kept in recovery\.$')));
      expect(nb.recoveryDamaged.map((d) => d.reason).join('\n'), isNot(contains("can't finish")));
      // The clause the preview shows keeps its wording.
      expect(nb.recoveryProblems.any((p) => p.contains('; the merged copy is kept in recovery')), isTrue);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(writes, 3, reason: 'no fourth round while parked');
      await foreign(pathOf(id)); // a change of the file
      await until(() => writes == 4 && parked(), 'the fourth round');
      await foreign(pathOf(id));
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(writes, 4, reason: 'parked until a restart');
      expect(await entries(), hasLength(1));
    }, timeout: const Timeout(Duration(minutes: 1)));

    // The page's file is a chosen one with another name; a change of that file
    // unparks the mark, a file of the page's canonical name elsewhere doesn't.
    for (final elsewhere in [false, true]) {
      test('(e) a page with a chosen file name: ${elsewhere ? 'a same-named file in another folder' : 'a change of its file'} ${elsewhere ? 'does not unpark' : 'unparks once'}', () async {
        await start(retire: const Duration(milliseconds: 300));
        await withCopy();
        await nb.checkFile(copy);
        final chosen = '${dir.path}${sep}renamed.canvas';
        File(pathOf(id)).renameSync(chosen);
        await nb.checkFile(pathOf(id)); // seen missing
        await nb.checkFile(chosen);
        await nb.adoptUnlistedPageFile(chosen, id);
        var writes = 0;
        final hook = nb.syncHook;
        nb.syncHook = (p, path) async {
          await hook?.call(p, path);
          if (p != 'copy-recheck') return;
          writes++;
          File(chosen).writeAsStringSync(before);
        };
        bool parked() => nb.consumedCopiesForTest.values.any((p) => p);
        await recheck();
        await recheck();
        await recheck();
        await until(parked, 'the mark to be parked');
        expect(writes, 3);
        final other = Directory('${dir.path}${sep}elsewhere')..createSync();
        if (elsewhere) {
          for (final n in ['$id.canvas', 'renamed.canvas']) {
            final f = File('${other.path}$sep$n')..writeAsStringSync(before);
            await nb.checkFile(f.path);
          }
        } else {
          await foreign(chosen);
        }
        await recheck();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(writes, elsewhere ? 3 : 4);
        await foreign(chosen);
        await recheck();
        // The page's own file now changes: one more round, once per mark.
        expect(writes, 4);
        await foreign(chosen);
        await recheck();
        expect(writes, 4, reason: 'once per mark');
      }, timeout: const Timeout(Duration(minutes: 1)));
    }

    // Parks the mark: sync puts the old file back at every re-check, wherever
    // the page's file is at that moment. [writes] counts the rounds.
    Future<int Function()> park() async {
      await start(retire: const Duration(milliseconds: 300));
      await withCopy();
      await nb.checkFile(copy);
      var writes = 0;
      final hook = nb.syncHook;
      nb.syncHook = (p, path) async {
        await hook?.call(p, path);
        if (p != 'copy-recheck') return;
        writes++;
        File(path).writeAsStringSync(before);
      };
      await recheck();
      await recheck();
      await recheck();
      await until(() => nb.consumedCopiesForTest.values.any((p) => p), 'the mark to be parked');
      expect(writes, 3);
      return () => writes;
    }

    test('(e) an event path that differs in letter case and separators unparks (Windows)', () async {
      final writes = await park();
      final other = id.toUpperCase();
      revert(); // someone else's change
      await nb.checkFile('${dir.path.replaceAll(r'\', '/')}/$other.canvas');
      await recheck();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(writes(), 4);
    }, skip: !Platform.isWindows, timeout: const Timeout(Duration(minutes: 1)));

    test('(e) the event of the redo\'s own write does not unpark; a foreign change does, once', () async {
      final writes = await park();
      await nb.checkFile(pathOf(id)); // the file is as the last redo wrote it
      await recheck();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(writes(), 3, reason: 'no extra round on our own write');
      await foreign(pathOf(id));
      await recheck();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(writes(), 4);
      await foreign(pathOf(id));
      await recheck();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(writes(), 4, reason: 'once per mark');
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('(e) another page\'s real change checked meanwhile does not unpark this one on its own-write event', () async {
      final writes = await park();
      final qId = nb.currentId!;
      await nb.createPage(); // the page [qId] is closed
      final qPath = pathOf(qId);
      final hook = nb.syncHook;
      var fired = false;
      nb.syncHook = (p, path) async {
        await hook?.call(p, path);
        if (p != 'check-start' || fired || path != pathOf(id)) return;
        fired = true;
        // A direct check of another page's file, as a job of the chain runs it.
        File(qPath).writeAsStringSync(writePage(readPage(File(qPath).readAsStringSync()).insertNode(noteBox('q'))));
        await nb.checkFileInChainForTest(qPath);
      };
      await nb.checkFile(pathOf(id)); // the file is as the last redo wrote it
      expect(fired, isTrue);
      await recheck();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(writes(), 3, reason: 'a change of another page is not this page\'s');
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('(e) a mark parked while the event\'s check waits is not unparked by that event', () async {
      await start(retire: const Duration(milliseconds: 300));
      await withCopy();
      await nb.checkFile(copy);
      var writes = 0;
      final hook = nb.syncHook;
      final gate = Completer<void>();
      var held = false;
      nb.syncHook = (p, path) async {
        await hook?.call(p, path);
        if (p == 'copy-recheck') {
          writes++;
          File(path).writeAsStringSync(before);
        } else if (p == 'check-start' && held && !gate.isCompleted && path == pathOf(id)) {
          await gate.future;
        }
      };
      await recheck();
      await recheck(); // two rounds: not parked yet
      expect(nb.consumedCopiesForTest.values.any((p) => p), isFalse);
      held = true;
      revert(); // a real change, announced now
      final event = nb.checkFile(pathOf(id));
      await recheck(); // the third round parks the mark while the check waits
      await until(() => nb.consumedCopiesForTest.values.any((p) => p), 'the mark to be parked');
      // The file is as the redo that parked wrote it: nothing changed after the park.
      gate.complete();
      await event;
      await recheck();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(writes, 3, reason: 'no change after the park');
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('(e) sync replaces the file and a direct check sees it first: the later event does not lose the round', () async {
      final writes = await park();
      revert(); // sync's replacement
      await nb.checkFileInChainForTest(pathOf(id)); // a save's check sees it first
      await nb.checkFile(pathOf(id)); // the watcher's job reads a match with what is known
      await recheck();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(writes(), 4);
      await foreign(pathOf(id));
      await recheck();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(writes(), 4, reason: 'once per mark');
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('(e) sync replaces the file and a closed-page update reads it first: the later event does not lose the round', () async {
      final writes = await park();
      revert(); // sync's replacement, before the watcher's check
      await nb.setAiAccess(id, AiAccess.open); // a closed page: _updateClosedPageNow
      await nb.checkFile(pathOf(id));
      await recheck();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(writes(), 4);
      await foreign(pathOf(id));
      await recheck();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(writes(), 4, reason: 'once per mark');
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('(e) moved to another folder while parked: the old folder\'s file does not unpark, the new one\'s does', () async {
      final writes = await park();
      final extraDir = await Directory('${root.path}${sep}extra').create();
      expect(await nb.moveToFolder(id, extraDir.path), isTrue);
      await nb.checkFile(pathOf(id));
      await recheck();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(writes(), 3, reason: 'the old folder is not the page\'s file now');
      await foreign('${extraDir.path}$sep$id.canvas');
      await recheck();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(writes(), 4);
      await foreign('${extraDir.path}$sep$id.canvas');
      await recheck();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(writes(), 4, reason: 'once per mark');
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('(f) a box from the copy moved inside the window: a revert brings it back in the copy\'s version', () async {
      await start();
      await withCopy();
      await nb.checkFile(copy);
      final away = nb.currentId!;
      await nb.open(id);
      nb.current!.requestBounds(extra.id, const Bounds(600, 300, 200, 40));
      await nb.flush();
      await nb.open(away);
      expect((onDisk(id).node(extra.id)! as BoxRecord).bounds, const Bounds(600, 300, 200, 40));
      revert();
      await recheck();
      expect(ids(), {box.id, extra.id}, reason: 'a moved box is still the copy\'s');
      expect((onDisk(id).node(extra.id)! as BoxRecord).bounds, extra.bounds);
      await recheck();
      expect(await entries(), isEmpty);
    });

    test('(f) a box from the copy deleted and the delete undone inside the window: a revert brings it back', () async {
      await start();
      await withCopy();
      await nb.checkFile(copy);
      final away = nb.currentId!;
      await nb.open(id);
      nb.current!.delete(extra.id);
      await nb.flush();
      nb.current!.undo();
      expect(nb.current!.page.node(extra.id), isNotNull, reason: 'the delete is undone');
      await nb.flush();
      await nb.open(away);
      revert();
      await recheck();
      expect(ids(), {box.id, extra.id}, reason: 'an undone delete is not the user\'s');
      await recheck();
      expect(await entries(), isEmpty);
    });

    for (final open in [true, false]) {
      final where = open ? 'open' : 'closed';
      test('(f) AI access loosened, then tightened back (page $where), then a revert: the user\'s last choice stands', () async {
        await start();
        await withCopy(originalAi: AiAccess.open, shape: (c) => c.withMeta(c.meta.withAiAccess(AiAccess.guarded)));
        await nb.checkFile(copy);
        final away = nb.currentId!;
        if (open) await nb.open(id);
        await nb.setAiAccess(id, AiAccess.open);
        await nb.flush();
        await nb.setAiAccess(id, AiAccess.guarded);
        await nb.flush();
        if (open) await nb.open(away);
        expect(onDisk(id).meta.aiAccess, AiAccess.guarded);
        revert(); // the pre-merge file, Open
        await recheck();
        expect(ids(), {box.id, extra.id});
        expect(onDisk(id).meta.aiAccess, AiAccess.guarded);
      });

      test('(f) AI access set to Privileged (page $where), then a revert to the Open original: Privileged, the user\'s', () async {
        await start();
        await withCopy(originalAi: AiAccess.open, shape: (c) => c.withMeta(c.meta.withAiAccess(AiAccess.guarded)));
        await nb.checkFile(copy);
        final away = nb.currentId!;
        if (open) await nb.open(id);
        await nb.setAiAccess(id, AiAccess.privileged);
        await nb.flush();
        if (open) await nb.open(away);
        revert();
        await recheck();
        expect(ids(), {box.id, extra.id});
        expect(onDisk(id).meta.aiAccess, AiAccess.privileged, reason: 'not the disk\'s Open, nor the copy\'s Guarded');
        await recheck();
        expect(await entries(), isEmpty);
      });
    }

    // Another device deletes the page: the chosen file goes, and a later
    // folder check confirms it (_confirmGoneChosen).
    for (final back in [false, true]) {
      test('another device\'s delete confirmed: ${back ? 'sync put the old file back first: the entry stays and the re-check merges' : 'no file: the entry is retired'}', () async {
        await start();
        await withCopy();
        await nb.checkFile(copy);
        // Make the page's file a chosen one: it arrives unlisted and is adopted.
        final aside = File('${root.path}$sep$id.canvas');
        File(pathOf(id)).renameSync(aside.path);
        await nb.checkFile(pathOf(id));
        aside.renameSync(pathOf(id));
        await nb.adoptUnlistedPageFile(pathOf(id), id);
        expect(await entries(), hasLength(1));
        File(pathOf(id)).deleteSync();
        await nb.checkFile(pathOf(id)); // seen missing once
        if (back) revert();
        await nb.checkFolders(); // the confirming check
        if (back) {
          expect(await entries(), hasLength(1), reason: 'the file is back: the confirmation does not retire it');
          await recheck();
          expect(ids(), {box.id, extra.id});
        } else {
          await until(() async => (await entries()).isEmpty, 'the re-check after the confirmation');
          expect(File(pathOf(id)).existsSync(), isFalse);
        }
      });
    }

    // Issues the user settles inside the window (0120) stay settled: the
    // re-check doesn't require them, and a redo doesn't bring them back.
    BoxRecord withV1(BoxRecord b) => b.withConflict(BoxConflict.other(node: noteBox('v1').toRaw(), at: 5));
    BoxRecord withMarker(BoxRecord b) => b.withLanded(BoxLanded(at: 5));

    // Opens the page, settles [what] on box [boxId] as the user does, saves and
    // leaves.
    Future<void> settleIssue(String what, String boxId) async {
      final away = nb.currentId!;
      await nb.open(id);
      final c = nb.current!;
      if (what == 'conflict') {
        expect((c.page.node(boxId)! as BoxRecord).conflicts, isNotEmpty);
        c.resolveKeepMine(boxId);
        expect((c.page.node(boxId)! as BoxRecord).conflicts, isEmpty);
      } else {
        expect((c.page.node(boxId)! as BoxRecord).landed, isNotNull);
        c.leaveLanded(boxId);
      }
      await nb.flush();
      await nb.open(away);
    }

    BoxRecord diskBox(String boxId) => onDisk(id).node(boxId)! as BoxRecord;

    for (final what in ['conflict', 'marker']) {
      final issue = what == 'conflict' ? 'a recorded conflict resolved' : 'a landed marker dismissed';
      test('(f) $issue inside the window, no revert: the entry retires and the issue stays settled', () async {
        await start();
        await withCopy(
          shape: (c) => c.replaceNode(what == 'conflict' ? withV1(c.node(box.id)! as BoxRecord) : withMarker(c.node(box.id)! as BoxRecord)),
        );
        await nb.checkFile(copy);
        await settleIssue(what, box.id);
        await recheck();
        expect(await entries(), isEmpty, reason: 'held without the settled issue');
        expect(diskBox(box.id).conflicts, isEmpty);
        expect(diskBox(box.id).landed, isNull);
      });

      test('(f) $issue on a box from the copy, then a revert: the box comes back without it', () async {
        await start();
        late BoxRecord shaped;
        await withCopy(
          shape: (c) {
            final x = c.node(extra.id)! as BoxRecord;
            shaped = what == 'conflict' ? withV1(x) : withMarker(x);
            return c.replaceNode(shaped);
          },
        );
        await nb.checkFile(copy);
        await settleIssue(what, extra.id);
        revert();
        await recheck();
        expect(ids(), {box.id, extra.id});
        expect(diskBox(extra.id).rev, shaped.rev);
        expect(diskBox(extra.id).conflicts, isEmpty);
        expect(diskBox(extra.id).landed, isNull);
        await recheck();
        expect(await entries(), isEmpty);
      });
    }

    test('(f) the conflict the merge recorded with the copy\'s version, resolved inside the window: not recorded again', () async {
      await start();
      final codec = modules.codecs.codecFor('noted.note')!;
      late BoxRecord theirs;
      await withCopy(
        shape: (c) {
          theirs = commitBox(c.node(box.id)! as BoxRecord, codec, codec.decode(doc('edited in the copy'), 1));
          return c.replaceNode(theirs);
        },
      );
      // The original was edited too, from the same version: the merge records the copy's.
      final mineEdit = commitBox(box, codec, codec.decode(doc('edited here'), 1));
      File(pathOf(id)).writeAsStringSync(writePage(readPage(before).replaceNode(mineEdit)));
      await nb.checkFile(pathOf(id));
      await nb.checkFile(copy);
      expect(diskBox(box.id).conflicts.single.node, theirs.toRaw());
      await settleIssue('conflict', box.id);
      await recheck();
      expect(await entries(), isEmpty);
      expect(diskBox(box.id).conflicts, isEmpty);
      expect(diskBox(box.id).rev, mineEdit.rev);
    });

    // A resolution that carries the copy's version forward doesn't settle it:
    // after a revert the copy's version is back in the file (perhaps recorded
    // again as a conflict), never lost.
    for (final how in ['placeBoth', 'acceptMerged', 'keepOtherThenEdit']) {
      test('(f) the merge\'s conflict resolved by $how, then a revert: the copy\'s version is back in the file', () async {
        await start();
        final codec = modules.codecs.codecFor('noted.note')!;
        late BoxRecord theirs;
        await withCopy(
          shape: (c) {
            theirs = commitBox(c.node(box.id)! as BoxRecord, codec, codec.decode(doc('edited in the copy'), 1));
            return c.replaceNode(theirs);
          },
        );
        final mineEdit = commitBox(box, codec, codec.decode(doc('edited here'), 1));
        final preMerge = writePage(readPage(before).replaceNode(mineEdit));
        File(pathOf(id)).writeAsStringSync(preMerge);
        await nb.checkFile(pathOf(id));
        await nb.checkFile(copy);
        expect(diskBox(box.id).conflicts.single.node, theirs.toRaw());
        final away = nb.currentId!;
        await nb.open(id);
        final c = nb.current!;
        switch (how) {
          case 'placeBoth':
            c.resolveKeepBoth(box.id);
          case 'acceptMerged':
            expect(c.resolveWithData(box.id, codec.decode(doc('merged by hand'), 1)), isTrue);
          case 'keepOtherThenEdit':
            c.resolveKeepTheirs(box.id);
            c.editBox(box.id, codec.decode(doc('then edited'), 1));
        }
        expect((c.page.node(box.id)! as BoxRecord).conflicts, isEmpty);
        await nb.flush();
        await nb.open(away);
        File(pathOf(id)).writeAsStringSync(preMerge); // sync puts back the pre-merge original
        await recheck();
        final page = onDisk(id);
        final held = page.nodes.whereType<BoxRecord>().any(
          (b) => b.rev == theirs.rev || b.conflicts.any((k) => k.node == theirs.toRaw()),
        );
        expect(held, isTrue, reason: 'the copy\'s version is in the file');
        await recheck();
        expect(await entries(), isEmpty);
      });
    }

    test('(f) opened inside the window: editable; a box deleted there stays deleted after a revert', () async {
      await start();
      final more = noteBox('also from the copy', at: const Bounds(400, 100, 200, 40));
      await withCopy(shape: (c) => c.insertNode(more));
      await nb.checkFile(copy);
      final away = nb.currentId!;
      await nb.open(id);
      expect(nb.current!.readOnly, isFalse, reason: 'not a preview');
      nb.current!.delete(extra.id);
      await nb.flush();
      await nb.open(away);
      expect(ids(), {box.id, more.id});
      revert();
      await recheck();
      expect(ids(), {box.id, more.id});
      await recheck();
      expect(await entries(), isEmpty);
    });

    for (final open in [true, false]) {
      test('(f) AI access loosened in settings inside the window (page ${open ? 'open' : 'closed'}) stays after a revert', () async {
        await start();
        await withCopy(originalAi: AiAccess.open, shape: (c) => c.withMeta(c.meta.withAiAccess(AiAccess.guarded)));
        await nb.checkFile(copy);
        expect(onDisk(id).meta.aiAccess, AiAccess.guarded, reason: 'the stricter');
        final away = nb.currentId!;
        if (open) await nb.open(id);
        await nb.setAiAccess(id, AiAccess.open);
        await nb.flush();
        if (open) await nb.open(away);
        expect(onDisk(id).meta.aiAccess, AiAccess.open);
        revert();
        await recheck();
        expect(ids(), {box.id, extra.id});
        expect(onDisk(id).meta.aiAccess, AiAccess.open);
      });
    }

    test('(f2) shown as a preview when the re-check is due: it waits, and runs once the preview is closed', () async {
      await start();
      await withCopy();
      await nb.checkFile(copy);
      final away = nb.currentId!;
      final disk = onDisk(id);
      final edit = noteBox('a kept edit', at: const Bounds(10, 300, 200, 40));
      expect((await nb.keepClosedForTest(disk.insertNode(edit), disk, dir.path)).kind, KeepKind.kept);
      final hook = nb.syncHook;
      nb.syncHook = (p, path) async {
        if (p == 'recover-before-publish') throw const FileSystemException('not now');
        await hook?.call(p, path);
      };
      await nb.open(id);
      expect(nb.current!.readOnly, isTrue, reason: 'a preview: the kept edit waits');
      revert();
      await recheck();
      expect(ids(), {box.id}, reason: 'waits while the page is shown');
      expect(nb.consumedCopiesForTest, hasLength(1));
      nb.syncHook = hook;
      await nb.open(away);
      await recheck();
      expect(ids(), containsAll({box.id, extra.id}));
    });

    test('(f3) a failed save of the open page keeps its own entry beside the copy\'s, which is unchanged', () async {
      await start();
      await withCopy();
      await nb.checkFile(copy);
      final kept = (await entries()).single;
      await nb.open(id);
      final mine = nb.current!.createBoxAt(const Bounds(10, 300, 0, 0));
      counting.beforeWrite = () => throw const FileSystemException('disk full');
      await nb.flush();
      final now = await entries();
      expect(now, hasLength(2), reason: 'the session keep is not refused');
      expect(now.singleWhere((e) => e.gen == kept.gen).pageText, kept.pageText);
      expect(now.singleWhere((e) => e.gen != kept.gen).page.node(mine.id), isNotNull);
      expect(nb.consumedCopiesForTest.keys, [kept.gen]);
    });

    test('(f3) a closed save inside the window is a separate entry; the mark stays', () async {
      await start();
      await withCopy();
      await nb.checkFile(copy);
      final kept = (await entries()).single;
      final disk = onDisk(id);
      final edit = noteBox('a kept edit', at: const Bounds(10, 300, 200, 40));
      expect((await nb.keepClosedForTest(disk.insertNode(edit), disk, dir.path)).kind, KeepKind.kept);
      final now = await entries();
      expect(now, hasLength(2));
      expect(now.singleWhere((e) => e.gen == kept.gen).pageText, kept.pageText);
      expect(nb.consumedCopiesForTest.keys, [kept.gen]);
    });

    test('(f4) moved to another folder inside the window: a revert at the new place is merged again there', () async {
      await start();
      await withCopy();
      await nb.checkFile(copy);
      final extraDir = await Directory('${root.path}${sep}extra').create();
      expect(await nb.moveToFolder(id, extraDir.path), isTrue);
      final moved = '${extraDir.path}$sep$id.canvas';
      expect(File(pathOf(id)).existsSync(), isFalse);
      expect(nb.consumedCopiesForTest, hasLength(1), reason: 'the mark moved with the entry');
      revert(moved);
      await recheck();
      expect(ids(moved), {box.id, extra.id});
      await recheck();
      expect(await entries(), isEmpty);
    });

    test('(g) another device\'s version without the box brings it back (the stated limit)', () async {
      await start();
      await withCopy();
      await nb.checkFile(copy);
      File(pathOf(id)).writeAsStringSync(writePage(onDisk(id).removeNode(extra.id)));
      await recheck();
      expect(ids(), {box.id, extra.id});
    });

    test('(h) a restart before the re-check replays the entry: the box is in the file and the entry is gone', () async {
      await start();
      await withCopy();
      revertAt('copy-merged');
      await nb.checkFile(copy);
      expect(ids(), {box.id});
      await restart();
      expect(ids(), {box.id, extra.id});
      expect(await entries(), isEmpty);
    });

    group('(i) the page deleted inside the window', () {
      test('the entry survives the delete, waits while Undo can reach it, and goes once the delete is let go', () async {
        await start();
        await withCopy();
        await nb.checkFile(copy);
        final d = await nb.delete(id);
        expect(await entries(), hasLength(1));
        await recheck();
        expect(await entries(), hasLength(1), reason: 'Undo can still bring the page back');
        nb.discardDeleted(d);
        await until(() async => (await entries()).isEmpty, 'the let-go re-check');
        expect(File(pathOf(id)).existsSync(), isFalse);
      });

      test('delete, Undo, then the old original put back: the re-check restores the box', () async {
        await start();
        await withCopy();
        await nb.checkFile(copy);
        final d = await nb.delete(id);
        await nb.undoDelete(d);
        expect(ids(), {box.id, extra.id});
        revert();
        await recheck();
        expect(ids(), {box.id, extra.id});
      });

      test('delete, sync puts the old original back, the delete is let go before a scan: the box comes back', () async {
        await start();
        await withCopy();
        await nb.checkFile(copy);
        final d = await nb.delete(id);
        revert();
        nb.discardDeleted(d);
        await until(() => ids().contains(extra.id), 'the let-go re-check');
        // The box is in the file once the redo has written it, but the let-go
        // pass may still be finishing (the page busy, the redo's time not yet
        // set), so a single re-check may find nothing due: re-check until the
        // entry is retired.
        await until(() async {
          await recheck();
          return (await entries()).isEmpty;
        }, 'the entry to be retired');
        expect(ids(), contains(extra.id));
      });

      test('at quit with no file: the entry is retired', () async {
        await start();
        await withCopy();
        await nb.checkFile(copy);
        await nb.delete(id);
        await nb.discardPendingDelete();
        expect(await entries(), isEmpty);
      });

      test('at quit with the old original put back: the entry stays and the next start brings the box back', () async {
        await start();
        await withCopy();
        await nb.checkFile(copy);
        await nb.delete(id);
        revert();
        await nb.discardPendingDelete();
        expect(await entries(), hasLength(1));
        await restart();
        expect(ids(), {box.id, extra.id});
        expect(await entries(), isEmpty);
      });
    });

    test('(j) a re-check due while the copy waits for its delete does not retire it; a later revert is undone', () async {
      await start();
      await withCopy();
      final gate = Completer<void>();
      final held = Completer<void>();
      final hook = nb.syncHook;
      nb.syncHook = (p, path) async {
        await hook?.call(p, path);
        if (p != 'copy-merged' || held.isCompleted) return;
        // Another job takes the folder: the copy's delete waits for it.
        unawaited(
          locks.run(dir, () {
            held.complete();
            return gate.future;
          }),
        );
        await held.future;
      };
      final merging = nb.checkFile(copy);
      await until(() async => (await entries()).isNotEmpty, 'the copy kept');
      await recheck().timeout(const Duration(seconds: 10));
      expect(await entries(), hasLength(1), reason: 'not retired before the copy is deleted');
      gate.complete();
      await merging;
      expect(File(copy).existsSync(), isFalse);
      revert();
      await recheck();
      expect(ids(), {box.id, extra.id});
    });

    test('(k) recovery locked when the timer fires: it arms again and re-checks once the lock is back', () async {
      final lock = _SwitchLock(File('${Directory.systemTemp.path}${sep}noted_race_unused.lock'));
      await start(retire: const Duration(milliseconds: 300), lock: lock);
      await withCopy();
      revertAt('copy-merged');
      final hook = nb.syncHook;
      nb.syncHook = (p, path) async {
        await hook?.call(p, path);
        if (p == 'copy-deleted') lock.broken = true; // before the timer can re-check
      };
      await nb.checkFile(copy);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(ids(), {box.id}, reason: 'nothing replayed without the lock');
      lock.broken = false;
      await until(() => ids().contains(extra.id), 'the re-check');
      // The next round retires the entry; nothing is left running at the tear-down.
      await until(() async => (await entries()).isEmpty, 'the entry to be retired');
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('(k) moved between arming and firing: the timer re-checks at the new place', () async {
      await start(retire: const Duration(milliseconds: 500));
      final extraDir = await Directory('${root.path}${sep}extra').create();
      await withCopy();
      final moved = '${extraDir.path}$sep$id.canvas';
      final read = <String>[];
      final hook = nb.syncHook;
      nb.syncHook = (p, path) async {
        await hook?.call(p, path);
        if (p != 'copy-recheck') return;
        read.add(path);
        // Sync puts the old file back at the new place, just before the read.
        if (read.length == 1 && File(moved).existsSync()) revert(moved);
      };
      // The timer fires every half second; the re-check is due only once the
      // clock moves on, after the move.
      var at = DateTime(2026, 11, 16, 12);
      nb.now = () => at;
      await nb.checkFile(copy);
      expect(await nb.moveToFolder(id, extraDir.path), isTrue);
      at = at.add(const Duration(seconds: 1));
      await until(() => ids(moved).contains(extra.id) && read.isNotEmpty, 'the re-check at the new place');
      expect(read.first, moved);
      // The clock moves on at every look: the redo may still be setting its time.
      await until(() async {
        at = at.add(const Duration(seconds: 1));
        return (await entries()).isEmpty;
      }, 'the entry to be retired');
    }, timeout: const Timeout(Duration(minutes: 1)));
  });

  // Area R-1: every write of a page file is a compare-and-swap, so a version a
  // sync client lands during the write is merged, never overwritten.
  group('a sync replacement during a write is merged, not overwritten', () {
    Set<String> idsOnDisk(String id) => onDisk(id).nodes.map((n) => n.id).toSet();

    test('autosave: the file replaced before the write', () async {
      await start();
      final id = nb.currentId!;
      final mine = nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      final theirs = noteBox('from the other device', at: const Bounds(400, 10, 200, 40));
      final base = onDisk(id);
      counting.beforeWrite = () => File(pathOf(id)).writeAsStringSync(writePage(base.insertNode(theirs)));

      await nb.flush();

      expect(idsOnDisk(id), {mine.id, theirs.id});
      expect(nb.current!.page.node(theirs.id), isNotNull);
    });

    test('autosave: the file replaced during the publication', () async {
      await start();
      final id = nb.currentId!;
      final mine = nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      final theirs = noteBox('from the other device', at: const Bounds(400, 10, 200, 40));
      final base = onDisk(id);
      var fired = false;
      counting.beforePublishOnce = () {
        fired = true;
        File(pathOf(id)).writeAsStringSync(writePage(base.insertNode(theirs)));
      };

      await nb.flush();

      expect(fired, isTrue);
      expect(idsOnDisk(id), {mine.id, theirs.id});
    });

    test('a closed page renamed: the file replaced before the write', () async {
      await start();
      final id = nb.currentId!;
      await nb.createPage(); // id is closed now
      final theirs = noteBox('from the other device', at: const Bounds(400, 10, 200, 40));
      final base = onDisk(id);
      counting.beforeWrite = () => File(pathOf(id)).writeAsStringSync(writePage(base.insertNode(theirs)));

      await nb.rename(id, 'Renamed');

      expect(onDisk(id).meta.title, 'Renamed');
      expect(idsOnDisk(id), {theirs.id});
    });

    test('a closed page renamed: the file replaced during the publication', () async {
      await start();
      final id = nb.currentId!;
      await nb.createPage();
      final theirs = noteBox('from the other device', at: const Bounds(400, 10, 200, 40));
      final base = onDisk(id);
      var fired = false;
      counting.beforePublishOnce = () {
        fired = true;
        File(pathOf(id)).writeAsStringSync(writePage(base.insertNode(theirs)));
      };

      await nb.rename(id, 'Renamed');

      expect(fired, isTrue);
      expect(onDisk(id).meta.title, 'Renamed');
      expect(idsOnDisk(id), {theirs.id});
    });

    test('a page deleted while a newer version lands is kept, and the note says so', () async {
      await start();
      final id = nb.currentId!;
      await nb.createPage(); // id is closed now
      final theirs = noteBox('from the other device', at: const Bounds(400, 10, 200, 40));
      final base = onDisk(id);
      counting.beforeDeleteOnce = () => File(pathOf(id)).writeAsStringSync(writePage(base.insertNode(theirs)));

      final deleted = await nb.delete(id);

      expect(File(pathOf(id)).existsSync(), isTrue);
      expect(idsOnDisk(id), {theirs.id});
      expect(deleted.pages, isEmpty);
      expect(deleted.keptNote, contains('not deleted'));
    });

    test('an undone page whose file came back meanwhile is merged into it, not lost', () async {
      await start();
      final id = nb.currentId!;
      final mine = nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      await nb.createPage();
      await nb.flush();
      final deleted = await nb.delete(id);
      expect(File(pathOf(id)).existsSync(), isFalse);
      // A sync client puts another version of the page back.
      final theirs = noteBox('from the other device', at: const Bounds(400, 10, 200, 40));
      File(pathOf(id)).writeAsStringSync(writePage(deleted.pages.first.removeNode(mine.id).insertNode(theirs)));

      await expectLater(
        nb.undoDelete(deleted),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('merged into it'))),
      );

      expect(idsOnDisk(id), {mine.id, theirs.id});
      expect(
        dir.listSync().where((f) => f.path.contains('-undo-')),
        isEmpty,
        reason: 'the copy was merged and removed',
      );
    });

    test('a closed page changed while it is being opened: the editor takes the change', () async {
      await start();
      final id = nb.currentId!;
      final other = await nb.createPage();
      await nb.flush();
      nb.syncHook = (point, path) async {
        if (point != 'closed-update-read') return;
        nb.syncHook = null;
        await nb.open(id); // opened from the file as it is before the write
      };

      await nb.rename(id, 'Renamed');

      expect(nb.currentId, id);
      expect(nb.current!.page.meta.title, 'Renamed');
      await nb.open(other);
      expect(onDisk(id).meta.title, 'Renamed');
    });

    test('a closed page changed by a setting: a file that keeps changing is not written over', () async {
      await start();
      final id = nb.currentId!;
      await nb.createPage();
      final base = onDisk(id);
      var n = 0;
      late String last;
      void change() {
        last = writePage(base.insertNode(noteBox('sync $n', at: Bounds(400.0 + n++, 10, 200, 40))));
        File(pathOf(id)).writeAsStringSync(last);
      }

      // Every attempt finds a newer file at the moment of replacing.
      var rounds = 0;
      void again() {
        change();
        if (++rounds < 100) counting.beforeWrite = again;
      }

      counting.beforeWrite = again;

      await expectLater(nb.rename(id, 'Renamed'), throwsA(isA<NotebookException>()));
      expect(File(pathOf(id)).readAsStringSync(), last, reason: 'the other device\'s file stays');
    });
  });

  group('a delete rollback keeps its pages from its first step (run 2026-11-09-01)', () {
    late String parent;
    late String child;
    late BoxRecord mine;

    List<File> copies() => dir.listSync().whereType<File>().where((f) => f.path.contains('-undo-')).toList();
    List<File> entryFiles() =>
        rec.existsSync() ? rec.listSync().whereType<File>().where((f) => f.path.endsWith('.entry')).toList() : [];

    // A parent with a box and a subpage whose file can't be deleted.
    Future<void> tree({Duration? backoff}) async {
      await start(backoff: backoff);
      parent = nb.currentId!;
      mine = nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      child = await nb.createPage(parentId: parent);
      await nb.createPage(); // the page that stays open
      await nb.flush();
      counting.failDelete.add(child);
    }

    // Runs [action] to its end, returning what it threw.
    Future<Object?> attempt(Future<void> Function() action) async {
      try {
        await action();
      } on Object catch (e) {
        return e;
      }
      return null;
    }

    Future<Object?> startDelete() => attempt(() => nb.delete(parent));

    // The next restore waits at its publish; the returned gate lets it go.
    Completer<void> stallRestore() {
      final hold = Completer<void>();
      counting.holdNew = hold;
      counting.reachedNew = Completer<void>();
      return hold;
    }

    // A quit at its time limit: what it asked, and whether it let go.
    Future<(List<UserQuestion>, bool)> quit() async {
      final asked = <UserQuestion>[];
      nb.questioner = (q, title) async {
        asked.add(q);
        return false; // stay
      };
      final go = await nb.prepareToExit(limit: const Duration(milliseconds: 300));
      return (asked, go);
    }

    // The app is gone without a quit (the old notebook is left as it is), and
    // the next launch replays recovery.
    Future<void> killAndLaunch() async {
      nb.dispose();
      nb = Notebook(
        PageStore(dir),
        modules,
        saveDelay: const Duration(hours: 1),
        recoveryDirectory: rec,
        folderCheckInterval: Duration.zero,
      );
      await nb.load();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    for (final viaQuit in [false, true]) {
      final how = viaQuit ? 'quit' : 'kill';

      test('1, 4 ($how): the restore stalled, recovery on: the next launch has the page back with its text', () async {
        await tree();
        final text = File(pathOf(parent)).readAsStringSync();
        final old = nb;
        final hold = stallRestore();
        final outcome = startDelete();
        await counting.reachedNew!.future.timeout(const Duration(seconds: 10));
        expect(File(pathOf(parent)).existsSync(), isFalse);
        expect(entryFiles(), hasLength(1), reason: 'the page is in recovery before the restore');
        if (viaQuit) {
          final (asked, go) = await quit();
          expect(asked, isEmpty);
          expect(go, isTrue);
        }
        await killAndLaunch();
        expect(File(pathOf(parent)).readAsStringSync(), text);
        expect((await nb.pendingRecovery()).entries, isEmpty);
        expect(entryFiles(), isEmpty);
        hold.complete();
        await outcome.timeout(const Duration(seconds: 10));
        expect(identical(old, nb), isFalse);
      });

      // The parent has attachments, moved by copying so a hook can stall them.
      void giveAssets(List<int> bytes) {
        final d = Directory('${dir.path}$sep${assetsFolderName(parent)}')..createSync();
        File('${d.path}$sep${contentHash(bytes)}.txt').writeAsBytesSync(bytes);
      }

      Completer<void> stallAt(bool Function(String target) where, Completer<void> reached) {
        final gate = Completer<void>();
        attachmentBeforePublishHook = (target) async {
          if (!where(target)) return;
          attachmentBeforePublishHook = null;
          reached.complete();
          await gate.future;
        };
        addTearDown(() => attachmentBeforePublishHook = null);
        return gate;
      }

      test('1, 4 ($how): the page stuck and the attachment put-back stalled: the next launch has the page', () async {
        Notebook.forcePutBackCannotRenameForTest = true;
        addTearDown(() => Notebook.forcePutBackCannotRenameForTest = false);
        await tree();
        giveAssets([1, 2, 3]);
        final text = File(pathOf(parent)).readAsStringSync();
        counting.failNew.add(parent); // not restored, whatever the stall
        final reached = Completer<void>();
        final gate = stallAt((t) => t.startsWith(dir.path) && !t.contains('deleted-attachments'), reached);
        final outcome = startDelete();
        await reached.future.timeout(const Duration(seconds: 10));
        expect(File(pathOf(parent)).existsSync(), isFalse);
        if (viaQuit) {
          final (asked, go) = await quit();
          expect(asked, isEmpty);
          expect(go, isTrue);
        }
        await killAndLaunch();
        expect(File(pathOf(parent)).readAsStringSync(), text);
        expect((await nb.pendingRecovery()).entries, isEmpty);
        gate.complete();
        await outcome.timeout(const Duration(seconds: 10));
      });

      test('1, 4 ($how): the attachments being handed to recovery: the next launch has the page', () async {
        Notebook.forcePutBackCannotRenameForTest = true;
        addTearDown(() => Notebook.forcePutBackCannotRenameForTest = false);
        await tree();
        giveAssets([1, 2, 3]);
        final text = File(pathOf(parent)).readAsStringSync();
        counting.failNew.add(parent);
        // A file takes the attachments' folder's place, so they can't go back.
        counting.onFailDelete = () => File('${dir.path}$sep${assetsFolderName(parent)}').writeAsBytesSync([9]);
        final reached = Completer<void>();
        final gate = stallAt((t) => t.startsWith(rec.path), reached);
        final outcome = startDelete();
        await reached.future.timeout(const Duration(seconds: 10));
        if (viaQuit) {
          final (asked, go) = await quit();
          expect(asked, isEmpty);
          expect(go, isTrue);
        }
        await killAndLaunch();
        expect(File(pathOf(parent)).readAsStringSync(), text);
        gate.complete();
        await outcome.timeout(const Duration(seconds: 10));
      });
    }

    // A page with boxes [a] (both sides change it), [d] (only the file edits
    // it) and [m] (only the file moves it). The deleted version has its own
    // edit of [a] and a box [onlyP] that overlaps the file's [onlyF].
    late NotedPage fileVersion;
    late String boxA;
    late String boxD;
    late String boxM;
    late String onlyP;
    late String onlyF;

    Future<void> treeWithBoxes({bool ownRecord = true}) async {
      await start();
      parent = nb.currentId!;
      boxA = nb.current!.createBoxAt(const Bounds(10, 10, 0, 0)).id;
      boxD = nb.current!.createBoxAt(const Bounds(10, 100, 0, 0)).id;
      boxM = nb.current!.createBoxAt(const Bounds(10, 200, 0, 0)).id;
      child = await nb.createPage(parentId: parent);
      await nb.createPage();
      await nb.flush();
      counting.failDelete.add(child);
      final orig = onDisk(parent);
      final codec = modules.codecs.codecFor('noted.note')!;
      BoxRecord edited(BoxRecord b, String text) => commitBox(b, codec, codec.decode(doc(text), 1));
      final f = noteBox('only in the file', at: const Bounds(300, 300, 100, 40));
      onlyF = f.id;
      fileVersion = orig
          .replaceNode(edited(orig.node(boxA)! as BoxRecord, 'a in the file'))
          .replaceNode(edited(orig.node(boxD)! as BoxRecord, 'd in the file'))
          .replaceNode((orig.node(boxM)! as BoxRecord).withBounds(const Bounds(500, 200, 100, 40)))
          .insertNode(f);
      // The deleted version.
      await nb.open(parent);
      nb.current!.commit(boxA, codec.decode(doc('a in the deleted version'), 1));
      final p = noteBox('only in the deleted version', at: const Bounds(300, 300, 100, 40));
      onlyP = p.id;
      nb.current!.insertBox(p);
      await nb.flush();
      await nb.createPage();
      await nb.flush();
      if (!ownRecord) return;
      // The deleted version's box a already has a record of its own.
      final p0 = onDisk(parent);
      final older = BoxConflict.other(node: RawJson.encode('an older version'), at: 1);
      File(pathOf(parent)).writeAsStringSync(writePage(p0.replaceNode((p0.node(boxA)! as BoxRecord).withConflict(older))));
    }

    // The file lands as the failing delete runs, and the copy beside it stalls.
    Future<(Future<Object?>, Completer<void>)> landAndStallCopy() async {
      final text = writePage(fileVersion);
      counting.onFailDelete = () => File(pathOf(parent)).writeAsStringSync(text);
      final gate = Completer<void>();
      final reached = Completer<void>();
      nb.syncHook = (point, path) async {
        if (point == 'new-before-publish') return counting.pauseRestore();
        if (point != 'undo-copy-before-publish') return;
        nb.syncHook = null;
        reached.complete();
        await gate.future;
      };
      final outcome = startDelete();
      await reached.future.timeout(const Duration(seconds: 10));
      return (outcome, gate);
    }

    void expectMerged(NotedPage page) {
      expect(page.node(onlyP), isNotNull, reason: 'a box only in the deleted version');
      expect(page.node(onlyF), isNotNull, reason: 'a box only in the file');
      final a = page.node(boxA)! as BoxRecord;
      expect(a.data!.text, contains('a in the file'), reason: 'the file\'s box is displayed');
      final recorded = a.conflicts.where((k) => k.node!.text.contains('a in the deleted version')).toList();
      expect(recorded, hasLength(1), reason: 'the deleted version is recorded once');
      expect(recorded.single.node!.text, isNot(contains('conflicts')), reason: 'without its own conflicts');
      expect(a.conflicts.where((k) => k.node!.text.contains('an older version')), hasLength(1), reason: 'its own record is kept');
      final d = page.node(boxD)! as BoxRecord;
      expect(d.conflicts, isEmpty, reason: 'a descendant in the file stays, nothing recorded');
      expect(d.data!.text, contains('d in the file'));
      expect((page.node(boxM)! as BoxRecord).bounds, const Bounds(500, 200, 100, 40), reason: 'moved only in the file');
      expect(
        page.nodes.whereType<BoxRecord>().where((b) => b.landed != null),
        isEmpty,
        reason: 'independent boxes that overlap get no new landed marker',
      );
    }

    for (final viaQuit in [false, true]) {
      test('5 (${viaQuit ? 'quit' : 'kill'}): a different file landed: the conflict-copy merge keeps both, with no question', () async {
        await treeWithBoxes();
        final (outcome, gate) = await landAndStallCopy();
        if (viaQuit) {
          final (asked, go) = await quit();
          expect(asked, isEmpty);
          expect(go, isTrue);
        }
        await killAndLaunch();
        expectMerged(readPage(File(pathOf(parent)).readAsStringSync()));
        expect((await nb.pendingRecovery()).entries, isEmpty);
        // A merge done again changes nothing: nothing nests.
        final once = File(pathOf(parent)).readAsStringSync();
        await nb.checkFolders();
        expect(File(pathOf(parent)).readAsStringSync(), once);
        gate.complete();
        await outcome.timeout(const Duration(seconds: 10));
      });
    }

    test('7: a different file, the copy published: no entry of ours, the file unchanged', () async {
      await treeWithBoxes();
      final text = writePage(fileVersion);
      counting.onFailDelete = () => File(pathOf(parent)).writeAsStringSync(text);
      final error = await startDelete();
      expect(error, isA<NotebookException>());
      expect(File(pathOf(parent)).readAsStringSync(), text, reason: 'the file is unchanged');
      expect(copies(), hasLength(1));
      expect(entryFiles(), isEmpty, reason: 'the published copy holds this version');
    });

    // The copy, a page file of the same page, is merged as a conflict copy, and
    // the entry its delete left behind is replayed.
    for (final own in [false, true]) {
      test('7b: the copy published, the entry\'s delete fails, then a kill: both are replayed; '
          '${own ? 'a box with its own record has the version twice, one nested, nothing lost' : 'one record, no nesting'}', () async {
        await treeWithBoxes(ownRecord: own);
        final text = writePage(fileVersion);
        counting.onFailDelete = () => File(pathOf(parent)).writeAsStringSync(text);
        var entryDeletes = 0;
        nb.recoveryStoreForTest!.hook = (point) async {
          if (point != 'delete') return;
          entryDeletes++;
          throw const FileSystemException('the delete of the entry failed');
        };
        await startDelete();
        expect(entryDeletes, greaterThan(0), reason: 'the delete of ours was reached');
        expect(copies(), hasLength(1));
        expect(entryFiles(), isNotEmpty, reason: 'its delete failed');
        await killAndLaunch();
        await nb.checkFolders();
        expect(copies(), isEmpty, reason: 'the copy was merged and removed');
        // The merged copy is kept in recovery until its re-check (run
        // 2026-11-16-01); the replayed entry is gone already.
        expect(nb.consumedCopiesForTest, hasLength(1));
        expect(entryFiles(), hasLength(1));
        nb.now = () => DateTime.now().add(const Duration(hours: 1));
        await nb.createPage(); // the page is closed: an open one waits
        await nb.recoverNowForTest();
        expect(entryFiles(), isEmpty, reason: 'the entry was replayed and retired, and the copy\'s after its re-check');
        final merged = readPage(File(pathOf(parent)).readAsStringSync());
        expect(merged.node(onlyP), isNotNull);
        final a = merged.node(boxA)! as BoxRecord;
        final records = a.conflicts.where((k) => k.node!.text.contains('a in the deleted version'));
        final nested = a.conflicts.where((k) => k.node!.text.contains('conflicts'));
        // The normal merge of a copy records the whole box, as it does for
        // every conflict copy; only the recovery merge strips it.
        expect(records, hasLength(own ? 2 : 1));
        expect(nested, hasLength(own ? 1 : 0));
      });
    }

    test('8: a different file and the copy fails: the entry stays, the page is not held, and replay merges it', () async {
      await treeWithBoxes();
      final text = writePage(fileVersion);
      counting.onFailDelete = () => File(pathOf(parent)).writeAsStringSync(text);
      var fired = false;
      nb.syncHook = (point, path) async {
        if (point == 'new-before-publish') return counting.pauseRestore();
        if (point != 'undo-copy-before-publish') return;
        fired = true;
        throw const FileSystemException('no copy');
      };
      final error = await startDelete();
      expect(fired, isTrue);
      expect(error, isA<NotebookException>());
      expect(error, isNot(isA<PagesNotRestoredException>()), reason: 'recovery holds it, nothing is held in memory');
      expect((error! as NotebookException).message, contains('will add it to the file there'));
      expect(entryFiles(), hasLength(1));
      expect(copies(), isEmpty);
      await killAndLaunch();
      expectMerged(readPage(File(pathOf(parent)).readAsStringSync()));
      expect(entryFiles(), isEmpty);
    });

    test('8b: the copy fails and recovery is not there: the page is held, as before', () async {
      await start(withRecovery: false);
      parent = nb.currentId!;
      mine = nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      child = await nb.createPage(parentId: parent);
      await nb.createPage();
      await nb.flush();
      counting.failDelete.add(child);
      final theirs = writePage(
        onDisk(parent).removeNode(mine.id).insertNode(noteBox('theirs', at: const Bounds(400, 10, 200, 40))),
      );
      counting.onFailDelete = () => File(pathOf(parent)).writeAsStringSync(theirs);
      nb.syncHook = (point, path) async {
        if (point == 'undo-copy-before-publish') throw const FileSystemException('no copy');
      };
      final error = await startDelete();
      expect(error, isA<PagesNotRestoredException>());
      expect((error! as NotebookException).message, contains('a copy could not be saved'));
    });

    test('13: the copy beside a different file threw: the version is in the file after replay', () async {
      await treeWithBoxes();
      final text = writePage(fileVersion);
      counting.onFailDelete = () => File(pathOf(parent)).writeAsStringSync(text);
      nb.syncHook = (point, path) async {
        if (point == 'new-before-publish') return counting.pauseRestore();
        if (point == 'undo-copy-before-publish') throw StateError('the copy threw');
      };
      final error = await startDelete();
      expect(error, isA<NotebookException>());
      expect(error, isNot(isA<PagesNotRestoredException>()));
      expect((error! as NotebookException).message, contains('will add it to the file there'));
      expect((error as NotebookException).message, isNot(contains('will write it back')));
      await killAndLaunch();
      expectMerged(readPage(File(pathOf(parent)).readAsStringSync()));
    });

    // An older entry for the page, with a box of its own, as the user was asked about.
    Future<RecoveryEntry> olderEntry(BoxRecord box) async {
      final text = File(pathOf(parent)).readAsStringSync();
      final a = await RecoveryStore(rec).write(
        folder: dir.path,
        page: readPage(text).insertNode(box),
        baseText: text,
        time: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      await nb.refreshRecoveryIndexForTest();
      nb.questioner = (q, title) async => true; // delete them with the page
      return a;
    }

    test('6: an older entry A and a deleted version B that differ: both survive a kill, and A is untouched meanwhile', () async {
      await tree();
      final aBox = noteBox('only in the older entry', at: const Bounds(400, 10, 200, 40));
      final a = await olderEntry(aBox);
      final aBytes = a.file.readAsBytesSync();
      final hold = stallRestore();
      final outcome = startDelete();
      await counting.reachedNew!.future.timeout(const Duration(seconds: 10));
      expect(entryFiles(), hasLength(2), reason: 'ours is beside A');
      expect(a.file.readAsBytesSync(), aBytes, reason: 'A was untouched');
      await killAndLaunch();
      final page = readPage(File(pathOf(parent)).readAsStringSync());
      expect(page.node(aBox.id), isNotNull, reason: 'a box of A');
      expect(page.node(mine.id), isNotNull, reason: 'a box of the deleted version');
      expect(nb.recoveryDamaged, isEmpty, reason: 'no "can\'t be read" row');
      expect(entryFiles(), isEmpty);
      hold.complete();
      await outcome.timeout(const Duration(seconds: 10));
    });

    test('6b: a normal rollback leaves an older entry exactly as it was and removes its own', () async {
      await tree();
      final text = File(pathOf(parent)).readAsStringSync();
      final a = await olderEntry(noteBox('only in the older entry', at: const Bounds(400, 10, 200, 40)));
      final aBytes = a.file.readAsBytesSync();
      final error = await startDelete();
      expect(error, isNotNull);
      expect(File(pathOf(parent)).readAsStringSync(), text);
      expect(entryFiles().map((f) => f.path), [a.file.path]);
      expect(a.file.readAsBytesSync(), aBytes);
    });

    test('6c: a verify that fails after the write: a restored page leaves no entry behind', () async {
      await tree();
      var verifies = 0;
      nb.recoveryStoreForTest!.hook = (point) async {
        if (point != 'verify') return;
        if (++verifies == 1) throw const FileSystemException('read-back failed');
      };
      final error = await startDelete();
      expect(error, isNotNull);
      expect(verifies, greaterThan(0));
      expect(entryFiles(), isEmpty, reason: 'written, not verified, and still removed once the page is back');
    });

    test('6d: a verify that fails once and a page that is stuck: it is read again, not written twice, and recovery holds it', () async {
      await tree();
      counting.failNew.add(parent);
      var verifies = 0;
      nb.recoveryStoreForTest!.hook = (point) async {
        if (point != 'verify') return;
        if (++verifies == 1) throw const FileSystemException('read-back failed');
      };
      final error = await startDelete();
      expect(error, isA<NotebookException>());
      expect(error, isNot(isA<PagesNotRestoredException>()));
      expect(entryFiles(), hasLength(1), reason: 'one entry, read again');
      await killAndLaunch();
      expect(File(pathOf(parent)).existsSync(), isTrue);
    });

    test('12: another writer on top of the restored page: the entry goes and what they wrote stands', () async {
      await treeWithBoxes();
      // Right after the restore publishes, a sync client lands a version in
      // which box a is deleted and box d edited.
      final theirs = writePage(fileVersion.removeNode(boxA));
      counting.afterNewText = () => File(pathOf(parent)).writeAsStringSync(theirs);
      final error = await startDelete();
      expect(error, isNotNull);
      expect(File(pathOf(parent)).readAsStringSync(), theirs, reason: 'their file stands');
      expect(entryFiles(), isEmpty, reason: 'the entry went: merging it again would bring box a back');
      await killAndLaunch();
      expect(File(pathOf(parent)).readAsStringSync(), theirs);
    });

    test('12b: the read after the restore fails: the entry stays, and a later replay merges to nothing', () async {
      await tree();
      final text = File(pathOf(parent)).readAsStringSync();
      counting.afterNewText = () => counting.failReadOnce = true;
      final error = await startDelete();
      expect(error, isNotNull);
      expect(entryFiles(), hasLength(1));
      await killAndLaunch();
      expect(File(pathOf(parent)).readAsStringSync(), text);
      expect(entryFiles(), isEmpty, reason: 'the entry is retired at the next start');
    });

    test('11: the delete of the entry fails: marked landed for the session, retried at quit', () async {
      await tree();
      final text = File(pathOf(parent)).readAsStringSync();
      final store = nb.recoveryStoreForTest!;
      store.hook = (point) async {
        if (point == 'delete') throw const FileSystemException('delete failed');
      };
      final error = await startDelete();
      expect(error, isNotNull);
      expect(File(pathOf(parent)).readAsStringSync(), text);
      expect(entryFiles(), hasLength(1), reason: 'the entry could not be deleted');
      expect((await nb.pendingRecovery()).entries, isEmpty, reason: 'it is marked landed, so nothing waits');
      store.hook = null;
      expect(await nb.prepareToExit(limit: const Duration(seconds: 3)), isTrue);
      expect(entryFiles(), isEmpty, reason: 'retried at quit');
    });

    test('11b: the delete of the entry fails and the app restarts: the entry merges to nothing and retires', () async {
      await tree();
      final text = File(pathOf(parent)).readAsStringSync();
      nb.recoveryStoreForTest!.hook = (point) async {
        if (point == 'delete') throw const FileSystemException('delete failed');
      };
      await startDelete();
      expect(entryFiles(), hasLength(1));
      await killAndLaunch();
      expect(File(pathOf(parent)).readAsStringSync(), text);
      expect(entryFiles(), isEmpty);
    });

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    test('2: a page recovery holds is written back by the backoff, without a relaunch', () async {
      await tree(backoff: const Duration(milliseconds: 100));
      final text = File(pathOf(parent)).readAsStringSync();
      counting.failNew.add(parent);
      final error = await startDelete();
      expect(error, isNotNull);
      expect(File(pathOf(parent)).existsSync(), isFalse);
      expect(entryFiles(), hasLength(1));
      counting.failNew.clear();
      counting.failDelete.clear();
      await until(() => File(pathOf(parent)).existsSync() && entryFiles().isEmpty);
      expect(File(pathOf(parent)).readAsStringSync(), text);
      expect(entryFiles(), isEmpty);
    });

    test('12c: the read after the restore fails: the backoff settles the entry, without a relaunch', () async {
      await tree(backoff: const Duration(milliseconds: 100));
      final text = File(pathOf(parent)).readAsStringSync();
      counting.afterNewText = () => counting.failReadOnce = true;
      await startDelete();
      counting.failDelete.clear();
      await until(() => entryFiles().isEmpty);
      expect(entryFiles(), isEmpty);
      expect(File(pathOf(parent)).readAsStringSync(), text);
    });

    test('3: the app is disposed during the restore and the restore is let go: the entry is still on disk', () async {
      await tree();
      final hold = stallRestore();
      final outcome = startDelete();
      await counting.reachedNew!.future.timeout(const Duration(seconds: 10));
      expect(entryFiles(), hasLength(1));
      nb.dispose();
      nb = Notebook(PageStore(dir), modules, saveDelay: const Duration(hours: 1), folderCheckInterval: Duration.zero);
      hold.complete();
      await outcome.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(entryFiles(), hasLength(1), reason: 'a notebook that is gone deletes nothing; the next start settles it');
    });

    test('4: quit without recovery, the put-back stalled: asks and names the page, staying keeps it', () async {
      Notebook.forcePutBackCannotRenameForTest = true;
      addTearDown(() => Notebook.forcePutBackCannotRenameForTest = false);
      await start(withRecovery: false);
      parent = nb.currentId!;
      await nb.rename(parent, 'Rollback parent');
      child = await nb.createPage(parentId: parent);
      await nb.createPage();
      await nb.flush();
      counting.failDelete.add(child);
      final bytes = [1, 2, 3];
      final d = Directory('${dir.path}$sep${assetsFolderName(parent)}')..createSync();
      File('${d.path}$sep${contentHash(bytes)}.txt').writeAsBytesSync(bytes);
      counting.failNew.add(parent);
      final gate = Completer<void>();
      final reached = Completer<void>();
      attachmentBeforePublishHook = (target) async {
        if (!target.startsWith(dir.path) || target.contains('deleted-attachments')) return;
        attachmentBeforePublishHook = null;
        reached.complete();
        await gate.future;
      };
      addTearDown(() => attachmentBeforePublishHook = null);
      final outcome = startDelete();
      await reached.future.timeout(const Duration(seconds: 10));
      final asked = <(UserQuestion, String)>[];
      nb.questioner = (q, title) async {
        asked.add((q, title));
        return false; // stay
      };
      expect(await nb.prepareToExit(limit: const Duration(milliseconds: 300)), isFalse);
      expect(asked, [(UserQuestion.leaveAndLose, 'Rollback parent')]);
      gate.complete();
      final error = await outcome.timeout(const Duration(seconds: 10));
      expect(error, isA<PagesNotRestoredException>(), reason: 'the page is held, not lost');
    });

    test('7: the preview of an entry with no base over a file shows what replay would land', () async {
      await treeWithBoxes();
      final deleted = onDisk(parent);
      final e = await RecoveryStore(rec).write(folder: dir.path, page: deleted, baseText: null, time: DateTime.now());
      File(pathOf(parent)).writeAsStringSync(writePage(fileVersion));
      await nb.refreshRecoveryIndexForTest();
      nb.syncHook = (point, path) async {
        if (point == 'recover-before-publish') throw const FileSystemException('replay fails');
      };
      await nb.open(parent);
      expect(nb.current!.readOnly, isTrue, reason: 'a preview: the entry is still waiting');
      final want = mergeConflictCopy(
        fileVersion,
        deleted,
        modules.codecs,
        copyTime: e.time.millisecondsSinceEpoch,
        topOfChain: fileVersion.meta.parentId == null,
        forRecovery: true,
      ).page;
      expect(writePage(nb.current!.page), writePage(want));
    });
  });
}

// A recovery lock that can be made to fail and come back.
class _SwitchLock extends RecoveryLock {
  _SwitchLock(super.file);

  bool broken = false;

  @override
  bool check() => !broken;

  @override
  bool ensure() => !broken;

  @override
  String get problem => 'another window holds the recovery folder';
}
