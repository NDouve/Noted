// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:noted_core/noted_core.dart';

/// One descriptor of a file being created, as `createExclusive` writes it.
/// The default is a POSIX file descriptor; tests give their own.
abstract interface class ExclusiveFile {
  /// Writes some of [bytes] from [offset] and returns how many were written.
  /// Throws a [FileSystemException] when it can't.
  int write(Uint8List bytes, int offset);

  /// Flushes to the device.
  void sync();

  void close();
}

/// Opens [path] with `O_CREAT|O_EXCL|O_WRONLY`: the file, or null when the
/// name is taken. Throws a [FileSystemException] for any other failure.
typedef ExclusiveOpener = ExclusiveFile? Function(String path);

/// How `createExclusive` ended.
enum ExclusiveOutcome {
  /// The file was created with all [bytes] and flushed.
  created,

  /// A file was at the name (it was never touched).
  taken,
}

/// A write that failed after the file was created. [path] holds a partial file
/// when [left] is true (it could not be removed, or it must not be: in the
/// macOS sandbox, where only the file itself is granted); the message then
/// says so.
class ExclusiveWriteFailed extends FileSystemException {
  ExclusiveWriteFailed(super.message, String super.path, {required this.left});

  /// Whether a partial file was left under [path].
  final bool left;
}

/// Creates the new file [path] holding [bytes] through one descriptor: open
/// exclusively, write, `fsync`, close. A name that is taken is
/// [ExclusiveOutcome.taken] and nothing is touched. It never replaces.
///
/// If the write fails, the partial file is compared with the bytes actually
/// written (the count the descriptor reported) and removed through
/// [deleteFileIfMatches] when it matches; a file that doesn't match stays. With
/// [sandboxed] (macOS, where only the chosen file is granted) the partial file
/// is left in place and an [ExclusiveWriteFailed] says `NAME may be
/// incomplete.` A crash mid-write can leave a partial new file.
///
/// Used where hard links don't work, so the publish by temporary file and
/// link can't be (see `ExportWriter`). It lives in the app and never in
/// noted_core, so the MCP server gets no FFI.
Future<ExclusiveOutcome> createExclusive(
  String path,
  Uint8List bytes, {
  ExclusiveOpener? open,
  bool sandboxed = false,
}) async {
  final file = (open ?? _openPosix)(path);
  if (file == null) return ExclusiveOutcome.taken;
  var written = 0;
  try {
    try {
      while (written < bytes.length) {
        final n = file.write(bytes, written);
        if (n <= 0) throw FileSystemException('Nothing was written', path);
        written += n;
      }
      file.sync();
    } finally {
      try {
        file.close();
      } on Object {
        // The failure that matters is the one being thrown, or the write is
        // complete and the flush happened.
      }
    }
  } on Object catch (e) {
    final name = path.split(RegExp(r'[\\/]')).last;
    if (sandboxed) {
      throw ExclusiveWriteFailed('$name may be incomplete.', path, left: true);
    }
    var left = true;
    try {
      final r = await deleteFileIfMatches(path, bytes: Uint8List.sublistView(bytes, 0, written));
      left = !r.deleted && r.outcome != DeleteOutcome.absent;
    } on Object {
      left = true;
    }
    throw ExclusiveWriteFailed(
      left ? '$name may be incomplete.' : (e is FileSystemException ? e.message : 'The file could not be written.'),
      path,
      left: left,
    );
  }
  return ExclusiveOutcome.created;
}

/// [createExclusive] for content in the file [source], read in chunks, so it
/// is never held whole (a binder `.zip`). A partial file is removed only
/// through [deleteFileIfMatches] with the identity of the bytes written.
Future<ExclusiveOutcome> createExclusiveFromFile(
  String path,
  String source, {
  ExclusiveOpener? open,
  bool sandboxed = false,
}) async {
  final file = (open ?? _openPosix)(path);
  if (file == null) return ExclusiveOutcome.taken;
  var written = 0;
  try {
    final src = File(source).openSync();
    try {
      try {
        final buffer = Uint8List(64 * 1024);
        while (true) {
          final n = src.readIntoSync(buffer);
          if (n <= 0) break;
          final chunk = Uint8List.sublistView(buffer, 0, n);
          var at = 0;
          while (at < n) {
            final w = file.write(chunk, at);
            if (w <= 0) throw FileSystemException('Nothing was written', path);
            at += w;
            written += w;
          }
        }
        file.sync();
      } finally {
        try {
          file.close();
        } on Object {
          // As in createExclusive.
        }
      }
    } finally {
      src.closeSync();
    }
  } on Object catch (e) {
    final name = path.split(RegExp(r'[\\/]')).last;
    if (sandboxed) {
      throw ExclusiveWriteFailed('$name may be incomplete.', path, left: true);
    }
    var left = true;
    try {
      // The identity of the bytes written: the source's first [written]
      // bytes, hashed as a stream of chunks, never held whole.
      final head = ContentIdentity(written, await contentHashOfStream(File(source).openRead(0, written)));
      final r = await deleteFileIfMatches(path, identity: head);
      left = !r.deleted && r.outcome != DeleteOutcome.absent;
    } on Object {
      left = true;
    }
    throw ExclusiveWriteFailed(
      left ? '$name may be incomplete.' : (e is FileSystemException ? e.message : 'The file could not be written.'),
      path,
      left: left,
    );
  }
  return ExclusiveOutcome.created;
}

