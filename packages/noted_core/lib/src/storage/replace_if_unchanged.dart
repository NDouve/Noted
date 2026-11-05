// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:math';

import '../attachments/attachments.dart';
import '../merge/conflict_copy.dart';
import 'exclusive_publish.dart';

/// The ending of the unique name a file is moved to while it is being replaced.
/// [PageStore.scan] puts any such file left behind back (see [sweepAsideFiles]).
const String asideSuffix = '.cas-old';

/// The ending of the aside file once its bytes were verified equal to what the
/// caller expected. Such a file is still never deleted because the target is
/// occupied: it may be the only durable copy of that version, so it is kept as a
/// conflict copy (see [sweepAsideFiles]).
const String verifiedSuffix = '.cas-verified';

/// What [replaceIfUnchanged] did.
enum ReplaceOutcome {
  /// The target held exactly the expected bytes and now holds the new file.
  replaced,

  /// The target did not hold the expected bytes (it changed, or it is gone
  /// while bytes were expected, or it exists while absence was expected). The
  /// new file was not published and the target was not touched (or was put
  /// back, byte for byte). The caller should reread and retry.
  changed,

  /// The target did not hold the expected bytes, and while it was set aside a
  /// newer file appeared at the target. The newer file is untouched, and the
  /// file that was set aside is kept at [ReplaceResult.keptPath].
  changedKept,

  /// The target held the expected bytes, and while it was set aside a newer
  /// file appeared at the target, so the new file was not published. The newer
  /// file is untouched; the set-aside copy of the expected version is never
  /// deleted: it is kept as a conflict copy of the target (a name that
  /// [conflictCopyOriginalNames] recognises) at [ReplaceResult.keptPath], or,
  /// if even that failed, under its set-aside name for [sweepAsideFiles].
  supersededKept,
}

class ReplaceResult {
  const ReplaceResult(this.outcome, [this.keptPath]);

  final ReplaceOutcome outcome;

  /// A file left behind under its own name. After [ReplaceOutcome.supersededKept]
  /// that is usually a conflict copy of the target (`<stem>-conflict-<hex><ext>`,
  /// see [conflictCopyName]); otherwise it ends in [asideSuffix] (or
  /// [verifiedSuffix] if no conflict copy could be made), and the next
  /// [PageStore.scan] turns it back into a page or a conflict copy. Null when
  /// nothing was left behind.
  final String? keptPath;

  bool get replaced => outcome == ReplaceOutcome.replaced;

  @override
  String toString() => 'ReplaceResult($outcome, $keptPath)';
}

final Random _random = Random.secure();

String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

/// The ending of [name] that [conflictCopyName] keeps: `.canvas`, or whatever
/// follows the last dot (empty when there is none).
String _extensionOf(String name) {
  if (name.endsWith('.canvas')) return '.canvas';
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot);
}

/// Moves [file] (which holds data that must not be lost) to a conflict-copy
/// name beside [target], never over anything. Returns the new path, or null if
/// that failed (the file then stays where it is, under its set-aside name).
Future<String?> _keepAsConflictCopy(File file, String target, String label) async {
  final name = _baseName(target);
  final ext = _extensionOf(name);
  final dir = File(target).parent.path;
  final sep = Platform.pathSeparator;
  for (var attempt = 0; attempt < 8; attempt++) {
    final path = '$dir$sep${conflictCopyName(name, label: label, extension: ext, random: _random)}';
    try {
      if (await publishExclusive(file, path)) {
        await _dropLeftoverLink(file, path);
        return path;
      }
    } on FileSystemException {
      if (attempt >= 3) return null;
      await Future<void>.delayed(Duration(milliseconds: 25 * (attempt + 1)));
    }
  }
  return null;
}

/// On POSIX [publishExclusive] can rarely leave the source as a second hard link
/// to the published file. Remove it, but only if it still holds the same bytes
/// (so it is our link, not something that took the name since).
Future<void> _dropLeftoverLink(File source, String published) async {
  try {
    if (!await source.exists()) return;
    final a = await source.readAsBytes();
    if (_same(a, await File(published).readAsBytes())) await source.delete();
  } on FileSystemException {
    // Leave it; the sweep treats it as a leftover and finds the target taken.
  }
}

