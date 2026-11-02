// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

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
/// Windows: `MoveFileExW` without `MOVEFILE_REPLACE_EXISTING`, on `\\?\` paths
/// so long paths work. Linux, macOS, iOS, Android: `link(tmp, target)` (fails
/// with EEXIST), then `unlink(tmp)`.
Future<bool> publishExclusive(
  File tmp,
  String target, {
  void Function()? beforeOsCall,
}) async => publishExclusiveSync(tmp, target, beforeOsCall: beforeOsCall);

/// The synchronous form of [publishExclusive].
bool publishExclusiveSync(
  File tmp,
  String target, {
  void Function()? beforeOsCall,
}) {
  final from = tmp.path;
  final bool ok;
  try {
    if (Platform.isWindows) {
      _checkWindowsName(target);
      ok = _moveWindows(_windowsPath(from), _windowsPath(target), beforeOsCall);
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
  final libc = DynamicLibrary.process();
  final link = libc.lookupFunction<_Link2C, _Link2D>('link');
  final unlink = libc.lookupFunction<_UnlinkC, _UnlinkD>('unlink');
  final malloc = libc.lookupFunction<_MallocC, _MallocD>('malloc');
  final free = libc.lookupFunction<_FreeVC, _FreeVD>('free');
  final a = _cString(malloc, from);
  final b = _cString(malloc, to);
  try {
    hook?.call();
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
void _checkWindowsName(String path) {
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
String _windowsPath(String path) {
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
