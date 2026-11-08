// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:noted_core/noted_core.dart';

/// What the engine is doing or why it isn't.
enum SyncState {
  idle,
  running,

  /// Something stops the pull for now (offline, throttled, a missing folder,
  /// repeated hash mismatches); [SyncStatus.reason] says what.
  paused,
  signedOut,

  /// The chosen OneDrive folder is gone or was moved out of reach.
  rootGone,

  /// The journal exists but can't be read. It is never overwritten.
  journalUnreadable,

  /// A mass removal waits for the user's answer (see [GuardQuestion]).
  guardWaiting,
}

class SyncStatus {
  const SyncStatus(this.state, [this.reason]);

  final SyncState state;
  final String? reason;

  @override
  bool operator ==(Object other) =>
      other is SyncStatus && other.state == state && other.reason == reason;

  @override
  int get hashCode => Object.hash(state, reason);

  @override
  String toString() => reason == null ? '$state' : '$state($reason)';
}

/// "OneDrive says N pages were removed": the paths (relative to the working
/// copy, with `/`) a round would remove here, waiting for an answer.
class GuardQuestion {
  GuardQuestion(List<String> paths) : paths = List.unmodifiable(paths);

  final List<String> paths;

  @override
  bool operator ==(Object other) =>
      other is GuardQuestion && _sameList(other.paths, paths);

  @override
  int get hashCode => Object.hashAll(paths);

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Something the pull left alone and tells the user about.
class SyncIssue {
  const SyncIssue(this.path, this.reason);

  /// Relative to the working copy, with `/`.
  final String path;
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is SyncIssue && other.path == path && other.reason == reason;

  @override
  int get hashCode => Object.hash(path, reason);

  @override
  String toString() => '$path: $reason';
}

/// What one round did. Filled as the round goes, so a failed round still
/// reports what it applied.
class RoundResult {
  /// Absolute paths published, deleted or moved by this round.
  final List<String> changedPaths = [];

  /// Whether a `noted-binder.json` is among [changedPaths].
  bool anyBinderChange = false;

  /// What stopped the round, if anything.
  Object? error;
}

/// A folder the user can pick, with what Noted would find in it.
class FolderHint {
  const FolderHint({
    required this.canvasCount,
    required this.binderCount,
    required this.holdsBinderFile,
  });

  /// `*.canvas` files directly in the folder.
  final int canvasCount;

  /// Subfolders that hold `noted-binder.json`.
  final int binderCount;

  /// The folder itself holds `noted-binder.json`: it is a binder, not a
  /// folder of binders.
  final bool holdsBinderFile;

  bool get isEmpty => canvasCount == 0 && binderCount == 0;
}

/// A path part for the state folder: [value] itself when it is made of safe
/// characters only, else the SHA-256 of it (G8). The account key and the
/// root item id come from the server and end up in paths.
String safePathPart(String value) {
  final ok =
      RegExp(r'^[A-Za-z0-9!_.-]+$').hasMatch(value) &&
      value != '.' &&
      value != '..' &&
      !value.endsWith('.');
  return ok ? value : contentHash(utf8.encode(value));
}

/// The folder for an account's sync state: `support/onedrive/account/root`
/// (the account key and the root item id), holding `journal.json`, `tmp/` and `base/`. Both
/// ids are made safe with [safePathPart].
Directory syncStateDir(
  Directory support,
  String accountKey,
  String rootItemId,
) => Directory(
  [
    support.path,
    'onedrive',
    safePathPart(accountKey),
    safePathPart(rootItemId),
  ].join(Platform.pathSeparator),
);
