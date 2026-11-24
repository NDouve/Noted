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
const double _padX = 8, _maxCellWidth = 280, _margin = 12;

/// The space above and below a cell's text.
const double sheetPadY = 5;
const ui.Color _ink = ui.Color(0xFF1B1B1B), _line = ui.Color(0xFFBDBDBD), _head = ui.Color(0xFFEFEFEF);

const TextStyle _style = TextStyle(color: _ink, fontSize: _fontSize, height: 1.25);

TextPainter _paint(String text, {bool bold = false, int? maxLines, double maxWidth = _maxCellWidth}) => TextPainter(
  text: TextSpan(text: text, style: bold ? _style.copyWith(fontWeight: FontWeight.w600) : _style),
  textDirection: TextDirection.ltr,
  maxLines: maxLines,
  ellipsis: maxLines == null ? null : '…',
)..layout(maxWidth: maxWidth);

/// How a sheet is drawn: the column widths, the height of each row, the
/// chunks (each an image) and whether a cell had to be cut.
final class SheetPlan {
  SheetPlan(this.widths, this.rowHeights, this.rowMaxLines, this.chunks, this.titleWidth, this.cut);

  final List<double> widths;

  /// The height of each row, with its padding.
  final List<double> rowHeights;

  /// For a row whose text is cut to fit an image, the most lines a cell shows.
  final List<int?> rowMaxLines;

  /// Row ranges, one image each: at most [sheetChunkRows] rows and
  /// [sheetChunkCells] cells, and a height that fits [maxImageSide].
  final List<(int, int)> chunks;

  /// The width of the sheet's name, 0 if it has none.
  final double titleWidth;

  /// A row was taller than an image can be, so its cells are cut.
  final bool cut;
}

/// Measures [sheet] and splits it into chunks, each at most 100 rows and 2,000
/// cells and short enough for one image. A cell shows its whole text; only a
/// row taller than an image is cut (then [SheetPlan.cut] is true).
SheetPlan planSheet(SheetData sheet) {
  final rows = sheet.rows;
  final cols = rows.isEmpty ? 0 : rows.first.length;
  final title = sheet.name == null || sheet.name!.isEmpty ? null : _paint(sheet.name!, bold: true, maxWidth: 1000);
  final titleW = title?.width ?? 0;
  final titleH = title == null ? 0.0 : title.height + sheetPadY * 2;
  title?.dispose();
  final room = maxImageSide - 2 * _margin - titleH;
  final widths = List<double>.filled(cols, 24);
  final heights = <double>[];
  final maxLines = <int?>[];
  var cut = false;
  for (var r = 0; r < rows.length; r++) {
    var h = 0.0, line = 0.0;
    final painters = <TextPainter>[];
    for (var c = 0; c < cols; c++) {
      final t = _paint(rows[r][c].isEmpty ? ' ' : rows[r][c], bold: r == 0);
      painters.add(t);
      if (rows[r][c].isNotEmpty) widths[c] = math.max(widths[c], t.width);
      h = math.max(h, t.height);
      line = t.preferredLineHeight;
    }
    for (final t in painters) {
      t.dispose();
    }
    int? limit;
    if (h + 2 * sheetPadY > room) {
      // One row taller than an image: show what fits of each cell.
      limit = math.max(1, ((room - 2 * sheetPadY) / line).floor());
      h = limit * line;
      cut = true;
    }
    heights.add(h + 2 * sheetPadY);
    maxLines.add(limit);
  }
  final chunks = <(int, int)>[];
  var from = 0, used = 0.0;
  for (var r = 0; r < rows.length; r++) {
    final full = r - from >= sheetChunkRows || (r - from + 1) * cols > sheetChunkCells || used + heights[r] > room;
    if (full && r > from) {
      chunks.add((from, r));
      from = r;
      used = 0;
    }
    used += heights[r];
  }
  if (from < rows.length) chunks.add((from, rows.length));
  return SheetPlan(widths, heights, maxLines, chunks, titleW, cut);
}

/// Draws rows [from] to [to] of [sheet] as a PNG: black on white, drawn with
/// a `PictureRecorder` and `TextPainter` (nothing is mounted), scaled down to
/// the pixel cap ([maxImageSide], [maxImagePixels]). The first row is shaded
/// as a header; the sheet's name is the title and widens the image if it must.
Future<Uint8List> drawSheetChunk(SheetData sheet, SheetPlan plan, int from, int to) async {
  final rows = sheet.rows.sublist(from, to);
  final cols = rows.isEmpty ? 0 : rows.first.length;
  final painters = <List<TextPainter>>[];
  for (var r = 0; r < rows.length; r++) {
    painters.add([
      for (var c = 0; c < cols; c++)
        _paint(rows[r][c].isEmpty ? ' ' : rows[r][c], bold: from + r == 0, maxLines: plan.rowMaxLines[from + r]),
    ]);
  }
  final title = sheet.name == null || sheet.name!.isEmpty ? null : _paint(sheet.name!, bold: true, maxWidth: 1000);
  final titleH = title == null ? 0.0 : title.height + sheetPadY * 2;
  final tableW = plan.widths.fold<double>(0, (a, b) => a + b + 2 * _padX);
  final w = _margin * 2 + math.max(tableW, plan.titleWidth);
  var h = _margin * 2 + titleH;
  for (var r = from; r < to; r++) {
    h += plan.rowHeights[r];
  }
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
    title.paint(canvas, Offset(_margin, y + sheetPadY));
    y += titleH;
  }
  final line = Paint()
    ..color = _line
    ..strokeWidth = 1
    ..style = PaintingStyle.stroke;
  for (var r = 0; r < rows.length; r++) {
    var x = _margin;
    final rh = plan.rowHeights[from + r];
    for (var c = 0; c < cols; c++) {
      final cell = Rect.fromLTWH(x, y, plan.widths[c] + 2 * _padX, rh);
      if (from + r == 0) canvas.drawRect(cell, Paint()..color = _head);
      canvas.drawRect(cell, line);
      painters[r][c].paint(canvas, Offset(x + _padX, y + sheetPadY));
      x += cell.width;
    }
    y += rh;
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
