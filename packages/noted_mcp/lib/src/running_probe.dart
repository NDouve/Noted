// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

/// The file in the app's data folder that the running Noted app holds an
/// exclusive operating-system lock on for its whole lifetime. The operating
/// system drops the lock when the app exits or crashes, so a stale file means
/// closed.
const String aiRunningLockFileName = 'noted-running.lock';

/// What taking the shared lock on the running-lock file found (run
/// 2026-11-06-02).
enum LockClass {
  /// The shared lock is held by this process now (release it).
  held,

  /// Another process (the app) holds it: Noted is running.
  running,

  /// Nothing is at the path.
  noLockFile,

  /// Any other failure to open or lock it (access denied, a folder at the
  /// path, an I/O error): treated as running, and never written around.
  unusable,
}

/// A shared lock taken through [LockGate.take]. [release] gives it back,
/// at most once, however often it is called.
final class LockHold {
  LockHold._(this.lockClass, this._gate, this._path);

  final LockClass lockClass;
  final LockGate _gate;
  final String _path;
  bool _released = false;

  /// Whether the shared lock is held through this object.
  bool get isHeld => lockClass == LockClass.held && !_released;

  /// Gives the lock back. Idempotent.
  Future<void> release() {
    if (lockClass != LockClass.held || _released) return Future.value();
    _released = true;
    return _gate._release(_path);
  }
}

class _GateState {
  int count = 0;
  RandomAccessFile? raf;
}

/// The only code in the server that opens, locks, unlocks or closes
/// `noted-running.lock` (run 2026-11-06-02).
///
/// On Linux and macOS a process's locks on a file go when any descriptor of
/// that file in the process is closed. So there is at most one descriptor per
/// lock file, a count of the holds on it, and every operation runs one at a
/// time on a chain: a probe's close can never drop a write's hold.
final class LockGate {
  LockGate._();

  /// The one gate of this process.
  static final LockGate instance = LockGate._();

  /// Test seam: called between the open and the lock.
  static Future<void> Function()? beforeLockForTest;

  Future<void> _chain = Future.value();
  final Map<String, _GateState> _states = {};

  Future<T> _serial<T>(Future<T> Function() op) {
    final r = _chain.then((_) => op());
    _chain = r.then((_) {}, onError: (_) {});
    return r;
  }

  static String lockPath(Directory dataDir) => '${dataDir.path}${Platform.pathSeparator}$aiRunningLockFileName';

  /// Takes (or joins) the non-blocking shared lock on the running-lock file
  /// in [dataDir]. With a count above zero it joins with no new descriptor.
  Future<LockHold> take(Directory dataDir) {
    final path = lockPath(dataDir);
    return _serial(() async {
      final state = _states.putIfAbsent(path, _GateState.new);
      LockHold answer(LockClass c) => LockHold._(c, this, path);
      if (state.count > 0) {
        state.count++;
        return answer(LockClass.held);
      }
      RandomAccessFile? raf;
      try {
        if (await FileSystemEntity.type(path) == FileSystemEntityType.notFound) return answer(LockClass.noLockFile);
        raf = await File(path).open(mode: FileMode.read);
        final hook = beforeLockForTest;
        if (hook != null) await hook();
        await raf.lock(FileLock.shared);
        state.raf = raf;
        state.count = 1;
        return answer(LockClass.held);
      } on FileSystemException catch (e) {
        // Safe: no other descriptor of the file exists in this process.
        final r = raf;
        if (r != null) {
          try {
            await r.close();
          } on Object {
            // Nothing to do.
          }
        }
        if (_isHeldError(e, opened: r != null)) return answer(LockClass.running);
        if (r == null && await FileSystemEntity.type(path) == FileSystemEntityType.notFound) {
          return answer(LockClass.noLockFile);
        }
        return answer(LockClass.unusable);
      } on Object {
        final r = raf;
        if (r != null) {
          try {
            await r.close();
          } on Object {
            // Nothing to do.
          }
        }
        return answer(LockClass.unusable);
      }
    });
  }

