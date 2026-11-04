// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:math';

import 'package:noted_core/noted_core_read.dart';
// The core's read-only barrel leaves out storage code; this one file is
// imported directly (invariant_test.dart allows exactly it).
// ignore: implementation_imports
import 'package:noted_core/src/storage/exclusive_publish.dart' show publishExclusive;

/// What happened to a page file given to [ClosedWriter.replacePage].
enum PageReplace {
  /// The new text is in place.
  done,

  /// The file's bytes were not the ones the caller read, so nothing was
  /// written. The caller may read again and retry.
  changed,

  /// The path is not a page file in a folder the writer was given, or the
  /// file could not be read or written. Nothing was changed.
  refused,

  /// Another writer put a file at the page's path while the replacement was
  /// under way. That file is untouched; the page's previous bytes are kept as
  /// a conflict copy beside it. The caller may retry later.
  busy,
}

/// The narrow writer (invariant 4, wording of run 2026-11-01-03): the only
/// code in the MCP server that writes a file. It can do exactly two things:
///
/// 1. append one line to the server's own access log, `ai-mcp-log.jsonl`
///    beside `ai-access.json` ([appendLog]); and
/// 2. replace a page file (`*.canvas`) that is directly inside one of the
///    folders it was given, by move-aside publication: the new text goes to a
///    temporary file, the page file is moved to a conflict-copy-named file
///    beside it and the temporary file is published exclusively at the page's
///    path ([replacePage]). If another writer got there first, the aside is
///    kept as a conflict copy, never deleted.
///
/// It never creates a folder, never deletes or renames anything but its own
/// temporary file and aside, and never follows a link out of the folders: the page file
/// must itself be a plain file (not a link) whose real folder is one of the
/// given folders' real paths. The invariant test checks that no other file in
/// the server (or the core it imports) calls a file-writing API.
final class ClosedWriter {
  /// [dataDir] is the app's data folder (where the log goes); [folders] are
  /// the page folders the server's library lists.
  ///
  /// [publish] is for tests only (the invariant test checks that no code
  /// outside the tests passes it): it stands in for [publishExclusive].
  ClosedWriter({
    required this.dataDir,
    required Iterable<String> folders,
    Future<bool> Function(File tmp, String target)? publish,
  }) : folders = List.unmodifiable(folders),
       publish = publish ?? publishExclusive;

  final Directory dataDir;
  final List<String> folders;

  /// Test seams: called after the previous bytes are verified and before the
  /// new file is published (where a sync writer could get in); and before the
  /// aside is deleted after publishing.
  Future<void> Function()? beforePublish;
  Future<void> Function(File aside)? beforeAsideDelete;

  /// Publishes a finished file at a path without replacing.
  final Future<bool> Function(File tmp, String target) publish;

  /// A test seam: called after the first look at the page, before it is moved aside.
  Future<void> Function()? beforeAside;

  /// The extension of a page file.
  static const String pageExtension = '.canvas';

  static final String _sep = Platform.pathSeparator;

  File get _log => File('${dataDir.path}$_sep$aiMcpLogFileName');

  /// Appends [line] (one JSON object, no newline in it) and a newline to the
  /// access log, creating the file if it is not there. Never rewrites what is
  /// already in it. Returns false if it could not (the data folder is gone,
  /// say); a failed log never fails the request it records.
  Future<bool> appendLog(String line) async {
    if (line.contains('\n') || line.contains('\r')) return false;
    // The app may hold the file locked while it trims it: a few tries over
    // about a second, then give up quietly (the log is best effort).
    for (var attempt = 0; attempt < 5; attempt++) {
      if (attempt > 0) await Future<void>.delayed(const Duration(milliseconds: 250));
      try {
        if (!await dataDir.exists()) return false;
        // Never through a link: the log is a plain file or not there yet.
        final kind = await FileSystemEntity.type(_log.path, followLinks: false);
        if (kind != FileSystemEntityType.file && kind != FileSystemEntityType.notFound) return false;
        final raf = await _log.open(mode: FileMode.append);
        try {
          // The app's trim holds this same lock while it rewrites the file. A
          // non-blocking try, so a held lock never hangs the caller.
          await raf.lock(FileLock.exclusive);
          // The app may have shortened the file between the open and the
          // lock: write at its end now, not where it ended at open time.
          final length = await raf.length();
          // A torn last line (a crash mid-write) has no newline: start a new
          // line first so this entry never joins it. Only ever appends.
          var lead = '';
          if (length > 0) {
            await raf.setPosition(length - 1);
            if (await raf.readByte() != 0x0A) lead = '\n';
          }
          await raf.setPosition(length);
          await raf.writeString('$lead$line\n');
          await raf.flush();
          await raf.unlock();
        } finally {
          await raf.close();
        }
        return true;
      } on FileSystemException catch (e) {
        // Only a lock or sharing violation is worth another try.
        if (!_isLockViolation(e)) return false;
      } on Object {
        return false;
      }
    }
    return false;
  }

