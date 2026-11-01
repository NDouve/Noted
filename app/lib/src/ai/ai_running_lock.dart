// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart';

/// The name of the lock file in the data folder. It matches `noted_mcp`'s
/// `aiRunningLockFileName`: the MCP server tries to take the same lock, and
/// that is how it knows whether Noted is running.
const String aiRunningLockFileName = 'noted-running.lock';

/// An exclusive OS lock on [aiRunningLockFileName], held for as long as the
/// app runs. The OS lets go of it if the app dies, so it never goes stale.
///
/// If it can't be taken (a `noted_mcp` probe holds it for a moment, or another
/// Noted on the same data holds it) the app keeps running, but [held] is false:
/// the app retries every few seconds ([startRetrying]) and shows a warning
/// ([AiRunningLockBanner]) until it has the lock.
class AiRunningLock extends ChangeNotifier {
  AiRunningLock(this.dataFolder);

  final Directory dataFolder;

  RandomAccessFile? _file;
  Timer? _timer;
  bool _disposed = false;

  /// Whether this process holds the lock.
  bool get held => _file != null;

  /// Takes the lock in [dataFolder], trying up to [tries] times [pause] apart
  /// (a probe holds it for milliseconds). The file is opened for appending,
  /// so a failed attempt never changes it. Returns [held].
  bool acquire({int tries = 10, Duration pause = const Duration(milliseconds: 200)}) {
    for (var i = 0; i < tries && !held; i++) {
      if (i > 0) sleep(pause);
      _tryOnce(log: i == tries - 1);
    }
    return held;
  }

  void _tryOnce({bool log = false}) {
    if (held || _disposed) return;
    RandomAccessFile? file;
    try {
      if (!dataFolder.existsSync()) dataFolder.createSync(recursive: true);
      file = File('${dataFolder.path}${Platform.pathSeparator}$aiRunningLockFileName').openSync(mode: FileMode.append);
      file.lockSync(FileLock.exclusive);
      _file = file;
      try {
        // Ours now: replace what an earlier run wrote.
        file.truncateSync(0);
        file.writeStringSync('$pid\n');
        file.flushSync();
      } on Object {
        // The contents don't matter.
      }
      notifyListeners();
    } on Object catch (e) {
      // Nothing secret in the message: it names a file, not content.
      if (log) stderr.writeln('Noted: the running lock could not be taken: ${e.runtimeType}');
      try {
        file?.closeSync();
      } on Object {
        // Nothing to do.
      }
    }
  }

  /// Retries every [every] until the lock is held.
  void startRetrying({Duration every = const Duration(seconds: 3)}) {
    _timer?.cancel();
    if (held || _disposed) return;
    _timer = Timer.periodic(every, (t) {
      _tryOnce();
      if (held) {
        t.cancel();
        _timer = null;
      }
    });
  }

  /// Lets go of the lock.
  void release() {
    _timer?.cancel();
    _timer = null;
    final f = _file;
    _file = null;
    if (f != null) {
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
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    release();
    _disposed = true;
    super.dispose();
  }
}

/// Shown across the top while Noted doesn't hold the running lock: AI tools
/// can't tell that Noted is running, so writes made while it is closed are
/// paused.
class AiRunningLockBanner extends StatelessWidget {
  const AiRunningLockBanner({super.key});

  static const String message =
      "Noted can't tell AI tools it's running, so writes while Noted is closed are paused.";

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    final colors = NotedColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall!.copyWith(color: scheme.onSurface);
    return Semantics(
      container: true,
      liveRegion: true,
      child: Material(
        color: colors.conflictSoft,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: m.space6, vertical: m.space2),
          child: Row(
            children: [
              Icon(Icons.info_outline_rounded, size: m.icon, color: scheme.onSurface),
              SizedBox(width: m.space2),
              Flexible(child: Text(message, key: const ValueKey('ai-running-lock-message'), style: small)),
            ],
          ),
        ),
      ),
    );
  }
}
