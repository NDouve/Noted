// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Test helper (a copy of noted_mcp's, which holds noted-running.lock; the app's
// recovery-lock tests start it too), run as its own process: takes an exclusive lock on the file
// named by its one argument (as the running Noted app does), prints "locked",
// and keeps the lock until its standard input closes. Linux file locks are
// per process, so a test must hold the lock from another process.
import 'dart:io';

Future<void> main(List<String> args) async {
  final file = File(args.first);
  // With a second argument, "keep": lock an existing file (the log) without
  // truncating or deleting it.
  final keep = args.length > 1 && (args[1] == 'keep' || args[1] == 'shared');
  // "shared": a shared lock, as a noted_mcp write holds (the file is opened
  // read-only and kept).
  final shared = args.length > 1 && args[1] == 'shared';
  final raf = file.openSync(mode: shared ? FileMode.read : (keep ? FileMode.append : FileMode.write));
  raf.lockSync(shared ? FileLock.shared : FileLock.exclusive);
  stdout.writeln('locked');
  await stdout.flush();
  await stdin.drain<void>();
  raf.unlockSync();
  raf.closeSync();
  if (keep) return;
  try {
    file.deleteSync();
  } on FileSystemException {
    // Already gone.
  }
}
