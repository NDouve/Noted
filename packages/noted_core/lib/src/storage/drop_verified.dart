// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

/// The ending of the aside file once its bytes were verified equal to what the
/// caller expected. Such a file is still never deleted because the target is
/// occupied: it may be the only durable copy of that version, so it is kept as a
/// conflict copy (see `sweepAsideFiles`).
const String verifiedSuffix = '.cas-verified';

/// What [dropVerified] did.
enum DropKind {
  /// The verified file was deleted.
  deleted,

  /// Nothing was there to drop (someone took it first).
  vanished,

  /// The file is in doubt (or a delete's copy stopped being redundant): keep it.
  keep,

  /// A rename or delete failed; the file is where [DropResult.file] says.
  failed,
}

class DropResult {
  const DropResult(this.kind, {this.file, this.late, this.error});

  final DropKind kind;

  /// The file to keep ([DropKind.keep]) or that is stuck ([DropKind.failed]).
  final File? file;

  /// A file found at the pre-drop name after the rename (a by-name write).
  final String? late;
  final Object? error;
}

/// The shared tail of `replaceIfUnchanged`, `deleteFileIfMatches` and the MCP
/// server's page replacement (V1 to V5 of the aside re-check): deletes the
/// verified [aside] only if, renamed to [dropPath] (a name no one else knows),
/// it still satisfies [matches], and (for a delete) the copy [stillRedundant]
/// speaks for still does, checked immediately before the unlink with nothing
/// awaited in between. On any doubt the file is kept.
Future<DropResult> dropVerified(
  File aside,
  String dropPath,
  Future<bool> Function(File file) matches, {
  bool Function()? stillRedundant,
  Future<void> Function(String path)? beforeRename,
  Future<void> Function(String path)? beforeFinalCheck,
  Future<void> Function(String path)? afterFinalRead,
  bool late = true,
}) async {
  final drop = File(dropPath);
  // V1. Rename to a fresh name only this call knows.
  try {
    if (beforeRename != null) await beforeRename(aside.path);
    for (var attempt = 1;; attempt++) {
      try {
        await aside.rename(dropPath);
        break;
      } on FileSystemException catch (e) {
        if (isNotFoundError(e) || attempt >= 4) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 25 * attempt));
      }
    }
  } on FileSystemException catch (e) {
    if (isNotFoundError(e)) return const DropResult(DropKind.vanished);
    return DropResult(DropKind.failed, file: aside, error: e);
  } catch (e) {
    return DropResult(DropKind.failed, file: aside, error: e);
  }
  // V5's look at the old name: a by-name write after V1 landed there. Taken on
  // every way out after V1, so a late file is never left unreported.
  String? lateOf() =>
      late &&
          FileSystemEntity.typeSync(aside.path, followLinks: false) !=
              FileSystemEntityType.notFound
      ? aside.path
      : null;
  // V2 (re-check), V3 (redundancy again) and V4 (delete). The reads and stats
  // are tried again a few times on an I/O error (a sync client may hold the
  // file for a moment) before the file is kept.
  var keep = false;
  try {
    if (beforeFinalCheck != null) await beforeFinalCheck(drop.path);
    final first = await _retryIo(drop.stat);
    if (first.type == FileSystemEntityType.notFound) {
      return DropResult(DropKind.vanished, late: lateOf());
    }
    if (first.type != FileSystemEntityType.file) {
      keep = true;
    } else {
      final equal = await _retryIo(() => matches(drop));
      if (afterFinalRead != null) await afterFinalRead(drop.path);
      final second = await _retryIo(drop.stat);
      keep = !equal ||
          second.type != FileSystemEntityType.file ||
          second.size != first.size ||
          second.modified != first.modified;
    }
  } catch (_) {
    keep = true;
  }
  if (!keep && stillRedundant != null && !stillRedundant()) keep = true;
  Object? failure;
  if (!keep) {
    try {
      drop.deleteSync();
    } on FileSystemException catch (e) {
      failure = e;
    }
  }
  final lateFile = lateOf();
  if (failure != null) {
    return DropResult(DropKind.failed, file: drop, late: lateFile, error: failure);
  }
  if (keep) return DropResult(DropKind.keep, file: drop, late: lateFile);
  return DropResult(DropKind.deleted, late: lateFile);
}

/// Runs [op], trying again a few times with short delays when it throws a
/// [FileSystemException].
Future<T> _retryIo<T>(Future<T> Function() op) async {
  for (var attempt = 1;; attempt++) {
    try {
      return await op();
    } on FileSystemException {
      if (attempt >= 4) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 25 * attempt));
    }
  }
}

// 2: file not found (both platforms); 3: path not found (Windows).
bool isNotFoundError(FileSystemException e) {
  final code = e.osError?.errorCode;
  return code == 2 || (Platform.isWindows && code == 3);
}
