// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:noted_canvas/noted_canvas.dart' show AttachmentState;
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

  /// The content identity of each file in [created] as it was published, so a
  /// rollback deletes it only while it still holds that (see [removeCreated]).
  final Map<String, ContentIdentity> createdIdentity = {};

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

/// The marker of a damaged attachment kept aside: `<name>.damaged-<12 hex>`,
/// the first 12 characters of the hash of its actual bytes. Such a file is not an
/// attachment (its name is not a hash name), is never promoted by the leftover
/// sweeps (they look for `.tmp`, `.cas-old` and `.cas-verified` only), and is
/// copied along with the folder like any other file that is not a hash name.
const String damagedMarker = '.damaged-';

/// The name a damaged copy of [name] is kept under, given the SHA-256 [hash]
/// of its actual bytes.
String damagedCopyName(String name, String hash) => '$name$damagedMarker${hash.substring(0, 12)}';

final RegExp _damagedName = RegExp(r'\.damaged-[0-9a-f]{12}$');

/// Whether [name] is a damaged copy kept aside (see [damagedMarker]).
bool isDamagedCopyName(String name) => _damagedName.hasMatch(name);

/// The hash an attachment file name stands for (`<64 hex>` or
/// `<64 hex>.<ext>`), or null for any other name.
String? attachmentNameHash(String fileName) => _hashName.firstMatch(fileName)?.group(1);

/// What [checkAttachmentFile] found.
class FileCheck {
  const FileCheck(this.state, {this.found, this.bytes});

  final AttachmentState state;

  /// The length and hash of what was read, when [state] is damaged.
  final ContentIdentity? found;

  /// The bytes, when asked for and the file is fine.
  final Uint8List? bytes;
}

/// Hashes [file] (streamed, once) and compares it with [expectedHash]. A file
/// shorter than [size] (the size the box recorded), one that changes while it
/// is read, or one that can't be read now is still syncing; only a file of at
/// least [size] bytes with another hash is damaged. With [keepBytes] the file
/// is read into memory instead and the bytes are returned, so what was
/// checked is what the caller gets.
Future<FileCheck> checkAttachmentFile(
  File file,
  String expectedHash,
  int size, {
  bool keepBytes = false,
}) async {
  try {
    final before = await file.stat();
    if (before.type != FileSystemEntityType.file || before.size < size) {
      return const FileCheck(AttachmentState.syncing);
    }
    final Uint8List? bytes;
    final String hash;
    if (keepBytes) {
      bytes = await file.readAsBytes();
      if (bytes.length != before.size) return const FileCheck(AttachmentState.syncing);
      hash = contentHash(bytes);
    } else {
      bytes = null;
      hash = await contentHashOfStream(file.openRead());
    }
    final after = await file.stat();
    if (after.size != before.size || after.modified != before.modified) {
      return const FileCheck(AttachmentState.syncing);
    }
    if (hash == expectedHash) return FileCheck(AttachmentState.ok, bytes: bytes);
    return FileCheck(AttachmentState.damaged, found: ContentIdentity(before.size, hash));
  } on FileSystemException {
    return const FileCheck(AttachmentState.syncing);
  }
}

