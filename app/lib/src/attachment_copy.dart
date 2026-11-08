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

  /// Damaged or incomplete files found at a target, moved aside under
  /// `<name>.damaged-<12 hex>` (never deleted) while the good copy took their
  /// name. Reported to the user.
  final List<DamagedKept> damagedKept = [];

  /// Targets that were left alone because they were changing (a sync client
  /// still writing) or could not be read. Their sources are not deleted.
  final List<String> stillChanging = [];
}

/// A file found at a hash name that failed its hash, kept aside next to it.
class DamagedKept {
  DamagedKept({required this.folder, required this.name, required this.aside, required this.incomplete});

  /// The folder both files are in.
  final String folder;

  /// The hash file name the damaged bytes were found under.
  final String name;

  /// The name they were kept under (`<name>.damaged-<12 hex>`).
  final String aside;

  /// Shorter than the good file (an unfinished write) rather than a full-size
  /// file with other bytes.
  final bool incomplete;

  /// Whether the good copy is in place at [path] at the end: set once it was
  /// verified there, and cleared when a rollback removed it ([removeCreated]).
  bool replaced = false;

  /// Where the damaged bytes were found.
  String get path => '$folder${Platform.pathSeparator}$name';
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

/// Runs in [checkAttachmentFile] after the file was hashed and before its
/// size and time are checked again. For tests.
@visibleForTesting
Future<void> Function(File file)? attachmentAfterHashHook;

/// Runs in [setAsideDamaged] after the file was moved and before it is
/// checked there. For tests.
@visibleForTesting
void Function(String aside)? attachmentAfterSetAsideHook;

/// Runs in [setAsideDamaged] before the exclusive move. A test makes it throw
/// a [FileSystemException] to simulate a volume that can't set a file aside.
@visibleForTesting
void Function(String aside)? attachmentBeforeSetAsideHook;

/// Hashes [file] (streamed, once) and compares it with [expectedHash]. A file
/// shorter than [size] (the size the box recorded), one that changes while it
/// is read, or one that can't be read now is still syncing; only a file of at
/// least [size] bytes with another hash is damaged. With [keepBytes] the bytes
/// are collected while they are hashed (still chunk by chunk) and returned, so
/// what was checked is what the caller gets.
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
    final builder = keepBytes ? BytesBuilder(copy: false) : null;
    final hash = await contentHashOfStream(
      builder == null
          ? file.openRead()
          : file.openRead().map((c) {
              builder.add(c);
              return c;
            }),
    );
    await attachmentAfterHashHook?.call(file);
    final after = await file.stat();
    if (after.size != before.size || after.modified != before.modified) {
      return const FileCheck(AttachmentState.syncing);
    }
    final bytes = builder?.takeBytes();
    if (bytes != null && bytes.length != before.size) {
      return const FileCheck(AttachmentState.syncing);
    }
    if (hash == expectedHash) return FileCheck(AttachmentState.ok, bytes: bytes);
    return FileCheck(AttachmentState.damaged, found: ContentIdentity(before.size, hash));
  } on FileSystemException {
    return const FileCheck(AttachmentState.syncing);
  }
}

/// What [setAsideDamaged] did: [name] is the new name when the damaged file
/// was set aside; otherwise null, and [leftAt] says which file name it is
/// under now (it may have moved part-way).
typedef SetAside = ({String? name, String leftAt});

