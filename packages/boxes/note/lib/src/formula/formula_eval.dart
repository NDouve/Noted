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
/// Values are computed on demand and memoized, so each cell's value is
/// computed once however many formulas use it, and a cell is computed before
/// the cells that depend on it. (A formula that reads cells not yet computed
/// is evaluated again once they are; all of its missing cells are collected
/// in one pass, so it restarts once per level of the chain, not once per
/// reference.) A cell reached again while it is still being
/// evaluated is a circular reference. Every cell on a reference cycle is
/// [FormulaError.cycle] whichever cell is computed first, whatever other
/// error it would have (every operand and argument of a formula is read,
/// even after an error; only the branch an `IF` does not take is not). A
/// cell that merely depends on a cycle shows the error it passes on. (The
/// cells of a cycle are found as a strongly connected set of the
/// dependencies actually read, Tarjan style.)
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
  final Map<int, String> _texts = {};

  /// The cells the formula being evaluated read before they had a value.
  final Set<int> _missing = {};

  /// How many reads so far returned [_pending].
  int _pendingReads = 0;

  /// The worklist of the [valueAt] running: the cells in progress are in it
  /// in dependency order.
  List<int> _stack = const [];

  /// For a cell found to be on a cycle: the earliest cell of that cycle that
  /// was in progress at the time.
  final Map<int, int> _roots = {};

  /// Where a cell in progress sits in the worklist.
  final Map<int, int> _pos = {};

  /// The value of the cell at ([row], [col]) ([FormulaError.ref] outside
  /// the sheet).
  ///
  /// Dependencies between cells are followed with an explicit worklist, not
  /// by recursion: a formula that reads a cell not yet computed is
  /// suspended, that cell is computed first, and the formula is evaluated
  /// again. So a chain of any length uses constant stack, and the result
  /// does not depend on which cell is asked for first.
  Object? valueAt(int row, int col) {
    if (row < 0 || col < 0 || row >= rows || col >= cols) {
      return FormulaError.ref;
    }
    final start = row * cols + col;
    if (_values.containsKey(start)) return _values[start];
    final stack = _stack = <int>[start];
    while (stack.isNotEmpty) {
      final key = stack.last;
      if (_values.containsKey(key) && !_visiting.contains(key)) {
        stack.removeLast();
        continue;
      }
      _visiting.add(key);
      _pos[key] = stack.length - 1;
      _missing.clear();
      Object? value;
      _Pending? pending;
      try {
        value = _compute(
          key,
          _texts[key] ??= textAt(key ~/ cols, key % cols),
        );
      } on _Pending catch (p) {
        pending = p;
      } on Object {
        // A stack overflow from an absurdly deep expression, or a bug: a
        // cell never takes the editor down.
        value = FormulaError.parse;
      }
      _missing.clear();
      if (pending != null) {
        // Stays in progress: a read of this cell meanwhile is a cycle.
        stack.addAll(pending.keys);
      } else {
        _visiting.remove(key);
        // A cell found to be on a cycle keeps that value, but finishes
        // reading its own references first (they may be on the cycle too).
        _values.putIfAbsent(key, () => value);
        stack.removeLast();
      }
    }
    return _values[start];
  }

  /// The value of a cell read by a formula being evaluated: memoized, a
  /// cycle if the cell is in progress, else the cell is noted as missing and
  /// [_pending] stands in for its value (it passes through operators like
  /// an error). [_compute] then suspends the formula until every missing
  /// cell has been computed.
  Object? _read(int row, int col) {
    if (row < 0 || col < 0 || row >= rows || col >= cols) {
      return FormulaError.ref;
    }
    final key = row * cols + col;
    if (_visiting.contains(key)) {
      _markCycle(key);
      return FormulaError.cycle;
    }
    if (_values.containsKey(key)) {
      // A cell on a cycle whose other members are still in progress: the
      // reader is on that cycle too.
      final root = _roots[key];
      if (root != null && _visiting.contains(root)) _markCycle(root);
      return _values[key];
    }
    _missing.add(key);
    _pendingReads++;
    return _pending;
  }

  /// Makes every cell in progress from [root] up to the one reading it
  /// [FormulaError.cycle]. If one of them is already on a cycle with an
  /// earlier cell still in progress, that cycle is joined: the cells of a
  /// strongly connected set are all marked, whatever was computed first.
  void _markCycle(int root) {
    var lo = _pos[root]!;
    // Already marked with this cycle or an earlier one: nothing to do.
    final own = _roots[_stack.last];
    if (own != null && _visiting.contains(own) && _pos[own]! <= lo) return;
    for (var again = true; again;) {
      again = false;
      for (var i = lo; i < _stack.length; i++) {
        final r = _roots[_stack[i]];
        if (r == null || !_visiting.contains(r)) continue;
        final j = _pos[r]!;
        if (j < lo) {
          lo = j;
          again = true;
          break;
        }
      }
    }
    final top = _stack[lo];
    for (var i = lo; i < _stack.length; i++) {
      final k = _stack[i];
      if (!_visiting.contains(k)) continue;
      _values[k] = FormulaError.cycle;
      _roots[k] = top;
    }
  }

  /// [valueAt] as the text a cell shows.
  String displayAt(int row, int col) => formatFormulaValue(valueAt(row, col));

  Object? _compute(int key, String text) {
    if (!isFormulaText(text)) return literalValue(text);
    final parsed = _parsed[key] ??= _parse(text);
    if (parsed is FormulaError) return parsed;
    final v = _scalar(parsed as Expr);
    if (_missing.isNotEmpty) {
      throw _Pending(_missing.toList().reversed.toList());
    }
    return v;
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
        return _read(e.ref.row, e.ref.col);
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

  /// A run of operators, folded left to right in a loop (no recursion on its
  /// length). Each operand is evaluated even after an error, as before; the
  /// error of the left side wins.
  Object? _binary(BinaryExpr e) {
    var acc = _scalar(e.operands[0]);
    for (var i = 0; i < e.ops.length; i++) {
      acc = _apply(e.ops[i], acc, _scalar(e.operands[i + 1]));
    }
    return acc;
  }

  Object? _apply(String op, Object? l, Object? r) {
    if (identical(l, _pending) || identical(r, _pending)) return _pending;
    if (l is FormulaError) return l;
    if (r is FormulaError) return r;
    switch (op) {
      case '&':
        return formatFormulaValue(l) + formatFormulaValue(r);
      case '=' || '<>' || '<' || '>' || '<=' || '>=':
        return _compare(op, l, r);
    }
    final a = _number(l);
    if (a is! double) return a;
    final b = _number(r);
    if (b is! double) return b;
    switch (op) {
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
    if (identical(v, _pending)) return v;
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
        final before = _pendingReads;
        final c = _truth(_scalar(args[0]));
        // A condition made from cells with no value yet decides nothing: no
        // branch is taken (it would be a dependency that may not exist).
        if (_pendingReads != before) return _pending;
        if (c is FormulaError || identical(c, _pending)) return c;
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
        // Both arguments are read even if the first is an error.
        final d = args.length == 2 ? _number(_scalar(args[1])) : 0.0;
        if (x is! double) return x;
        if (d is! double) return d;
        final digits = d;
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
    if (identical(v, _pending)) return v;
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
        for (var c = c0; c <= c1; c++) _read(r, c),
    ];
  }

  bool _rangeInside(RangeExpr e) =>
      math.max(e.from.row, e.to.row) < rows &&
      math.max(e.from.col, e.to.col) < cols;

  /// Collects the numbers among [args] and applies [reduce]; the first error
  /// found (in argument order) is the result. Every argument is read even
  /// after an error.
  Object? _aggregate(List<Expr> args, Object? Function(List<double>) reduce) {
    if (args.isEmpty) return FormulaError.value;
    final numbers = <double>[];
    FormulaError? error;
    for (final a in args) {
      if (a is RefExpr || a is RangeExpr) {
        final cells = _cells(a);
        if (cells is FormulaError) {
          error ??= cells;
          continue;
        }
        for (final v in cells as List<Object?>) {
          if (v is FormulaError) error ??= v;
          if (v is double) numbers.add(v);
        }
      } else {
        final v = _scalar(a);
        if (v is FormulaError) {
          error ??= v;
          continue;
        }
        final n = _number(v);
        if (n is FormulaError) {
          error ??= n;
          continue;
        }
        if (identical(n, _pending)) continue;
        numbers.add(n as double);
      }
    }
    // Missing cells: the formula is evaluated again, this value is dropped.
    return error ?? _finiteOrError(reduce(numbers));
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

/// Stands in for the value of a cell that has none yet (see
/// [FormulaSheet]); never leaves the sheet.
final Object _pending = Object();

/// Thrown inside an evaluation to suspend a formula until the cells [keys]
/// (to be computed, last first) have values. Never leaves [FormulaSheet].
final class _Pending implements Exception {
  _Pending(this.keys);
  final List<int> keys;
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
