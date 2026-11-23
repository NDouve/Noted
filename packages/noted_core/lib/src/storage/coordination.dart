// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

/// What a coordinated call does to a path.
enum CoordinationKind {
  /// Writes inside the folder, or to the file.
  write,

  /// Moves the file or folder (its versions must be settled first).
  move,

  /// Deletes the file or folder.
  delete,
}

/// One path a coordinated call touches, and how.
final class CoordinationIntent {
  const CoordinationIntent(this.path, this.kind);

  final String path;
  final CoordinationKind kind;

  @override
  bool operator ==(Object other) =>
      other is CoordinationIntent && other.path == path && other.kind == kind;

  @override
  int get hashCode => Object.hash(path, kind);

  @override
  String toString() => '${kind.name} $path';
}

/// Everything one outermost storage call touches, sent to the coordinator in
/// one piece, whichever roots the paths are under.
final class CoordinatedWrite {
  const CoordinatedWrite(this.intents);

  final List<CoordinationIntent> intents;

  @override
  String toString() => 'CoordinatedWrite($intents)';
}

/// Why a coordinated call did not run.
enum StorageBusyReason {
  /// The coordinator is unavailable, refused, or didn't start the call within
  /// [coordinationStartTimeout].
  coordination,

  /// A file the call needs is not downloaded yet.
  dataless,

  /// A file the call would move or delete has unresolved versions.
  versionsPending,
}

/// A coordinated call did not run: nothing was written. It is a
/// [FileSystemException], so a handler that catches that around a storage call
/// must catch this first and rethrow it or answer "busy"; it must never fall
/// back to an uncoordinated write.
class StorageBusy extends FileSystemException {
  StorageBusy(this.reason, this.paths, [String message = ''])
    : super(
        message.isEmpty ? 'The folder is busy (${reason.name})' : message,
        paths.isEmpty ? null : paths.first,
      );

  final StorageBusyReason reason;

  /// The paths the refused call named.
  final List<String> paths;
}

/// Runs a body while the platform holds access to the paths of a
/// [CoordinatedWrite]. One method: the body runs inside the platform's file
/// coordination, and the future completes when the body has, with the body's
/// result or error.
///
/// An implementation that can't start the body throws [StorageBusy] (or any
/// error) without running it; [coordinated] also gives up if the body hasn't
/// started within [coordinationStartTimeout].
abstract interface class StorageCoordinator {
  Future<T> coordinate<T>(CoordinatedWrite write, Future<T> Function() body);
}

/// How long [coordinated] waits for the coordinator to start the body.
const Duration coordinationStartTimeout = Duration(seconds: 60);

StorageCoordinator? _coordinator;
final List<String> _roots = [];

/// Registers [coordinator] for the folder tree at [realRoot] (a real path;
/// resolved here too when it exists). There is one coordinator per process:
/// registering a different one while any root is registered is a
/// [StateError].
void registerCoordinator(String realRoot, StorageCoordinator coordinator) {
  final current = _coordinator;
  if (current != null && _roots.isNotEmpty && !identical(current, coordinator)) {
    throw StateError('Another storage coordinator is registered');
  }
  _coordinator = coordinator;
  final root = _trim(_real(realRoot));
  if (!_roots.contains(root)) _roots.add(root);
}

/// Removes [realRoot]; with no root left, the coordinator is forgotten.
void unregisterCoordinator(String realRoot) {
  _roots.remove(_trim(_real(realRoot)));
  if (_roots.isEmpty) _coordinator = null;
}

