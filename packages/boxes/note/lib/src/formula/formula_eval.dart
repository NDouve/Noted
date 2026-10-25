// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pure Dart: no Flutter or appflowy_editor imports.

import 'dart:math' as math;

import 'formula_parser.dart';
import 'formula_value.dart';

/// The text of the cell at ([row], [col]); an empty string for an empty
/// cell. Both are zero-based and inside the sheet.
typedef CellTextReader = String Function(int row, int col);

/// One table's cells and the values of its formulas.
///
/// A cell whose text starts with `=` is a formula; any other cell is a
/// literal: empty, a number (`3`, `-2.5`, `1e3`), `TRUE` or `FALSE`, or text.
/// Values are computed on demand and memoized, so each cell is evaluated at
/// most once however many formulas use it, and a cell is evaluated before
/// the cells that depend on it. A cell reached again while it is still being
/// evaluated is a circular reference ([FormulaError.cycle]).
///
/// Nothing here throws: whatever goes wrong becomes an error value.
///
/// Functions (any case): `SUM AVERAGE MIN MAX COUNT ROUND ABS IF`. `SUM`,
/// `AVERAGE`, `MIN` and `MAX` use the numbers among their arguments: in a
/// range or a single-cell reference, empty cells, text and booleans are
/// skipped; written out directly, `TRUE` counts as 1 and text must look
/// like a number (else `#VALUE!`). `COUNT` counts numbers and ignores
/// errors. In arithmetic an empty cell is 0 and text that is not a number
/// is `#VALUE!`. `IF` evaluates only the branch it takes. A range outside
/// the table (even partly) is `#REF!`. Errors in an operand or argument
/// pass through unchanged, the first one winning.
final class FormulaSheet {
  FormulaSheet({required this.rows, required this.cols, required this.textAt});

  final int rows;
  final int cols;
  final CellTextReader textAt;

  final Map<int, Object?> _values = {};
  final Set<int> _visiting = {};
  final Map<int, Object> _parsed = {};

  /// The value of the cell at ([row], [col]) ([FormulaError.ref] outside
  /// the sheet).
  Object? valueAt(int row, int col) {
    if (row < 0 || col < 0 || row >= rows || col >= cols) {
      return FormulaError.ref;
    }
    final key = row * cols + col;
    if (_values.containsKey(key)) return _values[key];
    if (!_visiting.add(key)) return FormulaError.cycle;
    Object? value;
    try {
      value = _compute(key, textAt(row, col));
    } on Object {
      // A stack overflow from an absurdly deep chain, or a bug: a cell never
      // takes the editor down.
      value = FormulaError.parse;
    } finally {
      _visiting.remove(key);
    }
    return _values[key] = value;
  }

  /// [valueAt] as the text a cell shows.
  String displayAt(int row, int col) => formatFormulaValue(valueAt(row, col));

  Object? _compute(int key, String text) {
    if (!isFormulaText(text)) return literalValue(text);
    final parsed = _parsed[key] ??= _parse(text);
    if (parsed is FormulaError) return parsed;
    return _scalar(parsed as Expr);
  }

  Object _parse(String text) {
    try {
      return parseFormula(text);
    } on Object {
      return FormulaError.parse;
    }
  }

  // ---- expressions --------------------------------------------------------

  /// Evaluates [e] where one value is needed.
  Object? _scalar(Expr e) {
    switch (e) {
      case NumberExpr():
        return e.value;
      case StringExpr():
        return e.value;
      case BoolExpr():
        return e.value;
      case ErrorExpr():
        return e.error;
      case NameExpr():
        return FormulaError.name;
      case RefExpr():
        return valueAt(e.ref.row, e.ref.col);
      case RangeExpr():
        // No implicit intersection: a range needs a function around it.
        return _rangeInside(e) ? FormulaError.value : FormulaError.ref;
      case CallExpr():
        return _call(e);
      case UnaryExpr():
        final v = _number(_scalar(e.operand));
        if (v is! double) return v;
        return e.op == '-' ? -v : v;
      case PercentExpr():
        final v = _number(_scalar(e.operand));
        return v is double ? v / 100 : v;
      case BinaryExpr():
        return _binary(e);
    }
  }

