// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

/// The result of trying to take the recovery lock.
enum RecoveryLockResult {
  /// This process owns recovery now.
  acquired,

  /// Another process holds the lock: Noted is already open.
  heldByOther,

  /// The lock couldn't be taken for another reason ([RecoveryLock.error]).
  failed,
}

/// One process owns the recovery folder for its whole life (R-1 v5, 3.1): an
/// exclusive lock on `recovery.lock` beside the recovery folder, taken at
/// startup and never let go of or reopened (a POSIX lock is dropped when any
/// handle to the file is closed). The file has zero bytes and is never
/// deleted. The operating system frees the lock when the process ends.
class RecoveryLock {
  RecoveryLock(this.file);

  /// `recovery.lock` beside [recoveryDirectory].
  RecoveryLock.besides(Directory recoveryDirectory)
    : file = File(
        '${recoveryDirectory.absolute.parent.path}${Platform.pathSeparator}recovery.lock',
      );

  final File file;

  RandomAccessFile? _handle;

  /// Why the lock isn't held, when it isn't because another process has it.
  Object? error;

  bool get held => _handle != null;

  /// Takes the lock, trying [tries] times [gap] apart. Blocks the isolate
  /// (it runs before the window is built).
  RecoveryLockResult acquireSync({
    int tries = 10,
    Duration gap = const Duration(milliseconds: 200),
  }) {
    if (_handle != null) return RecoveryLockResult.acquired;
    for (var i = 0; i < tries; i++) {
      final r = _tryOnce();
      if (r != _Try.busy)
        return r == _Try.ok
            ? RecoveryLockResult.acquired
            : RecoveryLockResult.failed;
      if (i < tries - 1) sleep(gap);
    }
    return RecoveryLockResult.heldByOther;
  }

  /// One try, without waiting.
  RecoveryLockResult tryOnce() {
    if (_handle != null) return RecoveryLockResult.acquired;
    return switch (_tryOnce()) {
      _Try.ok => RecoveryLockResult.acquired,
      _Try.busy => RecoveryLockResult.heldByOther,
      _Try.failed => RecoveryLockResult.failed,
    };
  }

  _Try _tryOnce() {
    RandomAccessFile? raf;
    try {
      file.parent.createSync(recursive: true);
      raf = file.openSync(mode: FileMode.append);
      raf.lockSync(FileLock.exclusive);
      _handle = raf;
      error = null;
      return _Try.ok;
    } on FileSystemException catch (e) {
      try {
        raf?.closeSync();
      } on Object {
        // Nothing more to do.
      }
      if (_isHeld(e)) return _Try.busy;
      error = e;
      return _Try.failed;
    } on Object catch (e) {
      error = e;
      return _Try.failed;
    }
  }

  // Windows 33 is a lock violation; POSIX EAGAIN (11 on Linux, 35 on macOS)
  // and EACCES (13) are what a non-blocking lock reports [ASSUMED: Dart's
  // non-blocking lock is F_SETLK].
  static bool _isHeld(FileSystemException e) {
    final code = e.osError?.errorCode;
    if (code == null) return false;
    if (Platform.isWindows) return code == 33;
    return code == 11 || code == 35 || code == 13;
  }

  /// Whether the handle still works (a lock on a network share is lost when
  /// the share drops). Cheap: one length call.
  bool check() {
    final h = _handle;
    if (h == null) return false;
    try {
      h.lengthSync();
      return true;
    } on Object {
      return false;
    }
  }

  /// A lost handle is dropped and the lock taken again, once. True if held.
  bool ensure() {
    if (check()) return true;
    final lost = _handle;
    _handle = null;
    if (lost != null) {
      try {
        lost.closeSync();
      } on Object {
        // Already unusable.
      }
    }
    return tryOnce() == RecoveryLockResult.acquired;
  }

  /// Why recovery can't be used, in a plain sentence, when [held] is false.
  String get problem {
    final e = error;
    final os = e is FileSystemException ? e.osError?.message.trim() : null;
    return "Noted can't use its recovery folder${os == null || os.isEmpty ? '' : ': $os'}";
  }
}

enum _Try { ok, busy, failed }
