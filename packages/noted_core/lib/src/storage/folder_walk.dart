// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ffi';
import 'dart:io';

import 'dataless.dart';

/// A test seam: act as Apple without `debugDatalessAbi`, whose `lstat` lookup
/// fails closed off Apple (every existing file counts as dataless). Null in
/// production. Not exported by `noted_core.dart`.
bool? debugAppleMode;

/// A test seam: lists a folder in place of `Directory.listSync`, so a listing
/// can fail. Null in production. Not exported by `noted_core.dart`.
List<FileSystemEntity> Function(String dir)? debugListDir;

/// Whether the folder rules of Apple's cloud storage apply: real macOS or iOS,
/// or a test that set `debugDatalessAbi` to an Apple ABI or [debugAppleMode].
bool appleMode() {
  final forced = debugAppleMode;
  if (forced != null) return forced;
  final abi = debugDatalessAbi;
  if (abi != null) {
    return abi == Abi.macosX64 ||
        abi == Abi.macosArm64 ||
        abi == Abi.iosArm64 ||
        abi == Abi.iosX64;
  }
  return Platform.isMacOS || Platform.isIOS;
}

/// What [folderWalk] found in a folder tree, by name and metadata only: nothing
/// was read.
final class FolderWalk {
  FolderWalk(this.files, this.notDownloaded, this.stubs);

  /// The files that are on this device (a stub is not one).
  final List<String> files;

  /// The paths to ask the system for: a dataless file or folder, and the target
  /// of each stub (`.<name>.icloud` stands for `<name>`). A folder whose listing
  /// failed is here too: it may hold a file that is not downloaded, so it is
  /// never treated as empty.
  final List<String> notDownloaded;

  /// The stub files themselves.
  final List<String> stubs;

  /// Whether something in the tree is not on this device.
  bool get hasNotDownloaded => notDownloaded.isNotEmpty;
}

/// Lists [dir] recursively by name, without following links and without
/// reading any file. A folder that is not downloaded is recorded and not
/// entered; a stub is recorded with the name it stands for. One walk serves a
/// move's guard, its set-asides, its one-by-one fallback and the stray listing
/// (the notebook passes the result along).
FolderWalk folderWalk(String dir) {
  final files = <String>[];
  final missing = <String>[];
  final stubs = <String>[];
  final sep = Platform.pathSeparator;
  void walk(String d) {
    final List<FileSystemEntity> entries;
    try {
      entries = debugListDir?.call(d) ?? Directory(d).listSync(followLinks: false);
    } on FileSystemException {
      // A folder that vanished holds nothing; any other failure may hide an
      // evicted file, so the folder is recorded as not downloaded.
      if (FileSystemEntity.typeSync(d, followLinks: false) != FileSystemEntityType.notFound) {
        missing.add(d);
      }
      return;
    }
    for (final e in entries) {
      final cut = e.path.lastIndexOf(RegExp(r'[\\/]'));
      final name = e.path.substring(cut + 1);
      final type = FileSystemEntity.typeSync(e.path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        if (isDataless(e.path)) {
          missing.add(e.path);
        } else {
          walk(e.path);
        }
        continue;
      }
      if (type != FileSystemEntityType.file) continue;
      final target = stubTargetName(name);
      if (target != null && target != '.' && target != '..' && !target.contains(RegExp(r'[\\/]'))) {
        stubs.add(e.path);
        missing.add('$d$sep$target');
      } else if (isDataless(e.path)) {
        missing.add(e.path);
      } else {
        files.add(e.path);
      }
    }
  }

  // The folder itself first: an evicted folder is asked for and never listed.
  if (isDataless(dir)) {
    missing.add(dir);
  } else {
    walk(dir);
  }
  return FolderWalk(files, missing, stubs);
}