String _asideName(String target) =>
    '$target.$pid-${_random.nextInt(1 << 32).toRadixString(16)}-'
    '${_random.nextInt(1 << 32).toRadixString(16)}$asideSuffix';

/// Replaces the file at [target] with the finished file [tmp], only if the
/// target holds exactly [expected] when it is replaced; [expected] null means
/// no file is expected there (the same as [publishExclusive]).
///
/// When [expected] is null, or the target plainly differs from it, nothing is
/// moved. Otherwise the target is moved aside to a unique name (which captures
/// exactly the file being replaced), its bytes are compared with [expected]
/// again, and only then is [tmp] published with [publishExclusive], which never
/// replaces. The aside file is deleted only after its bytes were verified equal
/// to [expected]; one that is not equal is put back with [publishExclusive],
/// never over anything, retrying a few times on transient errors. If a newer
/// file appeared at [target] in the meantime, it is left alone and the aside
/// file stays under its own name ([ReplaceResult.keptPath]).
///
/// Limits. Between moving aside and publishing, [target] is briefly absent; a
/// reader that opens it in that moment finds no page and should retry. On
/// POSIX the move captures the file by name, so a writer that already holds the
/// old file open and keeps writing into it in place (rather than replacing it
/// the way sync clients and this class do) is not detected; its later writes go
/// to the set-aside file.
///
/// [tmp] is consumed when replaced and left in place on every other path,
/// including a throw, for the caller to remove. A [FileSystemException] means
/// "retry later": the target is in use by another process (for example a sync
/// client or virus scanner has it open on Windows), is not a plain file, or the
/// platform can't publish exclusively. Nothing has changed then, unless the
/// message says the original is kept under another name, in which case the next
/// [PageStore.scan] puts it back.
///
/// Test seams, each run at the named point: [beforeMoveAside] just before the
/// target is moved aside, [afterRead] after the aside file's bytes were read
/// (the target is absent then), [beforePublish] just before [tmp] is published,
/// and [beforeRestore] just before the aside file is put back.
Future<ReplaceResult> replaceIfUnchanged(
  File tmp,
  String target,
  List<int>? expected, {
  void Function()? beforeMoveAside,
  void Function()? afterRead,
  void Function()? beforePublish,
  void Function()? beforeRestore,
}) async {
  if (expected == null) {
    final ok = await publishExclusive(tmp, target, beforeOsCall: beforePublish);
    return ReplaceResult(ok ? ReplaceOutcome.replaced : ReplaceOutcome.changed);
  }
  // Don't move anything when it plainly can't match.
  try {
    if (!_same(await File(target).readAsBytes(), expected)) {
      return const ReplaceResult(ReplaceOutcome.changed);
    }
  } on FileSystemException {
    if (FileSystemEntity.typeSync(target, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return const ReplaceResult(ReplaceOutcome.changed);
    }
    rethrow;
  }

  var aside = File(_asideName(target));
  beforeMoveAside?.call();
  try {
    await File(target).rename(aside.path);
  } on FileSystemException catch (e) {
    // Not found: it vanished or was replaced since the read above.
    if (_isNotFound(e)) return const ReplaceResult(ReplaceOutcome.changed);
    rethrow;
  }

  // The aside file is exactly what was at the target. Compare it.
  final bool equal;
  try {
    equal = _same(await aside.readAsBytes(), expected);
    afterRead?.call();
  } catch (_) {
    await _putBack(aside, target, beforeRestore);
    rethrow;
  }
  if (!equal) {
    return _restore(aside, target, beforeRestore, ReplaceOutcome.changed);
  }

  // Mark it verified (a unique name, so this never replaces). The mark records
  // that the bytes equal what the caller held; it does not make the file
  // disposable. The sweep keeps a verified leftover as a conflict copy when the
  // target is occupied. Trade-off: a crash after our own publish succeeded
  // leaves the verified aside beside our new file, and the sweep turns it into a
  // conflict copy of the older version, so a box deleted in that save can come
  // back after the merge. That is preferred to losing the only copy. If the
  // rename fails the original is put back and the error is the caller's.
  try {
    final base = aside.path.substring(0, aside.path.length - asideSuffix.length);
    aside = await aside.rename('$base$verifiedSuffix');
  } catch (_) {
    await _putBack(aside, target, beforeRestore);
    rethrow;
  }

  final bool ok;
  try {
    ok = await _retry(
      () => publishExclusive(tmp, target, beforeOsCall: beforePublish),
    );
  } catch (_) {
    await _putBack(aside, target, beforeRestore);
    rethrow;
  }
  // Not published because a newer file is at the target. The verified file is
  // never deleted here: the caller only held a copy in memory, and the file may
  // be the one durable copy of that version (0128). It is kept as a conflict
  // copy next to the target, which the conflict-copy merge picks up.
  if (!ok) {
    final copy = await _keepAsConflictCopy(aside, target, 'conflict');
    return ReplaceResult(ReplaceOutcome.supersededKept, copy ?? aside.path);
  }
  // Verified equal to what the caller expected: safe to drop.
  try {
    await aside.delete();
  } on FileSystemException {
    return ReplaceResult(ReplaceOutcome.replaced, aside.path);
  }
  return const ReplaceResult(ReplaceOutcome.replaced);
}

/// Puts back every file in [directory] that a crashed or failed
/// [replaceIfUnchanged] left under an [asideSuffix] or [verifiedSuffix] name,
/// without ever replacing anything: each is published to the file it was moved
/// from if that name is free. When the name is occupied (a newer file was
/// written there), the leftover is renamed to a conflict-copy name beside the
/// target (see [conflictCopyName]; `<id>-recovered-<random>.canvas` for an
/// [asideSuffix] leftover, `<id>-conflict-<random>.canvas` for a verified
/// one), which [PageStore.scan] reports as a conflict copy of the page when
/// the ids match, or as an unreadable file otherwise. A leftover is never
/// deleted, verified or not: it may be the only durable copy of its version.
/// A leftover whose target does not end in [extension] is not touched;
/// [PageStore.scan] lists it (pass `extension: ''` to sweep any file, as for
/// an attachments folder). Returns the paths now holding the recovered files. A leftover
/// that can't be moved now is left for the next call.
///
/// Don't run it while a [replaceIfUnchanged] on the same folder is in flight;
/// it would take that call's aside file.
Future<List<String>> sweepAsideFiles(
  Directory directory, {
  String extension = '.canvas',
  bool Function(String targetName)? only,
}) async {
  final out = <String>[];
  if (!await directory.exists()) return out;
  final sep = Platform.pathSeparator;
  final leftovers = <File>[];
  await for (final f in directory.list(followLinks: false)) {
    if (f is File &&
        (f.path.endsWith(asideSuffix) || f.path.endsWith(verifiedSuffix))) {
      leftovers.add(f);
    }
  }
  for (final f in leftovers) {
    final name = f.path.split(RegExp(r'[\\/]')).last;
    final verified = name.endsWith(verifiedSuffix);
    final body = name.substring(
      0,
      name.length - (verified ? verifiedSuffix : asideSuffix).length,
    );
    final dot = body.lastIndexOf('.');
    if (dot <= 0) continue;
    final targetName = body.substring(0, dot);
    // Not a page file: leave it where it is; [PageStore.scan] lists it.
    if (!targetName.endsWith(extension)) continue;
    if (only != null && !only(targetName)) continue;
    final dir = f.parent.path;
    try {
      if (await publishExclusive(f, '$dir$sep$targetName')) {
        out.add('$dir$sep$targetName');
        continue;
      }
      // A newer file is at the target. Even a verified leftover is kept: it may
      // be the only durable copy of the version it holds (0128).
      final kept = await _keepAsConflictCopy(f, '$dir$sep$targetName', verified ? 'conflict' : 'recovered');
      if (kept != null) out.add(kept);
    } on FileSystemException {
      // Locked for now; the next scan tries again. It stays under its name.
    }
  }
  return out;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// 2: file not found (both platforms); 3: path not found (Windows).
bool _isNotFound(FileSystemException e) {
  final code = e.osError?.errorCode;
  return code == 2 || (Platform.isWindows && code == 3);
}

/// Runs [op], retrying a few times with short delays when it throws a
/// [FileSystemException] (another process may have the file open for a moment).
/// A false result is final.
Future<bool> _retry(Future<bool> Function() op) async {
  for (var attempt = 1;; attempt++) {
    try {
      return await op();
    } on FileSystemException {
      if (attempt >= 4) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 25 * attempt));
    }
  }
}

