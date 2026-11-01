// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/ai/ai_running_lock.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('noted_running'));
  tearDown(() => dir.deleteSync(recursive: true));

  // Whether another handle can take the lock right now (it is released at once).
  bool canLock() {
    final f = File('${dir.path}/$aiRunningLockFileName').openSync(mode: FileMode.append);
    try {
      f.lockSync(FileLock.exclusive);
      f.unlockSync();
      return true;
    } on FileSystemException {
      return false;
    } finally {
      f.closeSync();
    }
  }

  test('the file name is the one noted_mcp uses', () {
    expect(aiRunningLockFileName, 'noted-running.lock');
  });

  test('the lock is held until released, and the file is created', () {
    final lock = AiRunningLock.acquire(dir);
    expect(lock.held, isTrue);
    expect(File('${dir.path}/$aiRunningLockFileName').existsSync(), isTrue);
    // OS locks between handles of one process conflict on Windows only; the
    // other systems are covered by the held flag.
    if (Platform.isWindows) expect(canLock(), isFalse, reason: 'held while the app runs');
    lock.release();
    expect(lock.held, isFalse);
    expect(canLock(), isTrue, reason: 'released');
    lock.release(); // again: harmless
  });

  test('a second Noted on the same data does not get the lock, and carries on', () {
    final first = AiRunningLock.acquire(dir);
    final second = AiRunningLock.acquire(dir);
    if (Platform.isWindows) expect(second.held, isFalse);
    second.release();
    first.release();
    final third = AiRunningLock.acquire(dir);
    expect(third.held, isTrue);
    third.release();
  });

  test('a folder that is missing is created; one that cannot be used just means not held', () {
    final fresh = Directory('${dir.path}/new/sub');
    final lock = AiRunningLock.acquire(fresh);
    expect(lock.held, isTrue);
    lock.release();
    final blocker = File('${dir.path}/file')..writeAsStringSync('x');
    expect(AiRunningLock.acquire(Directory(blocker.path)).held, isFalse);
  });
}