  // Windows: 32 sharing violation, 33 lock violation. POSIX: EAGAIN (11 Linux,
  // 35 macOS), as fcntl reports a lock held by another process. EACCES (13) is
  // left out: on POSIX it usually means the file really can't be written, and
  // retrying would only slow every logged request down.
  static bool _isLockViolation(FileSystemException e) {
    final code = e.osError?.errorCode;
    return Platform.isWindows ? (code == 32 || code == 33) : (code == 11 || code == 35);
  }

  /// Replaces the page file [path] with [text] if its bytes are still
  /// [expected] (what the caller read). Returns [PageReplace.done],
  /// [PageReplace.changed] if the file differs from [expected] (nothing
  /// written), [PageReplace.busy] or [PageReplace.refused].
  ///
  /// Move-aside publication (run 2026-11-03-01): the full text is written
  /// first to a temporary file beside the page (not a `.canvas` name). The page
  /// file is then moved to a unique aside name with the shape of a sync
  /// client's conflict copy (`<page>-NOTED-MCP-<random>.canvas`, which the
  /// app's scanner reads) and its bytes there are checked against [expected].
  /// The temporary file is published at the page's path with
  /// [publishExclusive], which never replaces a file. Nothing is ever written
  /// at the page's path after the move aside.
  ///
  /// If a file is at the page's path at that point (another writer, such as a
  /// sync client, put one there), it is untouched, the aside stays as a
  /// conflict copy holding the page's previous bytes, and the answer is
  /// [PageReplace.busy]. The server never deletes a kept copy. If publishing
  /// fails, the aside is put back the same exclusive way (kept as a conflict
  /// copy if that is not possible) and the answer is [PageReplace.refused].
  Future<PageReplace> replacePage(String path, {required List<int> expected, required List<int> text}) async {
    File? tmp;
    try {
      final file = await _checked(path);
      if (file == null) return PageReplace.refused;
      if (!_same(await file.readAsBytes(), expected)) return PageReplace.changed;
      final name = path.split(RegExp(r'[\\/]')).last;
      final stem = name.substring(0, name.length - pageExtension.length);
      // A random name, created exclusively: two writers never share a file.
      final made = File('${file.parent.path}$_sep.$name.noted_mcp-$pid-${_suffix()}.tmp');
      await made.create(exclusive: true);
      tmp = made;
      await tmp.writeAsBytes(text, flush: true);
      // Probe: can this volume publish exclusively at all (hard links on
      // POSIX)? Publishing the finished file to a second temporary name finds
      // out with the page untouched; if it throws, the answer is `refused`
      // (the outer handler) and nothing has moved. The probed name is then
      // the file to publish.
      final probe = File('${file.parent.path}$_sep.$name.noted_mcp-$pid-${_suffix()}.tmp');
      if (!await publish(tmp, probe.path)) return PageReplace.refused;
      tmp = probe;
      final aside = File('${file.parent.path}$_sep$stem-NOTED-MCP-${_suffix()}$pageExtension');
      if (beforeAside != null) await beforeAside!();
      await file.rename(aside.path);
      // From here the aside holds the page's previous bytes: it is removed
      // only after the new text is published, and otherwise put back or kept.
      if (!_same(await aside.readAsBytes(), expected)) {
        // The page changed after the first look: put it back, as it was.
        return await _putBack(aside, file) ? PageReplace.changed : PageReplace.busy;
      }
      if (beforePublish != null) await beforePublish!();
      final bool published;
      try {
        published = await publish(tmp, file.path);
      } on Object {
        await _putBack(aside, file);
        return PageReplace.refused;
      }
      // A file is at the page's path: it stays, and so does the aside.
      if (!published) return PageReplace.busy;
      tmp = null;
      try {
        if (beforeAsideDelete != null) await beforeAsideDelete!(aside);
        await aside.delete();
      } on Object {
        // Published; the aside stays as a conflict copy.
      }
      return PageReplace.done;
    } on Object {
      return PageReplace.refused;
    } finally {
      if (tmp != null) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } on Object {
          // Left behind at worst; it is not a page file.
        }
      }
    }
  }

  // Puts [aside] back as [file] without replacing anything. False if it could
  // not be (a file is at the path, or the move failed): the aside then stays
  // beside the page as a conflict copy.
  Future<bool> _putBack(File aside, File file) async {
    try {
      return await publish(aside, file.path);
    } on Object {
      return false;
    }
  }

  // The file at [path] if it may be replaced: a page file name, a plain file
  // (not a link), directly in a listed folder, judged by real paths.
  Future<File?> _checked(String path) async {
    if (!path.endsWith(pageExtension)) return null;
    if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.file) return null;
    final file = File(path);
    final realParent = _norm(await file.parent.resolveSymbolicLinks());
    for (final f in folders) {
      try {
        if (_norm(await Directory(f).resolveSymbolicLinks()) == realParent) return file;
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  static final Random _random = Random.secure();

  static String _suffix() => [for (var i = 0; i < 8; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();

  static String _norm(String p) {
    var s = p;
    while (s.length > 1 && (s.endsWith('/') || s.endsWith('\\'))) {
      s = s.substring(0, s.length - 1);
    }
    return Platform.isWindows ? s.replaceAll('/', '\\').toLowerCase() : s;
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
