// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'coordination.dart';
import 'dataless.dart' show hasStub;

/// Moves the finished file [tmp] to [target] only if nothing is at [target]
/// at the moment of publishing. There is no check-then-rename window: the
/// operating system makes the decision atomically.
///
/// Returns true when published; [tmp] is then gone, except on POSIX in the
/// rare case that removing the temporary name failed after two tries: the page
/// is published, and [tmp] stays as a second hard link to the same file, so
/// writing through it would change the target. Callers must use a unique temp
/// name per call and never reopen it.
/// Returns false when a file is at [target] now (it existed, or was created
/// while this ran); [tmp] is left in place for the caller to remove or retry,
/// and [target] is never touched.
/// Throws a [FileSystemException] for any other failure (for example [tmp] or
/// the target's folder is missing), including a platform or file system that
/// can't do this. Volumes without hard links (exFAT/FAT, some FUSE and SMB
/// mounts, Android shared storage) throw on POSIX; callers must then choose
/// their own non-replacing fallback. It never falls back to replacing.
///
/// This blocks the calling isolate while the OS call runs (one short file
/// system call). Write and flush [tmp] before calling, in the same folder as
/// [target] so the publish stays on one volume.
///
/// [beforeOsCall] runs immediately before the OS call, after any checking the
/// implementation does; it is a seam for tests.
///
/// - **Windows**: `MoveFileExW` without `MOVEFILE_REPLACE_EXISTING`, on `\\?\`
///   paths so long paths work.
/// - **Linux, macOS, iOS**, and **Android where `link` works**: `link(tmp,
///   target)` (fails with EEXIST), then `unlink(tmp)`.
/// - **Android with `link` refused (EACCES, EPERM), API 30 and up**:
///   `renameat2(RENAME_NOREPLACE)`. The kernel decides atomically; EEXIST is
///   false.
/// - **Android with `link` refused, API 26 to 29** (no `renameat2`, and the raw
///   syscall may be killed by seccomp), **or `renameat2` returning ENOSYS or
///   EINVAL**: an lstat, then `rename(2)`, in the same synchronous call (no
///   `await` between them). Noted is then the only writer in its private
///   storage, and the check and the rename run in its only writing isolate.
/// - **Android with no publisher registered** (see [nonLinkPublisher]): `link`,
///   which throws.
///
/// Under a registered coordinator (`coordination.dart`) the call runs inside
/// it, naming the folders as writes and [tmp] as a move; a [StorageBusy] means
/// nothing was written. With none registered it runs directly.
Future<bool> publishExclusive(
  File tmp,
  String target, {
  void Function()? beforeOsCall,
}) {
  String folder(String p) => folderOf(p);
  final targetFolder = folder(target), sourceFolder = folder(tmp.path);
  return coordinated(
    CoordinatedWrite([
      CoordinationIntent(targetFolder, CoordinationKind.write),
      if (sourceFolder != targetFolder)
        CoordinationIntent(sourceFolder, CoordinationKind.write),
      CoordinationIntent(tmp.path, CoordinationKind.move),
    ]),
    () => publishExclusiveUncoordinated(tmp, target, beforeOsCall: beforeOsCall),
  );
}

/// Android's publisher, registered once at start by `useRenamePublishOnAndroid`
/// (`exclusive_move.dart`, which is outside the MCP server's import graph).
/// `(tmp, target, beforeOsCall)` gives true when published and false when
/// something is at the target, and throws a [FileSystemException] otherwise.
/// With none registered, Android uses its own `link` as every POSIX system
/// does: it fails safe (throws) and never replaces. Not exported by the
/// package's libraries.
bool Function(String from, String to, void Function()? beforeOsCall)?
nonLinkPublisher;

/// A test seam: makes every `link` call of the publish fail with this errno
/// without calling. Null in production. Not exported by the package's libraries.
int? debugLinkErrno;

/// A test seam: how many times the publish tried `link` (a forced failure
/// counts). Not exported by the package's libraries.
int debugLinkCalls = 0;

