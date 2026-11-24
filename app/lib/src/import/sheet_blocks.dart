// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:noted_core/noted_core.dart';

import 'import_limits.dart';
import 'import_result.dart';

/// One sheet's cells, as text.
final class SheetData {
  SheetData(this.name, this.rows, {this.rowsCut = false, this.columnsCut = false});

  /// The sheet's name, or null for a file that is one table (csv).
  final String? name;

  /// Rows of equal length, trailing empty rows and columns already trimmed.
  final List<List<String>> rows;

  /// Rows or columns past the limits were left out.
  final bool rowsCut;
  final bool columnsCut;
}

/// Sparse cells to a dense, trimmed grid of at most [rows] by [columns].
/// [cells] maps row to column to text; empty text is not stored.
SheetData gridOf(String? name, Map<int, Map<int, String>> cells, {bool rowsCut = false, bool columnsCut = false}) {
  var maxRow = -1, maxCol = -1;
  for (final r in cells.entries) {
    for (final c in r.value.entries) {
      if (c.value.isEmpty) continue;
      if (r.key > maxRow) maxRow = r.key;
      if (c.key > maxCol) maxCol = c.key;
    }
  }
  return SheetData(
    name,
    [
      for (var r = 0; r <= maxRow; r++) [for (var c = 0; c <= maxCol; c++) cells[r]?[c] ?? ''],
    ],
    rowsCut: rowsCut,
    columnsCut: columnsCut,
  );
}

/// What the readers keep of one cell: twice what a table cell shows, so that
/// [sheetsToBlocks] can tell that a cell was shortened.
const int noteCellReadMax = noteCellMaxBytes * 2;

/// The blocks for [sheets] of the file [fileName]: each named sheet a
/// heading and its table, a table of more than the limit's cells or bytes
/// cut into tables with the first row repeated. Empty sheets are skipped;
/// none left refuses the file.
BlocksResult sheetsToBlocks(List<SheetData> sheets, ImportLimits limits, String fileName) {
  final blocks = <Map<String, Object?>>[];
  final rowsCut = <String>[], colsCut = <String>[];
  var longCells = false;
  for (final s in sheets) {
    final label = s.name;
    if (s.rowsCut) rowsCut.add(label ?? '');
    if (s.columnsCut) colsCut.add(label ?? '');
    if (s.rows.isEmpty) continue;
    if (s.name != null) blocks.add(noteHeading(2, [NoteRun(s.name!)]));
    longCells = longCells || s.rows.any((r) => r.any((c) => c.length * 3 > noteCellMaxBytes && utf8.encode(c).length > noteCellMaxBytes));
    blocks.addAll(noteTables(s.rows, maxCells: limits.noteCells, maxBytes: limits.noteBytes));
  }
  if (blocks.isEmpty) throw const ImportException('has nothing to import');
  String where(List<String> names) {
    final named = names.where((n) => n.isNotEmpty).toList();
    return named.isEmpty ? '' : ' in ${named.join(', ')}';
  }

  final parts = [
    if (rowsCut.isNotEmpty) 'rows past ${limits.rows}${where(rowsCut)}',
    if (colsCut.isNotEmpty) 'columns past ${limits.columns}${where(colsCut)}',
  ];
  return BlocksResult(blocks, [
    if (parts.isNotEmpty) '"$fileName": left out ${parts.join('; ')}.',
    if (longCells) '"$fileName": long cells were shortened.',
  ]);
}
