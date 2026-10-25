// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pure Dart: no Flutter or appflowy_editor imports.

/// The error values a formula can produce. [code] is what a cell shows.
enum FormulaError {
  /// A reference outside the table, or to a deleted row or column.
  ref('#REF!'),

  /// Division by zero (also `0^-1`).
  div0('#DIV/0!'),

  /// A value of the wrong kind: text that is not a number in arithmetic, a
  /// range where one value is needed, a wrong number of arguments.
  value('#VALUE!'),

  /// An unknown function or name.
  name('#NAME?'),

  /// A number that does not exist or does not fit: `10^1000`, `(-8)^0.5`.
  num('#NUM!'),

  /// A circular reference. Excel shows 0 and a warning; here every cell on
  /// the cycle, and every cell that depends on one, shows this.
  cycle('#CYCLE!'),

  /// The formula could not be parsed (Excel refuses to accept such text).
  parse('#ERROR!');

  const FormulaError(this.code);

  final String code;

  /// The error with this [code], or null.
  static FormulaError? fromCode(String code) {
    for (final e in values) {
      if (e.code == code) return e;
    }
    return null;
  }

  @override
  String toString() => code;
}

/// A formula value is one of: `null` (an empty cell), a [double], a
/// [String], a [bool] or a [FormulaError].
///
/// How a value is written into a cell and into the box snapshot: numbers
/// without a trailing `.0` and rounded to 15 significant digits (so `0.1+0.2`
/// shows `0.3`), booleans as `TRUE` and `FALSE`, errors as their code.
String formatFormulaValue(Object? value) {
  if (value == null) return '';
  if (value is FormulaError) return value.code;
  if (value is bool) return value ? 'TRUE' : 'FALSE';
  if (value is double) return formatFormulaNumber(value);
  return value.toString();
}

/// See [formatFormulaValue].
String formatFormulaNumber(double n) {
  if (n.isNaN || n.isInfinite) return FormulaError.num.code;
  if (n == 0) return '0';
  if (n == n.truncateToDouble() && n.abs() < 1e15) {
    return n.toInt().toString();
  }
  final s = double.parse(n.toStringAsPrecision(15)).toString();
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

final RegExp _numberText = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');

/// The number in [text] (ignoring surrounding spaces), or null. Only plain
/// decimal notation: no `NaN`, `Infinity` or hex.
double? parseNumberText(String text) {
  final t = text.trim();
  if (!_numberText.hasMatch(t)) return null;
  return double.tryParse(t);
}
