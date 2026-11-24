// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

import 'import_limits.dart';

/// Reads entries of a zip file by name, from its central directory. Stored
/// and deflate entries only. Nothing is extracted to disk: an entry is
/// inflated in memory, up to the limits, and counted while it inflates, so a
/// zip bomb stops at the limit. Encrypted, zip64, truncated and inconsistent
/// archives are refused with an [ImportException].
final class ZipReader {
  ZipReader._(this._bytes, this._limits, this._entries);

  /// Reads the central directory of [bytes].
  factory ZipReader(Uint8List bytes, ImportLimits limits) {
    const bad = ImportException('can’t be read');
    const zip64 = ImportException('can’t be read');
    if (bytes.length < 22) throw bad;
    final d = ByteData.sublistView(bytes);
    // The end record is in the last 22 + 65,535 bytes.
    var eocd = -1;
    final from = bytes.length - 22;
    final to = from - 65535 < 0 ? 0 : from - 65535;
    for (var i = from; i >= to; i--) {
      if (d.getUint32(i, Endian.little) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw bad;
    if (eocd >= 20 && d.getUint32(eocd - 20, Endian.little) == 0x07064b50) throw zip64;
    final disk = d.getUint16(eocd + 4, Endian.little);
    final cdDisk = d.getUint16(eocd + 6, Endian.little);
    final count = d.getUint16(eocd + 10, Endian.little);
    final cdSize = d.getUint32(eocd + 12, Endian.little);
    final cdOffset = d.getUint32(eocd + 16, Endian.little);
    if (count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) throw zip64;
    if (disk != 0 || cdDisk != 0) throw bad;
    if (count > limits.entries) throw const ImportException('has too many parts to import');
    if (cdOffset + cdSize > eocd) throw bad;
    final entries = <String, _Entry>{};
    var p = cdOffset;
    for (var i = 0; i < count; i++) {
      if (p + 46 > bytes.length || d.getUint32(p, Endian.little) != 0x02014b50) throw bad;
      final flags = d.getUint16(p + 8, Endian.little);
      final method = d.getUint16(p + 10, Endian.little);
      final csize = d.getUint32(p + 20, Endian.little);
      final usize = d.getUint32(p + 24, Endian.little);
      final nameLen = d.getUint16(p + 28, Endian.little);
      final extraLen = d.getUint16(p + 30, Endian.little);
      final commentLen = d.getUint16(p + 32, Endian.little);
      final local = d.getUint32(p + 42, Endian.little);
      if (p + 46 + nameLen + extraLen + commentLen > bytes.length) throw bad;
      final name = utf8.decode(Uint8List.sublistView(bytes, p + 46, p + 46 + nameLen), allowMalformed: true);
      if (csize == 0xFFFFFFFF || usize == 0xFFFFFFFF || local == 0xFFFFFFFF) throw zip64;
      entries[name] = _Entry(flags, method, csize, usize, local);
      p += 46 + nameLen + extraLen + commentLen;
    }
    return ZipReader._(bytes, limits, entries);
  }

  final Uint8List _bytes;
  final ImportLimits _limits;
  final Map<String, _Entry> _entries;
  int _total = 0;

  /// Whether the archive lists [name].
  bool has(String name) => _entries.containsKey(name);

  /// The entry names.
  Iterable<String> get names => _entries.keys;

  /// The bytes of the entry [name], or null if there is none. Throws an
  /// [ImportException] for an entry that is encrypted, uses another method,
  /// is over a limit, or doesn't agree with its own header.
  Uint8List? read(String name) {
    final e = _entries[name];
    if (e == null) return null;
    const bad = ImportException('can’t be read');
    if (e.flags & 1 != 0 || e.flags & 0x40 != 0) throw const ImportException('is encrypted and can’t be imported');
    if (e.method != 0 && e.method != 8) throw const ImportException('can’t be read');
    final d = ByteData.sublistView(_bytes);
    final o = e.local;
    if (o + 30 > _bytes.length || d.getUint32(o, Endian.little) != 0x04034b50) throw bad;
    final start = o + 30 + d.getUint16(o + 26, Endian.little) + d.getUint16(o + 28, Endian.little);
    final end = start + e.csize;
    if (end > _bytes.length) throw const ImportException('can’t be read');
    if (e.usize > _limits.entryBytes || _total + e.usize > _limits.archiveBytes) {
      throw const ImportException('is too large to import');
    }
    final data = Uint8List.sublistView(_bytes, start, end);
    if (e.method == 0) {
      if (e.csize != e.usize) throw bad;
      _total += e.usize;
      return data;
    }
    final out = BytesBuilder(copy: false);
    final room = _limits.entryBytes < _limits.archiveBytes - _total ? _limits.entryBytes : _limits.archiveBytes - _total;
    var size = 0;
    final sink = ZLibDecoder(raw: true).startChunkedConversion(
      _Collect((chunk) {
        size += chunk.length;
        // A bomb stops here, at the limit, not at what its header says.
        if (size > room) throw const ImportException('is too large to import');
        if (size > e.usize) throw bad;
        out.add(chunk);
      }),
    );
    try {
      const step = 64 * 1024;
      for (var i = 0; i < data.length; i += step) {
        sink.add(Uint8List.sublistView(data, i, i + step < data.length ? i + step : data.length));
      }
      sink.close();
    } on ImportException {
      rethrow;
    } on Object {
      throw bad;
    }
    if (size != e.usize) throw bad;
    _total += size;
    return out.takeBytes();
  }
}

final class _Entry {
  const _Entry(this.flags, this.method, this.csize, this.usize, this.local);
  final int flags;
  final int method;
  final int csize;
  final int usize;
  final int local;
}

class _Collect implements Sink<List<int>> {
  _Collect(this._on);
  final void Function(List<int>) _on;
  @override
  void add(List<int> data) => _on(data);
  @override
  void close() {}
}
