// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

/// What [replaceByRenameIfUnchanged] did.
enum RenameOutcome {
  /// The target held exactly the expected bytes and now holds the new file.
  replaced,

  /// The target held other bytes. Nothing was changed.
  changed,

  /// There is no file at the target. Nothing was changed.
  missing,
}

/// Replaces the file at [target] with the finished file [tmp] by a replacing
/// rename, only if the target holds exactly [expected] when it is compared.
///
/// **For binder files only** (the exception to 0131): the target is never
/// absent, but a writer that replaces it between the compare and the rename
/// is overwritten. The window is one small read and one rename, with no Dart
/// code of this isolate in between: the function is synchronous.
///
/// [tmp] stays where it is unless the outcome is [RenameOutcome.replaced];
/// the caller removes it. A [FileSystemException] other than "not found" is
/// rethrown (Windows raises a `PathAccessException` while any handle is open
/// on the target, or when it is read-only). A target without the owner write
/// permission is refused with a [PathAccessException] before the rename on
/// every platform, because POSIX `rename` would replace it.
///
/// [beforeCompare] runs just before the target is read and [beforeRename]
/// just before the rename; both are seams for tests.
RenameOutcome replaceByRenameIfUnchanged(
  File tmp,
  String target,
  List<int> expected, {
  void Function()? beforeCompare,
  void Function()? beforeRename,
}) {
  beforeCompare?.call();
  final List<int> current;
  try {
    current = File(target).readAsBytesSync();
  } on FileSystemException {
    if (FileSystemEntity.typeSync(target, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return RenameOutcome.missing;
    }
    rethrow;
  }
  if (!_same(current, expected)) return RenameOutcome.changed;
  beforeRename?.call();
  if (!isWritableFile(target)) {
    throw PathAccessException(target, const OSError('The file is read-only', 5));
  }
  tmp.renameSync(target);
  return RenameOutcome.replaced;
}

/// Whether the file at [path] has the owner write permission (on Windows,
/// does not have the read-only attribute). A file that can't be examined
/// counts as writable: the caller's next step reports the real error.
bool isWritableFile(String path) {
  try {
    final stat = FileStat.statSync(path);
    if (stat.type == FileSystemEntityType.notFound) return true;
    return stat.mode & 0x80 != 0;
  } on FileSystemException {
    return true;
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
