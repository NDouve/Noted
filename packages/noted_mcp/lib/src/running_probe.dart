// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

/// The file in the app's data folder that the running Noted app holds an
/// exclusive operating-system lock on for its whole lifetime. The operating
/// system drops the lock when the app exits or crashes, so a stale file means
/// closed.
const String aiRunningLockFileName = 'noted-running.lock';

/// Whether Noted is running, decided from a positive signal only.
///
/// Noted is **closed** only if the lock file is absent, or it can be opened
/// read-only and a non-blocking shared lock on it succeeds (released at once).
/// If the lock is held, or the file can't be examined, Noted counts as
/// **running**: the caller then goes through the app and never writes a page
/// file itself. The file is never created or written, and no socket is
/// opened.
Future<bool> isNotedRunning(Directory dataDir) async {
  final file = File('${dataDir.path}${Platform.pathSeparator}$aiRunningLockFileName');
  RandomAccessFile? raf;
  try {
    if (!await file.exists()) return false;
    raf = await file.open(mode: FileMode.read);
  } on FileSystemException {
    // Gone in the meantime: closed. Present but not openable: running.
    return file.existsSync();
  }
  try {
    await raf.lock(FileLock.shared);
    await raf.unlock();
    return false;
  } on FileSystemException {
    return true;
  } finally {
    await raf.close();
  }
}