/// Puts [aside] back at [target] without replacing anything.
Future<ReplaceResult> _restore(
  File aside,
  String target,
  void Function()? hook,
  ReplaceOutcome same,
) async {
  final bool ok;
  try {
    ok = await _retry(
      () => publishExclusive(aside, target, beforeOsCall: hook),
    );
  } on FileSystemException catch (e) {
    throw FileSystemException(
      'Could not put the original back; it is kept as ${aside.path} '
      'and the next scan restores it: ${e.message}',
      target,
    );
  }
  if (ok) return ReplaceResult(same);
  return ReplaceResult(ReplaceOutcome.changedKept, aside.path);
}

/// Best-effort restore on an error path; the caller rethrows its own error. If
/// it fails the aside file stays, and the next scan puts it back.
/// Returns the path the file is kept at when it could not be put back at
/// [target], else null.
Future<String?> _putBack(File aside, String target, void Function()? hook) async {
  try {
    return (await _restore(aside, target, hook, ReplaceOutcome.changed)).keptPath;
  } catch (_) {
    return aside.path;
  }
}

/// What [deleteFileIfUnchanged] did.
enum DeleteOutcome {
  /// The target held exactly the expected bytes and is gone.
  deleted,

  /// There was no file at the target.
  absent,

  /// The target did not hold the expected bytes. It was not deleted (or was
  /// put back, byte for byte).
  changed,

