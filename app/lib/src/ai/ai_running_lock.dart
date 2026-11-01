// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

/// The name of the lock file in the data folder. It matches `noted_mcp`'s
/// `aiRunningLockFileName`: the MCP server tries to take the same lock, and
/// that is how it knows whether Noted is running.
const String aiRunningLockFileName = 'noted-running.lock';

/// An exclusive OS lock on [aiRunningLockFileName], held for as long as the
/// app runs. The OS lets go of it if the app dies, so it never goes stale.
class AiRunningLock {
  AiRunningLock._(this._file);

  RandomAccessFile? _file;

  /// Whether this process holds the lock.
  bool get held => _file != null;

  /// Takes the lock in [dataFolder]. If it can't be taken (another Noted on
  /// the same data holds it, or the folder can't be written) the result is not
  /// [held]; the app carries on.
  static AiRunningLock acquire(Directory dataFolder) {
    RandomAccessFile? file;
    try {
      if (!dataFolder.existsSync()) dataFolder.createSync(recursive: true);
      file = File('${dataFolder.path}${Platform.pathSeparator}$aiRunningLockFileName').openSync(mode: FileMode.write);
      file.lockSync(FileLock.exclusive);
      try {
        file.writeStringSync('$pid\n');
        file.flushSync();
      } on Object {
        // The contents don't matter.
      }
      return AiRunningLock._(file);
    } on Object catch (e) {
      // Nothing secret in the message: it names a file, not content.
      stderr.writeln('Noted: the running lock could not be taken: ${e.runtimeType}');
      try {
        file?.closeSync();
      } on Object {
        // Nothing to do.
      }
      return AiRunningLock._(null);
    }
  }

  /// Lets go of the lock.
  void release() {
    final f = _file;
    _file = null;
    if (f == null) return;
    try {
      f.unlockSync();
    } on Object {
      // Closing releases it anyway.
    }
    try {
      f.closeSync();
    } on Object {
      // Nothing to do.
    }
  }
}
