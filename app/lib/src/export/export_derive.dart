// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:noted_canvas/noted_canvas.dart' show decodeToRgba;

import '../import/convert.dart' show ImportRunner, runInIsolate;
import 'jpeg_encoder.dart';
import 'pdf_writer.dart';

/// [rgba] (straight alpha, four bytes a pixel) flattened onto white as three
/// bytes a pixel: `c * a + 255 * (1 - a)`. White, not the page background: the
/// export is paper.
Uint8List flattenOntoWhite(Uint8List rgba) {
  final n = rgba.length ~/ 4;
  final rgb = Uint8List(n * 3);
  for (var i = 0, s = 0, d = 0; i < n; i++, s += 4, d += 3) {
    final a = rgba[s + 3];
    if (a == 255) {
      rgb[d] = rgba[s];
      rgb[d + 1] = rgba[s + 1];
      rgb[d + 2] = rgba[s + 2];
    } else {
      // Rounded: (c * a + 255 * (255 - a)) / 255.
      final inv = 255 * (255 - a);
      rgb[d] = (rgba[s] * a + inv + 127) ~/ 255;
      rgb[d + 1] = (rgba[s + 1] * a + inv + 127) ~/ 255;
      rgb[d + 2] = (rgba[s + 2] * a + inv + 127) ~/ 255;
    }
  }
  return rgb;
}

/// The JPEG or the single-page PDF of a box's PNG (host-derived, design 1a).
///
/// The PNG is decoded on this isolate the bounded way (the size is read first
/// and the codec decodes within the caps; one over 100 MP is refused with a
/// [FormatException] before any decode). Flattening, the encode and the PDF
/// then run together in one isolate through [run], and only the RGBA bytes go
/// in and the file's bytes come back.
Future<Uint8List> derivePngExport({
  required Uint8List png,
  required String name,
  required bool pdf,
  required Size boxSize,
  ImportRunner run = runInIsolate,
}) async {
  final px = await decodeToRgba(png, name);
  final w = px.width, h = px.height, rgba = px.rgba;
  final page = singleBoxPdfPage(
    logicalWidth: boxSize.width,
    logicalHeight: boxSize.height,
    pixelWidth: w,
    pixelHeight: h,
  );
  return run(() {
    final rgb = flattenOntoWhite(rgba);
    if (!pdf) return encodeJpeg(w, h, rgb, dpi: page.dpi);
    return writeRasterPdf([
      RasterPdfPage(widthPt: page.widthPt, heightPt: page.heightPt, pixelWidth: w, pixelHeight: h, rgb: rgb),
    ]);
  });
}
