// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

import 'package:noted/src/import/zip_reader.dart' show zipCrc32;

/// One entry of a crafted archive. Every header field can be set, so each
/// refusal rule gets an archive of its own.
class CraftedEntry {
  CraftedEntry(
    this.name,
    Object data, {
    this.rawName,
    this.deflate = true,
    this.method,
    this.flags = 0x0800,
    this.madeBy = 20,
    this.external = 0,
    this.crc,
    this.diskStart = 0,
  }) : data = data is String ? utf8.encode(data) : data as List<int>;

  /// A directory entry (`name/`, no data).
  CraftedEntry.dir(String name, {int madeBy = 20, int external = 0x10})
    : this(name.endsWith('/') ? name : '$name/', const <int>[], deflate: false, madeBy: madeBy, external: external);

  final String name;
  final List<int> data;
  final List<int>? rawName;
  final bool deflate;
  final int? method;
  final int flags;
  final int madeBy;
  final int external;
  final int? crc;
  final int diskStart;
}

/// The archive of [entries], in order.
Uint8List craftZip(List<CraftedEntry> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final e in entries) {
    final name = e.rawName ?? utf8.encode(e.name);
    final packed = e.deflate ? ZLibEncoder(raw: true).convert(e.data) : e.data;
    final method = e.method ?? (e.deflate ? 8 : 0);
    final crc = e.crc ?? zipCrc32(e.data);
    final offset = out.length;
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, e.flags, Endian.little)
      ..setUint16(8, method, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, packed.length, Endian.little)
      ..setUint32(22, e.data.length, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(name)
      ..add(packed);
    final c = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, e.madeBy, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, e.flags, Endian.little)
      ..setUint16(10, method, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, packed.length, Endian.little)
      ..setUint32(24, e.data.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint16(34, e.diskStart, Endian.little)
      ..setUint32(38, e.external, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(c.buffer.asUint8List())
      ..add(name);
  }
  final cdOffset = out.length;
  out.add(central.takeBytes());
  final cdSize = out.length - cdOffset;
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, cdSize, Endian.little)
    ..setUint32(16, cdOffset, Endian.little);
  out.add(end.buffer.asUint8List());
  return out.takeBytes();
}

/// A binder file's text.
String binderJson({String id = '0123456789abcdef', String title = 'Shared', String? ai, String extra = ''}) =>
    '{"format":1,"binderId":"$id","title":"$title"${ai == null ? '' : ',"ai":"$ai"'}$extra}\n';