  // Held by another: a lock-conflict code from the lock call (Windows 33;
  // POSIX EAGAIN 11/35 or EACCES 13, which fcntl uses), or a sharing violation
  // from the open (Windows 32).
  static bool _isHeldError(FileSystemException e, {required bool opened}) {
    final code = e.osError?.errorCode;
    if (Platform.isWindows) return opened ? code == 33 : code == 32;
    return opened && (code == 11 || code == 35 || code == 13);
  }

  Future<void> _release(String path) => _serial(() async {
    final state = _states[path];
    if (state == null || state.count == 0) return;
    state.count--;
    if (state.count > 0) return;
    final raf = state.raf;
    state.raf = null;
    if (raf == null) return;
    try {
      await raf.unlock();
    } on Object {
      // Closing releases it anyway.
    } finally {
      try {
        await raf.close();
      } on Object {
        // Nothing to do.
      }
    }
  });
}

/// Whether Noted is running, decided from a positive signal only, for reads
/// and grants.
///
/// Noted is **closed** only if the lock file is absent, or the shared lock on
/// it succeeds (released at once). If the lock is held, or the file can't be
/// examined (including a folder at its path), Noted counts as **running**: the
/// caller then goes through the app and never writes a page file itself. The
/// file is never created or written, and no socket is opened.
Future<bool> isNotedRunning(Directory dataDir) async {
  final hold = await LockGate.instance.take(dataDir);
  try {
    return switch (hold.lockClass) {
      LockClass.held || LockClass.noLockFile => false,
      LockClass.running || LockClass.unusable => true,
    };
  } finally {
    await hold.release();
  }
}

/// Tells a file that is the running-lock file itself (the same device and
/// inode, after links) from other files, on Linux and macOS, where reading it
/// and closing it would drop this process's locks. Every file the server reads
/// is checked with it. Windows needs none: its locks belong to a handle.
final class LockIdentity {
  LockIdentity._(this._lockPath);

  final String? _lockPath;

  /// Never anything: for callers that read no data files.
  static final LockIdentity none = LockIdentity._(null);

  /// The identity for [dataDir]: stats the lock file once. If it is absent
  /// (or on Windows) nothing is ever refused.
  static Future<LockIdentity> of(Directory dataDir) async {
    if (Platform.isWindows) return none;
    return forLockFile(LockGate.lockPath(dataDir));
  }

  /// The identity for the lock file at [path], on any platform (the decision
  /// itself is tested on Windows through this). Absent: nothing is refused.
  /// The lock path is resolved through its own links once, so it is never a link.
  static Future<LockIdentity> forLockFile(String path) async {
    try {
      if (await FileSystemEntity.type(path) == FileSystemEntityType.notFound) return none;
      return LockIdentity._(await File(path).resolveSymbolicLinks());
    } on Object {
      return none;
    }
  }

  /// Whether [path] is the lock file itself.
  Future<bool> isLock(String path) async {
    final lock = _lockPath;
    if (lock == null) return false;
    try {
      // `identical` compares a link with its target as different, so a path is
      // resolved through its links first: a symlink to the lock file is the lock
      // file, and a hard link is caught by `identical` itself (same inode).
      final real = await File(path).resolveSymbolicLinks();
      return await FileSystemEntity.identical(real, lock);
    } on Object {
      // Can't tell: a file that exists is skipped (fail closed); one that is gone is not,
      // and nor is any file if the lock file itself is gone (it can't be opened then).
      try {
        if (await FileSystemEntity.type(lock) == FileSystemEntityType.notFound) return false;
        return await FileSystemEntity.type(path) != FileSystemEntityType.notFound;
      } on Object {
        return true;
      }
    }
  }

  /// Whether [path] is known to be the lock file or a link to it (a sync
  /// client may leave one among the page files): false when it can't be told,
  /// unlike [isLock], which then fails closed. Such a path is not a page file.
  Future<bool> isLockFile(String path) async {
    final lock = _lockPath;
    if (lock == null) return false;
    try {
      return await FileSystemEntity.identical(await File(path).resolveSymbolicLinks(), lock);
    } on Object {
      return false;
    }
  }

  /// [path]'s bytes, or null if it is absent, unreadable or the lock file.
  Future<List<int>?> readBytes(String path) async {
    try {
      if (await isLock(path)) return null;
      final f = File(path);
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } on Object {
      return null;
    }
  }
}
