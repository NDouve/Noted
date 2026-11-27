// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Noted's own zip writer (design t6 §2, A6): one top folder, UTF-8 names (bit
// 11), `/` separators, zip32, raw deflate (method 8) or stored (0). Files are
// streamed in chunks from disk into a zip file being built; nothing is held
// whole. Every function here is synchronous and meant to run in a background
// isolate (CRC-32 and deflate are off the UI isolate).

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:noted_core/noted_core.dart';

import '../import/zip_reader.dart' show ZipCrc32;

const int _chunk = 64 * 1024;

/// A file to put in a zip: its archive [name] (`/` separators) and where it
/// is on disk.
final class ZipSource {
  const ZipSource(this.name, this.path, {required this.deflate});

  final String name;
  final String path;

  /// Raw deflate (method 8); stored (0) otherwise.
  final bool deflate;
}

/// One entry written to a zip being built: where its local record is
/// ([offset] to [end]) and what its central-directory record says.
final class ZipRecord {
  const ZipRecord({
    required this.name,
    required this.offset,
    required this.end,
    required this.crc,
    required this.compressedSize,
    required this.size,
    required this.method,
    required this.dosTime,
    required this.dosDate,
  });

  final String name;
  final int offset;
  final int end;
  final int crc;
  final int compressedSize;
  final int size;
  final int method;
  final int dosTime;
  final int dosDate;

  ZipRecord movedTo(int at) => ZipRecord(
    name: name,
    offset: at,
    end: at + end - offset,
    crc: crc,
    compressedSize: compressedSize,
    size: size,
    method: method,
    dosTime: dosTime,
    dosDate: dosDate,
  );
}

/// How adding one file ended.
enum ZipAddState {
  /// Written, and the file's stamp was the same before and after the read.
  added,

  /// The file kept changing while it was read; nothing of it is in the zip.
  changed,

  /// The file is gone.
  missing,

  /// The file's data is not on this device; nothing was read.
  notDownloaded,

  /// Over the per-file limit.
  tooLarge,

  /// It couldn't be read.
  failed,
}

/// What adding one [source] did. [stamp] is the file's stamp, taken before
/// the read and equal after it.
final class ZipAdded {
  const ZipAdded(this.source, this.state, {this.record, this.stamp, this.error});

  final ZipSource source;
  final ZipAddState state;
  final ZipRecord? record;
  final FileStamp? stamp;
  final String? error;
}

/// A test seam: after the source named [name] is open for reading, the writer
/// creates `<gate>.reached` and waits (up to [limit]) while [gate] exists.
final class ZipReadPause {
  const ZipReadPause(this.name, this.gate, {this.limit = const Duration(seconds: 30)});

  final String name;
  final String gate;
  final Duration limit;
}

/// The stamp of [path]: [fileStamp], or, where the file system gives no file
/// id (FAT, exFAT), its size and modified time alone. Null when it is gone.
FileStamp? zipStampOf(String path) {
  final s = fileStamp(path);
  if (s != null) return s;
  final st = FileStat.statSync(path);
  if (st.type == FileSystemEntityType.notFound) return null;
  return FileStamp(volume: 0, fileId: '', size: st.size, modifiedNs: st.modified.microsecondsSinceEpoch * 1000);
}

(int, int) _dosTime(DateTime t) {
  final l = t.toLocal();
  if (l.year < 1980) return (0, (0 << 9) | (1 << 5) | 1);
  final time = (l.hour << 11) | (l.minute << 5) | (l.second ~/ 2);
  final date = ((l.year - 1980).clamp(0, 127) << 9) | (l.month << 5) | l.day;
  return (time, date);
}

Uint8List _localHeader(Uint8List name, int method, int time, int date, int crc, int csize, int usize) {
  final h = ByteData(30)
    ..setUint32(0, 0x04034b50, Endian.little)
    ..setUint16(4, 20, Endian.little)
    ..setUint16(6, 0x0800, Endian.little)
    ..setUint16(8, method, Endian.little)
    ..setUint16(10, time, Endian.little)
    ..setUint16(12, date, Endian.little)
    ..setUint32(14, crc, Endian.little)
    ..setUint32(18, csize, Endian.little)
    ..setUint32(22, usize, Endian.little)
    ..setUint16(26, name.length, Endian.little)
    ..setUint16(28, 0, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(h.buffer.asUint8List())
        ..add(name))
      .takeBytes();
}

