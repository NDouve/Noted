// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:noted_core/noted_core.dart';

/// A source attachment file and the copy that was verified equal to it.
class CopiedFile {
  const CopiedFile(this.source, this.target);

  final File source;
  final File target;
}

/// What copying an attachments folder did (see [copyAttachmentTree]).
class AttachmentCopy {
  /// Files this copy published and folders it created, in creation order, so
  /// a rollback can remove just those (see [removeCreated]).
  final List<String> created = [];

  /// Source files whose target holds exactly their bytes: the only ones
  /// [removeVerifiedSources] may delete.
  final List<CopiedFile> verified = [];

  /// Targets that were left as they are because they hold something else (a
  /// different file, a link, a folder). Their sources are not deleted.
  final List<String> differing = [];

  /// Whether the source attachments folder existed when it was copied.
  bool sourceExisted = false;

  /// Leftover temporary files in the source that could not be put back or
  /// checked, and set-aside originals that could not be put back. They stay
  /// where they are and are reported to the user.
  final List<String> keptAside = [];
}

final RegExp _hashName = RegExp(r'^([0-9a-f]{64})(\.[a-z0-9]+)?$');
String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

int _counter = 0;

/// Replaces [publishExclusive] in tests (for instance to throw as a volume
/// without hard links does).
@visibleForTesting
Future<bool> Function(File tmp, String target)? attachmentPublishHook;

/// Runs after a target was found missing and before the copy is published. For
/// tests.
@visibleForTesting
Future<void> Function(String target)? attachmentBeforePublishHook;

/// Run in [removeVerifiedSources] just before a source is moved aside. For
/// tests.
@visibleForTesting
Future<void> Function(File source)? attachmentBeforeRemoveHook;

/// Run in [removeVerifiedSources] just after a source was moved aside. For
/// tests.
@visibleForTesting
Future<void> Function(File aside)? attachmentAfterAsideHook;

const _chunk = 64 * 1024;

/// The name a file of an attachments folder is copied or landed under, or
/// null when it is not an attachment to take along. The writer's temporary
/// name is `<attachment name>.tmp`. `<hash>.tmp` is also a real attachment (a
/// file called report.tmp), so it keeps its own name, never renamed. Only
/// `<hash>.<ext>.tmp`, which no attachment is called, is an unfinished write:
/// when it holds its hash it lands as `<hash>.<ext>`. Any other `.tmp` is not
/// an attachment.
Future<String?> attachmentNameToTake(File f, String raw) async {
  if (!raw.endsWith('.tmp')) return raw;
  if (raw.endsWith('.landing.tmp')) return null; // the landing code's own temp file
  final stripped = raw.substring(0, raw.length - '.tmp'.length);
  final m = _hashName.firstMatch(stripped);
  if (m != null && m.group(2) != null) {
    return await contentHashOfStream(f.openRead()) == m.group(1) ? stripped : null;
  }
  return _hashName.firstMatch(raw) != null ? raw : null;
}

// `<name>.<micros>-<n>.tmp`: the unique temporary and set-aside names.
final RegExp _uniqueTmp = RegExp(r'^(.+)\.\d+-\d+\.tmp$');

/// Puts back what an interrupted write or removal left under a unique
/// temporary name in [dir]: a file that holds its hash goes back to its name
/// if that is free, and a duplicate of a file already there is dropped. Any
/// other leftover stays and is added to [AttachmentCopy.keptAside].
Future<void> sweepAttachmentLeftovers(Directory dir, AttachmentCopy r) async {
  final sep = Platform.pathSeparator;
  final found = <File>[];
  await for (final e in dir.list(followLinks: false)) {
    if (e is File && _uniqueTmp.hasMatch(_baseName(e.path))) found.add(e);
  }
  for (final f in found) {
    final base = _uniqueTmp.firstMatch(_baseName(f.path))!.group(1)!;
    final target = '${dir.path}$sep$base';
    try {
      final hm = _hashName.firstMatch(base);
      final complete = hm != null && await contentHashOfStream(f.openRead()) == hm.group(1);
      if (complete) {
        if (FileSystemEntity.typeSync(target, followLinks: false) == FileSystemEntityType.notFound) {
          if (await publishExclusive(f, target)) continue;
        }
        if (FileSystemEntity.typeSync(target, followLinks: false) == FileSystemEntityType.file &&
            await sameContent(f, File(target))) {
          await f.delete(); // a duplicate of what is there
          continue;
        }
      }
    } on FileSystemException catch (e) {
      debugPrint('Checking the leftover ${f.path} failed: $e');
    }
    r.keptAside.add(f.path);
  }
}

Future<Uint8List> _readFully(RandomAccessFile f) async {
  final out = BytesBuilder(copy: false);
  var got = 0;
  while (got < _chunk) {
    final part = await f.read(_chunk - got);
    if (part.isEmpty) break;
    out.add(part);
    got += part.length;
  }
  return out.takeBytes();
}