/// Keeps the damaged [file] aside, in its own folder, as [damagedCopyName],
/// never over anything: it is moved with [publishExclusive] and checked there.
/// [found] is what the check read. A file that changed between the check and
/// the move is put back, not renamed.
Future<SetAside> setAsideDamaged(File file, ContentIdentity found) async {
  final sep = Platform.pathSeparator;
  final name = _baseName(file.path);
  final asideName = damagedCopyName(name, found.sha256);
  final aside = '${file.parent.path}$sep$asideName';
  var leftAt = name;
  try {
    attachmentBeforeSetAsideHook?.call(aside);
    if (await publishExclusive(file, aside)) {
      leftAt = asideName;
      attachmentAfterSetAsideHook?.call(aside);
      if (await ContentIdentity.ofFile(aside) == found) return (name: asideName, leftAt: asideName);
      // Something else was at the path when it was moved: not the file that
      // was checked. Put it back where it was if that is free.
      if (FileSystemEntity.typeSync(file.path, followLinks: false) == FileSystemEntityType.notFound &&
          await publishExclusive(File(aside), file.path)) {
        leftAt = name;
      }
      return (name: null, leftAt: leftAt);
    }
    // The same damaged bytes were kept before: this one is a duplicate, and
    // goes only while it still holds exactly what was seen.
    if (FileSystemEntity.typeSync(aside, followLinks: false) == FileSystemEntityType.file &&
        await ContentIdentity.ofFile(aside) == found) {
      final del = await deleteFileIfMatches(file.path, identity: found);
      if (del.deleted || del.outcome == DeleteOutcome.absent) return (name: asideName, leftAt: asideName);
    }
  } on FileSystemException catch (e) {
    debugPrint('Keeping the damaged ${file.path} aside failed: $e');
  }
  return (name: null, leftAt: leftAt);
}

/// The marker of a good copy kept beside a file that could not be replaced
/// (`<name>.kept-<n>`). Like [damagedMarker] it is not an attachment name.
const String keptMarker = '.kept-';

/// Called before this module creates a new file (a temporary file, the
/// exclusive publish of a kept copy or an attachment). A test makes it throw a
/// [FileSystemException] to simulate a folder that rejects new files.
@visibleForTesting
void Function(String path)? attachmentBeforeCreateHook;

/// Runs in [writeNewAttachmentFile] after a no-hard-link publish filled the
/// target and before it is checked by hash. For tests.
@visibleForTesting
Future<void> Function(String target)? attachmentAfterFillHook;

/// Writes [bytes] (whose SHA-256 is [hash]) to the new file [target], never
/// over anything: they go to a unique temporary file that is published with
/// [publishAttachment]. Returns true when this call created [target], false
/// when something was there already (it is left alone). Throws a
/// [FileSystemException] when the file could not be written. This call's own
/// temporary file is always removed. After the no-hard-link publish (which
/// copies and leaves the temporary file) the target is checked by hash; one
/// that does not hold [hash] is left alone (it may be another writer's file)
/// and counts as refused.
Future<bool> writeNewAttachmentFile(File target, Uint8List bytes, String hash) async {
  final tmp = File('${target.path}.${DateTime.now().microsecondsSinceEpoch}-${_counter++}.tmp');
  try {
    attachmentBeforeCreateHook?.call(tmp.path);
    await tmp.writeAsBytes(bytes, flush: true);
    final res = await _publishDetailed(tmp, target.path);
    if (!res.published) return false;
    if (res.copied) {
      await attachmentAfterFillHook?.call(target.path);
      // Whatever is there but not these bytes is not ours to delete (another
      // writer may have replaced it): it is left alone and counts as a
      // refused publish for the caller.
      final id = await ContentIdentity.ofFile(target.path);
      if (id.length != bytes.length || id.sha256 != hash) return false;
    }
    return true;
  } finally {
    try {
      if (await tmp.exists()) await tmp.delete();
    } on FileSystemException {
      // Only a leftover with this call's own name.
    }
  }
}

/// Writes [bytes] to a new file `<name>.kept-<n>` in [dir], never over
/// anything (see [writeNewAttachmentFile]). A kept copy that already holds
/// these bytes (a complete `<name>.kept-<n>`, never a `.tmp`) is returned
/// instead of writing another. Returns the name, or null if no copy could be
/// written.
Future<String?> keepGoodCopy(Directory dir, String name, Uint8List bytes) async {
  final sep = Platform.pathSeparator;
  final hash = contentHash(bytes);
  try {
    if (await dir.exists()) {
      await for (final e in dir.list(followLinks: false)) {
        final n = _baseName(e.path);
        if (e is! File || !n.startsWith('$name$keptMarker') || n.endsWith('.tmp')) continue;
        final c = await checkAttachmentFile(e, hash, bytes.length);
        if (c.state == AttachmentState.ok) return n;
      }
    }
  } on FileSystemException catch (e) {
    debugPrint('Looking for a kept copy of $name failed: $e');
  }
  final keptName = '$name$keptMarker${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
  try {
    if (await writeNewAttachmentFile(File('${dir.path}$sep$keptName'), bytes, hash)) return keptName;
  } on FileSystemException catch (e) {
    debugPrint('Keeping a good copy of $name failed: $e');
  }
  return null;
}

