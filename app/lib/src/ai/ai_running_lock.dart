// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart';

import '../app_theme.dart';

/// The name of the lock file in the data folder. It matches `noted_mcp`'s
/// `aiRunningLockFileName`: the MCP server tries to take the same lock, and
/// that is how it knows whether Noted is running.
const String aiRunningLockFileName = 'noted-running.lock';

/// Why the latest try at the lock failed (run 2026-11-06-02).
enum LockTry {
  /// No failure yet, or the lock is held.
  none,

  /// Another process (an MCP server finishing a write, or another Noted) holds it.
  heldByOther,

  /// Any other failure to open or lock the file: access denied, a folder at
  /// the path, an I/O error.
  unusable,
}

/// An exclusive OS lock on [aiRunningLockFileName], held for as long as the
/// app runs. The OS lets go of it if the app dies, so it never goes stale.
///
/// The app owns it before it answers the link, opens a page or starts the AI
/// services that write: [waitHeld] waits for it with no limit while a
/// [WaitingForLockApp] is on screen. Once held it is never let go of until the
/// app exits.
class AiRunningLock extends ChangeNotifier {
  AiRunningLock(this.dataFolder);

  final Directory dataFolder;

  RandomAccessFile? _file;
  bool _disposed = false;
  LockTry _lastTry = LockTry.none;

  /// Whether this process holds the lock.
  bool get held => _file != null;

  /// Why the latest try failed, so the waiting screen can say what to do.
  LockTry get lastTry => _lastTry;

  /// Takes the lock in [dataFolder], trying up to [tries] times [pause] apart
  /// (a server's hold lasts milliseconds). The file is opened for appending,
  /// so a failed attempt never changes it. Returns [held].
  bool acquire({int tries = 10, Duration pause = const Duration(milliseconds: 200)}) {
    for (var i = 0; i < tries && !held; i++) {
      if (i > 0) sleep(pause);
      _tryOnce(log: i == tries - 1);
    }
    return held;
  }

  /// Retries every [every] and completes once the lock is held. No limit: a
  /// server's hold ends within seconds, and a crashed holder's lock is dropped
  /// by the OS. Each try records why it failed ([lastTry]).
  Future<void> waitHeld({Duration every = const Duration(milliseconds: 250)}) async {
    while (!held && !_disposed) {
      _tryOnce();
      if (held || _disposed) return;
      await Future<void>.delayed(every);
    }
  }

  // Windows: 32 sharing violation, 33 lock violation. POSIX: EAGAIN (11 Linux,
  // 35 macOS) or EACCES (13), which fcntl uses for a lock another process holds.
  static LockTry _classify(Object e) {
    if (e is FileSystemException) {
      final code = e.osError?.errorCode;
      final held = Platform.isWindows ? (code == 32 || code == 33) : (code == 11 || code == 35 || code == 13);
      if (held) return LockTry.heldByOther;
    }
    return LockTry.unusable;
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
      _lastTry = LockTry.none;
      notifyListeners();
    } on Object catch (e) {
      // Nothing secret in the message: it names a file, not content.
      if (log) stderr.writeln('Noted: the running lock could not be taken: ${e.runtimeType}');
      try {
        file?.closeSync();
      } on Object {
        // Nothing to do.
      }
      final c = _classify(e);
      if (c != _lastTry) {
        _lastTry = c;
        notifyListeners();
      }
    }
  }

  /// Lets go of the lock.
  void release() {
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

/// What the waiting screen says while another process holds the lock.
const String waitingForHolderMessage =
    'Waiting for an AI app to finish writing to a page… If this doesn\'t go away, quit the AI app (or Noted) and try again.';

/// What it says while the lock file can't be opened or locked at all.
const String waitingUnusableMessage =
    "Noted can't use its running-lock file, so it can't tell AI apps it's running and won't open your pages. "
    'Check that its data folder is writable, then restart Noted.';

/// Shown instead of the app until it holds the running lock (run 2026-11-06-02):
/// nothing here reads a page, answers the link or writes a file. After
/// [noticeDelay] it shows the notice for [lock]'s latest try and a Quit button,
/// and nothing else.
class WaitingForLockApp extends StatefulWidget {
  const WaitingForLockApp({
    super.key,
    required this.lock,
    this.noticeDelay = const Duration(seconds: 1),
    this.onQuit,
  });

  final AiRunningLock lock;

  /// How long to wait before the notice shows.
  final Duration noticeDelay;

  /// What Quit does (default: exit the process).
  final VoidCallback? onQuit;

  @override
  State<WaitingForLockApp> createState() => _WaitingForLockAppState();
}

class _WaitingForLockAppState extends State<WaitingForLockApp> {
  Timer? _timer;
  bool _show = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.noticeDelay, () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Noted',
    debugShowCheckedModeBanner: false,
    theme: buildNotedTheme(Brightness.light, touch: false),
    darkTheme: buildNotedTheme(Brightness.dark, touch: false),
    themeMode: ThemeMode.system,
    home: Builder(
      builder: (context) {
        final m = NotedMetrics.of(context);
        final scheme = Theme.of(context).colorScheme;
        return Scaffold(
          body: Center(
            child: _show
                ? ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Padding(
                      padding: EdgeInsets.all(m.space6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListenableBuilder(
                            listenable: widget.lock,
                            builder: (context, _) => Semantics(
                              liveRegion: true,
                              child: Text(
                                widget.lock.lastTry == LockTry.unusable ? waitingUnusableMessage : waitingForHolderMessage,
                                key: const ValueKey('waiting-lock-notice'),
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: scheme.onSurface),
                              ),
                            ),
                          ),
                          SizedBox(height: m.space4),
                          FilledButton(
                            key: const ValueKey('waiting-lock-quit'),
                            autofocus: true,
                            onPressed: widget.onQuit ?? () => exit(0),
                            child: const Text('Quit'),
                          ),
                        ],
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        );
      },
    ),
  );
}
