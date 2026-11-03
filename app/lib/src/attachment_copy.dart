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

const _chunk = 64 * 1024;

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
/// [AttachmentCopy.differing]. A complete `<hash>.tmp` in the source (an
/// attachment write stopped before its rename) is copied as `<hash>`; other
/// `.tmp` files are skipped.
Future<void> copyAttachmentTree(Directory from, Directory to, AttachmentCopy r) async {
  if (!await from.exists()) return;
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
    var name = raw;
    if (raw.endsWith('.tmp')) {
      name = raw.substring(0, raw.length - '.tmp'.length);
      final m = _hashName.firstMatch(name);
      if (m == null || contentHash(await e.readAsBytes()) != m.group(1)) continue;
    }
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
    if (attachmentBeforePublishHook != null) await attachmentBeforePublishHook!(target);
    if (await _publish(tmp, target)) {
      r.created.add(target);
      if (!await sameContent(src, File(target))) {
        // Ours, and wrong: take it away again and let the move fail.
        r.created.removeLast();
        try {
          await File(target).delete();
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
  if (m != null && contentHash(await t.readAsBytes()) != m.group(1)) {
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
    // Android shared storage), or no exclusive publish here: create the target
    // exclusively and fill it. It is never replaced, and the caller compares
    // it afterwards.
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
  try {
    await _streamCopy(tmp, f);
  } catch (_) {
    try {
      await f.delete(); // ours: it did not exist a moment ago
    } on FileSystemException {
      // Left for the caller's verification to reject.
    }
    rethrow;
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
      await c.source.delete();
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
