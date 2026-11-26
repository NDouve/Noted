// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

/// The message when an export is pointed into Noted's own folders.
const String exportTargetRefusedMessage = "Choose a place outside Noted's folders.";

/// Decides whether an export may write to a path (desktop). Every storage
/// location and binder folder (with the assets, templates and
/// `deleted-attachments` inside them), the recovery folder, the cache and the
/// app data and support folders are refused, and so is everything below them.
///
/// Paths are compared by their real path (after symlinks) and by whole path
/// components, case-insensitively on Windows and macOS. A target that doesn't
/// exist yet is checked through its parent. A target that can't be resolved is
/// refused. A root that can't be resolved is compared by its stored path. In
/// the macOS sandbox, resolving an ungranted parent may fail with EPERM: the
/// target is then checked by the granted path itself (the save panel's URL,
/// with symlinks resolved as far as the grant allows) against every root's
/// real and stored paths; only a target that still can't be resolved that way
/// is refused.
class ExportTargetCheck {
  ExportTargetCheck({
    required this.roots,
    bool? caseInsensitive,
    this.sandboxed = false,
    this.resolve,
  }) : caseInsensitive = caseInsensitive ?? (Platform.isWindows || Platform.isMacOS);

  /// The refused folders, read when [refuses] is called.
  final List<String> Function() roots;

  /// Whether paths are compared without regard to case.
  final bool caseInsensitive;

  /// Whether this is the macOS sandbox (an EPERM from a parent falls back to
  /// the granted path).
  final bool sandboxed;

  /// Test seam: resolves symlinks in an existing path; throws a
  /// [FileSystemException] when it can't. Null: the file system's.
  final String Function(String path)? resolve;

  String _real(String path) {
    final r = resolve;
    if (r != null) return r(path);
    return FileSystemEntity.isDirectorySync(path)
        ? Directory(path).resolveSymbolicLinksSync()
        : File(path).resolveSymbolicLinksSync();
  }

  bool _exists(String path) => resolve != null
      ? _tryResolve(path) != null
      : FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;

  String? _tryResolve(String path) {
    try {
      return _real(path);
    } on FileSystemException {
      return null;
    }
  }

  /// The components of [path] as a comparison key: absolute, separators
  /// unified, no `\\?\` prefix, no empty or `.` parts, case folded where it
  /// doesn't matter.
  List<String> keyOf(String path) {
    var p = path;
    if (p.startsWith(r'\\?\UNC\')) {
      p = '\\\\${p.substring(8)}';
    } else if (p.startsWith(r'\\?\')) {
      p = p.substring(4);
    }
    p = p.replaceAll('\\', '/');
    final parts = <String>[];
    for (final s in p.split('/')) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') {
        if (parts.isNotEmpty) parts.removeLast();
        continue;
      }
      parts.add(caseInsensitive ? s.toLowerCase() : s);
    }
    return parts;
  }

  static bool _within(List<String> path, List<String> root) {
    if (root.isEmpty || path.length < root.length) return false;
    for (var i = 0; i < root.length; i++) {
      if (path[i] != root[i]) return false;
    }
    return true;
  }

  /// Whether [target] (the path the user chose) may not be written. [granted]
  /// is the save panel's own path where it differs from [target] (the
  /// sandbox's URL); null uses [target].
  bool refuses(String target, {String? granted}) {
    final abs = File(target).absolute.path;
    final candidates = <List<String>>[keyOf(abs)];
    try {
      candidates.add(keyOf(_realOfTarget(abs)));
    } on FileSystemException catch (e) {
      final denied = e.osError?.errorCode == 1 || e.osError?.errorCode == 13;
      if (!(sandboxed && denied)) return true;
      // The granted path itself, resolved as far as the grant allows.
      final g = File(granted ?? abs).absolute.path;
      candidates.add(keyOf(g));
      final real = _tryResolve(g);
      if (real != null) candidates.add(keyOf(real));
    }
    final refused = <List<String>>[];
    for (final root in roots()) {
      final abs = Directory(root).absolute.path;
      refused.add(keyOf(abs));
      final real = _tryResolve(abs);
      if (real != null) refused.add(keyOf(real));
    }
    for (final c in candidates) {
      for (final r in refused) {
        if (_within(c, r)) return true;
      }
    }
    return false;
  }

  // The real path of [abs]; for a name that doesn't exist yet, its parent's
  // real path with the name. Throws a FileSystemException when it can't.
  String _realOfTarget(String abs) {
    if (_exists(abs)) return _real(abs);
    final i = abs.lastIndexOf(RegExp(r'[\\/]'));
    if (i <= 0) throw FileSystemException('Can not resolve the path', abs);
    final parent = abs.substring(0, i);
    final name = abs.substring(i + 1);
    return '${_real(parent)}${Platform.pathSeparator}$name';
  }
}
