// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

import 'package:flutter/services.dart';

/// The longest side of an imported image, in pixels.
const int maxImageSide = 4096;

/// The most pixels of an imported image (16 megapixels).
const int maxImagePixels = 16 * 1000 * 1000;

/// The resolution a PDF page is rendered at.
const double pdfRenderDpi = 150;

/// The size in pixels of a page of [widthPt] by [heightPt] points (1/72 in)
/// rendered at [pdfRenderDpi] and scaled down so that neither side is over
/// [maxW] or [maxH] and the page is at most [maxImagePixels]; null if a side
/// would be under 1 px (the page is skipped). The platform renderers do the
/// same sum; Dart uses it for sheet images and to check what they return.
({int width, int height})? fitPixels(
  double widthPt,
  double heightPt, {
  double dpi = pdfRenderDpi,
  int maxW = maxImageSide,
  int maxH = maxImageSide,
}) {
  var w = widthPt * dpi / 72, h = heightPt * dpi / 72;
  if (!(w > 0) || !(h > 0) || w.isInfinite || h.isInfinite) return null;
  final s = math.min(1.0, math.min(math.min(maxW / w, maxH / h), math.sqrt(maxImagePixels / (w * h))));
  w *= s;
  h *= s;
  var pw = w.floor(), ph = h.floor();
  // Rounding down can't push a side past a cap; the pixel cap is exact.
  if (pw * ph > maxImagePixels) {
    final f = math.sqrt(maxImagePixels / (pw * ph));
    pw = (pw * f).floor();
    ph = (ph * f).floor();
  }
  if (pw < 1 || ph < 1) return null;
  return (width: pw, height: ph);
}

/// The pixel size a PNG says it has, or null if [png] isn't one.
({int width, int height})? pngSize(Uint8List png) {
  if (png.length < 24) return null;
  const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < 8; i++) {
    if (png[i] != sig[i]) return null;
  }
  final d = ByteData.sublistView(png);
  return (width: d.getUint32(16), height: d.getUint32(20));
}

/// An opened document: [handle] names it to the renderer until it is closed.
final class OpenedDocument {
  const OpenedDocument(this.handle, this.pageCount);

  final int handle;
  final int pageCount;
}

/// The renderer refused the document: it is password-protected.
final class DocumentPasswordException implements Exception {
  const DocumentPasswordException();
}

/// The renderer can't read the document, or failed.
final class DocumentRenderException implements Exception {
  const DocumentRenderException(this.message);

  final String message;

  @override
  String toString() => 'DocumentRenderException: $message';
}

/// The platform's document renderer, on the channel `noted/document_render`:
/// `open(bytes)` once, `render(handle, index, maxW, maxH)` for each page,
/// `close(handle)` in a `finally`. The native side works off the platform
/// thread and closes every open document when the engine detaches.
class DocumentRenderer {
  const DocumentRenderer([this.channel = const MethodChannel('noted/document_render')]);

  final MethodChannel channel;

  Future<OpenedDocument> open(Uint8List bytes) async {
    try {
      final r = await channel.invokeMapMethod<String, Object?>('open', {'bytes': bytes});
      final handle = r?['handle'], count = r?['pageCount'];
      if (handle is! int || count is! int) throw const DocumentRenderException('no document');
      return OpenedDocument(handle, count);
    } on PlatformException catch (e) {
      if (e.code == 'password') throw const DocumentPasswordException();
      throw DocumentRenderException('${e.code}: ${e.message}');
    } on MissingPluginException {
      throw const DocumentRenderException('no renderer');
    }
  }

  /// The PNG of page [index] (from 0), or null if the page is under 1 px.
  Future<Uint8List?> render(int handle, int index, {int maxW = maxImageSide, int maxH = maxImageSide}) async {
    try {
      return await channel.invokeMethod<Uint8List>('render', {
        'handle': handle,
        'index': index,
        'maxW': maxW,
        'maxH': maxH,
      });
    } on PlatformException catch (e) {
      throw DocumentRenderException('${e.code}: ${e.message}');
    }
  }

  Future<void> close(int handle) async {
    try {
      await channel.invokeMethod<void>('close', {'handle': handle});
    } on PlatformException {
      // Closing an unknown handle is harmless.
    } on MissingPluginException {
      // No renderer, nothing is open.
    }
  }
}

/// The renderer the import uses; tests change the channel's answers instead.
DocumentRenderer documentRenderer = const DocumentRenderer();