// --- POSIX -----------------------------------------------------------------

// `open` is variadic: on Apple arm64 the mode is passed as a vararg.
typedef _OpenC = Int32 Function(Pointer<Uint8>, Int32, VarArgs<(Int32,)>);
typedef _OpenD = int Function(Pointer<Uint8>, int, int);
typedef _WriteC = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _WriteD = int Function(int, Pointer<Uint8>, int);
typedef _FsyncC = Int32 Function(Int32);
typedef _FsyncD = int Function(int);
typedef _CloseC = Int32 Function(Int32);
typedef _CloseD = int Function(int);
typedef _MallocC = Pointer<Void> Function(IntPtr);
typedef _MallocD = Pointer<Void> Function(int);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _FreeD = void Function(Pointer<Void>);
typedef _ErrnoC = Pointer<Int32> Function();
typedef _ErrnoD = Pointer<Int32> Function();


// The flag values: macOS and iOS differ from Linux and Android.
int get _flags {
  const wronly = 1;
  return Platform.isMacOS || Platform.isIOS
      ? wronly | 0x200 | 0x800 // O_CREAT, O_EXCL
      : wronly | 0x40 | 0x80;
}

ExclusiveFile? _openPosix(String path) {
  if (!(Platform.isLinux || Platform.isMacOS || Platform.isIOS || Platform.isAndroid)) {
    throw FileSystemException('An exclusive create is not supported here', path);
  }
  final libc = DynamicLibrary.process();
  final open = libc.lookupFunction<_OpenC, _OpenD>('open');
  final malloc = libc.lookupFunction<_MallocC, _MallocD>('malloc');
  final free = libc.lookupFunction<_FreeC, _FreeD>('free');
  final errno = libc.lookupFunction<_ErrnoC, _ErrnoD>(
    Platform.isMacOS || Platform.isIOS
        ? '__error'
        : (libc.providesSymbol('__errno_location') ? '__errno_location' : '__errno'),
    isLeaf: true,
  );
  final bytes = utf8.encode(path);
  final p = malloc(bytes.length + 1).cast<Uint8>();
  if (p.address == 0) throw StateError('out of memory');
  p.asTypedList(bytes.length + 1)
    ..setAll(0, bytes)
    ..[bytes.length] = 0;
  try {
    final fd = open(p, _flags, 420); // 0644
    if (fd >= 0) return _PosixFile(libc, fd, errno, malloc, free, path);
    final e = errno().value;
    // Taken is what the file system says now (an lstat), not a separate errno read.
    if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound) return null;
    throw FileSystemException('Could not create the file', path, OSError('open', e));
  } finally {
    free(p.cast());
  }
}

final class _PosixFile implements ExclusiveFile {
  _PosixFile(DynamicLibrary libc, this._fd, this._errno, this._malloc, this._free, this._path)
    : _write = libc.lookupFunction<_WriteC, _WriteD>('write'),
      _fsync = libc.lookupFunction<_FsyncC, _FsyncD>('fsync'),
      _close = libc.lookupFunction<_CloseC, _CloseD>('close');

  final int _fd;
  final String _path;
  final _ErrnoD _errno;
  final _MallocD _malloc;
  final _FreeD _free;
  final _WriteD _write;
  final _FsyncD _fsync;
  final _CloseD _close;

  @override
  int write(Uint8List bytes, int offset) {
    final n = bytes.length - offset;
    final buf = _malloc(n).cast<Uint8>();
    if (buf.address == 0) throw StateError('out of memory');
    try {
      buf.asTypedList(n).setAll(0, Uint8List.sublistView(bytes, offset));
      final r = _write(_fd, buf, n);
      if (r < 0) {
        throw FileSystemException('Could not write the file', _path, OSError('write', _errno().value));
      }
      return r;
    } finally {
      _free(buf.cast());
    }
  }

  @override
  void sync() {
    if (_fsync(_fd) != 0) {
      throw FileSystemException('Could not flush the file', _path, OSError('fsync', _errno().value));
    }
  }

  @override
  void close() {
    if (_close(_fd) != 0) {
      throw FileSystemException('Could not close the file', _path, OSError('close', _errno().value));
    }
  }
}