class _RafSink implements Sink<List<int>> {
  _RafSink(this._raf);
  final RandomAccessFile _raf;
  int written = 0;
  @override
  void add(List<int> data) {
    if (data.isEmpty) return;
    _raf.writeFromSync(data);
    written += data.length;
  }

  @override
  void close() {}
}

/// Appends [sources] to the zip being built at [zipPath], from [offset] (the
/// file is created when missing; anything past [offset] is cut). Each file is
/// stamped, read in chunks, and stamped again; a stamp that moved cuts the
/// entry off and reads the file again, up to [tries] times. Stops at the first
/// entry that would take the zip past [archiveLimit] (`overArchive`).
({List<ZipAdded> added, int end, bool overArchive}) appendZipEntries(
  String zipPath,
  int offset,
  List<ZipSource> sources, {
  required int fileLimit,
  required int archiveLimit,
  int tries = 3,
  ZipReadPause? pause,
}) {
  final out = <ZipAdded>[];
  final raf = File(zipPath).openSync(mode: FileMode.append);
  var at = offset;
  try {
    raf.truncateSync(at);
    for (final s in sources) {
      ZipAdded? done;
      for (var attempt = 0; attempt < tries && done == null; attempt++) {
        final before = zipStampOf(s.path);
        if (before == null) {
          done = ZipAdded(s, ZipAddState.missing);
          break;
        }
        if (before.size > fileLimit) {
          done = ZipAdded(s, ZipAddState.tooLarge);
          break;
        }
        final r = _writeOne(raf, at, s, pause);
        if (r.state != ZipAddState.added) {
          raf.truncateSync(at);
          done = ZipAdded(s, r.state, error: r.error);
          break;
        }
        final after = zipStampOf(s.path);
        if (after != before) {
          raf.truncateSync(at);
          continue;
        }
        done = ZipAdded(s, ZipAddState.added, record: r.record, stamp: before);
      }
      done ??= ZipAdded(s, ZipAddState.changed);
      final rec = done.record;
      if (rec != null) {
        if (rec.end > archiveLimit) {
          raf.truncateSync(at);
          out.add(ZipAdded(s, ZipAddState.tooLarge));
          return (added: out, end: at, overArchive: true);
        }
        at = rec.end;
      }
      out.add(done);
    }
    raf.flushSync();
  } finally {
    raf.closeSync();
  }
  return (added: out, end: at, overArchive: false);
}

({ZipAddState state, ZipRecord? record, String? error}) _writeOne(
  RandomAccessFile raf,
  int at,
  ZipSource s,
  ZipReadPause? pause,
) {
  final RandomAccessFile src;
  switch (openStoredFileSync(s.path)) {
    case StoredOpened(:final value):
      src = value;
    case StoredRefused(result: StoredMissing()):
      return (state: ZipAddState.missing, record: null, error: null);
    case StoredRefused(result: StoredNotDownloaded()):
      return (state: ZipAddState.notDownloaded, record: null, error: null);
    case StoredRefused(result: StoredFailed(:final error)):
      return (state: ZipAddState.failed, record: null, error: error.message);
    case StoredRefused():
      return (state: ZipAddState.failed, record: null, error: null);
  }
  try {
    if (pause != null && pause.name == s.name) _waitAtGate(pause);
    final name = Uint8List.fromList(utf8.encode(s.name));
    final method = s.deflate ? 8 : 0;
    final (time, date) = _dosTime(File(s.path).lastModifiedSync());
    raf.setPositionSync(at);
    raf.writeFromSync(_localHeader(name, method, time, date, 0, 0, 0));
    final crc = ZipCrc32();
    final sink = _RafSink(raf);
    final deflater = s.deflate ? ZLibEncoder(raw: true).startChunkedConversion(sink) : null;
    final buffer = Uint8List(_chunk);
    var size = 0;
    while (true) {
      final n = src.readIntoSync(buffer);
      if (n <= 0) break;
      final chunk = Uint8List.sublistView(buffer, 0, n);
      crc.add(chunk);
      size += n;
      if (deflater != null) {
        deflater.add(Uint8List.fromList(chunk));
      } else {
        sink.add(chunk);
      }
    }
    deflater?.close();
    final end = raf.positionSync();
    raf.setPositionSync(at);
    raf.writeFromSync(_localHeader(name, method, time, date, crc.value, sink.written, size));
    raf.setPositionSync(end);
    return (
      state: ZipAddState.added,
      record: ZipRecord(
        name: s.name,
        offset: at,
        end: end,
        crc: crc.value,
        compressedSize: sink.written,
        size: size,
        method: method,
        dosTime: time,
        dosDate: date,
      ),
      error: null,
    );
  } on FileSystemException catch (e) {
    return (state: isDataless(s.path) ? ZipAddState.notDownloaded : ZipAddState.failed, record: null, error: e.message);
  } finally {
    src.closeSync();
  }
}

