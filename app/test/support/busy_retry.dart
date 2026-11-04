// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

/// Runs [op], trying again while Windows reports the file as in use (the
/// watching notebook reads these files at the same moment, and a rename or
/// delete over a file being read is refused), or reports a folder being deleted
/// as not empty (a save that was still finishing wrote into it). Gives up after
/// a deadline.
Future<T> busyRetry<T>(Future<T> Function() op) async {
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (true) {
    try {
      return await op();
    } on FileSystemException catch (e) {
      // Only "access denied" (5), "in use" (32) and "directory not empty"
      // (145, a save that was still finishing wrote into a folder being
      // deleted) on Windows are transient here; anything else is a real
      // failure and is reported at once.
      final code = e.osError?.errorCode;
      final busy = Platform.isWindows && (code == 5 || code == 32 || code == 145);
      if (!busy || DateTime.now().isAfter(end)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }
}