/// Runs [body] under the coordinator when any path of [write] is under a
/// registered root, with every path of the call. With nothing registered, or
/// when no path is under a root, [body] runs directly, with no system call.
///
/// Throws [StorageBusy] (reason `coordination`) without running [body] when a
/// coordinator is needed and doesn't start it: it throws, or doesn't answer
/// within [coordinationStartTimeout]. An error from [body] is the body's.
Future<T> coordinated<T>(
  CoordinatedWrite write,
  Future<T> Function() body,
) async {
  final c = _coordinator;
  if (c == null || _roots.isEmpty || !_anyUnderRoot(write)) return body();
  final paths = [for (final i in write.intents) i.path];
  var started = false;
  var abandoned = false;
  final timedOut = Completer<void>();
  final timer = Timer(coordinationStartTimeout, () {
    if (started) return;
    abandoned = true;
    timedOut.complete();
  });
  Future<T> guarded() {
    if (abandoned) {
      throw StorageBusy(StorageBusyReason.coordination, paths);
    }
    started = true;
    timer.cancel();
    return body();
  }

  try {
    return await Future.any<T>([
      c.coordinate<T>(write, guarded),
      timedOut.future.then<T>(
        (_) => throw StorageBusy(
          StorageBusyReason.coordination,
          paths,
          'The folder did not answer in time',
        ),
      ),
    ]);
  } on StorageBusy {
    rethrow;
  } catch (e) {
    if (started) rethrow;
    throw StorageBusy(
      StorageBusyReason.coordination,
      paths,
      'The folder is not available: $e',
    );
  } finally {
    timer.cancel();
  }
}

bool _anyUnderRoot(CoordinatedWrite write) {
  for (final i in write.intents) {
    final p = _trim(_real(_absolute(i.path)));
    for (final r in _roots) {
      if (_under(p, r)) return true;
    }
  }
  return false;
}

// Compared without case: an extra match only sends a call to the coordinator.
bool _under(String path, String root) {
  final p = path.toLowerCase(), r = root.toLowerCase();
  if (p == r) return true;
  if (!p.startsWith(r)) return false;
  return r.endsWith('/') || r.endsWith(r'\') || _isSep(p.codeUnitAt(r.length));
}

bool _isSep(int c) => c == 0x2F || (Platform.isWindows && c == 0x5C);

String _trim(String p) {
  var end = p.length;
  while (end > 1 && _isSep(p.codeUnitAt(end - 1))) {
    end--;
  }
  return end == p.length ? p : p.substring(0, end);
}

/// [path] with its nearest existing ancestor resolved (links followed) and the
/// missing tail appended; [path] itself when nothing resolves.
String _real(String path) {
  var cur = path;
  final tail = <String>[];
  for (var i = 0; i < 4096; i++) {
    if (FileSystemEntity.typeSync(cur, followLinks: false) !=
        FileSystemEntityType.notFound) {
      try {
        final real = Directory(cur).resolveSymbolicLinksSync();
        if (tail.isEmpty) return real;
        final sep = Platform.pathSeparator;
        return '${_trim(real)}$sep${tail.join(sep)}';
      } on FileSystemException {
        // A dangling link: treat it as missing and climb.
      }
    }
    final parent = folderOf(cur);
    if (parent == cur) break;
    final trimmed = _trim(cur);
    var cut = trimmed.length - 1;
    while (cut >= 0 && !_isSep(trimmed.codeUnitAt(cut))) {
      cut--;
    }
    tail.insert(0, trimmed.substring(cut + 1));
    cur = parent;
  }
  return path;
}

String _absolute(String path) {
  final rooted = Platform.isWindows
      ? RegExp(r'^([A-Za-z]:[\\/]|[\\/])').hasMatch(path)
      : path.startsWith('/');
  if (rooted) return path;
  final cwd = Directory.current.path;
  return '${_trim(cwd)}${Platform.pathSeparator}$path';
}

/// The folder part of [path] (the path with its last name cut), as text: it
/// asks the file system nothing. A name with no folder gives `.`; a name in
/// the root gives the root.
String folderOf(String path) {
  final t = _trim(path);
  var cut = t.length - 1;
  while (cut >= 0 && !_isSep(t.codeUnitAt(cut))) {
    cut--;
  }
  if (cut < 0) return '.';
  if (cut == 0) return t.substring(0, 1);
  // "C:\name": the folder is the drive root, kept with its separator.
  if (cut == 2 && t.codeUnitAt(1) == 0x3A) return t.substring(0, 3);
  return _trim(t.substring(0, cut));
}
