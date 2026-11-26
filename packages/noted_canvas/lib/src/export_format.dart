// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart' show immutable;

import 'attachment_store.dart';

/// A way to export one box (Box API 0.18). A module lists the formats it
/// makes ([BoxModule.exportFormats]); the host shows them and calls
/// [BoxModule.export].
@immutable
final class ExportFormat {
  const ExportFormat(this.id, this.label, this.extension);

  /// One of [text], [markdown], [html], [png], [svg], [original] (the ids a
  /// module may list), or [jpeg] and [pdf] (made by the host from a module's
  /// PNG; never passed to a module, and dropped from a module's list).
  final String id;

  /// What the format dialog shows.
  final String label;

  /// The file name extension without its dot; empty for [original], whose
  /// extension comes from the file.
  final String extension;

  static const ExportFormat text = ExportFormat('text', 'Plain text (.txt)', 'txt');
  static const ExportFormat markdown = ExportFormat('markdown', 'Markdown (.md)', 'md');
  static const ExportFormat html = ExportFormat('html', 'Web page (.html)', 'html');
  static const ExportFormat png = ExportFormat('png', 'Image (.png)', 'png');
  static const ExportFormat svg = ExportFormat('svg', 'Vector image (.svg)', 'svg');
  static const ExportFormat original = ExportFormat('original', 'Original file', '');

  /// Host-derived from the PNG (see the class comment).
  static const ExportFormat jpeg = ExportFormat('jpeg', 'Image (.jpg)', 'jpg');
  static const ExportFormat pdf = ExportFormat('pdf', 'PDF (.pdf)', 'pdf');

  /// The ids the host makes itself.
  static const Set<String> hostIds = {'jpeg', 'pdf'};

  @override
  bool operator ==(Object other) =>
      other is ExportFormat && other.id == id && other.label == label && other.extension == extension;

  @override
  int get hashCode => Object.hash(id, label, extension);

  @override
  String toString() => 'ExportFormat($id)';
}

/// A file a module made for [ExportFormat]: its bytes and a name. The name is
/// the file's own display name for [ExportFormat.original] and empty for the
/// other formats (the host names those from the page and the box).
@immutable
final class ExportedFile {
  const ExportedFile(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

/// What the host gives a module's export (Box API 0.18).
final class ExportContext {
  const ExportContext({
    this.attachments,
    required this.size,
    this.pixelRatio = 2,
    this.viewRenderer,
  });

  /// The page's images and files, or null where there are none.
  final AttachmentStore? attachments;

  /// The box's size in page units.
  final Size size;

  /// The raster scale the host wants (2). The host caps the result.
  final double pixelRatio;

  /// What makes [renderView]'s PNG; null where the host has none.
  final Future<Uint8List?> Function()? viewRenderer;

  /// The host's PNG of the box's read-only view ([BoxContext.offscreen] is
  /// true while it is drawn), in the light theme, at [pixelRatio] and within
  /// the host's size caps; null where the host can't make one.
  Future<Uint8List?> renderView() async => await viewRenderer?.call();
}

/// The longest side of an exported raster, in pixels.
const int exportMaxSide = 4096;

/// The most pixels an exported raster holds (16 MP).
const int exportMaxPixels = 16 * 1024 * 1024;

/// An image whose size is over this many pixels (100 MP) is never decoded for
/// a JPEG or PDF export.
const int exportRefusePixels = 100 * 1024 * 1024;

/// The pixel size of a raster of [size] page units at [pixelRatio], scaled
/// down (keeping the aspect ratio) so that no side is over [exportMaxSide]
/// and it holds at most [exportMaxPixels]. Each side is at least 1. [scale]
/// is the factor actually used.
({int width, int height, double scale}) exportRasterSize(Size size, double pixelRatio) {
  final w = size.width <= 0 ? 1.0 : size.width;
  final h = size.height <= 0 ? 1.0 : size.height;
  var scale = pixelRatio;
  final longest = w > h ? w : h;
  if (longest * scale > exportMaxSide) scale = exportMaxSide / longest;
  if (w * h * scale * scale > exportMaxPixels) {
    scale = math.sqrt(exportMaxPixels / (w * h));
  }
  // The rounding must not push a side over the cap.
  var pw = (w * scale).round().clamp(1, exportMaxSide);
  var ph = (h * scale).round().clamp(1, exportMaxSide);
  while (pw * ph > exportMaxPixels) {
    if (pw >= ph) {
      pw--;
    } else {
      ph--;
    }
  }
  return (width: pw, height: ph, scale: scale);
}
