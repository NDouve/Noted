// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart' show addTearDown;
import 'package:noted_core/noted_core_read.dart' show aiMcpLogFileName;
import 'package:noted_mcp/noted_mcp.dart';

/// The exclusive lock the running Noted app holds on `noted-running.lock`,
/// held by a separate process (`lock_holder.dart`) so it also excludes this
/// one on Linux, where file locks are per process.
final class RunningLock {
  RunningLock._(this._process);

  final Process _process;

  static Future<String>? _compiled;

  // The helper compiled once per test process, so each start is quick.
  static Future<String> _holderKernel() => _compiled ??= () async {
    final out = Directory.systemTemp.createTempSync('noted_mcp_lockholder');
    final dill = '${out.path}/lock_holder.dill';
    final r = await Process.run('dart', ['compile', 'kernel', 'test/lock_holder.dart', '-o', dill], runInShell: true);
    if (r.exitCode != 0) throw StateError('could not compile the lock helper: ${r.stderr}');
    return dill;
  }();

  /// Starts the holder and returns once the lock is taken.
  /// The file is kept when the holder lets go (the app never deletes it).
  static Future<RunningLock> hold(Directory dataDir) =>
      _start(['${dataDir.path}/$aiRunningLockFileName', 'keep']);

  /// Holds a shared lock on the running-lock file, as a noted_mcp write does
  /// (the server side).
  static Future<RunningLock> holdShared(Directory dataDir) =>
      _start(['${dataDir.path}/$aiRunningLockFileName', 'shared']);

  /// Holds an exclusive lock on the existing log file (as the app's trim
  /// does), leaving its content alone.
  static Future<RunningLock> holdLog(Directory dataDir) =>
      _start(['${dataDir.path}/$aiMcpLogFileName', 'keep']);

  /// Holds an exclusive lock on the existing file [path], leaving its content
  /// alone: where locks are mandatory (Windows) the file can't be read.
  static Future<RunningLock> holdFile(String path) => _start([path, 'keep']);

  static Future<RunningLock> _start(List<String> args) async {
    final dill = await _holderKernel();
    final p = await Process.start('dart', [dill, ...args], runInShell: true);
    final lock = RunningLock._(p);
    // However the test ends, the holder goes away.
    addTearDown(lock.release);
    try {
      final line = await p.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 30));
      if (line != 'locked') throw StateError('lock helper said: $line');
    } on Object {
      await lock.release();
      rethrow;
    }
    return lock;
  }

  bool _released = false;

  /// Lets go: the helper exits (a log or running-lock file stays). Safe to call twice. If it
  /// doesn't exit in a few seconds it is killed.
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
        // Started through the shell: on Windows kill() would end only
        // cmd.exe, so end the whole tree there.
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