  /// As [changed], but while the file was set aside something new appeared at
  /// the target. The new file is untouched, and the file that was set aside is
  /// kept at [DeleteResult.keptPath] under an [asideSuffix] name, which the
  /// next [PageStore.scan] turns into a page or a conflict copy.
  changedKept,
}

class DeleteResult {
  const DeleteResult(this.outcome, [this.keptPath]);

  final DeleteOutcome outcome;
  final String? keptPath;

  bool get deleted => outcome == DeleteOutcome.deleted;

  @override
  String toString() => 'DeleteResult($outcome, $keptPath)';
}

/// A file's content identity: its length and the SHA-256 of its bytes (the same
/// hash as [contentHash], which names attachments). For deleting a file that
/// is too big to hold in memory, or whose bytes the caller no longer has.
class ContentIdentity {
  const ContentIdentity(this.length, this.sha256);

  /// The identity of [bytes].
  factory ContentIdentity.ofBytes(List<int> bytes) =>
      ContentIdentity(bytes.length, contentHash(bytes));

  /// The identity of the file at [path], read as a stream.
  static Future<ContentIdentity> ofFile(String path) async {
    final f = File(path);
    return ContentIdentity(await f.length(), await contentHashOfStream(f.openRead()));
  }

  final int length;

  /// Lowercase hex.
  final String sha256;

  @override
  bool operator ==(Object other) =>
      other is ContentIdentity && other.length == length && other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(length, sha256);

  @override
  String toString() => 'ContentIdentity($length, $sha256)';
}

/// Deletes the file at [target] only if it holds exactly [expected] at the
/// moment of deleting; see [deleteFileIfMatches], which this calls.
Future<DeleteResult> deleteFileIfUnchanged(
  String target,
  List<int> expected, {
  void Function()? beforeMoveAside,
  void Function()? afterRead,
  Future<void> Function()? beforeDelete,
  void Function()? beforeRestore,
}) => deleteFileIfMatches(
  target,
  bytes: expected,
  beforeMoveAside: beforeMoveAside,
  afterRead: afterRead,
  beforeDelete: beforeDelete,
  beforeRestore: beforeRestore,
);