/// Keeps the damaged [file] aside, in its own folder, as [damagedCopyName],
/// never over anything: it is moved with [publishExclusive] and checked there.
/// [found] is what the check read. Returns the new name, or null if it could
/// not be set aside (it then stays where it is). A file that changed between
/// the check and the move is put back, not renamed.
Future<String?> setAsideDamaged(File file, ContentIdentity found) async {
  final sep = Platform.pathSeparator;
  final name = _baseName(file.path);
  final asideName = damagedCopyName(name, found.sha256);
  final aside = '${file.parent.path}$sep$asideName';
  try {
    if (await publishExclusive(file, aside)) {
      if (await ContentIdentity.ofFile(aside) == found) return asideName;
      // Something else was at the path when it was moved: not the file that
      // was checked. Put it back where it was if that is free.
      if (FileSystemEntity.typeSync(file.path, followLinks: false) == FileSystemEntityType.notFound) {
        await publishExclusive(File(aside), file.path);
      }
      return null;
    }
    // The same damaged bytes were kept before: this one is a duplicate, and
    // goes only while it still holds exactly what was seen.
    if (FileSystemEntity.typeSync(aside, followLinks: false) == FileSystemEntityType.file &&
        await ContentIdentity.ofFile(aside) == found) {
      final del = await deleteFileIfMatches(file.path, identity: found);
      if (del.deleted || del.outcome == DeleteOutcome.absent) return asideName;
    }
  } on FileSystemException catch (e) {
    debugPrint('Keeping the damaged ${file.path} aside failed: $e');
  }
  return null;
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

/// Run in [removeVerifiedSources] after a source was moved aside and its bytes
/// were compared: the source path is free then. For tests.
@visibleForTesting
void Function(File source)? attachmentAfterAsideHook;

/// Run in [removeVerifiedSources] just before a source is moved aside, inside
/// the compare-and-delete (after its first check). For tests.
@visibleForTesting
void Function(File source)? attachmentMoveAsideHook;

/// Run in [removeVerifiedSources] just before a set-aside source that no longer
/// matches is put back (its path is free). For tests.
@visibleForTesting
void Function(File source)? attachmentBeforeRestoreHook;

const _chunk = 64 * 1024;

/// The name a file of an attachments folder is copied or landed under, or
/// null when it is not an attachment to take along. The writer's temporary
/// name is `<attachment name>.tmp`. `<hash>.tmp` is also a real attachment (a
/// file called report.tmp), so it keeps its own name, never renamed. Only
/// `<hash>.<ext>.tmp`, which no attachment is called, is an unfinished write:
/// when it holds its hash it lands as `<hash>.<ext>`. Any other `.tmp` is not
/// an attachment.
Future<String?> attachmentNameToTake(File f, String raw) async {
  // A file a compare-and-delete set aside and never finished with: not an
  // attachment to take along; the sweep puts it back (sweepAttachmentLeftovers).
  if (raw.endsWith(asideSuffix) || raw.endsWith(verifiedSuffix)) return null;
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
/// other leftover stays and is added to [AttachmentCopy.keptAside]. Files that
/// [deleteFileIfMatches] or [replaceIfUnchanged] set aside and never finished
/// with (a crash) are put back first, never over anything: [sweepAsideFiles]
/// does that, and PageStore.scan does not look inside attachments folders.
Future<void> sweepAttachmentLeftovers(Directory dir, AttachmentCopy r) async {
  final sep = Platform.pathSeparator;
  if (await dir.exists()) {
    try {
      // What was put back is not a loss; what was kept under another name (a
      // newer file was in the way) or could not be moved is reported.
      for (final p in await sweepAsideFiles(dir, extension: '')) {
        if (p.contains('-recovered-') || p.contains('-conflict-')) r.keptAside.add(p);
      }
      await for (final e in dir.list(followLinks: false)) {
        final n = _baseName(e.path);
        if (e is File && (n.endsWith(asideSuffix) || n.endsWith(verifiedSuffix))) r.keptAside.add(e.path);
      }
    } on FileSystemException catch (e) {
      debugPrint('Sweeping ${dir.path} failed: $e');
    }
  }
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
          // A duplicate of what is there: deleted only while it still holds
          // what the target holds.
          final del = await deleteFileIfMatches(
            f.path,
            identity: await ContentIdentity.ofFile(target),
          );
          if (del.deleted || del.outcome == DeleteOutcome.absent) continue;
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
      r.createdIdentity[target] = ContentIdentity(written, writtenHash);
      if (!await sameContent(src, File(target))) {
        // Ours, and wrong: take it away again and let the move fail.
        r.created.removeLast();
        r.createdIdentity.remove(target);
        try {
          // Only while it is still what was written (size and hash); a file
          // somebody else put there since is not ours to remove.
          await deleteFileIfMatches(target, identity: ContentIdentity(written, writtenHash));
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
      // Deleted by the shared compare-and-delete: the source is moved aside,
      // compared there with the copy's identity and only then removed, so a
      // file that replaces the source in between is never the one deleted.
      final identity = await ContentIdentity.ofFile(c.target.path);
      await attachmentBeforeRemoveHook?.call(c.source);
      try {
        final res = await deleteFileIfMatches(
          c.source.path,
          identity: identity,
          beforeMoveAside: () => attachmentMoveAsideHook?.call(c.source),
          afterRead: () => attachmentAfterAsideHook?.call(c.source),
          beforeRestore: () => attachmentBeforeRestoreHook?.call(c.source),
        );
        if (res.outcome == DeleteOutcome.changed) {
          debugPrint('Keeping ${c.source.path}: it changed after it was copied');
        } else if (res.keptPath != null) {
          r.keptAside.add(res.keptPath!); // something new is at the path: both stay
        }
      } on FileSystemException catch (e) {
        debugPrint('Putting back ${c.source.path} failed: $e');
        // Whatever was set aside stays under its own name; say where.
        final name = _baseName(c.source.path);
        await for (final f in c.source.parent.list(followLinks: false)) {
          final n = _baseName(f.path);
          if (f is File && n.startsWith('$name.') && (n.endsWith(asideSuffix) || n.endsWith(verifiedSuffix))) {
            r.keptAside.add(f.path);
          }
        }
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
/// A file goes only while it still holds the content identity it was published
/// with ([AttachmentCopy.createdIdentity]), checked at the moment of deleting;
/// one that changed since is kept (0124). Returns whether everything was
/// removed; false means something was kept (or could not be removed).
Future<bool> removeCreated(AttachmentCopy? copy) async {
  if (copy == null) return true;
  var all = true;
  for (final p in copy.created.reversed) {
    try {
      final type = FileSystemEntity.typeSync(p, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type == FileSystemEntityType.file) {
        final identity = copy.createdIdentity[p];
        if (identity == null) {
          all = false;
          debugPrint('Keeping $p: what it held when it was published is not known');
          continue;
        }
        final res = await deleteFileIfMatches(p, identity: identity);
        if (!res.deleted && res.outcome != DeleteOutcome.absent) {
          all = false;
          debugPrint('Keeping $p: it changed after it was copied');
        }
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
