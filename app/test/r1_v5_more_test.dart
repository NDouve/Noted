// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// R-1 v5, part two: the recovery lock, a locked page file, ordering of
// snapshots, and replays that hang (runs/designs/2026-11-05-r1-v5.md).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_lock.dart';
import 'package:noted/src/save_trouble.dart';
import 'package:noted_core/noted_core.dart';

import 'support/lock_holder_process.dart';
import 'support/trouble_world.dart';

void main() {
  late TroubleWorld w;

  setUp(() async {
    w = TroubleWorld();
    await w.init();
  });

  tearDown(() => w.dispose());

  group('one process owns recovery (3.1)', () {
    test('a lock held by another process is "already open"; once it lets go the lock is taken', () async {
      final file = File('${w.root.path}/app/recovery.lock');
      final holder = await LockHolder.hold(file);
      addTearDown(holder.release);
      final lock = RecoveryLock(file);
      expect(
        lock.acquireSync(tries: 3, gap: const Duration(milliseconds: 20)),
        RecoveryLockResult.heldByOther,
      );
      expect(lock.held, isFalse);
      await holder.release();
      expect(
        lock.acquireSync(tries: 3, gap: const Duration(milliseconds: 20)),
        RecoveryLockResult.acquired,
      );
      expect(lock.held, isTrue);
      expect(lock.check(), isTrue);
      expect(file.lengthSync(), 0, reason: 'zero bytes, never deleted');
    });

    test('a file that cannot be opened is a lock problem, not "already open"', () async {
      final file = File('${w.root.path}/ro/recovery.lock')..createSync(recursive: true);
      if (Platform.isWindows) {
        Process.runSync('attrib', ['+R', file.path]);
        addTearDown(() => Process.runSync('attrib', ['-R', file.path]));
      } else {
        Process.runSync('chmod', ['444', file.path]);
        addTearDown(() => Process.runSync('chmod', ['644', file.path]));
        if (Process.runSync('id', ['-u']).stdout.toString().trim() == '0') return; // root opens it anyway
      }
      final lock = RecoveryLock(file);
      expect(lock.acquireSync(tries: 2, gap: const Duration(milliseconds: 5)), RecoveryLockResult.failed);
      expect(lock.held, isFalse);
      expect(lock.problem, contains("Noted can't use its recovery folder"));
    });

    test('degraded mode still reads the folder, so a page with kept changes opens as a preview', () async {
      File('${w.root.path}/blocker').writeAsStringSync('x');
      final nb0 = w.make();
      final id = await w.editedPage(nb0);
      w.storeFor(w.pages).failWith = accessDenied();
      await nb0.flush();
      w.crash(nb0);
      expect(w.recFiles(), hasLength(1));
      w.storeFor(w.pages).failWith = null;
      final lock = RecoveryLock(File('${w.root.path}/blocker/recovery.lock'));
      lock.acquireSync(tries: 1);
      final nb = w.make(lock: lock);
      await nb.load();
      await nb.open(id);
      expect(nb.trouble.kind, TroubleKind.preview, reason: 'the index was built by reading');
      expect(w.recFiles(), hasLength(1), reason: 'nothing was written, deleted or replayed');
    });

    test('Discard kept changes deletes nothing while the lock is not held', () async {
      File('${w.root.path}/blocker').writeAsStringSync('x');
      final nb0 = w.make();
      final id = await w.editedPage(nb0);
      w.storeFor(w.pages).failWith = accessDenied();
      await nb0.flush();
      w.crash(nb0);
      w.storeFor(w.pages).failWith = null;
      w.pageFile(id).writeAsStringSync('this is not a page');
      final lock = RecoveryLock(File('${w.root.path}/blocker/recovery.lock'));
      lock.acquireSync(tries: 1);
      final nb = w.make(lock: lock);
      await nb.load();
      await nb.open(id);
      expect(nb.trouble.canDiscardKept, isTrue);
      nb.questioner = (q, t) async => true;
      await expectLater(nb.discardKept(), throwsA(isA<NotebookException>()));
      expect(w.recFiles(), hasLength(1), reason: 'nothing was deleted without the lock');
    });

    test('a lock that cannot be taken for another reason leaves pages editable and refuses recovery into state 4', () async {
      // The lock file's parent is a file: it can never be opened.
      File('${w.root.path}/blocker').writeAsStringSync('x');
      final lock = RecoveryLock(File('${w.root.path}/blocker/recovery.lock'));
      expect(
        lock.acquireSync(tries: 2, gap: const Duration(milliseconds: 5)),
        RecoveryLockResult.failed,
      );
      final nb = w.make(lock: lock);
      final id = await w.editedPage(nb);
      expect(
        nb.current!.readOnly,
        isFalse,
        reason: 'opening a page never needs the lock',
      );
      w.storeFor(w.pages).failWith = accessDenied();
      await nb.flush();
      expect(nb.trouble.kind, TroubleKind.recoveryFailing);
      expect(
        nb.trouble.reason,
        contains("Noted can't use its recovery folder"),
      );
      expect(w.recFiles(), isEmpty, reason: 'nothing was written');
      expect(nb.currentId, id);
    });

    test('a lock taken late lets the next Retry keep the edits', () async {
      final dir = Directory('${w.root.path}/lockdir')..createSync();
      final blocker = File('${dir.path}/sub');
      blocker.writeAsStringSync('x');
      final lock = RecoveryLock(File('${blocker.path}/recovery.lock'));
      lock.acquireSync(tries: 1);
      final nb = w.make(lock: lock);
      await w.editedPage(nb);
      w.storeFor(w.pages).failWith = accessDenied();
      await nb.flush();
      expect(nb.trouble.kind, TroubleKind.recoveryFailing);
      // The obstacle goes away, and a Retry takes the lock.
      blocker.deleteSync();
      await nb.retrySave();
      expect(lock.held, isTrue);
      expect(nb.trouble.kind, TroubleKind.failing);
      expect(w.recFiles(), hasLength(1));
    });

    test('multi-page deletes are refused while the lock is not held (build note 2)', () async {
      File('${w.root.path}/blocker').writeAsStringSync('x');
      final lock = RecoveryLock(File('${w.root.path}/blocker/recovery.lock'));
      lock.acquireSync(tries: 1);
      final nb = w.make(lock: lock);
      await nb.load();
      final parent = nb.currentId!;
      await nb.createPage(parentId: parent);
      await expectLater(
        nb.delete(parent),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            "Noted can't keep a backup right now.",
          ),
        ),
      );
      expect(w.pageFile(parent).existsSync(), isTrue);
    });
  });

  group('a locked page file is busy, not unreadable', () {
    final skip = Platform.isWindows
        ? null
        : 'byte-range locks only block reads on Windows';

    test('a lock released within the window never makes the page read-only, and the save lands', () async {
      final nb = w.make(busyWindow: const Duration(seconds: 4));
      final id = await w.editedPage(nb);
      final reasons = <String?>[];
      nb.addListener(() => reasons.add(nb.readOnlyReason));
      final raf = w.pageFile(id).openSync(mode: FileMode.append)
        ..lockSync(FileLock.exclusive);
      try {
        unawaited(nb.flush());
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(nb.readOnlyReason, isNull, reason: 'still busy, quietly');
      } finally {
        raf.unlockSync();
        raf.closeSync();
      }
      await nb.flush();
      expect(reasons.whereType<String>(), isEmpty);
      expect(nb.readOnlyReason, isNull);
      expect(readPage(w.pageFile(id).readAsStringSync()).nodes, hasLength(1));
      expect(nb.trouble.isTrouble, isFalse);
    }, skip: skip);

    test('a file still locked after the window blocks the page, and it clears when the lock goes', () async {
      final nb = w.make(busyWindow: const Duration(milliseconds: 300));
      final id = await w.editedPage(nb);
      final raf = w.pageFile(id).openSync(mode: FileMode.append)
        ..lockSync(FileLock.exclusive);
      try {
        await nb.flush();
        expect(nb.readOnlyReason, contains("couldn't be read"));
      } finally {
        raf.unlockSync();
        raf.closeSync();
      }
      await nb.checkFolders(); // the periodic look at a blocked page
      expect(nb.readOnlyReason, isNull);
    }, skip: skip);
  });

  group('snapshots of a page are ordered', () {
    test('a stalled save, more typing, a leave: the leave entry holds the newest; the old save lands and keeps it', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      await nb.addStandaloneFolder(w.other.path); // (this saves the first box)
      nb.current!.createBoxAt(const Bounds(60, 60, 0, 0)); // a2
      final store = w.storeFor(w.pages)
        ..stall = Completer<void>()
        ..stallId = id;
      unawaited(nb.flush()); // the save of a2 stalls
      await until(
        () => store.attempts > 0 && w.storeFor(w.pages).stall != null,
        what: 'the save to start',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      nb.current!.createBoxAt(const Bounds(120, 40, 0, 0)); // a3
      nb.current!.createBoxAt(const Bounds(200, 40, 0, 0)); // a4
      final other = await nb.createPage(folderPath: w.other.path);
      expect(nb.currentId, other);
      expect(w.recFiles(), hasLength(1));
      final kept = (await nb.pendingRecovery()).entries.single;
      expect(
        kept.page.nodes,
        hasLength(4),
        reason: 'the leave entry holds the newest snapshot',
      );
      // The stalled save and the leave's own save (queued behind it) land in
      // order; the retire of the older one keeps the newer generation until
      // the newer one has landed too. Nothing is lost.
      store.stall!.complete();
      await until(() => !nb.isBusy(id), what: 'the page to be free');
      await until(() => w.recFiles().isEmpty, what: 'the entry to be retired');
      expect(readPage(w.pageFile(id).readAsStringSync()).nodes, hasLength(4));
      await nb.open(id);
      expect(boxCount(nb.current!.page), 4);
      expect(nb.trouble.isTrouble, isFalse);
    });

    test('an edit typed while the leave waits on a stalled save is saved or kept, even when the next page is edited', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      await nb.addStandaloneFolder(w.other.path);
      final old = nb.current!;
      old.createBoxAt(const Bounds(60, 60, 0, 0));
      final store = w.storeFor(w.pages)
        ..stall = Completer<void>()
        ..stallId = id;
      unawaited(nb.flush());
      await until(() => store.attempts > 0, what: 'the save to start');
      final leaving = nb.createPage(folderPath: w.other.path);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      try {
        old.createBoxAt(const Bounds(120, 40, 0, 0)); // typed after the leave began
      } on StateError {
        // frozen for the departure: nothing was accepted
      }
      await leaving;
      final other = nb.currentId!;
      expect(other, isNot(id));
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0)); // replaces the shared pending save
      final accepted = boxCount(old.page);
      store.stall!.complete();
      await until(() => !nb.isBusy(id), what: 'the page to be free');
      w.crash(nb);
      final nb2 = w.make();
      await nb2.load();
      await nb2.open(id);
      expect(boxCount(nb2.current!.page), accepted, reason: 'every accepted edit survives a reload');
    });

    test('a stalled save that fails afterwards is dropped: it does not replace the newer entry', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      await nb.addStandaloneFolder(w.other.path);
      nb.current!.createBoxAt(const Bounds(60, 60, 0, 0));
      final store = w.storeFor(w.pages)
        ..stall = Completer<void>()
        ..stallId = id
        ..failWith = accessDenied();
      unawaited(nb.flush());
      await until(() => store.attempts > 0, what: 'the save to start');
      nb.current!.createBoxAt(const Bounds(120, 40, 0, 0));
      await nb.createPage(folderPath: w.other.path);
      final entry = w.recFiles().single.readAsStringSync();
      store.stall!.complete();
      await until(() => !nb.isBusy(id), what: 'the page to be free');
      expect(w.recFiles().single.readAsStringSync(), entry);
    });
  });

  group('old sessions and unreadable files (pre-merge)', () {
    test('a check that waited on the old chain before the detach completes after it', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      await nb.addStandaloneFolder(w.other.path);
      nb.current!.createBoxAt(const Bounds(60, 60, 0, 0));
      final store = w.storeFor(w.pages)
        ..stall = Completer<void>()
        ..stallId = id;
      unawaited(nb.flush());
      await until(() => store.attempts > 0, what: 'the save to start');
      final check = nb.checkFile(w.pageFile(id).path); // waits for the hung save
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await nb.createPage(folderPath: w.other.path); // the leave cuts the save
      await check.timeout(const Duration(seconds: 3));
      store.stall!.complete();
    });

    test('a late failure of an old session changes nothing in the preview that replaced it', () async {
      final nb = w.make();
      final id = await w.editedPage(nb);
      await nb.addStandaloneFolder(w.other.path);
      nb.current!.createBoxAt(const Bounds(60, 60, 0, 0));
      final store = w.storeFor(w.pages)
        ..stall = Completer<void>()
        ..stallId = id
        ..failWith = accessDenied();
      unawaited(nb.flush());
      await until(() => store.attempts > 0, what: 'the save to start');
      await nb.createPage(folderPath: w.other.path);
      await nb.open(id);
      expect(nb.trouble.kind, TroubleKind.preview);
      final entry = w.recFiles().single.readAsStringSync();
      final shown = nb.trouble;
      store.stall!.complete(); // the old save fails now, in a session that is over
      await until(() => !nb.isBusy(id), what: 'the old job to end');
      expect(w.recFiles().single.readAsStringSync(), entry);
      expect(nb.trouble.kind, TroubleKind.preview);
      expect(nb.currentId, id);
      expect(nb.trouble.pageId, shown.pageId);
      store.failWith = null;
      await nb.retryPreview();
      expect(nb.trouble.isTrouble, isFalse);
      expect(boxCount(nb.current!.page), 2);
    });

    for (final (name, text) in [
      ('from a newer version of Noted', null),
      ('not a page at all', 'this is not a page'),
    ]) {
      test('a page file that is $name opens a preview from the kept changes, which cannot land', () async {
        final nb = w.make();
        final id = await w.editedPage(nb);
        w.storeFor(w.pages).failWith = accessDenied();
        await nb.flush();
        await nb.createPage();
        w.storeFor(w.pages).failWith = null;
        final file = w.pageFile(id);
        file.writeAsStringSync(
          text ?? file.readAsStringSync().replaceFirst(RegExp(r'"format"\s*:\s*\d+'), '"format":99'),
        );
        await nb.open(id);
        expect(nb.trouble.kind, TroubleKind.preview);
        expect(nb.trouble.canDiscardKept, isTrue);
        expect(boxCount(nb.current!.page), 1, reason: 'the kept box is shown');
        expect(nb.current!.readOnly, isTrue);
        expect(w.recFiles(), hasLength(1), reason: 'nothing is replayed or deleted');
        // Discard kept changes asks, then deletes only that generation.
        nb.questioner = (q, t) async => true;
        await nb.discardKept();
        expect(w.recFiles(), isEmpty);
        expect(nb.trouble.isTrouble, isFalse);
      });
    }
  });
  group('a replay that hangs', () {
    test('does not hold recovery: leaving another page still keeps its entry within the bound', () async {
      final nb = w.make(
        backoffFirst: const Duration(milliseconds: 20),
        backoffMax: const Duration(milliseconds: 20),
      );
      final a = await w.editedPage(nb);
      await nb.addStandaloneFolder(w.other.path);
      nb.current!.createBoxAt(const Bounds(70, 70, 0, 0));
      w.storeFor(w.pages).failWith = accessDenied();
      await nb.flush();
      // B in another folder; A is closed with its entry.
      final b = await nb.createPage(folderPath: w.other.path);
      expect(nb.currentId, b);
      // A's replay publishes into a hung drive.
      final store = w.storeFor(w.pages)
        ..failWith = null
        ..stall = Completer<void>()
        ..stallId = a;
      await until(() => nb.isBusy(a), what: 'the replay to start');
      // B fails to save and is left within the bound, with its entry kept.
      nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      w.storeFor(w.other).failWith = accessDenied();
      final s = Stopwatch()..start();
      await nb.createPage(folderPath: w.other.path);
      expect(s.elapsed, lessThan(const Duration(seconds: 5)));
      expect(w.recFiles(), hasLength(2));
      w.storeFor(w.other).failWith = null;
      store.stall!.complete();
    });
  });
}