/// Puts a kept copy back when the attachment [fileName] is missing from [dir]
/// but a `<fileName>.damaged-…` or `<fileName>.kept-…` file now holds
/// [hash] at [size] bytes (for instance an in-place writer that was
/// mid-write when the file was set aside, and finished). The copy is moved
/// with [publishExclusive], never over anything. Returns whether one was put
/// back.
Future<bool> restoreKeptCopy(Directory dir, String fileName, String hash, int size) async {
  final sep = Platform.pathSeparator;
  final target = '${dir.path}$sep$fileName';
  try {
    if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) return false;
    if (!await dir.exists()) return false;
    await for (final e in dir.list(followLinks: false)) {
      final n = _baseName(e.path);
      if (e is! File || !n.startsWith('$fileName.')) continue;
      final rest = n.substring(fileName.length);
      if (!rest.startsWith(damagedMarker) && !rest.startsWith(keptMarker)) continue;
      if (rest.endsWith('.tmp')) continue;
      final c = await checkAttachmentFile(e, hash, size);
      if (c.state == AttachmentState.ok && await publishExclusive(e, target)) return true;
    }
  } on FileSystemException catch (e) {
    debugPrint('Looking for a kept copy of $fileName failed: $e');
  }
  return false;
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
/// hold that hash (a partial or damaged copy) it is moved aside as
/// `<name>.damaged-<12 hex>` and the verified copy takes its name (see
/// [AttachmentCopy.damagedKept]); one that is still changing stays
/// ([AttachmentCopy.stillChanging]); anything else (different bytes, a link, a
/// folder) stays as it is and is reported in [AttachmentCopy.differing]. Names are taken as [attachmentNameToTake] says
/// (a `<hash>.tmp` attachment keeps its name; an unfinished `<hash>.<ext>.tmp`
/// lands as `<hash>.<ext>`). Leftover unique temporary names in the source are
/// put back or reported (see [AttachmentCopy.keptAside]).
///
/// With [sweepSource] false the leftovers in [from] are not put back or
/// reported: a source that is only read (a pull-only folder) is never written.
Future<void> copyAttachmentTree(Directory from, Directory to, AttachmentCopy r, {bool sweepSource = true}) async {
  if (!await from.exists()) return;
  r.sourceExisted = true;
  if (sweepSource) await sweepAttachmentLeftovers(from, r);
  if (!await to.exists()) {
    await to.create(recursive: true);
    r.created.add(to.path);
  }
  final sep = Platform.pathSeparator;
  await for (final e in from.list()) {
    final raw = _baseName(e.path);
    if (e is Directory) {
      await copyAttachmentTree(e, Directory('${to.path}$sep$raw'), r, sweepSource: sweepSource);
      continue;
    }
    if (e is! File) continue;
    final name = await attachmentNameToTake(e, raw);
    if (name == null) continue;
    await _copyFile(e, '${to.path}$sep$name', name, r);
  }
}

