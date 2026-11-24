// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'document_render.dart';
import 'sheet_blocks.dart';

/// The most rows and cells of one sheet image.
const int sheetChunkRows = 100;
const int sheetChunkCells = 2000;

/// Row ranges of [rows] by [columns] for one image each: at most
/// [sheetChunkRows] rows and [sheetChunkCells] cells.
List<(int, int)> sheetChunks(int rows, int columns) {
  final per = math.max(1, math.min(sheetChunkRows, sheetChunkCells ~/ math.max(1, columns)));
  return [for (var r = 0; r < rows; r += per) (r, math.min(rows, r + per))];
}

const double _fontSize = 13;
const double _padX = 8, _padY = 5, _maxCellWidth = 280, _margin = 12;
const ui.Color _ink = ui.Color(0xFF1B1B1B), _line = ui.Color(0xFFBDBDBD), _head = ui.Color(0xFFEFEFEF);

/// Draws rows [from] to [to] of [sheet] as a PNG: black on white, drawn with
/// a `PictureRecorder` and `TextPainter` (nothing is mounted), scaled down to
/// the pixel cap ([maxImageSide], [maxImagePixels]). The first row is shaded
/// as a header.
Future<Uint8List> drawSheetChunk(SheetData sheet, int from, int to) async {
  final rows = sheet.rows.sublist(from, to);
  final cols = rows.isEmpty ? 0 : rows.first.length;
  final style = const TextStyle(color: _ink, fontSize: _fontSize, height: 1.25);
  TextPainter paint(String text, {bool bold = false}) => TextPainter(
    text: TextSpan(text: text, style: bold ? style.copyWith(fontWeight: FontWeight.w600) : style),
    textDirection: TextDirection.ltr,
    maxLines: 4,
    ellipsis: '…',
  )..layout(maxWidth: _maxCellWidth);

  final painters = <List<TextPainter>>[];
  final widths = List<double>.filled(cols, 24);
  final heights = <double>[];
  final title = sheet.name == null || sheet.name!.isEmpty ? null : paint(sheet.name!, bold: true);
  for (var r = 0; r < rows.length; r++) {
    final line = <TextPainter>[];
    var h = 0.0;
    for (var c = 0; c < cols; c++) {
      final t = rows[r][c].isEmpty ? null : paint(rows[r][c], bold: from + r == 0);
      line.add(t ?? paint(' '));
      if (t != null) widths[c] = math.max(widths[c], t.width);
      h = math.max(h, line.last.height);
    }
    painters.add(line);
    heights.add(h + 2 * _padY);
  }
  final titleH = title == null ? 0.0 : title.height + _padY * 2;
  final w = _margin * 2 + widths.fold<double>(0, (a, b) => a + b + 2 * _padX);
  final h = _margin * 2 + titleH + heights.fold<double>(0, (a, b) => a + b);
  // Drawn at 1x (a unit is a pixel), scaled down to the cap, never enlarged.
  final px = fitPixels(w, h, dpi: 72);
  if (px == null) throw StateError('A sheet image has no size');
  final outW = px.width, outH = px.height;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()));
  canvas.scale(outW / w, outH / h);
  canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const ui.Color(0xFFFFFFFF));
  var y = _margin;
  if (title != null) {
    title.paint(canvas, Offset(_margin, y + _padY));
    y += titleH;
  }
  final line = Paint()
    ..color = _line
    ..strokeWidth = 1
    ..style = PaintingStyle.stroke;
  for (var r = 0; r < rows.length; r++) {
    var x = _margin;
    for (var c = 0; c < cols; c++) {
      final cell = Rect.fromLTWH(x, y, widths[c] + 2 * _padX, heights[r]);
      if (from + r == 0) canvas.drawRect(cell, Paint()..color = _head);
      canvas.drawRect(cell, line);
      painters[r][c].paint(canvas, Offset(x + _padX, y + _padY));
      x += cell.width;
    }
    y += heights[r];
  }
  final picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(outW, outH);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('A sheet image could not be encoded');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
    for (final p in painters) {
      for (final t in p) {
        t.dispose();
      }
    }
    title?.dispose();
  }
}
