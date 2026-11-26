// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// JPEG and the single-box PDF, derived by the host from a module's PNG: a
// bounded decode, alpha flattened onto white, and one isolate run.

import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/export/export_derive.dart';
import 'package:noted_canvas/noted_canvas.dart';

/// A PNG of [w] x [h]: transparent in the left half, [right] in the right.
Future<Uint8List> halfTransparentPng(int w, int h, ui.Color right) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(ui.Rect.fromLTWH(w / 2, 0, w / 2, h.toDouble()), ui.Paint()..color = right);
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<(int, int, Uint8List)> decodeJpeg(Uint8List jpeg) async {
  final codec = await ui.instantiateImageCodec(jpeg);
  final frame = await codec.getNextFrame();
  final data = (await frame.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
  final r = (frame.image.width, frame.image.height, data.buffer.asUint8List());
  frame.image.dispose();
  return r;
}

class _Source implements ExportImageSource {
  _Source(this.width, this.height);
  @override
  final int width;
  @override
  final int height;
  final List<(int?, int?)> decoded = [];
  @override
  Future<ui.Codec> instantiateCodec({int? targetWidth, int? targetHeight}) async {
    decoded.add((targetWidth, targetHeight));
    throw StateError('stop');
  }

  @override
  void dispose() {}
}

void main() {
  tearDown(() => exportImageOpener = null);

  test('flattening puts alpha onto white: c * a + 255 * (1 - a)', () {
    final rgba = Uint8List.fromList([
      10, 20, 30, 255, // opaque: unchanged
      10, 20, 30, 0, // transparent: white
      0, 0, 0, 128, // half black: mid grey
      255, 0, 0, 51, // a fifth red: pale red
    ]);
    final rgb = flattenOntoWhite(rgba);
    expect(rgb.sublist(0, 3), [10, 20, 30]);
    expect(rgb.sublist(3, 6), [255, 255, 255]);
    expect(rgb.sublist(6, 9), everyElement(inInclusiveRange(126, 128)));
    expect(rgb.sublist(9, 12), [255, 204, 204]);
  });

  testWidgets('a JPEG has the PNG\'s size, and what was transparent is white', (t) async {
    await t.runAsync(() async {
      final png = await halfTransparentPng(32, 16, const ui.Color(0xFFFF0000));
      var runs = 0;
      final jpeg = await derivePngExport(
        png: png,
        name: 'x.png',
        pdf: false,
        boxSize: const ui.Size(16, 8),
        run: <R>(work) async {
          runs++;
          return work();
        },
      );
      expect(runs, 1, reason: 'flattening and encoding run together, once');
      final img = await decodeJpeg(jpeg);
      expect((img.$1, img.$2), (32, 16));
      for (final x in [2, 8, 12]) {
        final i = (8 * 32 + x) * 4;
        for (var c = 0; c < 3; c++) {
          expect(img.$3[i + c], greaterThanOrEqualTo(252), reason: 'white at x=$x channel $c');
        }
      }
      final red = (8 * 32 + 26) * 4;
      expect(img.$3[red], greaterThan(230));
      expect(img.$3[red + 1], lessThan(30));
      // The header says the dpi of the PDF page: 32 px over (16 * .75 pt = 12 pt), 192 dpi.
      final app0 = jpeg.sublist(0, 30);
      expect((app0[14] << 8) | app0[15], 192);
    });
  });

  testWidgets('the default runner makes the file in another isolate', (t) async {
    await t.runAsync(() async {
      final png = await halfTransparentPng(16, 16, const ui.Color(0xFF0000FF));
      final jpeg = await derivePngExport(png: png, name: 'x.png', pdf: false, boxSize: const ui.Size(8, 8));
      expect(jpeg.sublist(0, 2), [0xFF, 0xD8]);
    });
  });

  testWidgets('a PDF is one page at the box\'s logical size x 0.75 pt with the flattened pixels', (t) async {
    await t.runAsync(() async {
      final png = await halfTransparentPng(40, 20, const ui.Color(0xFF00FF00));
      var runs = 0;
      final pdf = await derivePngExport(
        png: png,
        name: 'x.png',
        pdf: true,
        boxSize: const ui.Size(20, 10),
        run: <R>(work) async {
          runs++;
          return work();
        },
      );
      expect(runs, 1);
      final text = String.fromCharCodes(pdf);
      expect(text, startsWith('%PDF-1.4'));
      expect(RegExp('/Type /Page ').allMatches(text), hasLength(1));
      expect(text, contains('/MediaBox [0 0 15 7.5]'));
      expect(text, contains('/Width 40 /Height 20'));
      final length = int.parse(RegExp(r'/Filter /FlateDecode /Length (\d+) >>').firstMatch(text)!.group(1)!);
      final from = text.indexOf('/Filter /FlateDecode') + text.substring(text.indexOf('/Filter /FlateDecode')).indexOf('stream\n') + 7;
      final pixels = ZLibDecoder().convert(pdf.sublist(from, from + length));
      expect(pixels.length, 40 * 20 * 3);
      expect(pixels.sublist(0, 3), [255, 255, 255], reason: 'transparent is white');
      expect(pixels.sublist((5 * 40 + 30) * 3, (5 * 40 + 30) * 3 + 3), [0, 255, 0]);
    });
  });

  group('the decode is bounded (a recording ImageDescriptor)', () {
    testWidgets('a PNG over the cap is decoded at its target size, never at full size', (t) async {
      final source = _Source(8000, 6000);
      exportImageOpener = (_) async => source;
      await expectLater(
        derivePngExport(png: Uint8List(8), name: 'big.png', pdf: false, boxSize: const ui.Size(100, 100)),
        throwsStateError,
      );
      expect(source.decoded, [(4096, 3072)]);
    });

    testWidgets('the same for the PDF', (t) async {
      final source = _Source(6000, 6000);
      exportImageOpener = (_) async => source;
      await expectLater(
        derivePngExport(png: Uint8List(8), name: 'big.png', pdf: true, boxSize: const ui.Size(100, 100)),
        throwsStateError,
      );
      // 16 MP at most (16,000,000 pixels): 4000 x 4000.
      expect(source.decoded, [(4000, 4000)]);
    });

    for (final pdf in [false, true]) {
      testWidgets('one over 100 MP is refused with no decode (${pdf ? 'pdf' : 'jpeg'})', (t) async {
        final source = _Source(11000, 10000);
        exportImageOpener = (_) async => source;
        var ran = false;
        await expectLater(
          derivePngExport(
            png: Uint8List(8),
            name: 'Huge.png',
            pdf: pdf,
            boxSize: const ui.Size(100, 100),
            run: <R>(work) async {
              ran = true;
              return work();
            },
          ),
          throwsA(
            isA<ExportRefused>().having(
              (e) => e.message,
              'message',
              'Huge.png is too large to convert. Export the original instead.',
            ),
          ),
        );
        expect(source.decoded, isEmpty);
        expect(ran, isFalse, reason: 'nothing is flattened or encoded');
      });
    }
  });
}
