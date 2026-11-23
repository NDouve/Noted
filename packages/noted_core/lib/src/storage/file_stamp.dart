// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'exclusive_publish.dart' show windowsPath;

/// A file's identity by metadata alone: the volume, the file id, the size and
/// the modification time. It says nothing about the content, and taking it
/// never reads the file's data (so it never downloads a cloud placeholder:
/// *unverified* on Windows).
///
/// Two stamps are equal when all four fields are. A rename keeps the stamp; a
/// replace or an append changes it.
final class FileStamp {
  const FileStamp({
    required this.volume,
    required this.fileId,
    required this.size,
    required this.modifiedNs,
  });

  /// The volume serial (Windows) or device number (POSIX).
  final int volume;

  /// The file id as lower-case hex (128 bits on Windows, the inode on POSIX).
  final String fileId;

  /// The size in bytes.
  final int size;

  /// The modification time, nanoseconds since 1970 (only compared, never shown).
  final int modifiedNs;

  @override
  bool operator ==(Object other) =>
      other is FileStamp &&
      other.volume == volume &&
      other.fileId == fileId &&
      other.size == size &&
      other.modifiedNs == modifiedNs;

  @override
  int get hashCode => Object.hash(volume, fileId, size, modifiedNs);

  @override
  String toString() => 'FileStamp($volume, $fileId, $size, $modifiedNs)';
}

/// A test seam: true makes [fileStamp] answer null for every path, as on a platform
/// that can't give a stamp.
bool noFileStampsForTest = false;

/// The stamp of the file or folder at [path] (a link is stamped, not followed),
/// from metadata only; no data access and no write call.
///
/// Returns null when the path is missing, and on any error from the platform
/// call or on a platform or file system that can't give the four fields (for
/// example no file id on FAT, or a 32-bit ABI): a null stamp only means "read
/// it".
FileStamp? fileStamp(String path) {
  if (noFileStampsForTest) return null;
  try {
    return rawFileInfo(path)?.stamp;
  } catch (_) {
    return null;
  }
}

/// What one metadata call tells about a path. Shared with `exclusive_move.dart`;
/// not exported by the package's libraries.
final class RawFileInfo {
  const RawFileInfo({
    required this.stamp,
    required this.isDirectory,
    required this.isLink,
    required this.placeholder,
  });

  /// Null when the platform or file system can't give a complete stamp.
  final FileStamp? stamp;
  final bool isDirectory;
  final bool isLink;

  /// The attributes say the data is not on this device (a cloud placeholder,
  /// or `SF_DATALESS` on Apple).
  final bool placeholder;
}

/// The metadata of [path] without following a link; null when it is missing or
/// the call fails. Throws only for unexpected FFI trouble (callers catch).
RawFileInfo? rawFileInfo(String path) {
  if (Platform.isWindows) return _winInfo(path);
  if (Platform.isLinux ||
      Platform.isAndroid ||
      Platform.isMacOS ||
      Platform.isIOS) {
    return _posixInfo(path);
  }
  return null;
}

// --- Native memory (shared with exclusive_move.dart) ------------------------

typedef _AllocC = Pointer<Void> Function(Uint32, IntPtr);
typedef _AllocD = Pointer<Void> Function(int, int);
typedef _LocalFreeC = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeD = Pointer<Void> Function(Pointer<Void>);
typedef _MallocC = Pointer<Void> Function(IntPtr);
typedef _MallocD = Pointer<Void> Function(int);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _FreeD = void Function(Pointer<Void>);

final DynamicLibrary _k32 = DynamicLibrary.open('kernel32.dll');
final _AllocD _localAlloc = _k32.lookupFunction<_AllocC, _AllocD>('LocalAlloc');
final _LocalFreeD _localFree = _k32.lookupFunction<_LocalFreeC, _LocalFreeD>(
  'LocalFree',
);
final DynamicLibrary _libc = DynamicLibrary.process();
final _MallocD _malloc = _libc.lookupFunction<_MallocC, _MallocD>('malloc');
final _FreeD _free = _libc.lookupFunction<_FreeC, _FreeD>('free');

/// A zeroed native block of [size] bytes (Windows: `LocalAlloc`; elsewhere
/// `malloc`). Release it with [freeNative].
Pointer<Uint8> allocNative(int size) {
  final Pointer<Uint8> p;
  if (Platform.isWindows) {
    p = _localAlloc(0x40 /* LPTR: zeroed */, size).cast<Uint8>();
  } else {
    p = _malloc(size).cast<Uint8>();
    if (p.address != 0) p.asTypedList(size).fillRange(0, size, 0);
  }
  if (p.address == 0) throw StateError('out of memory');
  return p;
}

void freeNative(Pointer<Uint8> p) {
  if (Platform.isWindows) {
    _localFree(p.cast());
  } else {
    _free(p.cast());
  }
}

