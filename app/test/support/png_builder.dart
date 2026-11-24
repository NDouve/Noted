// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

/// A valid PNG of [width] by [height], 8-bit gray and all black. [padding]
/// bytes of text chunk make the file larger without making it slower to
/// decode.
Uint8List buildPng(int width, int height, {int padding = 0}) {
  final raw = Uint8List(height * (width + 1));
  final out = BytesBuilder()..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    out
      ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
      ..add(body)
      ..add((ByteData(4)..setUint32(0, _crc32(body))).buffer.asUint8List());
  }

  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 0);
  chunk('IHDR', header.buffer.asUint8List());
  if (padding > 0) chunk('tEXt', [...ascii.encode('pad'), 0, ...Uint8List(padding)]);
  chunk('IDAT', ZLibEncoder().convert(raw));
  chunk('IEND', const []);
  return out.toBytes();
}

/// A PNG that only claims to be [width] by [height]: its header is real, its
/// data is cut short.
Uint8List claimPng(int width, int height) {
  final full = buildPng(1, 1);
  final d = ByteData.sublistView(full)
    ..setUint32(16, width)
    ..setUint32(20, height);
  return d.buffer.asUint8List();
}

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? 0xEDB88320 ^ (crc >>> 1) : crc >>> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