/// Whether the two files hold the same bytes, compared in fixed-size chunks.
Future<bool> sameContent(File a, File b) async {
  final ra = await a.open();
  try {
    final rb = await b.open();
    try {
      if (await ra.length() != await rb.length()) return false;
      while (true) {
        final x = await _readFully(ra);
        final y = await _readFully(rb);
        if (x.isEmpty && y.isEmpty) return true;
        if (!listEquals(x, y)) return false;
      }
    } finally {
      await rb.close();
    }
  } finally {
    await ra.close();
  }
}

/// Copies the files of [from] into [to] (made if needed) without ever
/// replacing a file that is not provably a broken copy. Each file is streamed
/// to a unique temporary name in [to] and published with [publishExclusive];
/// where the volume can't do that (no hard links), the target is created
/// exclusively and filled instead. The target is then compared with the
/// source, in chunks. A file already at the target is trusted only if its
/// bytes equal the source's; if it is named by its content hash and does not
/// hold that hash it is a partial copy and is replaced; anything else
/// (different bytes, a link, a folder) stays as it is and is reported in
/// [AttachmentCopy.differing]. Names are taken as [attachmentNameToTake] says
/// (a `<hash>.tmp` attachment keeps its name; an unfinished `<hash>.<ext>.tmp`
/// lands as `<hash>.<ext>`). Leftover unique temporary names in the source are
/// put back or reported (see [AttachmentCopy.keptAside]).
Future<void> copyAttachmentTree(Directory from, Directory to, AttachmentCopy r) async {
  if (!await from.exists()) return;
  r.sourceExisted = true;
  await sweepAttachmentLeftovers(from, r);
  if (!await to.exists()) {
    await to.create(recursive: true);
    r.created.add(to.path);
  }
  final sep = Platform.pathSeparator;
  await for (final e in from.list()) {
    final raw = _baseName(e.path);
    if (e is Directory) {
      await copyAttachmentTree(e, Directory('${to.path}$sep$raw'), r);
      continue;
    }
    if (e is! File) continue;
    final name = await attachmentNameToTake(e, raw);
    if (name == null) continue;
    await _copyFile(e, '${to.path}$sep$name', name, r);
  }
}

Future<void> _copyFile(File src, String target, String name, AttachmentCopy r) async {
  final type = FileSystemEntity.typeSync(target, followLinks: false);
  if (type != FileSystemEntityType.notFound) {
    await _settleExisting(src, target, name, type, r);
    return;
  }
  final tmp = File('$target.${DateTime.now().microsecondsSinceEpoch}-${_counter++}.tmp');
  try {
    await _streamCopy(src, tmp);
    final written = await tmp.length();
    final writtenHash = await contentHashOfStream(tmp.openRead());
    if (attachmentBeforePublishHook != null) await attachmentBeforePublishHook!(target);
    if (await _publish(tmp, target)) {
      r.created.add(target);
      if (!await sameContent(src, File(target))) {
        // Ours, and wrong: take it away again and let the move fail.
        r.created.removeLast();
        try {
          // Only while it is still what was written (size and hash); a file
          // somebody else put there since is not ours to remove.
          if (await File(target).length() == written &&
              await contentHashOfStream(File(target).openRead()) == writtenHash) {
            await File(target).delete();
          }
        } on FileSystemException {
          // The rollback reports what is left.
        }
        throw FileSystemException('The copy of $name differs from the original', src.path);
      }
      r.verified.add(CopiedFile(src, File(target)));
      return;
    }
  } finally {
    try {
      if (await tmp.exists()) await tmp.delete();
    } on FileSystemException {
      // Only a leftover with this move's own name.
    }
  }
  // A file appeared at the target while this ran.
  await _settleExisting(src, target, name, FileSystemEntity.typeSync(target, followLinks: false), r);
}

Future<void> _settleExisting(
  File src,
  String target,
  String name,
  FileSystemEntityType type,
  AttachmentCopy r,
) async {
  if (type != FileSystemEntityType.file) {
    r.differing.add(target); // a link or a folder is never trusted
    return;
  }
  final t = File(target);
  if (await sameContent(src, t)) {
    r.verified.add(CopiedFile(src, t));
    return;
  }
  final m = _hashName.firstMatch(name);
  // Replaced only when the target is provably broken (it fails the hash in its
  // name) and the source provably holds that hash; otherwise both are kept.
  if (m != null &&
      await contentHashOfStream(t.openRead()) != m.group(1) &&
      await contentHashOfStream(src.openRead()) == m.group(1)) {
    // Named by its hash and not holding it: a partial copy. It is replaced
    // by a verified copy (renamed over it); the original is kept until then.
    final tmp = File('$target.${DateTime.now().microsecondsSinceEpoch}-${_counter++}.tmp');
    try {
      await _streamCopy(src, tmp);
      if (!await sameContent(src, tmp)) {
        throw FileSystemException('The copy of $name differs from the original', src.path);
      }
      await tmp.rename(target);
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // Only a leftover with this move's own name.
      }
    }
    r.verified.add(CopiedFile(src, t));
    return;
  }
  r.differing.add(target);
}