/// [s] as a NUL-terminated UTF-16 string.
Pointer<Uint16> allocWide(String s) {
  final units = s.codeUnits;
  final p = allocNative((units.length + 1) * 2).cast<Uint16>();
  p.asTypedList(units.length + 1).setAll(0, units);
  return p;
}

/// [s] as a NUL-terminated UTF-8 string.
Pointer<Uint8> allocCString(String s) {
  final bytes = utf8.encode(s);
  final p = allocNative(bytes.length + 1);
  p.asTypedList(bytes.length + 1).setAll(0, bytes);
  return p;
}

// --- Windows ----------------------------------------------------------------

typedef _CreateFileC = IntPtr Function(
  Pointer<Uint16>,
  Uint32,
  Uint32,
  Pointer<Void>,
  Uint32,
  Uint32,
  IntPtr,
);
typedef _CreateFileD = int Function(
  Pointer<Uint16>,
  int,
  int,
  Pointer<Void>,
  int,
  int,
  int,
);
typedef _GetInfoC = Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32);
typedef _GetInfoD = int Function(int, int, Pointer<Void>, int);
typedef _CloseC = Int32 Function(IntPtr);
typedef _CloseD = int Function(int);

final _CreateFileD _createFile = _k32
    .lookupFunction<_CreateFileC, _CreateFileD>('CreateFileW');
final _GetInfoD _getInfo = _k32.lookupFunction<_GetInfoC, _GetInfoD>(
  'GetFileInformationByHandleEx',
);
final _CloseD _closeHandle = _k32.lookupFunction<_CloseC, _CloseD>(
  'CloseHandle',
);

const int _fileReadAttributes = 0x80;
const int _shareAll = 0x7; // read | write | delete
const int _openExisting = 3;
// FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS
const int _openFlags = 0x00200000 | 0x02000000;
const int _fileBasicInfo = 0;
const int _fileStandardInfo = 1;
const int _fileIdInfo = 18;
const int _fileAttributeTagInfo = 9;
const int _attrDirectory = 0x10;
const int _attrReparse = 0x400;
// Only these two reparse tags are links; Cloud Files placeholders are not.
const int _tagSymlink = 0xA000000C;
const int _tagMountPoint = 0xA0000003;
const int _attrOffline = 0x1000;
const int _attrRecallOnOpen = 0x40000;
const int _attrRecallOnDataAccess = 0x400000;

// Offsets in one buffer: FILE_BASIC_INFO (40), FILE_STANDARD_INFO (24),
// FILE_ID_INFO (24), FILE_ATTRIBUTE_TAG_INFO (8).
const int _basicAt = 0,
    _standardAt = 40,
    _idAt = 64,
    _tagAt = 88,
    _winBufSize = 96;

// 100 ns ticks from 1601 to the Unix epoch.
const int _unixEpochTicks = 116444736000000000;

RawFileInfo? _winInfo(String path) {
  final name = allocWide(windowsPath(path));
  final buf = allocNative(_winBufSize);
  try {
    final h = _createFile(
      name,
      _fileReadAttributes,
      _shareAll,
      nullptr,
      _openExisting,
      _openFlags,
      0,
    );
    if (h == -1) return null; // INVALID_HANDLE_VALUE
    try {
      if (_getInfo(h, _fileBasicInfo, (buf + _basicAt).cast(), 40) == 0 ||
          _getInfo(h, _fileStandardInfo, (buf + _standardAt).cast(), 24) == 0) {
        return null;
      }
      final idOk = _getInfo(h, _fileIdInfo, (buf + _idAt).cast(), 24) != 0;
      final d = ByteData.sublistView(buf.asTypedList(_winBufSize));
      final attrs = d.getUint32(_basicAt + 32, Endian.little);
      final write = d.getInt64(_basicAt + 16, Endian.little);
      final size = d.getInt64(_standardAt + 8, Endian.little);
      var isLink = false;
      if (attrs & _attrReparse != 0) {
        // A failed tag read counts as a link (the cautious case).
        isLink =
            _getInfo(h, _fileAttributeTagInfo, (buf + _tagAt).cast(), 8) == 0 ||
            switch (d.getUint32(_tagAt + 4, Endian.little)) {
              _tagSymlink || _tagMountPoint => true,
              _ => false,
            };
      }
      FileStamp? stamp;
      if (idOk) {
        final volume = d.getInt64(_idAt, Endian.little);
        final id = StringBuffer();
        for (var i = 15; i >= 0; i--) {
          id.write(d.getUint8(_idAt + 8 + i).toRadixString(16).padLeft(2, '0'));
        }
        stamp = FileStamp(
          volume: volume,
          fileId: id.toString(),
          size: size,
          modifiedNs: (write - _unixEpochTicks) * 100,
        );
      }
      return RawFileInfo(
        stamp: stamp,
        isDirectory: attrs & _attrDirectory != 0,
        isLink: isLink,
        placeholder:
            attrs &
                (_attrOffline | _attrRecallOnOpen | _attrRecallOnDataAccess) !=
            0,
      );
    } finally {
      _closeHandle(h);
    }
  } finally {
    freeNative(name.cast());
    freeNative(buf);
  }
}

