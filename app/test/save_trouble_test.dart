// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/notebook.dart' show Notebook;
import 'package:noted/src/recovery_store.dart';
import 'package:noted/src/save_trouble.dart';
import 'package:noted/src/storage_check.dart';
import 'package:noted_core/noted_core.dart';

FileSystemException _err(int code) =>
    FileSystemException('x', 'p', OSError('msg', code));

void main() {
  group('busy file errors', () {
    test(
      'Windows sharing and lock violations are busy; access denied is not',
      () {
        expect(isBusyError(_err(32), os: 'windows'), isTrue);
        expect(isBusyError(_err(33), os: 'windows'), isTrue);
        expect(isBusyError(_err(5), os: 'windows'), isFalse);
        expect(isBusyError(_err(2), os: 'windows'), isFalse);
      },
    );

    test('POSIX EAGAIN and EBUSY are busy', () {
      expect(isBusyError(_err(11), os: 'linux'), isTrue);
      expect(isBusyError(_err(16), os: 'linux'), isTrue);
      expect(isBusyError(_err(35), os: 'macos'), isTrue);
      expect(
        isBusyError(_err(35), os: 'linux'),
        isFalse,
        reason: '35 is EDEADLK on Linux',
      );
      expect(isBusyError(_err(13), os: 'linux'), isFalse);
      expect(isBusyError(StateError('x')), isFalse);
    });
  });

  group('the backoff', () {
    test('doubles from the first wait up to the longest, and starts over after a reset', () async {
      var ticks = 0;
      final b = SaveBackoff(
        first: const Duration(milliseconds: 20),
        max: const Duration(milliseconds: 80),
        onTick: () => ticks++,
      );
      addTearDown(b.dispose);
      expect(b.delay, isNull);
      final seen = <Duration>[];
      for (var i = 0; i < 5; i++) {
        b.schedule();
        seen.add(b.delay!);
        final before = ticks;
        while (ticks == before) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
      expect(seen, [
        const Duration(milliseconds: 20),
        const Duration(milliseconds: 40),
        const Duration(milliseconds: 80),
        const Duration(milliseconds: 80),
        const Duration(milliseconds: 80),
      ]);
      b.reset();
      expect(b.delay, isNull);
      b.schedule();
      expect(b.delay, const Duration(milliseconds: 20));
    });

    test('a second schedule while one is waiting changes nothing', () {
      final b = SaveBackoff(first: const Duration(seconds: 5), onTick: () {});
      addTearDown(b.dispose);
      b.schedule();
      b.schedule();
      expect(b.delay, const Duration(seconds: 5));
    });
  });

  group('the save chain', () {
    test('runs jobs in order', () async {
      final c = SaveChain();
      final order = <int>[];
      unawaited(
        c.run(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          order.add(1);
        }),
      );
      unawaited(c.run(() async => order.add(2)));
      await c.idle;
      await c.run(() async {});
      expect(order, [1, 2]);
      expect(c.isIdle, isTrue);
    });

    test('a failing job fails its caller and not the chain', () async {
      final c = SaveChain();
      await expectLater(
        c.run<void>(() async => throw StateError('x')),
        throwsStateError,
      );
      expect(await c.run(() async => 7), 7);
    });

    test('detach frees what waited for the old chain, runs later jobs on a new one, and reports the old pages', () async {
      final c = SaveChain();
      final gate = Completer<void>();
      final ended = <Set<String>>[];
      c.onDetachedJobEnded = ended.add;
      final hung = c.run(() => gate.future, pages: {'a'});
      final behind = c.run(() async {}, pages: {'c'});
      var idleDone = false;
      unawaited(
        c.idle.then((_) => idleDone = true),
      ); // captured before the detach
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(idleDone, isFalse);
      final pages = c.detach();
      expect(pages, {'a': 1, 'c': 1});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        idleDone,
        isTrue,
        reason: 'a waiter that captured idle before the detach is released',
      );
      var ran = false;
      await c.run(() async => ran = true).timeout(const Duration(seconds: 2));
      expect(ran, isTrue, reason: 'a later job does not wait for the hung one');
      gate.complete();
      await hung;
      await behind;
      expect(ended.expand((s) => s).toSet(), {'a', 'c'});
    });
  });

  group('storage causes by error code', () {
    test('per platform', () {
      expect(
        classifyErrorCode(_err(112), os: 'windows'),
        StorageCauseKind.diskFull,
      );
      expect(
        classifyErrorCode(_err(5), os: 'windows'),
        StorageCauseKind.notWritable,
      );
      expect(
        classifyErrorCode(_err(32), os: 'windows'),
        StorageCauseKind.notWritable,
      );
      expect(
        classifyErrorCode(_err(21), os: 'windows'),
        StorageCauseKind.driveFailing,
      );
      expect(
        classifyErrorCode(_err(28), os: 'linux'),
        StorageCauseKind.diskFull,
      );
      expect(
        classifyErrorCode(_err(13), os: 'linux'),
        StorageCauseKind.notWritable,
      );
      expect(
        classifyErrorCode(_err(1), os: 'linux'),
        StorageCauseKind.notWritable,
      );
      expect(
        classifyErrorCode(_err(30), os: 'macos'),
        StorageCauseKind.notWritable,
      );
      expect(
        classifyErrorCode(_err(5), os: 'linux'),
        StorageCauseKind.driveFailing,
        reason: 'EIO',
      );
      expect(classifyErrorCode(_err(99), os: 'linux'), isNull);
    });

    test('a folder that cannot be written gets the access advice; other errors the OS message', () async {
      final dir = Directory.systemTemp.createTempSync('noted_check');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/blocked').writeAsStringSync('x');
      final c = await checkStorage(
        _err(5),
        recoveryDirectory: Directory('${dir.path}/blocked'),
        os: 'linux',
      );
      expect(c.kind, StorageCauseKind.driveFailing);
      final w = await checkStorage(
        FileSystemException('x', 'p', const OSError('Something odd', 99)),
        recoveryDirectory: Directory('${dir.path}/blocked'),
        os: 'linux',
      );
      expect(
        w.kind,
        StorageCauseKind.notWritable,
        reason: 'a file where the folder should be',
      );
      final ok = await checkStorage(
        FileSystemException('x', 'p', const OSError('Something odd', 99)),
        recoveryDirectory: Directory('${dir.path}/fine'),
        os: 'linux',
      );
      expect(ok.kind, StorageCauseKind.other);
      expect(ok.summary, contains('Something odd'));
      expect(ok.advice, saveCopyAdvice);
    });
  });

  group('verifyRecoveredPage', () {
    BoxRecord box(String id, String data) => BoxRecord.create(
      id: id,
      typeId: 'x.unregistered',
      dataVersion: 1,
      bounds: const Bounds(0, 0, 10, 10),
      data: RawJson.trusted(data),
      snapshotText: 's',
      rev: 'r',
    );
    final empty = NotedPage.create(
      PageMeta.create(id: 'p1', title: 'T', order: 0),
    );

    test('a box the edits deleted, which the file still had unchanged, may be gone', () {
      final a = box('a', '{"n":1}');
      final base = empty.insertNode(a);
      expect(
        verifyRecoveredPage(
          base: base,
          mine: empty,
          theirs: base,
          result: empty,
        ),
        isNull,
      );
    });

    test('a box the edits deleted but the file changed since must stay', () {
      final base = empty.insertNode(box('a', '{"n":1}'));
      final theirs = empty.insertNode(box('a', '{"n":2}'));
      expect(
        verifyRecoveredPage(
          base: base,
          mine: empty,
          theirs: theirs,
          result: empty,
        ),
        contains('box a'),
      );
    });

    test('a box of the file that the edits never had is still required', () {
      final theirs = empty.insertNode(box('b', '{"n":1}'));
      expect(
        verifyRecoveredPage(
          base: empty,
          mine: empty,
          theirs: theirs,
          result: empty,
        ),
        contains('box b'),
      );
    });
  });

  group('what an entry already holds', () {
    BoxRecord box(String data) => BoxRecord.create(
      id: 'a',
      typeId: 'x.unregistered',
      dataVersion: 1,
      bounds: const Bounds(0, 0, 10, 10),
      data: RawJson.trusted(data),
      snapshotText: 's',
      rev: 'r$data',
    );
    final empty = NotedPage.create(PageMeta.create(id: 'p1', title: 'T', order: 0));

    test('a box with the same content is already in; one with more conflict versions is not', () {
      final eb = empty;
      final ep = empty.insertNode(box('{"n":1}'));
      expect(Notebook.editsInForTest(eb, ep, ep), isTrue);
      final withConflict = (ep.node('a')! as BoxRecord).withConflict(
        BoxConflict.other(node: const RawJson.trusted('{"id":"a"}'), at: 5),
      );
      expect(
        Notebook.editsInForTest(eb, ep, empty.insertNode(withConflict)),
        isFalse,
        reason: 'extra conflict versions are merged, not skipped',
      );
    });

    test('a reorder is in only when the closed writer has the same order', () {
      BoxRecord named(String id) => BoxRecord.create(
        id: id,
        typeId: 'x.unregistered',
        dataVersion: 1,
        bounds: const Bounds(0, 0, 10, 10),
        data: const RawJson.trusted('{}'),
        snapshotText: 's',
        rev: 'r',
      );
      final eb = empty.insertNode(named('a')).insertNode(named('b'));
      final ep = empty.insertNode(named('b')).insertNode(named('a'));
      expect(Notebook.editsInForTest(eb, ep, eb), isFalse, reason: 'the closed writer still has the old order');
      expect(Notebook.editsInForTest(eb, ep, ep), isTrue, reason: 'the closed writer already has the new order');
      expect(
        Notebook.editsInForTest(eb, ep, eb.removeNode('a')),
        isFalse,
        reason: 'the closed writer deleted a box the entry kept and reordered',
      );
    });

    test('a write of a snapshot that Discard threw away is never safe', () {
      expect(KeepOutcome.discarded.safe, isFalse);
      expect(KeepOutcome.dropped.safe, isTrue);
      expect(KeepOutcome.kept.safe, isTrue);
    });
  });

  group('the recovery store', () {
    late Directory dir;
    late RecoveryStore store;
    NotedPage page(String title) =>
        NotedPage.create(PageMeta.create(id: 'p1', title: title, order: 0));

    setUp(() {
      dir = Directory.systemTemp.createTempSync('noted_rs');
      store = RecoveryStore(Directory('${dir.path}/recovery'));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('write refuses to replace a slot whose content is not a generation the writer may replace', () async {
      final first = await store.write(
        folder: '${dir.path}/pages',
        page: page('one'),
        baseText: null,
        time: DateTime.now(),
      );
      await expectLater(
        store.write(
          folder: '${dir.path}/pages',
          page: page('two'),
          baseText: null,
          time: DateTime.now(),
          replaceable: {'some-other-generation'},
        ),
        throwsA(isA<RecoveryRefused>()),
      );
      expect(first.file.readAsStringSync(), contains('one'));
      final second = await store.write(
        folder: '${dir.path}/pages',
        page: page('two'),
        baseText: null,
        time: DateTime.now(),
        replaceable: {first.gen},
      );
      expect(second.file.path, first.file.path);
      expect(second.file.readAsStringSync(), contains('two'));
    });

    test('the index follows writes, deletes and listings', () async {
      expect(store.indexed, isFalse);
      final e = await store.write(
        folder: '${dir.path}/pages',
        page: page('one'),
        baseText: null,
        time: DateTime.now(),
      );
      expect(store.entriesFor('${dir.path}/pages', 'p1').map((x) => x.gen), [
        e.gen,
      ]);
      expect(store.entriesOfPage('p1'), hasLength(1));
      store.markLanded(e.gen);
      expect(store.landedEntries, hasLength(1));
      await store.delete(e);
      expect(store.indexEntries, isEmpty);
      expect(store.isLanded(e.gen), isFalse);
      await store.write(
        folder: '${dir.path}/pages',
        page: page('two'),
        baseText: null,
        time: DateTime.now(),
      );
      final listing = await store.list();
      expect(listing.entries, hasLength(1));
      expect(store.indexed, isTrue);
      expect(store.indexEntries.single.gen, listing.entries.single.gen);
    });

    test('a generation is named by its time, base and page, and survives a listing', () async {
      final t = DateTime.now();
      final e = await store.write(
        folder: '${dir.path}/pages',
        page: page('one'),
        baseText: null,
        time: t,
      );
      expect(
        e.gen,
        RecoveryStore.generationOf('${dir.path}/pages', t, null, writePage(page('one'))),
      );
      final listed = (await store.list()).entries.single;
      expect(listed.gen, e.gen);
    });

    test('a transaction that hangs fails its caller after the limit; later ones fail at once until it ends', () async {
      store.transactionLimit = const Duration(milliseconds: 100);
      final gate = Completer<void>();
      final hung = store.transaction((tx) => gate.future);
      await expectLater(hung, throwsA(isA<RecoveryTimeout>()));
      expect(store.hasAbandonedJob, isTrue);
      // Nothing else may change the folder under the abandoned job.
      await expectLater(store.transaction((tx) async => 5), throwsA(isA<RecoveryTimeout>()));
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(store.hasAbandonedJob, isFalse);
      expect(await store.transaction((tx) async => 5), 5);
    });

    test('an abandoned write does not publish over a slot that changed since it chose it', () async {
      final folder = '${dir.path}/pages';
      final first = await store.write(folder: folder, page: page('one'), baseText: null, time: DateTime.now());
      final release = Completer<void>();
      var hang = true;
      store.hook = (point) async {
        if (point == 'tmp-written' && hang) {
          hang = false;
          await release.future;
        }
      };
      store.transactionLimit = const Duration(milliseconds: 100);
      final late = store.write(
        folder: folder,
        page: page('two'),
        baseText: null,
        time: DateTime.now(),
        replaceable: {first.gen},
      );
      await expectLater(late, throwsA(isA<RecoveryTimeout>()));
      // A newer entry takes the slot meanwhile (put there from outside).
      final other = RecoveryStore(Directory('${dir.path}/other'));
      final newer = await other.write(folder: folder, page: page('three'), baseText: null, time: DateTime.now());
      first.file.writeAsStringSync(newer.file.readAsStringSync());
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(first.file.readAsStringSync(), contains('three'), reason: 'the late rename did not happen');
      expect(
        Directory('${dir.path}/recovery').listSync().where((f) => f.path.endsWith('.tmp')),
        isEmpty,
        reason: 'and its temporary file is gone',
      );
    });

    test('an abandoned delete does not delete', () async {
      final e = await store.write(folder: '${dir.path}/pages', page: page('one'), baseText: null, time: DateTime.now());
      final release = Completer<void>();
      store.hook = (point) async {
        if (point == 'delete') await release.future;
      };
      store.transactionLimit = const Duration(milliseconds: 100);
      await expectLater(store.delete(e), throwsA(isA<RecoveryTimeout>()));
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(e.file.existsSync(), isTrue);
    });
    test('transactions run one after another', () async {
      final order = <int>[];
      final a = store.transaction((tx) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        order.add(1);
      });
      final b = store.transaction((tx) async => order.add(2));
      await Future.wait([a, b]);
      expect(order, [1, 2]);
    });
  });
}
