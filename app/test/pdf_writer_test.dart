// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/export/pdf_writer.dart';

/// A small reader of what [writeRasterPdf] writes: the cross-reference table,
/// the objects it points at, the pages and the image streams.
class ParsedPdf {
  ParsedPdf(this.bytes) : text = latin1.decode(bytes) {
    expect(text, startsWith('%PDF-1.4'));
    expect(text.trimRight(), endsWith('%%EOF'));
    final start = int.parse(RegExp(r'startxref\n(\d+)\n%%EOF').firstMatch(text)!.group(1)!);
    expect(text.substring(start, start + 4), 'xref');
    final lines = text.substring(start).split('\n');
    final header = lines[1].split(' ');
    expect(header[0], '0');
    count = int.parse(header[1]);
    for (var i = 0; i < count; i++) {
      final line = lines[2 + i];
      expect(line.length, 19, reason: 'a 20-byte entry with its newline: "$line"');
      offsets.add(int.parse(line.substring(0, 10)));
      expect(line.substring(10), i == 0 ? ' 65535 f ' : ' 00000 n ');
    }
    // The trailer.
    expect(text, contains('trailer\n<< /Size $count /Root 1 0 R >>'));
    // Every offset points at its own object.
    for (var n = 1; n < count; n++) {
      expect(text.substring(offsets[n]), startsWith('$n 0 obj\n'), reason: 'object $n at ${offsets[n]}');
    }
  }

  final Uint8List bytes;
  final String text;
  int count = 0;
  final List<int> offsets = [];

  String object(int n) {
    final from = offsets[n];
    return text.substring(from, text.indexOf('endobj', from));
  }

  List<int> get pageObjects => [for (var n = 1; n < count; n++) if (object(n).contains('/Type /Page ')) n];

  List<double> mediaBox(int page) {
    final m = RegExp(r'/MediaBox \[0 0 ([\d.]+) ([\d.]+)\]').firstMatch(object(page))!;
    return [double.parse(m.group(1)!), double.parse(m.group(2)!)];
  }

  /// The image of [page]: its dictionary values and the inflated stream.
  ({int width, int height, int length, Uint8List pixels}) image(int page) {
    final ref = RegExp(r'/Im0 (\d+) 0 R').firstMatch(object(page))!.group(1)!;
    final n = int.parse(ref);
    final obj = object(n);
    final width = int.parse(RegExp(r'/Width (\d+)').firstMatch(obj)!.group(1)!);
    final height = int.parse(RegExp(r'/Height (\d+)').firstMatch(obj)!.group(1)!);
    final length = int.parse(RegExp(r'/Length (\d+)').firstMatch(obj)!.group(1)!);
    expect(obj, contains('/ColorSpace /DeviceRGB'));
    expect(obj, contains('/BitsPerComponent 8'));
    expect(obj, contains('/Filter /FlateDecode'));
    final from = offsets[n] + obj.indexOf('stream\n') + 'stream\n'.length;
    final raw = bytes.sublist(from, from + length);
    expect(latin1.decode(bytes.sublist(from + length, from + length + 10)), startsWith('\nendstream'));
    return (width: width, height: height, length: length, pixels: Uint8List.fromList(ZLibDecoder().convert(raw)));
  }
}

Uint8List pixels(int w, int h) => Uint8List.fromList([for (var i = 0; i < w * h * 3; i++) (i * 7) % 256]);