Future<void> _copyFile(File src, String target, String name, AttachmentCopy r, {bool settleOnce = false}) async {
  final type = FileSystemEntity.typeSync(target, followLinks: false);
  if (type != FileSystemEntityType.notFound) {
    await _settleExisting(src, target, name, type, r, settleOnce: settleOnce);
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
  await _settleExisting(
    src,
    target,
    name,
    FileSystemEntity.typeSync(target, followLinks: false),
    r,
    settleOnce: settleOnce,
  );
}

/// Settles a file already at [target]. Nothing there is ever replaced: bytes
/// that fail the hash in their name are moved aside as `.damaged-<12 hex>`
/// (see [setAsideDamaged]) and the verified copy is published exclusively.
/// With [settleOnce] (the call after a set-aside, or after a publish was
/// refused) it never sets anything aside again.
Future<void> _settleExisting(
  File src,
  String target,
  String name,
  FileSystemEntityType type,
  AttachmentCopy r, {
  bool settleOnce = false,
}) async {
  if (type != FileSystemEntityType.file) {
    r.differing.add(target); // a link or a folder is never trusted
    return;
  }
  final t = File(target);
  try {
    if (await sameContent(src, t)) {
      r.verified.add(CopiedFile(src, t));
      return;
    }
  } on FileSystemException {
    // An error reading the source is the move's own failure: it propagates.
    final probe = await src.open();
    try {
      await probe.read(1);
    } finally {
      await probe.close();
    }
    // The target could not be read: a file that is being written or is
    // locked. Left alone; the source stays.
    r.stillChanging.add(target);
    return;
  }
  final hash = attachmentNameHash(name);
  if (hash == null || settleOnce) {
    r.differing.add(target);
    return;
  }
  // Only when the source provably holds the hash in the name is the target
  // judged against it; otherwise both are kept.
  if (await contentHashOfStream(src.openRead()) != hash) {
    r.differing.add(target);
    return;
  }
  // Size 0: a short file is not "syncing" for being short; only a change across
  // the read, or a read error, is.
  final check = await checkAttachmentFile(t, hash, 0);
  final found = check.found;
  if (check.state == AttachmentState.syncing) {
    r.stillChanging.add(target);
    return;
  }
  if (check.state != AttachmentState.damaged || found == null) {
    r.differing.add(target);
    return;
  }
  // Stable, and not the source's bytes: incomplete (shorter) or damaged. The
  // old bytes are kept under their own name; the good copy then takes the name.
  final incomplete = found.length < await src.length();
  final verifiedBefore = r.verified.length; // an earlier copy into this target must not count
  final res = await setAsideDamaged(t, found);
  final base = _baseName(target);
  final kept = res.name ?? (res.leftAt != base ? res.leftAt : null);
  final entry = kept == null
      ? null
      : DamagedKept(folder: t.parent.path, name: base, aside: kept, incomplete: incomplete);
  if (entry != null) r.damagedKept.add(entry);
  final now = FileSystemEntity.typeSync(target, followLinks: false);
  if (now == FileSystemEntityType.notFound) {
    await _copyFile(src, target, name, r, settleOnce: true);
  } else {
    // Nothing was set aside (the file changed and was put back, or the move was
    // refused), or something arrived since: one more look, never another set-aside.
    await _settleExisting(src, target, name, now, r, settleOnce: true);
  }
  // Only reached when nothing threw: the good copy counts as in place when the
  // target was verified.
  if (entry != null) entry.replaced = r.verified.skip(verifiedBefore).any((c) => c.target.path == target);
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

/// Publishes [tmp] as [target], never over anything: a hard link (or the
/// platform's exclusive move), and where the volume has no hard links the
/// target is created exclusively and filled from [tmp], which is then left
/// where it is (the caller removes it). Returns false when something is at
/// [target] already.
Future<bool> publishAttachment(File tmp, String target) async => (await _publishDetailed(tmp, target)).published;

typedef _Published = ({bool published, bool copied});

Future<bool> _publish(File tmp, String target) => publishAttachment(tmp, target);

Future<_Published> _publishDetailed(File tmp, String target) async {
  attachmentBeforeCreateHook?.call(target);
  try {
    final hook = attachmentPublishHook;
    return (published: await (hook != null ? hook(tmp, target) : publishExclusive(tmp, target)), copied: false);
  } on FileSystemException {
    // A volume without hard links (exFAT/FAT, some SMB and FUSE mounts,
    // Android shared storage): create the target exclusively and fill it. It
    // is never replaced, and the caller compares it afterwards. On Windows the
    // publish does not depend on hard links, so a failure there (a refused
    // name, a locked file) is the caller's.
    if (Platform.isWindows && attachmentPublishHook == null) rethrow;
    return (published: await _createExclusive(tmp, target), copied: true);
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
      // Ours only while it still holds exactly the bytes written so far (their
      // size and hash), checked at the moment of deleting.
      final prefix = ContentIdentity(written, await contentHashOfStream(tmp.openRead(0, written)));
      await deleteFileIfMatches(target, identity: prefix);
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
        } else {
          // The good copy is gone again: what was kept aside is all that is left there.
          for (final k in copy.damagedKept) {
            if (k.path == p) k.replaced = false;
          }
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