/// Writes [src] to [dst] chunk by chunk and flushes it to disk.
Future<void> _streamCopy(File src, File dst) async {
  final out = await dst.open(mode: FileMode.write);
  try {
    await for (final chunk in src.openRead()) {
      await out.writeFrom(chunk);
    }
    await out.flush();
  } finally {
    await out.close();
  }
}

Future<bool> _publish(File tmp, String target) async {
  try {
    final hook = attachmentPublishHook;
    return await (hook != null ? hook(tmp, target) : publishExclusive(tmp, target));
  } on FileSystemException {
    // A volume without hard links (exFAT/FAT, some SMB and FUSE mounts,
    // Android shared storage): create the target exclusively and fill it. It
    // is never replaced, and the caller compares it afterwards. On Windows the
    // publish does not depend on hard links, so a failure there (a refused
    // name, a locked file) is the caller's.
    if (Platform.isWindows && attachmentPublishHook == null) rethrow;
    return _createExclusive(tmp, target);
  }
}

Future<bool> _createExclusive(File tmp, String target) async {
  final f = File(target);
  try {
    await f.create(exclusive: true);
  } on FileSystemException {
    if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
      return false;
    }
    rethrow;
  }
  // Written through the file just created, appending after a check that it is
  // still empty, so anything somebody else puts there is never truncated.
  var written = 0;
  RandomAccessFile? out;
  try {
    out = await f.open(mode: FileMode.writeOnlyAppend);
    if (await out.length() != 0) {
      await out.close();
      out = null;
      return false; // not ours
    }
    await for (final chunk in tmp.openRead()) {
      await out.writeFrom(chunk);
      written += chunk.length;
    }
    await out.flush();
  } catch (_) {
    await out?.close();
    out = null;
    try {
      // Ours only while it still holds exactly what was written.
      if (await f.length() == written) await f.delete();
    } on FileSystemException {
      // Left for the caller's verification to reject.
    }
    rethrow;
  } finally {
    await out?.close();
  }
  return true;
}

/// Deletes the source files [r] verified as copied, but only those that still
/// match their copy (the same size and bytes); one that changed since is kept.
/// Then the empty folders under [root] go (and [root]). Anything else in
/// [root], such as a file that arrived after the copy, stays.
Future<void> removeVerifiedSources(AttachmentCopy r, Directory root) async {
  for (final c in r.verified) {
    try {
      if (FileSystemEntity.typeSync(c.source.path, followLinks: false) != FileSystemEntityType.file) continue;
      if (!await sameContent(c.source, c.target)) {
        debugPrint('Keeping ${c.source.path}: it changed after it was copied');
        continue;
      }
      // Moved aside first and compared there, so a file that replaces the
      // source in between is never the one deleted.
      await attachmentBeforeRemoveHook?.call(c.source);
      final aside = File('${c.source.path}.${DateTime.now().microsecondsSinceEpoch}-${_counter++}.tmp');
      await c.source.rename(aside.path);
      try {
        await attachmentAfterAsideHook?.call(aside);
        if (await sameContent(aside, c.target)) {
          await aside.delete();
        } else if (!await publishExclusive(aside, c.source.path)) {
          r.keptAside.add(aside.path); // something new is at the path: both stay
        }
      } on FileSystemException catch (e) {
        debugPrint('Putting back ${c.source.path} failed: $e');
        if (aside.existsSync()) r.keptAside.add(aside.path);
      }
    } on FileSystemException catch (e) {
      debugPrint('Removing ${c.source.path} failed: $e');
    }
  }
  Future<void> prune(Directory d) async {
    if (!await d.exists()) return;
    await for (final e in d.list(followLinks: false)) {
      if (e is Directory) await prune(e);
    }
    try {
      if (await d.list().isEmpty) await d.delete();
    } on FileSystemException catch (e) {
      debugPrint('Removing ${d.path} failed: $e');
    }
  }

  await prune(root);
}

/// Removes what [copyAttachmentTree] recorded in `created`: the files, then
/// the folders it made (deepest first), each only if it is empty by then.
/// Returns whether everything was removed.
Future<bool> removeCreated(List<String> created) async {
  var all = true;
  for (final p in created.reversed) {
    try {
      final type = FileSystemEntity.typeSync(p, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type == FileSystemEntityType.file) {
        await File(p).delete();
      } else {
        await Directory(p).delete();
      }
    } on Object catch (e) {
      all = false;
      debugPrint('Removing $p failed: $e');
    }
  }
  return all;
}
