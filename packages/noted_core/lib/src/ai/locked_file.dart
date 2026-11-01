// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:math';

/// The lock on a file could not be taken in time: another process is
/// changing it.
final class FileLockTimeout implements Exception {
  const FileLockTimeout(this.path);

  final String path;

  @override
  String toString() => 'FileLockTimeout: $path is in use';
}

/// Runs [body] while holding an exclusive lock on `<file>.lock`, so two
/// processes can't both read-modify-write [file] and lose a change. The app's
/// single-instance guard covers the common case; this covers the rest.
///
/// Retries for about [timeout], then throws [FileLockTimeout].
T withFileLock<T>(File file, T Function() body, {Duration timeout = const Duration(seconds: 2)}) {
  final dir = file.parent;
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final lock = File('${file.path}.lock').openSync(mode: FileMode.append);
  try {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      try {
        lock.lockSync(FileLock.exclusive);
        break;
      } on FileSystemException {
        if (DateTime.now().isAfter(deadline)) throw FileLockTimeout(file.path);
        sleep(const Duration(milliseconds: 20));
      }
    }
    try {
      return body();
    } finally {
      lock.unlockSync();
    }
  } finally {
    lock.closeSync();
  }
}

/// Writes [text] to [file] atomically through a temporary file whose name is
/// unique to this process and call, then renamed over [file].
void writeFileAtomically(File file, String text) {
  final dir = file.parent;
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final tmp = File('${file.path}.$pid.${Random.secure().nextInt(1 << 32).toRadixString(16)}.tmp');
  try {
    tmp.writeAsStringSync(text, flush: true);
    tmp.renameSync(file.path);
  } finally {
    if (tmp.existsSync()) tmp.deleteSync();
  }
}
