// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// An exclusive lock on a file held by another process (the helper in
/// `packages/noted_core/test/lock_holder.dart`), so it also excludes this
/// process on Linux, where file locks are per process.
final class LockHolder {
  LockHolder._(this._process);

  final Process _process;

  static Future<String>? _compiled;

  static Future<String> _kernel() => _compiled ??= () async {
    final out = Directory.systemTemp.createTempSync('noted_lockholder');
    final dill = '${out.path}/lock_holder.dill';
    final source =
        '${Directory.current.parent.path}/packages/noted_core/test/lock_holder.dart';
    final r = await Process.run('dart', [
      'compile',
      'kernel',
      source,
      '-o',
      dill,
    ], runInShell: true);
    if (r.exitCode != 0) {
      throw StateError('could not compile the lock helper: ${r.stderr}');
    }
    return dill;
  }();

  /// Starts the helper and returns once it holds the lock on [file]. The file
  /// is left in place afterwards (the helper is told to keep it). With [shared], the
  /// lock is a shared one, as a noted_mcp write holds.
  static Future<LockHolder> hold(File file, {bool shared = false}) async {
    file.parent.createSync(recursive: true);
    final dill = await _kernel();
    final p = await Process.start('dart', [
      dill,
      file.path,
      shared ? 'shared' : 'keep',
    ], runInShell: true);
    final holder = LockHolder._(p);
    final line = await p.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 30));
    if (line != 'locked') throw StateError('lock helper said: $line');
    return holder;
  }

  bool _released = false;

  /// Lets go of the lock: the helper exits.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _process.stdin.close();
    } on Object {
      // Already closed.
    }
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        if (Platform.isWindows) {
          Process.runSync('taskkill', ['/PID', '${_process.pid}', '/T', '/F']);
        } else {
          _process.kill();
        }
        return -1;
      },
    );
  }
}
