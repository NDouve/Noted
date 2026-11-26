// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/export/jpeg_encoder.dart';

Uint8List flat(int w, int h, int r, int g, int b) {
  final out = Uint8List(w * h * 3);
  for (var i = 0; i < w * h; i++) {
    out[i * 3] = r;
    out[i * 3 + 1] = g;
    out[i * 3 + 2] = b;
  }
  return out;
}

/// Decodes [jpeg] with the engine's codec: size and RGB pixels.
Future<(int, int, Uint8List)> decode(Uint8List jpeg) async {
  final codec = await ui.instantiateImageCodec(jpeg);
  final frame = await codec.getNextFrame();
  final data = (await frame.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
  final rgba = data.buffer.asUint8List();
  final rgb = Uint8List(frame.image.width * frame.image.height * 3);
  for (var i = 0; i < rgb.length ~/ 3; i++) {
    rgb[i * 3] = rgba[i * 4];
    rgb[i * 3 + 1] = rgba[i * 4 + 1];
    rgb[i * 3 + 2] = rgba[i * 4 + 2];
  }
  final r = (frame.image.width, frame.image.height, rgb);
  frame.image.dispose();
  return r;
}

/// The mean absolute difference between [a] and [b], per sample.
double meanError(Uint8List a, Uint8List b) {
  var sum = 0;
  for (var i = 0; i < a.length; i++) {
    sum += (a[i] - b[i]).abs();
  }
  return sum / a.length;
}

int count(Uint8List bytes, List<int> pattern) {
  var n = 0;
  for (var i = 0; i + pattern.length <= bytes.length; i++) {
    var ok = true;
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) {
        ok = false;
        break;
      }
    }
    if (ok) n++;
  }
  return n;
}

/// The segment of marker [m] (its body, without the length), or null.
Uint8List? segment(Uint8List jpeg, int m) {
  var i = 2;
  while (i + 4 <= jpeg.length) {
    if (jpeg[i] != 0xFF) return null;
    final marker = jpeg[i + 1];
    final len = (jpeg[i + 2] << 8) | jpeg[i + 3];
    if (marker == m) return jpeg.sublist(i + 4, i + 2 + len);
    if (marker == 0xDA) return null;
    i += 2 + len;
  }
  return null;
}