/// Deletes the file at [target] (any file: a page or an attachment) only if it
/// holds exactly [bytes], or has the content [identity], at the moment of
/// deleting; give exactly one. The file is first moved aside to a unique name
/// (which captures exactly the file being deleted) and compared; only a file
/// that matches is deleted. One that differs is put back with
/// [publishExclusive], never over anything; if a file appeared at [target] in
/// the meantime, the set-aside file stays under its [asideSuffix] name
/// ([DeleteResult.keptPath]). Limits and error behaviour are those of
/// [replaceIfUnchanged]: the target is briefly absent, and a
/// [FileSystemException] means "retry later" with the original kept (see
/// there). If the set-aside file can't be put back after an error, the thrown
/// [FileSystemException] names the path it is kept at; a file that isn't a page
/// is brought back only when the caller sweeps its folder with
/// [sweepAsideFiles] and `extension: ''`: [PageStore.scan] sweeps `.canvas`
/// files only and does not look inside assets folders, so whoever deletes
/// attachments must sweep them (the app does not do so yet).
///
/// Crash window: the file is only set aside, not yet deleted, between the
/// move-aside and the final delete. A crash there leaves it under its
/// [asideSuffix] name; the next [sweepAsideFiles] of the folder (run by [PageStore.scan] for
/// pages; the caller's job for other files) puts it back, so the page reappears (a duplicate of what the caller meant
/// to delete). Nothing is lost.
///
/// Test seams: [beforeMoveAside], [afterRead] (the target is absent), the
/// asynchronous [beforeDelete] (the verified file is still set aside) and
/// [beforeRestore], as in [replaceIfUnchanged].
Future<DeleteResult> deleteFileIfMatches(
  String target, {
  List<int>? bytes,
  ContentIdentity? identity,
  void Function()? beforeMoveAside,
  void Function()? afterRead,
  Future<void> Function()? beforeDelete,
  void Function()? beforeRestore,
}) async {
  if ((bytes == null) == (identity == null)) {
    throw ArgumentError('give exactly one of bytes and identity');
  }
  Future<bool> matches(File f) async {
    if (bytes != null) return _same(await f.readAsBytes(), bytes);
    // The length is cheap to compare before hashing.
    if (await f.length() != identity!.length) return false;
    return await contentHashOfStream(f.openRead()) == identity.sha256;
  }

  try {
    if (!await matches(File(target))) {
      return const DeleteResult(DeleteOutcome.changed);
    }
  } on FileSystemException {
    if (FileSystemEntity.typeSync(target, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return const DeleteResult(DeleteOutcome.absent);
    }
    rethrow;
  }
  final aside = File(_asideName(target));
  beforeMoveAside?.call();
  try {
    await File(target).rename(aside.path);
  } on FileSystemException catch (e) {
    if (_isNotFound(e)) return const DeleteResult(DeleteOutcome.absent);
    rethrow;
  }
  final bool equal;
  try {
    equal = await matches(aside);
    afterRead?.call();
  } catch (e) {
    await _putBackOrThrow(aside, target, beforeRestore, e);
    rethrow;
  }
  if (!equal) {
    final r = await _restore(aside, target, beforeRestore, ReplaceOutcome.changed);
    return r.keptPath == null
        ? const DeleteResult(DeleteOutcome.changed)
        : DeleteResult(DeleteOutcome.changedKept, r.keptPath);
  }
  try {
    if (beforeDelete != null) await beforeDelete();
    await aside.delete();
  } catch (e) {
    await _putBackOrThrow(aside, target, beforeRestore, e);
    rethrow;
  }
  return const DeleteResult(DeleteOutcome.deleted);
}

/// As [_putBack], but when the file could not be put back where it was (the
/// target is occupied, or the restore failed) throws a [FileSystemException]
/// naming the path it is kept at, so it is never lost silently.
Future<void> _putBackOrThrow(
  File aside,
  String target,
  void Function()? hook,
  Object cause,
) async {
  final kept = await _putBack(aside, target, hook);
  if (kept != null) {
    throw FileSystemException(
      'Could not put the original back; it is kept as $kept ($cause)',
      target,
    );
  }
}
