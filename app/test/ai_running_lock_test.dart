// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/ai/ai_running_lock.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('noted_running'));
  tearDown(() => dir.deleteSync(recursive: true));

  File lockFile() => File('${dir.path}/$aiRunningLockFileName');

  // Another handle taking the lock; null if it is held. OS locks between
  // handles of one process conflict on Windows only.
  RandomAccessFile? probe() {
    final f = lockFile().openSync(mode: FileMode.append);
    try {
      f.lockSync(FileLock.exclusive);
      return f;
    } on FileSystemException {
      f.closeSync();
      return null;
    }
  }

  test('the file name is the one noted_mcp uses', () {
    expect(aiRunningLockFileName, 'noted-running.lock');
  });

  test('the lock is held until released, and the file is created', () {
    final lock = AiRunningLock(dir);
    expect(lock.acquire(), isTrue);
    expect(lock.held, isTrue);
    expect(lockFile().existsSync(), isTrue);
    if (Platform.isWindows) expect(probe(), isNull, reason: 'held while the app runs');
    lock.release();
    expect(lock.held, isFalse);
    final p = probe();
    expect(p, isNotNull, reason: 'released');
    p!.closeSync();
    lock.release(); // again: harmless
    lock.dispose();
  });

  test('a holder that lets go is waited for, a holder that keeps it is not taken over', () async {
    if (!Platform.isWindows) return; // in-process locks only conflict on Windows
    final other = probe()!;
    final lock = AiRunningLock(dir);
    addTearDown(lock.dispose);
    expect(lock.acquire(tries: 2, pause: const Duration(milliseconds: 20)), isFalse);
    expect(lock.held, isFalse);
    final before = lockFile().lengthSync();
    expect(before, 0, reason: 'a failed attempt never writes to the file');

    // It retries in the background and takes it once the other lets go.
    var told = 0;
    lock.addListener(() => told++);
    lock.startRetrying(every: const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(lock.held, isFalse);
    other.unlockSync();
    other.closeSync();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(lock.held, isTrue);
    expect(told, 1);
  });

  test('a folder that is missing is created; one that cannot be used just means not held', () {
    final lock = AiRunningLock(Directory('${dir.path}/new/sub'));
    addTearDown(lock.dispose);
    expect(lock.acquire(), isTrue);
    final blocker = File('${dir.path}/file')..writeAsStringSync('x');
    final bad = AiRunningLock(Directory(blocker.path));
    addTearDown(bad.dispose);
    expect(bad.acquire(tries: 2, pause: const Duration(milliseconds: 10)), isFalse);
  });

  group('the app', () {
    late Notebook nb;

    testWidgets('shows a warning while the lock is not held, and drops it once it is', (t) async {
      late AiRunningLock lock;
      await t.runAsync(() async {
        nb = Notebook(
          PageStore(Directory('${dir.path}/pages')..createSync()),
          buildModules(),
          saveDelay: Duration.zero,
        );
        await nb.load();
        lock = AiRunningLock(dir);
      });
      addTearDown(() async {
        lock.dispose();
        nb.dispose();
      });
      await t.pumpWidget(NotedApp(notebook: nb, runningLock: lock));
      await t.pump();
      expect(find.byKey(const ValueKey('ai-running-lock-message')), findsOneWidget);
      expect(find.text(AiRunningLockBanner.message), findsOneWidget);

      await t.runAsync(() async => lock.acquire());
      await t.pump();
      expect(lock.held, isTrue);
      expect(find.byKey(const ValueKey('ai-running-lock-message')), findsNothing);
    });

    testWidgets('no warning without a lock object (tests, other platforms)', (t) async {
      await t.runAsync(() async {
        nb = Notebook(
          PageStore(Directory('${dir.path}/pages2')..createSync()),
          buildModules(),
          saveDelay: Duration.zero,
        );
        await nb.load();
      });
      addTearDown(nb.dispose);
      await t.pumpWidget(NotedApp(notebook: nb));
      await t.pump();
      expect(find.byKey(const ValueKey('ai-running-lock-message')), findsNothing);
    });
  });
}
