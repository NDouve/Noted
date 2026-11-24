// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

/// The blocks for [sheets]: each named sheet a heading and its table, a table
/// of more than the limit's cells cut into tables with the first row
/// repeated. Empty sheets are skipped; none left refuses the file.
BlocksResult sheetsToBlocks(List<SheetData> sheets, ImportLimits limits) {
  final blocks = <Map<String, Object?>>[];
  final rowsCut = <String>[], colsCut = <String>[];
  for (final s in sheets) {
    final label = s.name ?? 'the table';
    if (s.rowsCut) rowsCut.add(label);
    if (s.columnsCut) colsCut.add(label);
    if (s.rows.isEmpty) continue;
    if (s.name != null) blocks.add(noteHeading(2, [NoteRun(s.name!)]));
    blocks.addAll(noteTables(s.rows, maxCells: limits.noteCells));
  }
  if (blocks.isEmpty) throw const ImportException('has nothing to import');
  final parts = [
    if (rowsCut.isNotEmpty) 'rows past ${limits.rows} in ${rowsCut.join(', ')}',
    if (colsCut.isNotEmpty) 'columns past ${limits.columns} in ${colsCut.join(', ')}',
  ];
  return BlocksResult(blocks, [if (parts.isNotEmpty) 'Left out: ${parts.join('; ')}.']);
}
