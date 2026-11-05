// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ffi';
import 'dart:io';

/// What most likely stops Noted from writing, checked when a save and the
/// recovery write both failed (R-1 v5, state 4). The app only: `noted_mcp` may
/// not import `dart:ffi`.
enum StorageCauseKind {
  diskFull,
  driveFailing,
  notWritable,
  recoveryUnavailable,
  other,
}

class StorageCause {
  const StorageCause(this.kind, this.summary, this.advice);

  final StorageCauseKind kind;

  /// One plain sentence for the warning.
  final String summary;

  /// What to do about it.
  final String advice;
}

/// Always shown with the advice.
const String saveCopyAdvice =
    'Save a copy elsewhere or copy the text before closing Noted.';

/// The cause for [error], by the operating system's error code alone. The code
/// is read per platform: 5 is "access denied" on Windows and EIO on POSIX.
/// [os] is for tests (`windows`, `linux`, `macos`).
StorageCauseKind? classifyErrorCode(Object error, {String? os}) {
  if (error is! FileSystemException) return null;
  final code = error.osError?.errorCode;
  if (code == null) return null;
  final windows = (os ?? Platform.operatingSystem) == 'windows';
  if (windows) {
    if (code == 112 || code == 39) return StorageCauseKind.diskFull;
    if (const {21, 23, 483, 1117, 1167}.contains(code)) {
      return StorageCauseKind.driveFailing;
    }
    if (const {5, 32, 19}.contains(code)) return StorageCauseKind.notWritable;
  } else {
    if (code == 28) return StorageCauseKind.diskFull;
    if (const {5, 6, 19}.contains(code)) return StorageCauseKind.driveFailing;
    if (const {13, 1, 30}.contains(code)) return StorageCauseKind.notWritable;
  }
  return null;
}

String _osMessage(Object error) {
  final m = error is FileSystemException ? error.osError?.message.trim() : null;
  if (m != null && m.isNotEmpty) {
    return m.endsWith('.') ? m.substring(0, m.length - 1) : m;
  }
  return error is FileSystemException && error.message.isNotEmpty
      ? error.message
      : '$error';
}

String _human(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).ceil()} KB';
}

/// Works out the cause. Causes are checked in this order: disk full, drive
/// failing or gone, data folder not writable, otherwise the OS message.
/// [needed] is how many bytes the page needs; [recoveryFailure] is the error
/// of the recovery write, if that is what failed.
Future<StorageCause> checkStorage(
  Object error, {
  required Directory recoveryDirectory,
  int needed = 0,
  Object? recoveryFailure,
  String? os,
}) async {
  final errors = [error, ?recoveryFailure];
  final kinds = [for (final e in errors) classifyErrorCode(e, os: os)];
  int? free;
  try {
    free = freeSpaceBytes(recoveryDirectory.path);
  } on Object {
    free = null;
  }
  if (kinds.contains(StorageCauseKind.diskFull) ||
      (free != null && needed > 0 && free < needed * 2)) {
    final left = free == null ? '' : ' ${_human(free)} is left.';
    final need = needed > 0 ? ' Noted needs about ${_human(needed * 2)}.' : '';
    return StorageCause(
      StorageCauseKind.diskFull,
      'The disk is full.$left',
      'Free up space (empty the Recycle Bin, move large files).$need Then press Retry. $saveCopyAdvice',
    );
  }
  var rootGone = false;
  try {
    final root = _volumeRoot(recoveryDirectory.absolute.path);
    rootGone = root != null && !Directory(root).existsSync();
  } on Object {
    rootGone = false;
  }
  if (rootGone || kinds.contains(StorageCauseKind.driveFailing)) {
    return const StorageCause(
      StorageCauseKind.driveFailing,
      'The drive holding Noted\'s data is failing or not there.',
      'Save a copy elsewhere now, then check the drive.',
    );
  }
  final probe = await _probe(recoveryDirectory);
  if (!probe || kinds.contains(StorageCauseKind.notWritable)) {
    return StorageCause(
      StorageCauseKind.notWritable,
      "Noted can't write to its data folder, ${recoveryDirectory.path}.",
      'Check your antivirus, Controlled Folder Access and the folder\'s read-only flag. $saveCopyAdvice',
    );
  }
  return StorageCause(
    StorageCauseKind.other,
    "Noted couldn't write (${_osMessage(errors.last)}).",
    saveCopyAdvice,
  );
}

String? _volumeRoot(String path) {
  if (Platform.isWindows) {
    final m = RegExp(r'^[A-Za-z]:\\').firstMatch(path);
    return m?.group(0);
  }
  return null;
}

// Whether a probe file can be created and removed in [dir]. The folder is
// created if it is missing (as a recovery write would).
Future<bool> _probe(Directory dir) async {
  final f = File(
    '${dir.path}${Platform.pathSeparator}noted-write-check-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}.probe',
  );
  try {
    await dir.create(recursive: true);
    await f.writeAsString('x', flush: true);
    await f.delete();
    return true;
  } on Object {
    try {
      if (f.existsSync()) f.deleteSync();
    } on Object {
      // A leftover is removed by the next check.
    }
    return false;
  }
}

// --- Free space (Windows only; no figure elsewhere) ----------------------------

typedef _FreeExC = Int32 Function(
  Pointer<Uint16>,
  Pointer<Uint64>,
  Pointer<Uint64>,
  Pointer<Uint64>,
);
typedef _FreeExD = int Function(
  Pointer<Uint16>,
  Pointer<Uint64>,
  Pointer<Uint64>,
  Pointer<Uint64>,
);
typedef _AllocC = Pointer<Void> Function(Uint32, IntPtr);
typedef _AllocD = Pointer<Void> Function(int, int);
typedef _FreeC = Pointer<Void> Function(Pointer<Void>);
typedef _FreeD = Pointer<Void> Function(Pointer<Void>);

/// Free bytes on the volume holding [path] for this user, or null where
/// unknown (not Windows, or the call failed).
int? freeSpaceBytes(String path) {
  if (!Platform.isWindows) return null;
  final k32 = DynamicLibrary.open('kernel32.dll');
  final getFree = k32.lookupFunction<_FreeExC, _FreeExD>('GetDiskFreeSpaceExW');
  final alloc = k32.lookupFunction<_AllocC, _AllocD>('LocalAlloc');
  final free = k32.lookupFunction<_FreeC, _FreeD>('LocalFree');
  // The nearest folder that exists: the recovery folder may be gone.
  var dir = Directory(path).absolute;
  while (!dir.existsSync() && dir.parent.path != dir.path) {
    dir = dir.parent;
  }
  final units = dir.path.codeUnits;
  final p = alloc(0x40, (units.length + 1) * 2).cast<Uint16>();
  final out = alloc(0x40, 8).cast<Uint64>();
  if (p.address == 0 || out.address == 0) return null;
  try {
    p.asTypedList(units.length + 1).setAll(0, units);
    final ok = getFree(
      p,
      out,
      Pointer<Uint64>.fromAddress(0),
      Pointer<Uint64>.fromAddress(0),
    );
    return ok == 0 ? null : out.value;
  } finally {
    free(p.cast());
    free(out.cast());
  }
}
