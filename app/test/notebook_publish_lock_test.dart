// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_lock.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted/src/save_trouble.dart';
import 'package:noted_core/noted_core.dart';

import 'support/busy_retry.dart';

/// A store whose delete and new-page publish can be intercepted.
class HookedStore extends PageStore {
  HookedStore(super.directory);

  /// Runs at the start of every delete; may throw.
  void Function()? onDelete;

  /// Runs at the start of every saveNew; true makes it report a taken name.
  bool Function()? onSaveNew;

  @override
  Future<DeleteResult> deleteIfUnchanged(
    String pageId,
    String expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    Future<void> Function()? beforeDelete,
    void Function()? beforeRestore,
  }) {
    onDelete?.call();
    return super.deleteIfUnchanged(pageId, expectedText);
  }

  /// Makes every saveNewText fail while set.
  bool failNewText = false;

  @override
  Future<bool> saveNewText(
    NotedPage page,
    String text, {
    Future<void> Function()? beforePublish,
  }) async {
    if (failNewText) throw const FileSystemException('destination gone');
    return super.saveNewText(page, text, beforePublish: beforePublish);
  }

  @override
  Future<bool> saveNew(
    NotedPage page, {
    Future<void> Function()? beforePublish,
  }) async {
    if (onSaveNew?.call() ?? false) return false;
    return super.saveNew(page, beforePublish: beforePublish);
  }
}

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 50));

