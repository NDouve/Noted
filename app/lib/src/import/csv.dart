// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:noted_core/noted_core.dart';

import 'import_limits.dart';
import 'import_result.dart';
import 'sheet_blocks.dart';

/// A `.csv` (comma) or `.tsv` (tab) as one table: RFC 4180 quoting, a quoted
/// cell may hold a newline (kept as a line break inside the cell). The same
/// row and column limits as a sheet.
BlocksResult csvToBlocks(Uint8List bytes, ImportLimits limits, String fileName, {required String delimiter}) =>
    sheetsToBlocks([csvSheet(utf8.decode(bytes, allowMalformed: true), limits, delimiter)], limits, fileName);

/// The cells of [text] as one [SheetData] with no name.
SheetData csvSheet(String text, ImportLimits limits, String delimiter) {
  final d = delimiter.codeUnitAt(0);
  final cells = <int, Map<int, String>>{};
  var rowsCut = false, columnsCut = false;
  var row = 0, col = 0;
  final cell = StringBuffer();
  var quoted = false; // inside quotes
  var wasQuoted = false; // the cell began with a quote
  var any = false; // something in the row

  void endCell() {
    final v = cell.toString();
    if (v.isNotEmpty || wasQuoted) any = true;
    if (v.isNotEmpty) {
      if (row >= limits.rows) {
        rowsCut = true;
      } else if (col >= limits.columns) {
        columnsCut = true;
      } else {
        (cells[row] ??= {})[col] = cutUtf8(v, noteCellReadMax);
      }
    }
    cell.clear();
    wasQuoted = false;
    col++;
  }

  void endRow() {
    endCell();
    if (any || col > 1) row++;
    col = 0;
    any = false;
  }

  var i = text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? 1 : 0;
  final n = text.length;
  while (i < n) {
    final c = text.codeUnitAt(i);
    if (quoted) {
      if (c == 0x22) {
        if (i + 1 < n && text.codeUnitAt(i + 1) == 0x22) {
          cell.writeCharCode(0x22);
          i++;
        } else {
          quoted = false;
        }
      } else if (c == 0x0D) {
        if (i + 1 < n && text.codeUnitAt(i + 1) == 0x0A) i++;
        cell.write('\n');
      } else {
        cell.writeCharCode(c);
      }
    } else if (c == 0x22 && cell.isEmpty && !wasQuoted) {
      quoted = true;
      wasQuoted = true;
    } else if (c == d) {
      endCell();
    } else if (c == 0x0A || c == 0x0D) {
      if (c == 0x0D && i + 1 < n && text.codeUnitAt(i + 1) == 0x0A) i++;
      endRow();
    } else {
      cell.writeCharCode(c);
    }
    i++;
    // Rows past the limit are only looked at for being non-empty.
    if (row > limits.rows + 1 && !quoted) {
      rowsCut = rowsCut || cells.isNotEmpty;
      break;
    }
  }
  if (cell.isNotEmpty || wasQuoted || col > 0) endRow();
  return gridOf(null, cells, rowsCut: rowsCut, columnsCut: columnsCut);
}