  Object? _binary(BinaryExpr e) {
    final l = _scalar(e.left);
    final r = _scalar(e.right);
    if (l is FormulaError) return l;
    if (r is FormulaError) return r;
    switch (e.op) {
      case '&':
        return formatFormulaValue(l) + formatFormulaValue(r);
      case '=' || '<>' || '<' || '>' || '<=' || '>=':
        return _compare(e.op, l, r);
    }
    final a = _number(l);
    if (a is! double) return a;
    final b = _number(r);
    if (b is! double) return b;
    switch (e.op) {
      case '+':
        return _finite(a + b);
      case '-':
        return _finite(a - b);
      case '*':
        return _finite(a * b);
      case '/':
        return b == 0 ? FormulaError.div0 : _finite(a / b);
      case '^':
        if (a == 0 && b < 0) return FormulaError.div0;
        if (a == 0 && b == 0) return FormulaError.num;
        return _finite(math.pow(a, b).toDouble());
    }
    return FormulaError.parse;
  }

  Object? _finite(double v) => v.isNaN || v.isInfinite ? FormulaError.num : v;

  /// [v] as a number for arithmetic: empty is 0, booleans 1 and 0, text must
  /// look like a number. Returns a double or a [FormulaError].
  Object _number(Object? v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is bool) return v ? 1.0 : 0.0;
    if (v is FormulaError) return v;
    return parseNumberText(v as String) ?? FormulaError.value;
  }

  /// Number < text < boolean, as in Excel; text compares ignoring case. An
  /// empty value takes the type of the other side.
  Object? _compare(String op, Object? l, Object? r) {
    Object blank(Object? other) =>
        other is String ? '' : (other is bool ? false : 0.0);
    final a = l ?? blank(r);
    final b = r ?? blank(l);
    l = a;
    r = b;
    int rank(Object? v) => v is double ? 0 : (v is String ? 1 : 2);
    int c;
    if (rank(l) != rank(r)) {
      c = rank(l).compareTo(rank(r));
    } else if (l is double) {
      c = l.compareTo(r as double);
    } else if (l is String) {
      c = l.toLowerCase().compareTo((r as String).toLowerCase());
    } else {
      c = ((l as bool) ? 1 : 0).compareTo((r as bool) ? 1 : 0);
    }
    return switch (op) {
      '=' => c == 0,
      '<>' => c != 0,
      '<' => c < 0,
      '>' => c > 0,
      '<=' => c <= 0,
      _ => c >= 0,
    };
  }

  // ---- functions ----------------------------------------------------------

  Object? _call(CallExpr e) {
    final args = e.args;
    switch (e.name.toUpperCase()) {
      case 'IF':
        if (args.isEmpty || args.length > 3) return FormulaError.value;
        final c = _truth(_scalar(args[0]));
        if (c is FormulaError) return c;
        if (c == true) {
          return args.length > 1 ? _scalar(args[1]) : true;
        }
        return args.length > 2 ? _scalar(args[2]) : false;
      case 'ABS':
        if (args.length != 1) return FormulaError.value;
        final v = _number(_scalar(args.first));
        return v is double ? v.abs() : v;
      case 'ROUND':
        if (args.isEmpty || args.length > 2) return FormulaError.value;
        final x = _number(_scalar(args[0]));
        if (x is! double) return x;
        var digits = 0.0;
        if (args.length == 2) {
          final d = _number(_scalar(args[1]));
          if (d is! double) return d;
          digits = d;
        }
        return _round(x, digits.truncate());
      case 'SUM':
        return _aggregate(
          args,
          (List<double> n) => n.fold<double>(0, (a, b) => a + b),
        );
      case 'AVERAGE':
        return _aggregate(
          args,
          (List<double> n) => n.isEmpty
              ? FormulaError.div0
              : n.fold<double>(0, (a, b) => a + b) / n.length,
        );
      case 'MIN':
        return _aggregate(
          args,
          (List<double> n) => n.isEmpty ? 0.0 : n.reduce(math.min),
        );
      case 'MAX':
        return _aggregate(
          args,
          (List<double> n) => n.isEmpty ? 0.0 : n.reduce(math.max),
        );
      case 'COUNT':
        return _count(args);
    }
    return FormulaError.name;
  }

  Object? _round(double x, int digits) {
    if (digits > 300 || digits < -300) return FormulaError.num;
    final p = math.pow(10, digits.abs()).toDouble();
    // 15 significant digits first, so 2.675 * 100 is 267.5 and not 267.4999.
    double scaled(double v) =>
        double.parse((digits >= 0 ? v * p : v / p).toStringAsPrecision(15));
    final r = scaled(x.abs()).roundToDouble();
    final back = digits >= 0 ? r / p : r * p;
    return _finite(x < 0 ? -back : back);
  }

  /// [v] as a condition: a boolean, a number (0 is false), or the text
  /// `TRUE` / `FALSE`; empty is false.
  Object _truth(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is double) return v != 0;
    if (v is FormulaError) return v;
    final t = (v as String).trim().toUpperCase();
    if (t == 'TRUE') return true;
    if (t == 'FALSE') return false;
    return FormulaError.value;
  }

  /// The cells of a reference or range argument, row by row, or a
  /// [FormulaError].
  Object _cells(Expr e) {
    final CellRef a;
    final CellRef b;
    if (e is RefExpr) {
      a = b = e.ref;
    } else {
      final r = e as RangeExpr;
      a = r.from;
      b = r.to;
    }
    final r0 = math.min(a.row, b.row);
    final r1 = math.max(a.row, b.row);
    final c0 = math.min(a.col, b.col);
    final c1 = math.max(a.col, b.col);
    if (r1 >= rows || c1 >= cols) return FormulaError.ref;
    return [
      for (var r = r0; r <= r1; r++)
        for (var c = c0; c <= c1; c++) valueAt(r, c),
    ];
  }

  bool _rangeInside(RangeExpr e) =>
      math.max(e.from.row, e.to.row) < rows &&
      math.max(e.from.col, e.to.col) < cols;

  /// Collects the numbers among [args] and applies [reduce]; the first error
  /// found (in argument order) is the result.
  Object? _aggregate(List<Expr> args, Object? Function(List<double>) reduce) {
    if (args.isEmpty) return FormulaError.value;
    final numbers = <double>[];
    for (final a in args) {
      if (a is RefExpr || a is RangeExpr) {
        final cells = _cells(a);
        if (cells is FormulaError) return cells;
        for (final v in cells as List<Object?>) {
          if (v is FormulaError) return v;
          if (v is double) numbers.add(v);
        }
      } else {
        final v = _scalar(a);
        if (v is FormulaError) return v;
        final n = _number(v);
        if (n is FormulaError) return n;
        numbers.add(n as double);
      }
    }
    return _finiteOrError(reduce(numbers));
  }

  Object? _finiteOrError(Object? v) => v is double ? _finite(v) : v;

  Object? _count(List<Expr> args) {
    if (args.isEmpty) return FormulaError.value;
    var n = 0;
    for (final a in args) {
      if (a is RefExpr || a is RangeExpr) {
        final cells = _cells(a);
        if (cells is FormulaError) return cells;
        n += (cells as List<Object?>).whereType<double>().length;
      } else {
        final v = _scalar(a);
        if (v is double || v is bool) {
          n++;
        } else if (v is String && parseNumberText(v) != null) {
          n++;
        }
      }
    }
    return n.toDouble();
  }
}

/// The value of a cell that is not a formula: nothing for blank text, a
/// number for text that looks like one, a boolean for `TRUE` and `FALSE`
/// (any case), else the text itself.
Object? literalValue(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  final n = parseNumberText(t);
  if (n != null) return n;
  final u = t.toUpperCase();
  if (u == 'TRUE') return true;
  if (u == 'FALSE') return false;
  return text;
}
