// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'export_format.dart';

/// An encoded image that has been opened but not decoded: its size, and a way
/// to decode it at a size. The default is a `dart:ui` `ImageDescriptor`.
abstract interface class ExportImageSource {
  int get width;
  int get height;

  /// Decodes (the first frame of) the image at the given size.
  Future<ui.Codec> instantiateCodec({int? targetWidth, int? targetHeight});

  void dispose();
}

/// Opens [bytes] for [decodeWithinCap]. Null means the default
/// (`ImageDescriptor.encoded`). A test seam: tests record what is decoded.
@visibleForTesting
Future<ExportImageSource> Function(Uint8List bytes)? exportImageOpener;

final class _DescriptorSource implements ExportImageSource {
  _DescriptorSource(this._buffer, this._d);

  final ui.ImmutableBuffer _buffer;
  final ui.ImageDescriptor _d;

  @override
  int get width => _d.width;
  @override
  int get height => _d.height;

  @override
  Future<ui.Codec> instantiateCodec({int? targetWidth, int? targetHeight}) =>
      _d.instantiateCodec(targetWidth: targetWidth, targetHeight: targetHeight);

  @override
  void dispose() {
    _d.dispose();
    _buffer.dispose();
  }
}

Future<ExportImageSource> _open(Uint8List bytes) async {
  final opener = exportImageOpener;
  if (opener != null) return opener(bytes);
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    return _DescriptorSource(buffer, await ui.ImageDescriptor.encoded(buffer));
  } on Object {
    buffer.dispose();
    rethrow;
  }
}

/// The message for an image over [exportRefusePixels].
String exportTooLargeMessage(String name) => '$name is too large to convert. Export the original instead.';

/// Decodes the image in [bytes] (the first frame of a GIF) at a size within
/// [exportMaxSide] and [exportMaxPixels], never larger: the size is read
/// first, and the codec decodes straight to the target size. An image over
/// [exportRefusePixels] is refused before any decode with a [ExportRefused]
/// carrying [exportTooLargeMessage] for [name]. The caller disposes the image.
/// Throws another exception when the bytes don't decode.
Future<ui.Image> decodeWithinCap(Uint8List bytes, String name) async {
  final source = await _open(bytes);
  try {
    final w = source.width, h = source.height;
    if (w <= 0 || h <= 0 || w * h > exportRefusePixels) {
      throw ExportRefused(exportTooLargeMessage(name));
    }
    final r = exportRasterSize(ui.Size(w.toDouble(), h.toDouble()), 1);
    final codec = await source.instantiateCodec(targetWidth: r.width, targetHeight: r.height);
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  } finally {
    source.dispose();
  }
}

/// [image] as PNG bytes.
Future<Uint8List> imageToPng(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) throw StateError('The image could not be encoded.');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// Straight (not premultiplied) RGBA pixels of an image.
typedef ExportRgba = ({int width, int height, Uint8List rgba});

/// Decodes [bytes] within the caps ([decodeWithinCap]) to RGBA pixels.
Future<ExportRgba> decodeToRgba(Uint8List bytes, String name) async {
  final image = await decodeWithinCap(bytes, name);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (data == null) throw StateError('The image could not be read.');
    return (
      width: image.width,
      height: image.height,
      rgba: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    image.dispose();
  }
}

/// Whether [bytes] start with the PNG signature.
bool isPngBytes(Uint8List bytes) =>
    bytes.length >= 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47 &&
    bytes[4] == 0x0D &&
    bytes[5] == 0x0A &&
    bytes[6] == 0x1A &&
    bytes[7] == 0x0A;
