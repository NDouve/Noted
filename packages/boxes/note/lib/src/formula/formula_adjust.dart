// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pure Dart: no Flutter or appflowy_editor imports.

import 'dart:math' as math;

import 'formula_parser.dart';
import 'formula_value.dart';

/// A row or column inserted into or deleted from a table. [at] is the
/// zero-based index of the new row or column, or of the deleted one.
sealed class TableEdit {
  const TableEdit(this.at);
  final int at;
}

final class InsertRow extends TableEdit {
  const InsertRow(super.at);
}

final class InsertColumn extends TableEdit {
  const InsertColumn(super.at);
}

final class DeleteRow extends TableEdit {
  const DeleteRow(super.at);
}

final class DeleteColumn extends TableEdit {
  const DeleteColumn(super.at);
}

/// Rewrites the references in the formula [text] the way Excel does after
/// [edit]; text that is not a formula, or does not parse, is returned as is.
///
/// - Inserting: a reference at or after the new row or column moves one
///   along. A range whose first row (column) is at or after it moves; one
///   that spans it grows; one that ends before it stays.
/// - Deleting: a reference into the deleted row or column becomes `#REF!`,
///   one after it moves back. A range shrinks by the deleted row (column),
///   and becomes `#REF!` if that was all of it.
///
/// Only the references are rewritten: spacing, case of function names and
/// `$` markers stay. Several edits are applied one after the other.
String adjustFormula(String text, TableEdit edit) {
  if (!isFormulaText(text)) return text;
  final Expr tree;
  try {
    tree = parseFormula(text);
  } on FormulaParseException {
    return text;
  } on Object {
    return text;
  }
  final changes = <(int, int, String)>[];
  _collect(tree, edit, changes);
  if (changes.isEmpty) return text;
  changes.sort((a, b) => b.$1.compareTo(a.$1));
  var out = text;
  for (final (start, end, replacement) in changes) {
    out = out.replaceRange(start, end, replacement);
  }
  return out;
}

void _collect(Expr e, TableEdit edit, List<(int, int, String)> out) {
  switch (e) {
    case RefExpr():
      final moved = _moveRef(e.ref, edit);
      if (moved == null) {
        out.add((e.start, e.end, FormulaError.ref.code));
      } else if (moved != e.ref) {
        out.add((e.start, e.end, moved.toString()));
      }
    case RangeExpr():
      final moved = _moveRange(e.from, e.to, edit);
      if (moved == null) {
        out.add((e.start, e.end, FormulaError.ref.code));
      } else if (moved.$1 != e.from || moved.$2 != e.to) {
        out.add((e.start, e.end, '${moved.$1}:${moved.$2}'));
      }
    case CallExpr():
      for (final a in e.args) {
        _collect(a, edit, out);
      }
    case UnaryExpr():
      _collect(e.operand, edit, out);
    case PercentExpr():
      _collect(e.operand, edit, out);
    case BinaryExpr():
      _collect(e.left, edit, out);
      _collect(e.right, edit, out);
    case NumberExpr() ||
        StringExpr() ||
        BoolExpr() ||
        ErrorExpr() ||
        NameExpr():
      break;
  }
}

bool _onRows(TableEdit edit) => edit is InsertRow || edit is DeleteRow;

CellRef? _moveRef(CellRef r, TableEdit edit) {
  final isRow = _onRows(edit);
  final v = _single(isRow ? r.row : r.col, edit);
  if (v == null) return null;
  return isRow ? r.copyWith(row: v) : r.copyWith(col: v);
}

int? _single(int v, TableEdit edit) {
  switch (edit) {
    case InsertRow() || InsertColumn():
      return v >= edit.at ? v + 1 : v;
    case DeleteRow() || DeleteColumn():
      if (v == edit.at) return null;
      return v > edit.at ? v - 1 : v;
  }
}

(CellRef, CellRef)? _moveRange(CellRef a, CellRef b, TableEdit edit) {
  final isRow = _onRows(edit);
  final av = isRow ? a.row : a.col;
  final bv = isRow ? b.row : b.col;
  final lo = math.min(av, bv);
  final hi = math.max(av, bv);
  final int newLo;
  final int newHi;
  switch (edit) {
    case InsertRow() || InsertColumn():
      if (lo >= edit.at) {
        newLo = lo + 1;
        newHi = hi + 1;
      } else {
        newLo = lo;
        newHi = hi >= edit.at ? hi + 1 : hi;
      }
    case DeleteRow() || DeleteColumn():
      if (lo == edit.at && hi == edit.at) return null;
      newLo = lo > edit.at ? lo - 1 : lo;
      newHi = hi >= edit.at ? hi - 1 : hi;
  }
  // The corner that was the low end of the range keeps being the low end.
  final aIsLow = av <= bv;
  final na = aIsLow ? newLo : newHi;
  final nb = aIsLow ? newHi : newLo;
  return isRow
      ? (a.copyWith(row: na), b.copyWith(row: nb))
      : (a.copyWith(col: na), b.copyWith(col: nb));
}