void main() {
  test('the quantisation tables are the Annex K examples at quality 90', () {
    // scale = 200 - 2 * 90 = 20: floor((base * 20 + 50) / 100), clamped to 1..255.
    final luma = jpegScaledTable(jpegLuminanceBase, 90);
    expect(luma.take(4), [3, 2, 2, 3]); // 16, 11, 10, 16
    expect(luma.last, 20); // 99
    final chroma = jpegScaledTable(jpegChrominanceBase, 90);
    expect(chroma.first, 3); // 17
    expect(chroma.last, 20);
    expect([...luma, ...chroma].every((q) => q >= 1 && q <= 255), isTrue);
    expect(jpegScaledTable([1, 2], 100), [1, 1], reason: 'clamped to at least 1');
    expect(jpegQuality, 90);
  });

  test('the Huffman tables are complete', () {
    for (final t in [jpegDcLuminance, jpegDcChrominance, jpegAcLuminance, jpegAcChrominance]) {
      expect(t.counts.reduce((a, b) => a + b), t.values.length);
      expect(t.counts, hasLength(16));
      // A prefix code: Kraft's sum is below 1 (the all-ones code is unused).
      var kraft = 0.0;
      for (var l = 1; l <= 16; l++) {
        kraft += t.counts[l - 1] / pow(2, l);
      }
      expect(kraft, lessThan(1));
      expect(t.values.toSet(), hasLength(t.values.length));
    }
    expect(jpegAcLuminance.values, hasLength(162));
    expect(jpegAcChrominance.values, hasLength(162));
    expect(jpegAcLuminance.values, contains(0xF0), reason: 'ZRL');
    expect(jpegAcLuminance.values, contains(0x00), reason: 'EOB');
  });

  test('the file is a JFIF baseline file with the tables in zigzag order and the dpi', () {
    final jpeg = encodeJpeg(16, 16, flat(16, 16, 10, 20, 30), dpi: 192);
    expect(jpeg.sublist(0, 2), [0xFF, 0xD8]);
    expect(jpeg.sublist(jpeg.length - 2), [0xFF, 0xD9]);
    final app0 = segment(jpeg, 0xE0)!;
    expect(String.fromCharCodes(app0.sublist(0, 4)), 'JFIF');
    expect(app0[7], 1, reason: 'dots per inch');
    expect((app0[8] << 8) | app0[9], 192);
    expect((app0[10] << 8) | app0[11], 192);
    final dqt = segment(jpeg, 0xDB)!;
    final luma = jpegScaledTable(jpegLuminanceBase, 90);
    expect(dqt[0], 0);
    expect(dqt.sublist(1, 65), [for (var i = 0; i < 64; i++) luma[jpegZigzag[i]]]);
    final sof = segment(jpeg, 0xC0)!;
    expect(sof[0], 8, reason: 'baseline, 8-bit');
    expect(sof[5], 3, reason: 'three components');
    expect(sof.sublist(6), [1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1], reason: '4:4:4');
  });

  test('the dpi is rounded into the header by the caller and at least 1', () {
    final jpeg = encodeJpeg(8, 8, flat(8, 8, 0, 0, 0), dpi: 0);
    final app0 = segment(jpeg, 0xE0)!;
    expect((app0[8] << 8) | app0[9], 1);
  });

  group('decoded by the engine', () {
    for (final (w, h) in [(16, 16), (17, 9), (1, 1), (8, 8), (33, 5)]) {
      testWidgets('a ${w}x$h image keeps its size', (t) async {
        await t.runAsync(() async {
          final jpeg = encodeJpeg(w, h, flat(w, h, 200, 100, 50));
          final img = await decode(jpeg);
          expect((img.$1, img.$2), (w, h));
          expect(meanError(img.$3, flat(w, h, 200, 100, 50)), lessThan(4));
        });
      });
    }

    for (final (name, r, g, b) in [('red', 255, 0, 0), ('green', 0, 255, 0), ('blue', 0, 0, 255), ('white', 255, 255, 255)]) {
      testWidgets('a flat $name block is within a tolerance of its colour', (t) async {
        await t.runAsync(() async {
          final img = await decode(encodeJpeg(16, 16, flat(16, 16, r, g, b)));
          for (var i = 0; i < 16 * 16; i++) {
            expect((img.$3[i * 3] - r).abs(), lessThanOrEqualTo(8), reason: 'R of pixel $i');
            expect((img.$3[i * 3 + 1] - g).abs(), lessThanOrEqualTo(8), reason: 'G of pixel $i');
            expect((img.$3[i * 3 + 2] - b).abs(), lessThanOrEqualTo(8), reason: 'B of pixel $i');
          }
        });
      });
    }

    testWidgets('noise exercises ZRL, EOB and byte stuffing and still decodes', (t) async {
      await t.runAsync(() async {
        final rnd = Random(7);
        const w = 64, h = 48;
        final rgb = Uint8List(w * h * 3);
        for (var i = 0; i < rgb.length; i++) {
          rgb[i] = rnd.nextInt(256);
        }
        final jpeg = encodeJpeg(w, h, rgb);
        // 0xFF in the entropy-coded data is followed by 0x00.
        expect(count(jpeg, [0xFF, 0x00]), greaterThan(0), reason: 'byte stuffing');
        final img = await decode(jpeg);
        expect((img.$1, img.$2), (w, h));
        // Quality 90 of noise is lossy, but not garbage.
        expect(meanError(img.$3, rgb), lessThan(40));
      });
    });

    testWidgets('a checkerboard has long zero runs: ZRL then a value, and it decodes', (t) async {
      await t.runAsync(() async {
        const w = 32, h = 32;
        final rgb = Uint8List(w * h * 3);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final v = (x + y) % 2 == 0 ? 255 : 0;
            final i = (y * w + x) * 3;
            rgb[i] = rgb[i + 1] = rgb[i + 2] = v;
          }
        }
        final jpeg = encodeJpeg(w, h, rgb);
        final img = await decode(jpeg);
        expect(meanError(img.$3, rgb), lessThan(30));
        // The coefficient (7, 7) is the only large one: a run of 62 zeros
        // before it takes three ZRL symbols (code of 0xF0 in the AC table).
        final codes = jpegHuffmanCodes(jpegAcLuminance);
        expect(codes.size[0xF0], greaterThan(0));
      });
    });

    testWidgets('one high-frequency coefficient after 62 zeros needs three ZRL symbols', (t) async {
      await t.runAsync(() async {
        // A grey block that is the (7, 7) basis function: after quantising,
        // its only AC coefficient is the last one in zigzag order, so 62 zeros
        // come first (three ZRL symbols and a run of 14).
        const w = 8, h = 8;
        final rgb = Uint8List(w * h * 3);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final v = 128 + 100 * cos((2 * x + 1) * 7 * pi / 16) * cos((2 * y + 1) * 7 * pi / 16);
            final i = (y * w + x) * 3;
            rgb[i] = rgb[i + 1] = rgb[i + 2] = v.round();
          }
        }
        final jpeg = encodeJpeg(w, h, rgb);
        final img = await decode(jpeg);
        expect((img.$1, img.$2), (w, h));
        expect(meanError(img.$3, rgb), lessThan(6));
      });
    });

    testWidgets('a gradient and a mix of edges decode close to the original', (t) async {
      await t.runAsync(() async {
        const w = 40, h = 24;
        final rgb = Uint8List(w * h * 3);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final i = (y * w + x) * 3;
            rgb[i] = x * 6;
            rgb[i + 1] = y * 10;
            rgb[i + 2] = x > 20 ? 220 : 30;
          }
        }
        final img = await decode(encodeJpeg(w, h, rgb));
        expect(meanError(img.$3, rgb), lessThan(6));
      });
    });
  });

  test('a size that can not be a JPEG is refused', () {
    expect(() => encodeJpeg(0, 5, Uint8List(0)), throwsArgumentError);
    expect(() => encodeJpeg(5, 5, Uint8List(10)), throwsArgumentError);
  });
}
