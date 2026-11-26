// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Brightness;
import 'package:noted_canvas/noted_canvas.dart' show exportRasterSize;

import 'drawing_codec.dart';
import 'drawing_module.dart' show StrokesPainter;
import 'ink_color.dart';
import 'stroke_render.dart';

/// A drawing box's rectangle ([size], at scroll offset 0, where the box's
/// origin applies) as a transparent PNG with the strokes in light-theme ink,
/// at [pixelRatio] and within the export size caps. Strokes outside the
/// rectangle are clipped, as on screen. Null for an empty rectangle.
Future<Uint8List?> drawingToPng(DrawingData data, ui.Size size, double pixelRatio) async {
  if (size.width <= 0 || size.height <= 0) return null;
  final r = exportRasterSize(size, pixelRatio);
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, r.width.toDouble(), r.height.toDouble()));
  canvas.scale(r.width / size.width, r.height / size.height);
  canvas.clipRect(ui.Offset.zero & size);
  StrokesPainter(data, ui.Offset.zero, {}, Brightness.light).paint(canvas, size);
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(r.width, r.height);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

/// The same rectangle as an SVG file: one filled `<path>` per stroke, from
/// the polygon [strokeOutlinePoints] gives. The root's size clips the ink.
/// A stroke's `#AARRGGBB` is written as `fill="#RRGGBB"` and, unless it is
/// opaque, `fill-opacity`; the default ink is black.
String drawingToSvg(DrawingData data, ui.Size size) {
  final w = _n(size.width), h = _n(size.height);
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" viewBox="0 0 $w $h">')
    ..writeln('<g transform="translate(${_n(data.originX)} ${_n(data.originY)})">');
  for (final s in data.strokes) {
    final outline = strokeOutlinePoints(
      s.points,
      size: s.size,
      hasPressure: s.hasPressure,
      complete: true,
    );
    if (outline.isEmpty) continue;
    final d = StringBuffer();
    for (var i = 0; i < outline.length; i++) {
      d.write('${i == 0 ? 'M' : 'L'}${_n(outline[i].dx)} ${_n(outline[i].dy)}');
    }
    d.write('Z');
    final argb = s.color == defaultInkValue ? 0xFF000000 : s.color;
    final alpha = (argb >> 24) & 0xFF;
    final rgb = (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
    final opacity = alpha == 0xFF ? '' : ' fill-opacity="${_n(alpha / 255, 3)}"';
    b.writeln('<path d="$d" fill="#$rgb"$opacity/>');
  }
  b
    ..writeln('</g>')
    ..writeln('</svg>');
  return b.toString();
}

/// [v] with at most [places] decimals and no trailing zeros.
String _n(double v, [int places = 2]) {
  final s = v.toStringAsFixed(places);
  if (!s.contains('.')) return s;
  final t = s.replaceFirst(RegExp(r'\.?0+$'), '');
  return t == '-0' ? '0' : t;
}