void _waitAtGate(ZipReadPause pause) {
  File('${pause.gate}.reached').writeAsStringSync('');
  final clock = Stopwatch()..start();
  while (File(pause.gate).existsSync() && clock.elapsed < pause.limit) {
    sleep(const Duration(milliseconds: 10));
  }
}

/// Writes the central directory of [records] and the end record at [offset]
/// of the zip at [zipPath], and cuts the file there. Returns its length.
int finishZip(String zipPath, int offset, List<ZipRecord> records) {
  final cd = BytesBuilder(copy: false);
  for (final r in records) {
    final name = utf8.encode(r.name);
    final c = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, 0x0800, Endian.little)
      ..setUint16(10, r.method, Endian.little)
      ..setUint16(12, r.dosTime, Endian.little)
      ..setUint16(14, r.dosDate, Endian.little)
      ..setUint32(16, r.crc, Endian.little)
      ..setUint32(20, r.compressedSize, Endian.little)
      ..setUint32(24, r.size, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, r.offset, Endian.little);
    cd
      ..add(c.buffer.asUint8List())
      ..add(name);
  }
  final cdBytes = cd.takeBytes();
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, records.length, Endian.little)
    ..setUint16(10, records.length, Endian.little)
    ..setUint32(12, cdBytes.length, Endian.little)
    ..setUint32(16, offset, Endian.little);
  final raf = File(zipPath).openSync(mode: FileMode.append);
  try {
    raf.truncateSync(offset);
    raf.setPositionSync(offset);
    raf.writeFromSync(cdBytes);
    raf.writeFromSync(end.buffer.asUint8List());
    raf.flushSync();
    return raf.lengthSync();
  } finally {
    raf.closeSync();
  }
}

/// Copies the local records of [records] from the zip at [from] into a new
/// zip at [to] (created exclusively), one after another, and returns them
/// with their new offsets. Used when entries read again left dead bytes.
List<ZipRecord> compactZip(String from, String to, List<ZipRecord> records) {
  File(to).createSync(exclusive: true);
  final src = File(from).openSync();
  final dst = File(to).openSync(mode: FileMode.append);
  final out = <ZipRecord>[];
  try {
    final buffer = Uint8List(_chunk);
    var at = 0;
    for (final r in records) {
      src.setPositionSync(r.offset);
      var left = r.end - r.offset;
      while (left > 0) {
        final n = src.readIntoSync(buffer, 0, left < _chunk ? left : _chunk);
        if (n <= 0) throw FileSystemException('The zip being built is short', from);
        dst.writeFromSync(buffer, 0, n);
        left -= n;
      }
      out.add(r.movedTo(at));
      at += r.end - r.offset;
    }
    dst.flushSync();
  } finally {
    src.closeSync();
    dst.closeSync();
  }
  return out;
}

// The isolate calls, made from top-level functions so that a closure never
// carries its caller's state into the isolate.

/// [appendZipEntries] in a background isolate.
Future<({List<ZipAdded> added, int end, bool overArchive})> appendZipEntriesInIsolate(
  String zipPath,
  int offset,
  List<ZipSource> sources, {
  required int fileLimit,
  required int archiveLimit,
  ZipReadPause? pause,
}) => Isolate.run(
  () => appendZipEntries(zipPath, offset, sources, fileLimit: fileLimit, archiveLimit: archiveLimit, pause: pause),
);

/// [compactZip] in a background isolate.
Future<List<ZipRecord>> compactZipInIsolate(String from, String to, List<ZipRecord> records) =>
    Isolate.run(() => compactZip(from, to, records));

/// [finishZip] in a background isolate.
Future<int> finishZipInIsolate(String zipPath, int offset, List<ZipRecord> records) =>
    Isolate.run(() => finishZip(zipPath, offset, records));

/// The [ContentIdentity] of the file at [path], hashed in a background isolate.
Future<ContentIdentity> identityInIsolate(String path) => Isolate.run(() => ContentIdentity.ofFile(path));
