// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// Why a page, binder file or attachment that is not downloaded is listed: the
/// text of the "Still downloading" row.
const String stillDownloading = 'Still downloading';

/// `SF_DATALESS` in Apple's `st_flags`: the file's data is not on this device.
const int sfDataless = 0x40000000;

// The byte offset of `st_flags` in the 64-bit-inode `struct stat` of macOS and
// iOS (*unverified*; probe I4 of the cloud-parity note).
const int _stFlagsAt = 116;

/// Whether the data of the file at [path] is not on this device, so that
/// reading it would make the system download it. Reads metadata only.
///
/// - macOS and iOS: `st_flags & SF_DATALESS` from a leaf `lstat`. If that call
///   can't be made (the symbol is missing) the failure is remembered and every
///   existing file then counts as dataless: it is never read (fail closed).
///   An `lstat` that fails for a file that exists counts as dataless too.
/// - A `.<name>.icloud` stub with no `<name>` beside it makes `<name>`
///   dataless, on any platform. A missing file with no stub is not dataless.
/// - Elsewhere an existing file is never dataless.
///
/// [statFlags] stands in for `st_flags` of an existing file (a test seam).
bool isDataless(String path, {int? statFlags}) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return hasStub(path);
  final marked = debugDatalessPaths;
  if (marked != null && marked.contains(debugDatalessKey(path))) return true;
  if (statFlags != null) return statFlags & sfDataless != 0;
  return _flagsSayDataless(path);
}

/// The name of the stub that stands for the file called [name]:
/// `.<name>.icloud`.
String stubNameOf(String name) => '.$name.icloud';

/// The file name [stubName] stands for (`.<name>.icloud` gives `<name>`), or
/// null when [stubName] is not a stub's name.
String? stubTargetName(String stubName) {
  const end = '.icloud';
  if (stubName.length <= end.length + 1) return null;
  if (!stubName.startsWith('.') || !stubName.endsWith(end)) return null;
  return stubName.substring(1, stubName.length - end.length);
}

/// Whether the stub of [path] (`.<name>.icloud`, in the same folder) is there.
/// The stub's own file is not the file: this says nothing about [path] itself.
bool hasStub(String path) {
  final cut = path.lastIndexOf(RegExp(r'[\\/]'));
  final stub =
      '${path.substring(0, cut + 1)}${stubNameOf(path.substring(cut + 1))}';
  return FileSystemEntity.typeSync(stub, followLinks: false) !=
      FileSystemEntityType.notFound;
}

// --- Apple: st_flags through lstat ------------------------------------------

// Leaf calls, so a Dart byte list's address can be passed without native
// memory of our own. The symbol is found in the running process. On macOS on
// Intel the plain `lstat` is the 32-bit-inode one, so the 64-bit-inode name is
// used there (*unverified*, I4); the other Apple ABIs have 64-bit inodes only.
@Native<Int32 Function(Pointer<Uint8>, Pointer<Uint8>)>(
  symbol: 'lstat',
  isLeaf: true,
)
external int _lstat(Pointer<Uint8> path, Pointer<Uint8> buf);

@Native<Int32 Function(Pointer<Uint8>, Pointer<Uint8>)>(
  symbol: r'lstat$INODE64',
  isLeaf: true,
)
external int _lstatInode64(Pointer<Uint8> path, Pointer<Uint8> buf);

/// A test seam: existing files that count as dataless (present, not
/// downloaded), by [debugDatalessKey]; null in production. Fill it with
/// [debugMarkDataless], never by hand.
Set<String>? debugDatalessPaths;

/// Makes the existing file at [path] count as dataless (a test seam).
void debugMarkDataless(String path) =>
    (debugDatalessPaths ??= <String>{}).add(debugDatalessKey(path));

/// Makes the file at [path] count as downloaded again (a test seam).
void debugUnmarkDataless(String path) =>
    debugDatalessPaths?.remove(debugDatalessKey(path));

/// The key of [path] in [debugDatalessPaths]: the resolved absolute path, in
/// lower case on Windows. A file that is not there has its folder resolved and
/// its name kept, so an 8.3 short path matches the long one.
String debugDatalessKey(String path) {
  var p = File(path).absolute.path;
  try {
    p = File(p).resolveSymbolicLinksSync();
  } on FileSystemException {
    final cut = p.lastIndexOf(RegExp(r'[\\/]'));
    try {
      final dir = Directory(p.substring(0, cut)).resolveSymbolicLinksSync();
      p = '$dir${Platform.pathSeparator}${p.substring(cut + 1)}';
    } on FileSystemException {
      // The folder is not there either: the absolute path stands.
    }
  }
  return Platform.isWindows ? p.toLowerCase() : p;
}

/// A test seam: the [Abi] to act as, null in production.
Abi? debugDatalessAbi;

/// The first failure of the `lstat` lookup, remembered; null while none.
Object? get debugDatalessLookupFailure => _lookupFailure;

/// Forgets a remembered lookup failure (a test seam).
void debugResetDataless() => _lookupFailure = null;

Object? _lookupFailure;

bool _flagsSayDataless(String path) {
  final abi = debugDatalessAbi ?? Abi.current();
  final apple =
      abi == Abi.macosX64 ||
      abi == Abi.macosArm64 ||
      abi == Abi.iosArm64 ||
      abi == Abi.iosX64;
  if (!apple) return false;
  // Remembered: every later check counts an existing file as dataless.
  if (_lookupFailure != null) return true;
  final name = _utf8z(path);
  final buf = Uint8List(256);
  final int code;
  try {
    // A separate call per ABI, each with its own symbol (see above).
    switch (abi) {
      case Abi.macosX64:
        code = _lstatInode64(name.address, buf.address);
      default:
        code = _lstat(name.address, buf.address);
    }
  } catch (e) {
    _lookupFailure = e;
    return true;
  }
  // An existing file that can't be examined is not read.
  if (code != 0) return true;
  final flags = ByteData.sublistView(buf).getUint32(_stFlagsAt, Endian.little);
  return flags & sfDataless != 0;
}

/// [s] as NUL-terminated UTF-8.
Uint8List _utf8z(String s) {
  final out = <int>[];
  for (final r in s.runes) {
    if (r < 0x80) {
      out.add(r);
    } else if (r < 0x800) {
      out
        ..add(0xC0 | (r >> 6))
        ..add(0x80 | (r & 0x3F));
    } else if (r < 0x10000) {
      out
        ..add(0xE0 | (r >> 12))
        ..add(0x80 | ((r >> 6) & 0x3F))
        ..add(0x80 | (r & 0x3F));
    } else {
      out
        ..add(0xF0 | (r >> 18))
        ..add(0x80 | ((r >> 12) & 0x3F))
        ..add(0x80 | ((r >> 6) & 0x3F))
        ..add(0x80 | (r & 0x3F));
    }
  }
  out.add(0);
  return Uint8List.fromList(out);
}
