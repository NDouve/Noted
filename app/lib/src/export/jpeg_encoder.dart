// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A baseline JPEG encoder written from ITU-T T.81 (the JPEG standard) only: no
// other encoder's code is copied or translated. Sequential DCT, YCbCr 4:4:4,
// 8 bits, the standard Huffman tables of Annex K.3 and the example
// quantisation tables of Annex K.1 scaled for quality 90, in a JFIF file.

import 'dart:math' as math;
import 'dart:typed_data';

/// The quality [encodeJpeg] uses: scale = 200 - 2 * 90 = 20, so each Annex K
/// example entry becomes floor((base * 20 + 50) / 100), clamped to 1..255.
const int jpegQuality = 90;

/// The quantisation tables of T.81 Annex K.1 (Table K.1 luminance and Table K.2
/// chrominance), in natural (row-major) order, unscaled.
const List<int> jpegLuminanceBase = [
  16, 11, 10, 16, 24, 40, 51, 61, //
  12, 12, 14, 19, 26, 58, 60, 55,
  14, 13, 16, 24, 40, 57, 69, 56,
  14, 17, 22, 29, 51, 87, 80, 62,
  18, 22, 37, 56, 68, 109, 103, 77,
  24, 35, 55, 64, 81, 104, 113, 92,
  49, 64, 78, 87, 103, 121, 120, 101,
  72, 92, 95, 98, 112, 100, 103, 99,
];

const List<int> jpegChrominanceBase = [
  17, 18, 24, 47, 99, 99, 99, 99, //
  18, 21, 26, 66, 99, 99, 99, 99,
  24, 26, 56, 99, 99, 99, 99, 99,
  47, 66, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
];

/// [base] scaled for [quality] (the usual formula: scale is 200 - 2 * quality
/// from 50 up, 5000 / quality below), in natural order.
List<int> jpegScaledTable(List<int> base, int quality) {
  final scale = quality < 50 ? 5000 ~/ quality : 200 - 2 * quality;
  return [for (final b in base) ((b * scale + 50) ~/ 100).clamp(1, 255)];
}

/// The zigzag order: entry i is the natural index of the i-th coefficient
/// (T.81 Figure A.6).
const List<int> jpegZigzag = [
  0, 1, 8, 16, 9, 2, 3, 10, //
  17, 24, 32, 25, 18, 11, 4, 5,
  12, 19, 26, 33, 40, 48, 41, 34,
  27, 20, 13, 6, 7, 14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36,
  29, 22, 15, 23, 30, 37, 44, 51,
  58, 59, 52, 45, 38, 31, 39, 46,
  53, 60, 61, 54, 47, 55, 62, 63,
];

/// A Huffman table as T.81 writes it in a DHT segment: the number of codes of
/// each length 1..16, and the values in code order.
class JpegHuffmanTable {
  const JpegHuffmanTable(this.counts, this.values);

  final List<int> counts;
  final List<int> values;
}

/// Table K.3.
const JpegHuffmanTable jpegDcLuminance = JpegHuffmanTable(
  [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0],
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
);

/// Table K.4.
const JpegHuffmanTable jpegDcChrominance = JpegHuffmanTable(
  [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0],
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
);

/// Table K.5.
const JpegHuffmanTable jpegAcLuminance = JpegHuffmanTable(
  [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d],
  [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, //
    0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
    0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16,
    0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
    0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
    0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
    0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
    0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
    0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4,
    0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea,
    0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
  ],
);

/// Table K.6.
const JpegHuffmanTable jpegAcChrominance = JpegHuffmanTable(
  [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77],
  [
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, //
    0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
    0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34,
    0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38,
    0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
    0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
    0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96,
    0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
    0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2,
    0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9,
    0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
  ],
);

/// The code and its length for each value of [t], by the procedure of T.81
/// Annex C (Figures C.1 to C.3). Both lists are indexed by value (0..255).
({List<int> code, List<int> size}) jpegHuffmanCodes(JpegHuffmanTable t) {
  final code = List<int>.filled(256, 0);
  final size = List<int>.filled(256, 0);
  var k = 0, c = 0;
  for (var len = 1; len <= 16; len++) {
    for (var i = 0; i < t.counts[len - 1]; i++) {
      code[t.values[k]] = c;
      size[t.values[k]] = len;
      k++;
      c++;
    }
    c <<= 1;
  }
  return (code: code, size: size);
}