// --- POSIX ------------------------------------------------------------------

typedef _LstatC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _LstatD = int Function(Pointer<Uint8>, Pointer<Uint8>);

// `struct stat` field offsets for the 64-bit ABIs.
class _StatLayout {
  const _StatLayout({
    required this.dev,
    required this.devWide,
    required this.ino,
    required this.mode,
    required this.modeWide,
    required this.size,
    required this.mtime,
    required this.flags,
  });
  final int dev;
  final bool devWide; // 64-bit st_dev (Linux) or 32-bit (Apple)
  final int ino;
  final int mode;
  final bool modeWide; // 32-bit st_mode (Linux) or 16-bit (Apple)
  final int size;
  final int mtime; // seconds, then nanoseconds 8 bytes on
  final int? flags; // st_flags (Apple), `SF_DATALESS` is bit 30
}

// x86-64 Linux and Android: st_mode after st_nlink (8 bytes).
const _linuxX64 = _StatLayout(
  dev: 0,
  devWide: true,
  ino: 8,
  mode: 24,
  modeWide: true,
  size: 48,
  mtime: 88,
  flags: null,
);
// aarch64 and riscv64 Linux and Android: the generic layout.
const _linuxGeneric = _StatLayout(
  dev: 0,
  devWide: true,
  ino: 8,
  mode: 16,
  modeWide: true,
  size: 48,
  mtime: 88,
  flags: null,
);
// macOS and iOS (64-bit inodes).
const _apple = _StatLayout(
  dev: 0,
  devWide: false,
  ino: 8,
  mode: 4,
  modeWide: false,
  size: 96,
  mtime: 48,
  flags: 116,
);

/// The libc symbol that reads `struct stat` in the layout this file uses for
/// [abi], or null for an ABI this file does not know. A seam for tests.
///
/// On x86-64 macOS the plain `lstat` is the 32-bit-inode version, so the
/// 64-bit-inode one is named; on the other Apple ABIs plain `lstat` is it.
String? lstatSymbolFor(Abi abi) {
  switch (abi) {
    case Abi.macosX64:
      return r'lstat$INODE64';
    case Abi.macosArm64:
      return 'lstat';
    case Abi.iosArm64:
      return 'lstat';
    case Abi.iosX64:
      return 'lstat';
    case Abi.linuxX64:
      return 'lstat';
    case Abi.linuxArm64:
      return 'lstat';
    case Abi.linuxRiscv64:
      return 'lstat';
    case Abi.androidX64:
      return 'lstat';
    case Abi.androidArm64:
      return 'lstat';
    default:
      return null;
  }
}

_StatLayout? _layout() {
  final abi = Abi.current();
  if (abi == Abi.linuxX64 || abi == Abi.androidX64) return _linuxX64;
  if (abi == Abi.linuxArm64 ||
      abi == Abi.androidArm64 ||
      abi == Abi.linuxRiscv64) {
    return _linuxGeneric;
  }
  if (abi == Abi.macosX64 ||
      abi == Abi.macosArm64 ||
      abi == Abi.iosArm64 ||
      abi == Abi.iosX64) {
    return _apple;
  }
  return null;
}

const int _sfDataless = 0x40000000;

RawFileInfo? _posixInfo(String path) {
  // Missing is not an error: null, and the caller reads.
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    return null;
  }
  final layout = _layout();
  final symbol = lstatSymbolFor(Abi.current());
  if (layout == null || symbol == null) return null;
  // A failed lookup throws; fileStamp and placeholderState turn that into null
  // and `unknown`.
  final lstat = _libc.lookupFunction<_LstatC, _LstatD>(symbol, isLeaf: true);
  final p = allocCString(path);
  final buf = allocNative(256);
  try {
    if (lstat(p, buf) != 0) return null;
    final d = ByteData.sublistView(buf.asTypedList(256));
    final dev = layout.devWide
        ? d.getInt64(layout.dev, Endian.little)
        : d.getInt32(layout.dev, Endian.little);
    final ino = d.getUint64(layout.ino, Endian.little);
    final mode = layout.modeWide
        ? d.getUint32(layout.mode, Endian.little)
        : d.getUint16(layout.mode, Endian.little);
    final size = d.getInt64(layout.size, Endian.little);
    final sec = d.getInt64(layout.mtime, Endian.little);
    final nsec = d.getInt64(layout.mtime + 8, Endian.little);
    final flags = layout.flags == null
        ? 0
        : d.getUint32(layout.flags!, Endian.little);
    final type = mode & 0xF000;
    return RawFileInfo(
      stamp: FileStamp(
        volume: dev,
        fileId: ino.toRadixString(16),
        size: size,
        modifiedNs: sec * 1000000000 + nsec,
      ),
      isDirectory: type == 0x4000,
      isLink: type == 0xA000,
      placeholder: flags & _sfDataless != 0,
    );
  } finally {
    freeNative(p);
    freeNative(buf);
  }
}