/// A test seam: true takes the Android branch on any platform, false never
/// does. Null in production (the platform decides). Not exported by the
/// package's libraries.
bool? debugPublishAsAndroid;

/// [publishExclusive] without the coordination hook, for the primitives that
/// are already inside their one coordinated call. Not exported by the
/// package's libraries.
Future<bool> publishExclusiveUncoordinated(
  File tmp,
  String target, {
  void Function()? beforeOsCall,
}) async => _publishExclusiveSync(tmp, target, beforeOsCall: beforeOsCall);

bool _publishExclusiveSync(
  File tmp,
  String target, {
  void Function()? beforeOsCall,
}) {
  final from = tmp.path;
  // A stubbed name (`.<name>.icloud`) is taken: nothing is published over a
  // file that is not downloaded.
  if (hasStub(target)) return false;
  final bool ok;
  try {
    if (debugPublishAsAndroid ?? Platform.isAndroid) {
      final publisher = nonLinkPublisher;
      ok = publisher != null
          ? publisher(from, target, beforeOsCall)
          : _linkPosix(from, target, beforeOsCall);
    } else if (Platform.isWindows) {
      checkWindowsName(target);
      ok = _moveWindows(windowsPath(from), windowsPath(target), beforeOsCall);
    } else if (Platform.isLinux ||
        Platform.isMacOS ||
        Platform.isIOS ||
        Platform.isAndroid) {
      ok = _linkPosix(from, target, beforeOsCall);
    } else {
      throw FileSystemException(
        'Exclusive publish is not supported here',
        target,
      );
    }
  } on FileSystemException {
    rethrow;
  } catch (e) {
    // FFI unavailable or a symbol is missing: fail safe, never replace.
    throw FileSystemException('Exclusive publish failed: $e', target);
  }
  if (ok) return true;
  // The call failed. If something is at the target, that is the reason.
  if (FileSystemEntity.typeSync(target, followLinks: false) !=
      FileSystemEntityType.notFound) {
    return false;
  }
  throw FileSystemException('Could not publish the file', target);
}

// --- Windows ---------------------------------------------------------------

typedef _MoveFileExC = Int32 Function(Pointer<Uint16>, Pointer<Uint16>, Uint32);
typedef _MoveFileExD = int Function(Pointer<Uint16>, Pointer<Uint16>, int);
typedef _AllocC = Pointer<Void> Function(Uint32, IntPtr);
typedef _AllocD = Pointer<Void> Function(int, int);
typedef _FreeC = Pointer<Void> Function(Pointer<Void>);
typedef _FreeD = Pointer<Void> Function(Pointer<Void>);

bool _moveWindows(String from, String to, void Function()? hook) {
  final k32 = DynamicLibrary.open('kernel32.dll');
  final move = k32.lookupFunction<_MoveFileExC, _MoveFileExD>('MoveFileExW');
  final alloc = k32.lookupFunction<_AllocC, _AllocD>('LocalAlloc');
  final free = k32.lookupFunction<_FreeC, _FreeD>('LocalFree');
  final a = _wide(alloc, from);
  final b = _wide(alloc, to);
  try {
    // Flags 0: no MOVEFILE_REPLACE_EXISTING, so an existing target fails.
    hook?.call();
    return move(a, b, 0) != 0;
  } finally {
    free(a.cast());
    free(b.cast());
  }
}

Pointer<Uint16> _wide(_AllocD alloc, String s) {
  final units = s.codeUnits;
  final p = alloc(
    0x40 /* LPTR: zeroed */,
    (units.length + 1) * 2,
  ).cast<Uint16>();
  if (p.address == 0) throw StateError('out of memory');
  p.asTypedList(units.length + 1).setAll(0, units);
  return p;
}

// --- POSIX -----------------------------------------------------------------

typedef _Link2C = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _Link2D = int Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _UnlinkC = Int32 Function(Pointer<Uint8>);
typedef _UnlinkD = int Function(Pointer<Uint8>);
typedef _MallocC = Pointer<Void> Function(IntPtr);
typedef _MallocD = Pointer<Void> Function(int);
typedef _FreeVC = Void Function(Pointer<Void>);
typedef _FreeVD = void Function(Pointer<Void>);

