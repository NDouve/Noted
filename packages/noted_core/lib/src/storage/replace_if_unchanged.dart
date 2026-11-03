// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:math';

import 'exclusive_publish.dart';

/// The ending of the unique name a file is moved to while it is being replaced.
/// [PageStore.scan] puts any such file left behind back (see [sweepAsideFiles]).
const String asideSuffix = '.cas-old';

/// The ending of the aside file once its bytes were verified equal to what the
/// caller expected: it holds nothing the caller doesn't already have.
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
  /// file is untouched; the set-aside copy of the expected version is kept at
  /// [ReplaceResult.keptPath].
  supersededKept,
}

class ReplaceResult {
  const ReplaceResult(this.outcome, [this.keptPath]);

  final ReplaceOutcome outcome;

  /// A file left behind under its own name (it ends in [asideSuffix], so the
  /// next [PageStore.scan] turns it back into a page or a conflict copy). Null
  /// when nothing was left behind.
  final String? keptPath;

  bool get replaced => outcome == ReplaceOutcome.replaced;

  @override
  String toString() => 'ReplaceResult($outcome, $keptPath)';
}

final Random _random = Random.secure();

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

  // Mark it verified (a unique name, so this never replaces). From here a
  // leftover holds only the version the caller already has, so the sweep may
  // delete it when the target is occupied, and a crash after a successful
  // publish doesn't bring deleted content back as a recovered copy. If the
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
  // the version the caller expected and already holds (it merged against it
  // and retries by rereading the target), so it is not unique data; it is kept
  // only until the caller or the sweep removes it.
  if (!ok) return ReplaceResult(ReplaceOutcome.supersededKept, aside.path);
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
/// written there), an [asideSuffix] leftover (not verified) is renamed to
/// `<id>-recovered-<random>.canvas`, which [PageStore.scan] reports as a
/// conflict copy of the page when the ids match, or as an unreadable file
/// otherwise; it is never deleted. A [verifiedSuffix] leftover was verified
/// equal to a version the caller held, so it is deleted instead. A leftover
/// whose target does not end in [extension] is not touched; [PageStore.scan]
/// lists it. Returns the paths now holding the recovered files. A leftover
/// that can't be moved now is left for the next call.
///
/// Don't run it while a [replaceIfUnchanged] on the same folder is in flight;
/// it would take that call's aside file.
Future<List<String>> sweepAsideFiles(
  Directory directory, {
  String extension = '.canvas',
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
    final dir = f.parent.path;
    try {
      if (await publishExclusive(f, '$dir$sep$targetName')) {
        out.add('$dir$sep$targetName');
        continue;
      }
      if (verified) {
        // Verified equal to a version the caller held, and a newer file is
        // at the target: nothing unique in it.
        await f.delete();
        continue;
      }
      var stem = targetName.substring(0, targetName.length - extension.length);
      if (stem.isEmpty) stem = 'page';
      final hex = _random.nextInt(1 << 32).toRadixString(16);
      final recovered = '$dir$sep$stem-recovered-$hex$extension';
      if (await publishExclusive(f, recovered)) out.add(recovered);
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
Future<void> _putBack(File aside, String target, void Function()? hook) async {
  try {
    await _restore(aside, target, hook, ReplaceOutcome.changed);
  } catch (_) {}
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

/// Deletes the file at [target] only if it holds exactly [expected] at the
/// moment of deleting. The file is first moved aside to a unique name (which
/// captures exactly the file being deleted) and its bytes compared; only a
/// file that is equal is deleted. One that differs is put back with
/// [publishExclusive], never over anything; if a file appeared at [target] in
/// the meantime, the set-aside file stays under its [asideSuffix] name
/// ([DeleteResult.keptPath]). Limits and error behaviour are those of
/// [replaceIfUnchanged]: target is briefly absent, and a [FileSystemException]
/// means "retry later" with the original kept (see there).
///
/// Test seams: [beforeMoveAside], [afterRead] (the target is absent) and
/// [beforeRestore], as in [replaceIfUnchanged].
Future<DeleteResult> deleteFileIfUnchanged(
  String target,
  List<int> expected, {
  void Function()? beforeMoveAside,
  void Function()? afterRead,
  void Function()? beforeRestore,
}) async {
  try {
    if (!_same(await File(target).readAsBytes(), expected)) {
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
    equal = _same(await aside.readAsBytes(), expected);
    afterRead?.call();
  } catch (_) {
    await _putBack(aside, target, beforeRestore);
    rethrow;
  }
  if (!equal) {
    final r = await _restore(aside, target, beforeRestore, ReplaceOutcome.changed);
    return r.keptPath == null
        ? const DeleteResult(DeleteOutcome.changed)
        : DeleteResult(DeleteOutcome.changedKept, r.keptPath);
  }
  try {
    await aside.delete();
  } catch (_) {
    await _putBack(aside, target, beforeRestore);
    rethrow;
  }
  return const DeleteResult(DeleteOutcome.deleted);
}