/// Waits until [ok] holds, polling; fails the test after [limit] rather than hanging.
Future<void> until(bool Function() ok, {Duration limit = const Duration(seconds: 10)}) async {
  final clock = Stopwatch()..start();
  while (!ok()) {
    if (clock.elapsed > limit) fail('the condition did not hold within $limit');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory root;
  late Directory pages;
  late Notebook nb;
  late FolderLocks locks;
  late List<LocalChange> events;
  late HookedStore store;
  late Directory copiesDir;
  final sep = Platform.pathSeparator;

  final stores = <String, HookedStore>{};

  // (Re)builds the notebook; [rec] turns recovery on.
  Future<void> build({Directory? rec}) async {
    nb.dispose();
    stores.clear();
    store = HookedStore(pages);
    stores[FolderLocks.keyOf(pages)] = store;
    locks = FolderLocks();
    nb = Notebook(
      store,
      buildModules(),
      saveDelay: const Duration(hours: 1),
      folderLocks: locks,
      recoveryDirectory: rec,
      storeFactory: (d) =>
          stores.putIfAbsent(FolderLocks.keyOf(d), () => HookedStore(d)),
      pickFolder: () async => copiesDir.path,
      templatesDirectory: Directory('${root.path}${sep}templates'),
    );
    events = [];
    await nb.load();
    nb.localChanges.listen(events.add);
    await pump();
    events.clear();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_publock');
    pages = await Directory('${root.path}${sep}pages').create();
    copiesDir = await Directory('${root.path}${sep}Copies').create();
    store = HookedStore(pages);
    nb = Notebook(store, buildModules());
    await build();
  });

  tearDown(() async {
    nb.dispose();
    await busyRetry(() => root.delete(recursive: true));
  });

  String pagePath(String id, [Directory? d]) =>
      '${(d ?? pages).path}$sep$id.canvas';

  test(
    'createPage waits for the folder lock before it publishes or emits',
    () async {
      final gate = Completer<void>();
      final held = locks.run(pages, () => gate.future);
      final before = pages.listSync().length;
      var done = false;
      final create = nb.createPage().whenComplete(() => done = true);
      await pump();
      expect(done, isFalse);
      expect(pages.listSync().length, before);
      expect(events, isEmpty);
      gate.complete();
      await held;
      final id = await create.timeout(const Duration(seconds: 10));
      await pump();
      expect(File(pagePath(id)).existsSync(), isTrue);
      expect(events.where((e) => e.path == pagePath(id)), hasLength(1));
    },
  );

  test(
    'undo of a delete (the _writeNew path) waits for the folder lock',
    () async {
      final first = nb.currentId!;
      await nb.createPage();
      final deleted = await nb.delete(first);
      await pump();
      events.clear();
      final gate = Completer<void>();
      final held = locks.run(pages, () => gate.future);
      var done = false;
      final undo = nb.undoDelete(deleted).whenComplete(() => done = true);
      await pump();
      expect(done, isFalse);
      expect(File(pagePath(first)).existsSync(), isFalse);
      expect(events, isEmpty);
      gate.complete();
      await held;
      await undo.timeout(const Duration(seconds: 10));
      await pump();
      expect(File(pagePath(first)).existsSync(), isTrue);
      expect(
        events.where(
          (e) =>
              e.path == pagePath(first) && e.kind == LocalChangeKind.published,
        ),
        hasLength(1),
      );
    },
  );

  test('a binder made from a template publishes its pages only under the folder lock', () async {
    final src = await Directory('${root.path}${sep}Src').create();
    final section = await nb.addBinder(src.path);
    await nb.createPage(binderPath: section.path);
    await nb.flush();
    final template = await nb.saveBinderAsTemplate(section.path, name: 'B');
    final target = await Directory('${root.path}${sep}FromTemplate').create();
    await pump();
    events.clear();
    final gate = Completer<void>();
    final held = locks.run(target, () => gate.future);
    var done = false;
    final made = nb
        .createBinderFromTemplate(template, target.path)
        .whenComplete(() => done = true);
    await pump();
    expect(done, isFalse);
    expect(target.listSync().where((e) => e.path.endsWith('.canvas')), isEmpty);
    expect(events.where((e) => e.path.endsWith('.canvas')), isEmpty);
    gate.complete();
    await held;
    await made.timeout(const Duration(seconds: 10));
    await pump();
    expect(
      target.listSync().where((e) => e.path.endsWith('.canvas')),
      isNotEmpty,
    );
    expect(events.where((e) => e.path.endsWith('.canvas')), isNotEmpty);
  });

  test(
    'an undo that meets a newer file (conflict copy merge) does not deadlock',
    () async {
      final first = nb.currentId!;
      await nb.createPage();
      final deleted = await nb.delete(first);
      File(pagePath(first)).writeAsStringSync(
        writePage(
          NotedPage.create(
            PageMeta.create(id: first, title: 'Newer', order: 0),
          ),
        ),
      );
      try {
        await nb.undoDelete(deleted).timeout(const Duration(seconds: 20));
      } on TimeoutException {
        fail('undoDelete hung');
      } on Object {
        // The outcome is told as an error or not; only a hang fails.
      }
      expect(locks.busyCount, 0);
    },
  );

  test('a move between folders does not deadlock', () async {
    final other = await Directory('${root.path}${sep}Other').create();
    final section = await nb.addBinder(other.path);
    final id = await nb.createPage();
    await nb.flush();
    final moved = nb.moveToLocation(id, binderPath: section.path);
    await moved.timeout(const Duration(seconds: 20));
    expect(File(pagePath(id, other)).existsSync(), isTrue);
    expect(File(pagePath(id)).existsSync(), isFalse);
    expect(locks.busyCount, 0);
  });

  test('a location that goes away while a new page waits for the lock: nothing is published', () async {
    final gate = Completer<void>();
    final held = locks.run(pages, () => gate.future);
    Object? error;
    final create = nb.createPage().then<void>(
      (_) {},
      onError: (Object e) => error = e,
    );
    await pump();
    pages.deleteSync(recursive: true);
    gate.complete();
    await held;
    await create.timeout(const Duration(seconds: 10));
    expect(error, isA<FolderUnavailableException>());
    expect(pages.existsSync(), isFalse);
    expect(events, isEmpty);
  });

  /// Deletes a page with a child so that the second delete fails and the
  /// first is put back by a rollback; the lock is held from the failing
  /// delete on. Returns the delete, the gate and the page being put back.
  Future<(Future<Object?>, Completer<void>, Future<void>, String)>
  rollbackHeld({String? binderPath, Directory? dir}) async {
    final s = dir == null ? store : stores[FolderLocks.keyOf(dir)]!;
    final parent = binderPath == null
        ? nb.currentId!
        : await nb.createPage(binderPath: binderPath);
    await nb.createPage(parentId: parent);
    if (binderPath == null) await nb.createPage(); // the open page is neither
    await nb.flush();
    await pump();
    final gate = Completer<void>();
    late Future<void> held;
    var calls = 0;
    s.onDelete = () {
      if (++calls == 1) return;
      held = locks.run(
        dir ?? pages,
        () => gate.future,
      ); // queued behind this delete
      throw const FileSystemException('delete failed');
    };
    events.clear();
    final result = nb
        .delete(parent)
        .then<Object?>((_) => null, onError: (Object e) => e);
    // Wait until the failing delete has queued the gate.
    for (var i = 0; i < 100 && calls < 2; i++) {
      await pump();
    }
    expect(calls, 2);
    await pump();
    return (result, gate, held, parent);
  }

  test(
    'a delete rollback (the _restoreText path) waits for the folder lock',
    () async {
      final (result, gate, held, _) = await rollbackHeld();
      // The first page is deleted and its rollback is waiting.
      final gone = pages
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.canvas'))
          .length;
      final deletedEvents = events
          .where((e) => e.kind == LocalChangeKind.deleted)
          .length;
      expect(deletedEvents, 1);
      expect(events.where((e) => e.kind == LocalChangeKind.published), isEmpty);
      gate.complete();
      await held;
      expect(
        await result.timeout(const Duration(seconds: 10)),
        isNotNull,
        reason: 'the delete failed',
      );
      await pump();
      expect(
        pages
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.canvas'))
            .length,
        gone + 1,
      );
      expect(
        events.where((e) => e.kind == LocalChangeKind.published),
        hasLength(1),
      );
    },
  );

  test('Save a copy into a joined folder waits for the folder lock', () async {
    await nb.addStandaloneFolder(copiesDir.path);
    await pump();
    events.clear();
    final gate = Completer<void>();
    final held = locks.run(copiesDir, () => gate.future);
    var done = false;
    final save = nb.saveCopyElsewhere().whenComplete(() => done = true);
    await pump();
    expect(done, isFalse);
    expect(
      copiesDir.listSync().where((e) => e.path.endsWith('.canvas')),
      isEmpty,
    );
    expect(events, isEmpty);
    gate.complete();
    await held;
    expect(
      await save.timeout(const Duration(seconds: 10)),
      startsWith('Saved a copy'),
    );
    expect(
      copiesDir.listSync().where((e) => e.path.endsWith('.canvas')),
      hasLength(1),
    );
    expect(
      events.where((e) => e.kind == LocalChangeKind.published),
      hasLength(1),
    );
  });

  test(
    'a conflict copy published by an undo waits for the folder lock',
    () async {
      final first = nb.currentId!;
      await nb.createPage();
      final deleted = await nb.delete(first);
      File(pagePath(first)).writeAsStringSync(
        writePage(
          NotedPage.create(
            PageMeta.create(id: first, title: 'Newer', order: 0),
          ),
        ),
      );
      await pump();
      events.clear();
      final gate = Completer<void>();
      late Future<void> held;
      final reached = Completer<void>();
      nb.syncHook = (point, path) async {
        if (point == 'undo-copy-before-publish') {
          held = locks.run(pages, () => gate.future);
          reached.complete();
        }
      };
      var done = false;
      final undo = nb
          .undoDelete(deleted)
          .then<void>((_) {}, onError: (_) {})
          .whenComplete(() => done = true);
      // The temp write takes as long as it takes on a loaded machine.
      await reached.future.timeout(const Duration(seconds: 20));
      await pump();
      await pump();
      expect(done, isFalse);
      bool copyThere() => pages.listSync().any(
        (e) => e.path.contains('-undo-') && !e.path.endsWith('.tmp'),
      );
      expect(copyThere(), isFalse);
      expect(events.where((e) => e.path.contains('-undo-')), isEmpty);
      gate.complete();
      await held;
      await undo.timeout(const Duration(seconds: 10));
      await pump();
      expect(
        events.where(
          (e) =>
              e.path.contains('-undo-') && e.kind == LocalChangeKind.published,
        ),
        isNotEmpty,
      );
    },
  );

  test('the rollback of a failed binder creation deletes its pages under the folder lock', () async {
    final src = await Directory('${root.path}${sep}Src').create();
    final section = await nb.addBinder(src.path);
    await nb.createPage(binderPath: section.path);
    await nb.createPage(binderPath: section.path);
    await nb.flush();
    final template = await nb.saveBinderAsTemplate(section.path, name: 'B');
    final target = await Directory('${root.path}${sep}Made').create();
    await pump();
    final gate = Completer<void>();
    late Future<void> held;
    var calls = 0;
    final targetStore = HookedStore(target);
    // The second page is refused; the gate is queued behind that job.
    targetStore.onSaveNew = () {
      if (++calls < 2) return false;
      held = locks.run(target, () => gate.future);
      return true;
    };
    final nb2 = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: const Duration(hours: 1),
      folderLocks: locks,
      storeFactory: (d) => d.path == target.path ? targetStore : PageStore(d),
      templatesDirectory: Directory('${root.path}${sep}templates'),
    );
    final evs = <LocalChange>[];
    nb2.localChanges.listen(evs.add);
    await nb2.load();
    evs.clear();
    final made = nb2
        .createBinderFromTemplate(template, target.path)
        .then<Object?>((_) => null, onError: (Object e) => e);
    for (var i = 0; i < 100 && calls < 2; i++) {
      await pump();
    }
    await pump();
    List<FileSystemEntity> canvases() =>
        target.listSync().where((e) => e.path.endsWith('.canvas')).toList();
    expect(
      canvases(),
      hasLength(1),
      reason: 'the first page waits to be removed',
    );
    expect(
      evs.where(
        (e) => e.kind == LocalChangeKind.deleted && e.path.endsWith('.canvas'),
      ),
      isEmpty,
    );
    gate.complete();
    await held;
    expect(await made.timeout(const Duration(seconds: 10)), isNotNull);
    await pump();
    expect(canvases(), isEmpty);
    expect(
      evs.where(
        (e) => e.kind == LocalChangeKind.deleted && e.path.endsWith('.canvas'),
      ),
      hasLength(1),
    );
    nb2.dispose();
  });

  List<FileSystemEntity> published(Directory d, {String? containing}) => d
      .listSync()
      .where(
        (e) =>
            e.path.endsWith('.canvas') &&
            (containing == null || e.path.contains(containing)),
      )
      .toList();

  // A notebook started from scratch on the same folders (the next launch): its
  // own folder locks, and it replays what recovery holds when it loads.
  Future<Notebook> launch(Directory rec) async {
    final n = Notebook(
      HookedStore(pages),
      buildModules(),
      saveDelay: const Duration(hours: 1),
      folderLocks: FolderLocks(),
      recoveryDirectory: rec,
      storeFactory: (d) => HookedStore(d),
      templatesDirectory: Directory('${root.path}${sep}templates'),
    );
    await n.load();
    await pump();
    return n;
  }

  test('quit during a delete rollback stalled at the folder lock, with recovery: nothing is asked, and the next launch has the page', () async {
    final rec = Directory('${root.path}${sep}rec');
    await build(rec: rec);
    final parentText = File(pagePath(nb.currentId!)).readAsStringSync();
    final (result, gate, held, parent) = await rollbackHeld();
    expect(File(pagePath(parent)).existsSync(), isFalse);
    final asked = <UserQuestion>[];
    nb.questioner = (q, title) async {
      asked.add(q);
      return false; // stay
    };
    final stay = await nb.prepareToExit(limit: const Duration(milliseconds: 300));
    expect(asked, isEmpty);
    expect(stay, isTrue, reason: 'recovery holds the page, so quit goes on');
    expect(published(pages, containing: '-undo-'), isEmpty);
    // The app is gone without the rollback having finished.
    nb.dispose();
    nb = await launch(rec);
    expect(File(pagePath(parent)).readAsStringSync(), parentText);
    expect((await nb.pendingRecovery()).entries, isEmpty);
  });

  test('quit during a delete rollback that waits for the folder lock, without recovery: asks, names the page, and keeps it', () async {
    await nb.rename(nb.currentId!, 'Rollback parent');
    final (result, gate, held, parent) = await rollbackHeld();
    expect(File(pagePath(parent)).existsSync(), isFalse);
    final asked = <(UserQuestion, String)>[];
    nb.questioner = (q, title) async {
      asked.add((q, title));
      return false; // stay
    };
    final stay = await nb.prepareToExit(limit: const Duration(milliseconds: 300));
    expect(stay, isFalse);
    expect(asked.map((a) => a.$1), [UserQuestion.leaveAndLose]);
    expect(asked.single.$2, 'Rollback parent');
    expect(published(pages, containing: '-undo-'), isEmpty);
    gate.complete();
    await held;
    expect(await result.timeout(const Duration(seconds: 10)), isNotNull);
    await pump();
    expect(File(pagePath(parent)).existsSync(), isTrue);
    expect(published(pages, containing: '-undo-'), isEmpty);
  });

  test('quit during a delete rollback stalled before its page is recorded: asks and names it, staying keeps it', () async {
    await build(rec: Directory('${root.path}${sep}rec'));
    final keepGate = Completer<void>();
    var fired = false;
    nb.syncHook = (point, path) async {
      if (point != 'delete-rollback-keep') return;
      fired = true;
      await keepGate.future;
    };
    final (result, gate, held, parent) = await rollbackHeld();
    expect(fired, isTrue, reason: 'the hook point was reached');
    final asked = <UserQuestion>[];
    nb.questioner = (q, title) async {
      asked.add(q);
      return false; // stay
    };
    final stay = await nb.prepareToExit(limit: const Duration(milliseconds: 300));
    expect(stay, isFalse);
    expect(asked, [UserQuestion.leaveAndLose]);
    keepGate.complete();
    gate.complete();
    await held;
    expect(await result.timeout(const Duration(seconds: 10)), isNotNull);
    await pump();
    expect(File(pagePath(parent)).existsSync(), isTrue);
  });

  test('a quit already waiting is not released until the page that recovery could not keep is held and copied', () async {
    final (result, gate, held, parent) = await rollbackHeld();
    store.failNewText = true; // the restore will fail, and there is no recovery
    nb.questioner = (q, title) async => false;
    var quitDone = false;
    final quit = nb.prepareToExit(limit: const Duration(seconds: 20)).whenComplete(() => quitDone = true);
    await pump();
    expect(quitDone, isFalse);
    gate.complete();
    await held;
    expect(await result.timeout(const Duration(seconds: 10)), isA<PagesNotRestoredException>());
    store.failNewText = false;
    expect(await quit.timeout(const Duration(seconds: 10)), isTrue);
    expect(published(pages, containing: '-undo-'), hasLength(1), reason: 'the held page was written beside its place');
    expect(File(pagePath(parent)).existsSync(), isFalse);
  });

  test('a rollback that succeeds leaves no recovery entry and no notice, and the file holds the deleted text', () async {
    final rec = Directory('${root.path}${sep}rec');
    await build(rec: rec);
    final parentText = File(pagePath(nb.currentId!)).readAsStringSync();
    final (result, gate, held, parent) = await rollbackHeld();
    gate.complete();
    await held;
    final error = await result.timeout(const Duration(seconds: 10));
    expect(error, isNotNull, reason: 'the delete failed');
    expect(error, isNot(isA<PagesNotRestoredException>()));
    await pump();
    expect(File(pagePath(parent)).readAsStringSync(), parentText);
    expect((await nb.pendingRecovery()).entries, isEmpty);
    expect(rec.existsSync() ? rec.listSync().where((e) => e.path.endsWith('.entry')) : [], isEmpty);
  });

  test('an entry another instance wrote for the page, behind the index, is left on disk by a rollback', () async {
    final rec = Directory('${root.path}${sep}rec');
    // A lock that is lost and taken again at every check: the notebook then
    // lists the recovery folder before its next merging write.
    nb.dispose();
    stores.clear();
    store = HookedStore(pages);
    stores[FolderLocks.keyOf(pages)] = store;
    locks = FolderLocks();
    nb = Notebook(
      store,
      buildModules(),
      saveDelay: const Duration(hours: 1),
      folderLocks: locks,
      recoveryDirectory: rec,
      recoveryLock: _LateLock(File('${root.path}${sep}recovery.lock')),
      storeFactory: (d) => stores.putIfAbsent(FolderLocks.keyOf(d), () => HookedStore(d)),
      pickFolder: () async => copiesDir.path,
      templatesDirectory: Directory('${root.path}${sep}templates'),
    );
    await nb.load();
    await pump();
    final parent = nb.currentId!;
    final disk = readPage(File(pagePath(parent)).readAsStringSync());
    final theirBox = BoxRecord.create(
      id: 'theirbox',
      typeId: 'test.other',
      dataVersion: 1,
      bounds: const Bounds(0, 0, 10, 10),
      data: RawJson.encode('x'),
      snapshotText: 's',
      rev: 'r1',
    );
    // Another instance's edit for the page: on disk, but not in the index.
    final theirs = await RecoveryStore(rec).write(
      folder: pages.path,
      page: disk.insertNode(theirBox),
      baseText: writePage(disk),
      time: DateTime.now(),
    );
    final (result, gate, held, _) = await rollbackHeld();
    gate.complete();
    await held;
    await result.timeout(const Duration(seconds: 10));
    await pump();
    expect(File(pagePath(parent)).existsSync(), isTrue);
    expect(theirs.file.existsSync(), isTrue, reason: 'their entry is not ours to delete');
    final entries = rec.listSync().where((e) => e.path.endsWith('.entry')).toList();
    expect(entries, hasLength(1), reason: 'the rollback left nothing of its own');
  });

  test('a binder removed while a new page waits for the lock: nothing is published', () async {
    final src = await Directory('${root.path}${sep}Src').create();
    final section = await nb.addBinder(src.path);
    await pump();
    events.clear();
    final gate = Completer<void>();
    final held = locks.run(src, () => gate.future);
    Object? error;
    final create = nb
        .createPage(binderPath: section.path)
        .then<void>((_) {}, onError: (Object e) => error = e);
    await pump();
    await nb.removeBinder(section.path).timeout(const Duration(seconds: 10));
    events.clear();
    gate.complete();
    await held;
    await create.timeout(const Duration(seconds: 10));
    expect(error, isA<NotebookException>());
    expect(published(src), isEmpty);
    expect(events.where((e) => e.path.endsWith('.canvas')), isEmpty);
  });

  test('a binder removed while a delete rollback waits for the lock: the restore publishes nothing', () async {
    await build(rec: Directory('${root.path}${sep}rec'));
    final src = await Directory('${root.path}${sep}Src').create();
    final section = await nb.addBinder(src.path);
    final (result, gate, held, parent) = await rollbackHeld(
      binderPath: section.path,
      dir: src,
    );
    await nb.removeBinder(section.path).timeout(const Duration(seconds: 10));
    events.clear();
    gate.complete();
    await held;
    await result.timeout(const Duration(seconds: 10));
    await pump();
    expect(File(pagePath(parent, src)).existsSync(), isFalse);
    expect(
      events.where(
        (e) =>
            e.kind == LocalChangeKind.published &&
            e.path.endsWith('$parent.canvas'),
      ),
      isEmpty,
    );
  });

  test('quit with held pages and a stalled folder lock: stay, then the copy is published once on release', () async {
    final parent = nb.currentId!;
    await nb.createPage(parentId: parent);
    await nb.createPage();
    await nb.flush();
    await pump();
    var calls = 0;
    store.onDelete = () {
      if (++calls > 1) throw const FileSystemException('delete failed');
    };
    store.failNewText = true;
    Object? error;
    try {
      await nb.delete(parent);
    } on Object catch (e) {
      error = e;
    }
    expect(error, isA<PagesNotRestoredException>());
    store.onDelete = null;
    store.failNewText = false;
    await pump();
    events.clear();
    final gate = Completer<void>();
    var copyHeld = 0; // calls that reached the lock with a finished .tmp
    nb.syncHook = (point, path) async {
      if (point == 'undo-copy-before-publish') copyHeld++;
    };
    final held = locks.run(pages, () => gate.future);
    nb.questioner = (q, title) async => false; // stay
    final stay = await nb.prepareToExit(
      limit: const Duration(milliseconds: 300),
    );
    expect(stay, isFalse);
    await until(() => copyHeld >= 1); // the copy is waiting at the lock
    expect(published(pages, containing: '-undo-'), isEmpty);
    gate.complete();
    await held;
    // The copy is written after the release (real IO); wait for it and its event.
    bool eventSeen() => events.any((e) => e.kind == LocalChangeKind.published && e.path.contains('-undo-'));
    await until(() => published(pages, containing: '-undo-').isNotEmpty && eventSeen());
    expect(pages.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
    expect(copyHeld, 1, reason: 'one copy, made once');
    expect(published(pages, containing: '-undo-'), hasLength(1));
    expect(
      events.where(
        (e) => e.kind == LocalChangeKind.published && e.path.contains('-undo-'),
      ),
      hasLength(1),
    );
  });
}

/// A recovery lock that is never held and is always taken again: the notebook
/// must list the recovery folder before its next merging write.
class _LateLock extends RecoveryLock {
  _LateLock(super.file);

  @override
  bool check() => false;

  @override
  bool ensure() => true;
}