bool _linkPosix(String from, String to, void Function()? hook) {
  if (debugLinkErrno != null) {
    hook?.call();
    debugLinkCalls++;
    return false;
  }
  final libc = DynamicLibrary.process();
  final link = libc.lookupFunction<_Link2C, _Link2D>('link');
  final unlink = libc.lookupFunction<_UnlinkC, _UnlinkD>('unlink');
  final malloc = libc.lookupFunction<_MallocC, _MallocD>('malloc');
  final free = libc.lookupFunction<_FreeVC, _FreeVD>('free');
  final a = _cString(malloc, from);
  final b = _cString(malloc, to);
  try {
    hook?.call();
    debugLinkCalls++;
    if (link(a, b) != 0) return false;
    // The target now exists with the full content; drop the temp name. If
    // this fails twice the page is still safely published, so don't report an
    // error; the temp name stays as a second link (see [publishExclusive]).
    if (unlink(a) != 0) unlink(a);
    return true;
  } finally {
    free(a.cast());
    free(b.cast());
  }
}

Pointer<Uint8> _cString(_MallocD malloc, String s) {
  final bytes = utf8.encode(s);
  final p = malloc(bytes.length + 1).cast<Uint8>();
  if (p.address == 0) throw StateError('out of memory');
  p.asTypedList(bytes.length + 1)
    ..setAll(0, bytes)
    ..[bytes.length] = 0;
  return p;
}

// --- Windows paths -----------------------------------------------------------

final _reservedName = RegExp(
  r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
  caseSensitive: false,
);

/// Throws if the last name of [path] is one Windows would quietly change
/// (trailing dot or space) or treat as a device (CON, NUL, COM1, ... with or
/// without an extension).
///
/// Public for `exclusive_move.dart` and `file_stamp.dart`; not exported by the
/// package's libraries.
void checkWindowsName(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  if (name.endsWith('.') || name.endsWith(' ')) {
    throw FileSystemException('Name ends with a dot or a space', path);
  }
  if (_reservedName.hasMatch(name.split('.').first.trimRight())) {
    throw FileSystemException('Reserved device name', path);
  }
}

/// [path] as Dart would see it (absolute, backslashes, no `.` or `..` parts),
/// with the `\\?\` (or `\\?\UNC\`) prefix added only when it is 260 characters
/// or longer, which turns off the length limit. `\\.\` and `\\?\` paths pass
/// through unchanged. A drive-relative path (`D:foo`) on another drive throws.
///
/// Public for `exclusive_move.dart` and `file_stamp.dart`; not exported by the
/// package's libraries.
String windowsPath(String path) {
  var s = path.replaceAll('/', r'\');
  if (s.startsWith(r'\\.\') || s.startsWith(r'\\?\')) return s;
  final drive = RegExp(r'^([A-Za-z]):(?!\\)').firstMatch(s);
  if (drive != null) {
    final cwd = Directory.current.path;
    if (cwd.length < 2 ||
        cwd[1] != ':' ||
        cwd[0].toLowerCase() != drive[1]!.toLowerCase()) {
      throw FileSystemException('Drive-relative path on another drive', path);
    }
    s = s.substring(2);
  }
  s = File(s).absolute.path.replaceAll('/', r'\');
  final unc = s.startsWith(r'\\');
  final parts = s
      .substring(unc ? 2 : 0)
      .split(r'\')
      .where((e) => e.isNotEmpty && e != '.')
      .toList();
  // The root ("C:" or "server" and "share") can't be removed by "..".
  final rootLen = unc ? 2 : 1;
  final out = <String>[];
  for (final e in parts) {
    if (e == '..') {
      if (out.length > rootLen) out.removeLast();
      continue;
    }
    out.add(e);
  }
  final plain = (unc ? r'\\' : '') + out.join(r'\');
  if (plain.length < 260) return plain;
  return (unc ? r'\\?\UNC\' : r'\\?\') + out.join(r'\');
}
