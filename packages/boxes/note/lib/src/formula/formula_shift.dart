// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pure Dart: no Flutter or appflowy_editor imports.

import 'formula_parser.dart';
import 'formula_value.dart';

/// Rewrites the references in the formula [text] as if the formula had been
/// copied [rowOffset] rows down and [colOffset] columns right (negative
/// offsets go up and left), the way Excel does when a formula is copied.
///
/// - A relative row or column part moves by the offset; a part anchored
///   with `$` stays: `$A$1` never moves, `$A1` only moves along rows, `A$1`
///   only along columns. The two ends of a range are shifted separately.
/// - A reference (or range end) shifted off the sheet, to a row before 1 or
///   a column before A, makes the whole reference `#REF!`.
/// - Only reference tokens are rewritten: strings, numbers, function names,
///   spacing and the case of the letters stay as they were. Text that is not
///   a formula, or does not parse, is returned as is.
String shiftFormula(String text, int rowOffset, int colOffset) {
  if (rowOffset == 0 && colOffset == 0) return text;
  if (!isFormulaText(text)) return text;
  final Expr tree;
  try {
    tree = parseFormula(text);
  } on Object {
    return text;
  }
  final changes = <(int, int, String)>[];
  _collect(tree, text, rowOffset, colOffset, changes);
  if (changes.isEmpty) return text;
  changes.sort((a, b) => b.$1.compareTo(a.$1));
  var out = text;
  for (final (start, end, replacement) in changes) {
    out = out.replaceRange(start, end, replacement);
  }
  return out;
}

CellRef? _shiftRef(CellRef r, int rowOffset, int colOffset) {
  final row = r.absoluteRow ? r.row : r.row + rowOffset;
  final col = r.absoluteCol ? r.col : r.col + colOffset;
  if (row < 0 || col < 0) return null;
  return r.copyWith(row: row, col: col);
}

final RegExp _token = RegExp(r'[$A-Za-z0-9]+');

/// [part] (one reference, maybe with spaces around) with the reference
/// replaced by [moved], in lower case if the letters in [part] were.
String _rewriteToken(String part, CellRef moved) {
  final s = moved.toString();
  final lower = RegExp('[a-z]').hasMatch(part);
  return part.replaceFirst(_token, lower ? s.toLowerCase() : s);
}

void _collect(
  Expr e,
  String text,
  int dr,
  int dc,
  List<(int, int, String)> out,
) {
  switch (e) {
    case RefExpr():
      final moved = _shiftRef(e.ref, dr, dc);
      if (moved == null) {
        out.add((e.start, e.end, FormulaError.ref.code));
      } else if (moved != e.ref) {
        out.add((
          e.start,
          e.end,
          _rewriteToken(text.substring(e.start, e.end), moved),
        ));
      }
    case RangeExpr():
      final a = _shiftRef(e.from, dr, dc);
      final b = _shiftRef(e.to, dr, dc);
      if (a == null || b == null) {
        out.add((e.start, e.end, FormulaError.ref.code));
      } else if (a != e.from || b != e.to) {
        final parts = text.substring(e.start, e.end).split(':');
        if (parts.length == 2) {
          out.add((
            e.start,
            e.end,
            '${_rewriteToken(parts[0], a)}:${_rewriteToken(parts[1], b)}',
          ));
        }
      }
    case CallExpr():
      for (final a in e.args) {
        _collect(a, text, dr, dc, out);
      }
    case UnaryExpr():
      _collect(e.operand, text, dr, dc, out);
    case PercentExpr():
      _collect(e.operand, text, dr, dc, out);
    case BinaryExpr():
      _collect(e.left, text, dr, dc, out);
      _collect(e.right, text, dr, dc, out);
    case NumberExpr() ||
        StringExpr() ||
        BoolExpr() ||
        ErrorExpr() ||
        NameExpr():
      break;
  }
}