void main() {
  test('one page: MediaBox, a FlateDecode DeviceRGB image of exactly W x H x 3 bytes', () {
    final rgb = pixels(6, 4);
    final pdf = ParsedPdf(
      writeRasterPdf([RasterPdfPage(widthPt: 300, heightPt: 200.5, pixelWidth: 6, pixelHeight: 4, rgb: rgb)]),
    );
    expect(pdf.pageObjects, hasLength(1));
    expect(pdf.text, contains('/Type /Pages /Count 1'));
    expect(pdf.mediaBox(pdf.pageObjects.single), [300, 200.5]);
    final img = pdf.image(pdf.pageObjects.single);
    expect((img.width, img.height), (6, 4));
    expect(img.pixels.length, 6 * 4 * 3);
    expect(img.pixels, rgb);
    // /Length is the compressed stream, and it is smaller than... what it says.
    expect(img.length, greaterThan(0));
    // The image is drawn to fill the page.
    expect(pdf.text, contains('q 300 0 0 200.5 0 0 cm /Im0 Do Q'));
  });

  test('several pages: a MediaBox and an image each, xref offsets right', () {
    final pdf = ParsedPdf(
      writeRasterPdf([
        RasterPdfPage(widthPt: 595.28, heightPt: 841.89, pixelWidth: 2, pixelHeight: 3, rgb: pixels(2, 3)),
        RasterPdfPage(widthPt: 841.89, heightPt: 595.28, pixelWidth: 3, pixelHeight: 2, rgb: pixels(3, 2)),
        RasterPdfPage(widthPt: 612, heightPt: 792, pixelWidth: 1, pixelHeight: 1, rgb: pixels(1, 1)),
      ]),
    );
    expect(pdf.pageObjects, hasLength(3));
    expect(pdf.text, contains('/Count 3'));
    expect([for (final p in pdf.pageObjects) pdf.mediaBox(p)], [
      [595.28, 841.89],
      [841.89, 595.28],
      [612, 792],
    ]);
    expect([for (final p in pdf.pageObjects) pdf.image(p).pixels.length], [18, 18, 3]);
    expect(pdf.count, 1 + 2 + 3 * 3);
  });

  test('a page whose pixels do not fill it, and no pages, are refused', () {
    expect(
      () => writeRasterPdf([RasterPdfPage(widthPt: 1, heightPt: 1, pixelWidth: 2, pixelHeight: 2, rgb: Uint8List(5))]),
      throwsArgumentError,
    );
    expect(() => writeRasterPdf(const []), throwsArgumentError);
  });

  group('the page of a single box', () {
    test('a 2x raster fits the box\'s logical size x 0.75 pt, and the dpi is 192', () {
      final p = singleBoxPdfPage(logicalWidth: 400, logicalHeight: 200, pixelWidth: 800, pixelHeight: 400);
      expect((p.widthPt, p.heightPt), (300, 150));
      expect(p.dpi, 192);
    });

    test('a raster of another aspect is contained, never stretched', () {
      // A square image in a 400x200 box: the page is as high as the box.
      final p = singleBoxPdfPage(logicalWidth: 400, logicalHeight: 200, pixelWidth: 100, pixelHeight: 100);
      expect((p.widthPt, p.heightPt), (150, 150));
      // A wide image in a tall box: as wide as the box.
      final q = singleBoxPdfPage(logicalWidth: 100, logicalHeight: 400, pixelWidth: 200, pixelHeight: 100);
      expect((q.widthPt, q.heightPt), (75, 37.5));
      expect(q.widthPt / q.heightPt, closeTo(2, 1e-9));
    });

    test('a side past 14,400 pt is scaled down, keeping the aspect', () {
      final p = singleBoxPdfPage(logicalWidth: 40000, logicalHeight: 1000, pixelWidth: 4096, pixelHeight: 102);
      expect(p.widthPt, closeTo(14400, 1e-6));
      expect(p.heightPt, closeTo(14400 * 102 / 4096, 1e-3));
      expect(p.widthPt / p.heightPt, closeTo(4096 / 102, 1e-3));
      // The cap lowered the dpi: 4096 px over 200 inches.
      expect(p.dpi, 20);
    });

    test('an image\'s own pixels give whatever dpi they give', () {
      final p = singleBoxPdfPage(logicalWidth: 100, logicalHeight: 100, pixelWidth: 3000, pixelHeight: 3000);
      expect((p.widthPt, p.heightPt), (75, 75));
      expect(p.dpi, 2880);
    });
  });
}