/// The DCT basis: entry [u * 8 + x] is the factor of sample x in coefficient u
/// of the one-dimensional transform, `C(u) / 2 * cos((2x + 1) u pi / 16)`.
final Float64List _basis = () {
  final t = Float64List(64);
  for (var u = 0; u < 8; u++) {
    final cu = u == 0 ? math.sqrt1_2 : 1.0;
    for (var x = 0; x < 8; x++) {
      t[u * 8 + x] = cu / 2 * math.cos((2 * x + 1) * u * math.pi / 16);
    }
  }
  return t;
}();

/// The two-dimensional DCT of the 8 x 8 block [src] (row-major), into [out].
void _dct8x8(Float64List src, Float64List tmp, Float64List out) {
  // Rows: tmp[y][u] = sum_x basis[u][x] * src[y][x].
  for (var y = 0; y < 8; y++) {
    for (var u = 0; u < 8; u++) {
      var s = 0.0;
      for (var x = 0; x < 8; x++) {
        s += _basis[u * 8 + x] * src[y * 8 + x];
      }
      tmp[y * 8 + u] = s;
    }
  }
  // Columns: out[v][u] = sum_y basis[v][y] * tmp[y][u].
  for (var v = 0; v < 8; v++) {
    for (var u = 0; u < 8; u++) {
      var s = 0.0;
      for (var y = 0; y < 8; y++) {
        s += _basis[v * 8 + y] * tmp[y * 8 + u];
      }
      out[v * 8 + u] = s;
    }
  }
}

class _BitWriter {
  final BytesBuilder out = BytesBuilder(copy: false);
  int _acc = 0;
  int _bits = 0;

  void write(int code, int length) {
    if (length == 0) return;
    _acc = (_acc << length) | (code & ((1 << length) - 1));
    _bits += length;
    while (_bits >= 8) {
      final b = (_acc >> (_bits - 8)) & 0xFF;
      out.addByte(b);
      // A data byte of 0xFF is followed by a zero byte (T.81 B.1.1.5).
      if (b == 0xFF) out.addByte(0);
      _bits -= 8;
    }
    _acc &= (1 << _bits) - 1;
  }

  // Pads the last byte with 1 bits (T.81 F.1.2.3).
  void flush() {
    if (_bits > 0) write((1 << (8 - _bits)) - 1, 8 - _bits);
  }
}

int _bitLength(int v) {
  var n = 0;
  var a = v < 0 ? -v : v;
  while (a > 0) {
    n++;
    a >>= 1;
  }
  return n;
}

