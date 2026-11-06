// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('noted_locks'));
  tearDown(() async => dir.delete(recursive: true));

  group('FolderLocks.keyOf', () {
    test('a trailing separator makes no difference', () {
      final sep = Platform.pathSeparator;
      expect(FolderLocks.keyOf(Directory('${dir.path}$sep')), FolderLocks.keyOf(dir));
    });

    test('case makes no difference on Windows', () {
      expect(FolderLocks.keyOf(Directory(dir.path.toUpperCase())), FolderLocks.keyOf(dir));
    }, skip: Platform.isWindows ? false : 'case-sensitive file systems');

    test('a symbolic link to the folder has the same key', () {
      final link = Link(
        '${dir.parent.path}${Platform.pathSeparator}'
        'noted_locks_link_${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        link.createSync(dir.path);
      } on FileSystemException {
        markTestSkipped('cannot create a symbolic link here');
        return;
      }
      addTearDown(() => link.deleteSync());
      expect(FolderLocks.keyOf(Directory(link.path)), FolderLocks.keyOf(dir));
    });

    test('a folder that is still missing has a stable key', () {
      final missing = Directory('${dir.path}${Platform.pathSeparator}nope');
      final k = FolderLocks.keyOf(missing);
      expect(k, FolderLocks.keyOf(Directory('${missing.path}${Platform.pathSeparator}')));
      expect(k, isNot(FolderLocks.keyOf(dir)));
    });
  });

  group('FolderLocks.run', () {
    test('one key serialises', () async {
      final locks = FolderLocks();
      final log = <String>[];
      final gate = Completer<void>();
      final a = locks.run(dir, () async {
        log.add('a start');
        await gate.future;
        log.add('a end');
      });
      final b = locks.run(dir, () async => log.add('b'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(log, ['a start']);
      gate.complete();
      await Future.wait([a, b]);
      expect(log, ['a start', 'a end', 'b']);
    });

    test('different keys run concurrently', () async {
      final locks = FolderLocks();
      final other = await dir.createTemp('other');
      final gate = Completer<void>();
      var bRan = false;
      final a = locks.run(dir, () => gate.future);
      await locks.run(other, () async => bRan = true);
      expect(bRan, isTrue);
      gate.complete();
      await a;
    });

    test('a failing job does not block the next', () async {
      final locks = FolderLocks();
      final a = locks.run<void>(dir, () async => throw StateError('x'));
      final b = locks.run(dir, () async => 5);
      await expectLater(a, throwsStateError);
      expect(await b, 5);
    });

    test('the map empties when idle', () async {
      final locks = FolderLocks();
      await locks.run(dir, () async {});
      await Future<void>.delayed(Duration.zero);
      expect(locks.busyCount, 0);
      final a = locks.run(dir, () async {});
      expect(locks.busyCount, 1);
      await a;
      await Future<void>.delayed(Duration.zero);
      expect(locks.busyCount, 0);
    });

    test('a nested, un-awaited run on the same key queues behind the job', () async {
      final locks = FolderLocks();
      final log = <String>[];
      late Future<void> inner;
      await locks.run(dir, () async {
        inner = locks.run(dir, () async => log.add('inner'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        log.add('outer end');
      });
      await inner;
      expect(log, ['outer end', 'inner']);
    });

    test('isHeld is true inside a job on that folder only', () async {
      final locks = FolderLocks();
      final other = await dir.createTemp('other');
      expect(FolderLocks.isHeld(dir), isFalse);
      await locks.run(dir, () async {
        expect(FolderLocks.isHeld(dir), isTrue);
        expect(FolderLocks.isHeld(other), isFalse);
      });
      expect(FolderLocks.isHeld(dir), isFalse);
    });
  });
}
