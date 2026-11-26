// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:math' as math;
import 'dart:typed_data';

/// PDF's largest page side, in points (user units).
const double pdfMaxPoints = 14400;

/// One page of a raster PDF: its size in points and the pixels drawn to fill
/// it, three bytes a pixel (RGB, row by row, already flattened onto white).
class RasterPdfPage {
  const RasterPdfPage({
    required this.widthPt,
    required this.heightPt,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.rgb,
  });

  final double widthPt;
  final double heightPt;
  final int pixelWidth;
  final int pixelHeight;
  final Uint8List rgb;
}

/// A PDF with one page for each of [pages]: each page is its MediaBox and one
/// `/FlateDecode` `DeviceRGB` image drawn to fill it. It knows no paper sizes.
/// The compressed stream is a zlib stream (as FlateDecode reads it) made with
/// `ZLibEncoder`'s defaults.
Uint8List writeRasterPdf(List<RasterPdfPage> pages) {
  if (pages.isEmpty) throw ArgumentError('A PDF needs a page');
  final out = BytesBuilder(copy: false);
  var length = 0;
  void raw(List<int> b) {
    out.add(b);
    length += b.length;
  }

  void text(String s) => raw(latin1.encode(s));
  final offsets = <int>[];
  void begin(int n) {
    offsets.add(length);
    text('$n 0 obj\n');
  }

  // The header and a comment of bytes over 127, so tools treat it as binary.
  text('%PDF-1.4\n');
  raw(const [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);

  begin(1);
  text('<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
  begin(2);
  text('<< /Type /Pages /Count ${pages.length} /Kids [${[for (var i = 0; i < pages.length; i++) '${3 + 3 * i} 0 R'].join(' ')}] >>\nendobj\n');
  for (var i = 0; i < pages.length; i++) {
    final p = pages[i];
    if (p.rgb.length != p.pixelWidth * p.pixelHeight * 3) {
      throw ArgumentError('Page $i does not hold ${p.pixelWidth} x ${p.pixelHeight} pixels');
    }
    final w = _pt(p.widthPt), h = _pt(p.heightPt);
    final page = 3 + 3 * i, content = page + 1, image = page + 2;
    begin(page);
    text(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $w $h] '
      '/Resources << /XObject << /Im0 $image 0 R >> >> /Contents $content 0 R >>\nendobj\n',
    );
    final draw = latin1.encode('q $w 0 0 $h 0 0 cm /Im0 Do Q');
    begin(content);
    text('<< /Length ${draw.length} >>\nstream\n');
    raw(draw);
    text('\nendstream\nendobj\n');
    final packed = zlib.encode(p.rgb);
    begin(image);
    text(
      '<< /Type /XObject /Subtype /Image /Width ${p.pixelWidth} /Height ${p.pixelHeight} '
      '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length ${packed.length} >>\nstream\n',
    );
    raw(packed);
    text('\nendstream\nendobj\n');
  }
  final xref = length;
  final count = offsets.length + 1;
  text('xref\n0 $count\n');
  text('0000000000 65535 f \n');
  for (final o in offsets) {
    text('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  text('trailer\n<< /Size $count /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return out.takeBytes();
}

/// A number of points with at most two decimals.
String _pt(double v) {
  final s = v.toStringAsFixed(2);
  final t = s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
  return t.isEmpty ? '0' : t;
}

/// The page of a single box's PDF: the raster's aspect ratio fitted inside the
/// box's logical size × 0.75 pt (96 logical px an inch; contain, so pixels are
/// never stretched), then a side past [pdfMaxPoints] scaled down, keeping the
/// aspect ratio. [dpi] is the raster's width in pixels over the page's width
/// in inches.
({double widthPt, double heightPt, int dpi}) singleBoxPdfPage({
  required double logicalWidth,
  required double logicalHeight,
  required int pixelWidth,
  required int pixelHeight,
}) {
  final boxW = math.max(1.0, logicalWidth) * 0.75;
  final boxH = math.max(1.0, logicalHeight) * 0.75;
  final aspect = pixelWidth / pixelHeight;
  var w = boxW, h = boxW / aspect;
  if (h > boxH) {
    h = boxH;
    w = boxH * aspect;
  }
  final over = math.max(w, h);
  if (over > pdfMaxPoints) {
    final f = pdfMaxPoints / over;
    w *= f;
    h *= f;
  }
  return (widthPt: w, heightPt: h, dpi: math.max(1, (pixelWidth / (w / 72)).round()));
}