/// [rgb] (three bytes a pixel, row by row, [width] x [height]) as a baseline
/// JPEG: YCbCr 4:4:4 at [jpegQuality], with a JFIF header that says [dpi]
/// dots per inch (rounded; at least 1).
Uint8List encodeJpeg(int width, int height, Uint8List rgb, {int dpi = 96}) {
  if (width < 1 || height < 1 || width > 65535 || height > 65535) {
    throw ArgumentError('The size $width x $height can not be a JPEG');
  }
  if (rgb.length < width * height * 3) throw ArgumentError('Not enough pixels');
  final lumaQ = jpegScaledTable(jpegLuminanceBase, jpegQuality);
  final chromaQ = jpegScaledTable(jpegChrominanceBase, jpegQuality);
  final dcL = jpegHuffmanCodes(jpegDcLuminance), acL = jpegHuffmanCodes(jpegAcLuminance);
  final dcC = jpegHuffmanCodes(jpegDcChrominance), acC = jpegHuffmanCodes(jpegAcChrominance);

  final out = BytesBuilder(copy: false);
  void marker(int m) => out
    ..addByte(0xFF)
    ..addByte(m);
  void u16(int v) => out
    ..addByte((v >> 8) & 0xFF)
    ..addByte(v & 0xFF);

  marker(0xD8); // SOI
  // APP0 JFIF: version 1.01, density in dots per inch.
  final d = dpi.clamp(1, 65535);
  marker(0xE0);
  u16(16);
  out.add(const [0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x01]);
  u16(d);
  u16(d);
  out.add(const [0, 0]);
  // DQT: both tables, 8-bit, in zigzag order.
  marker(0xDB);
  u16(2 + 2 * 65);
  out.addByte(0);
  for (var i = 0; i < 64; i++) {
    out.addByte(lumaQ[jpegZigzag[i]]);
  }
  out.addByte(1);
  for (var i = 0; i < 64; i++) {
    out.addByte(chromaQ[jpegZigzag[i]]);
  }
  // SOF0: 8 bits, three components 1x1 sampling.
  marker(0xC0);
  u16(17);
  out.addByte(8);
  u16(height);
  u16(width);
  out.addByte(3);
  out.add(const [1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1]);
  // DHT: DC0, AC0, DC1, AC1.
  void dht(int tcTh, JpegHuffmanTable t) {
    marker(0xC4);
    u16(2 + 1 + 16 + t.values.length);
    out.addByte(tcTh);
    out.add(t.counts);
    out.add(t.values);
  }

  dht(0x00, jpegDcLuminance);
  dht(0x10, jpegAcLuminance);
  dht(0x01, jpegDcChrominance);
  dht(0x11, jpegAcChrominance);
  // SOS: the three components, one scan, spectral 0..63.
  marker(0xDA);
  u16(12);
  out.addByte(3);
  out.add(const [1, 0x00, 2, 0x11, 3, 0x11]);
  out.add(const [0, 63, 0]);

  final w = _BitWriter();
  final yB = Float64List(64), cbB = Float64List(64), crB = Float64List(64);
  final tmp = Float64List(64), coef = Float64List(64);
  final quant = List<int>.filled(64, 0);
  var predY = 0, predCb = 0, predCr = 0;

  int block(
    Float64List samples,
    List<int> q,
    int pred,
    ({List<int> code, List<int> size}) dc,
    ({List<int> code, List<int> size}) ac,
  ) {
    _dct8x8(samples, tmp, coef);
    for (var i = 0; i < 64; i++) {
      // Zigzag order, divided by the quantiser and rounded to nearest.
      final natural = jpegZigzag[i];
      quant[i] = (coef[natural] / q[natural]).round();
    }
    final diff = quant[0] - pred;
    final size = _bitLength(diff);
    w.write(dc.code[size], dc.size[size]);
    if (size > 0) w.write(diff < 0 ? diff - 1 : diff, size);
    var run = 0;
    for (var i = 1; i < 64; i++) {
      final v = quant[i];
      if (v == 0) {
        run++;
        continue;
      }
      while (run > 15) {
        w.write(ac.code[0xF0], ac.size[0xF0]); // ZRL
        run -= 16;
      }
      final s = _bitLength(v);
      final sym = (run << 4) | s;
      w.write(ac.code[sym], ac.size[sym]);
      w.write(v < 0 ? v - 1 : v, s);
      run = 0;
    }
    if (run > 0) w.write(ac.code[0x00], ac.size[0x00]); // EOB
    return quant[0];
  }

  for (var by = 0; by < height; by += 8) {
    for (var bx = 0; bx < width; bx += 8) {
      for (var y = 0; y < 8; y++) {
        // Pixels past the edge repeat the last row and column.
        final sy = math.min(by + y, height - 1);
        for (var x = 0; x < 8; x++) {
          final sx = math.min(bx + x, width - 1);
          final p = (sy * width + sx) * 3;
          final r = rgb[p].toDouble(), g = rgb[p + 1].toDouble(), b = rgb[p + 2].toDouble();
          final i = y * 8 + x;
          yB[i] = 0.299 * r + 0.587 * g + 0.114 * b - 128;
          cbB[i] = -0.168736 * r - 0.331264 * g + 0.5 * b;
          crB[i] = 0.5 * r - 0.418688 * g - 0.081312 * b;
        }
      }
      predY = block(yB, lumaQ, predY, dcL, acL);
      predCb = block(cbB, chromaQ, predCb, dcC, acC);
      predCr = block(crB, chromaQ, predCr, dcC, acC);
    }
  }
  w.flush();
  out.add(w.out.takeBytes());
  marker(0xD9); // EOI
  return out.takeBytes();
}
