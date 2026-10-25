// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pure Dart: no Flutter or appflowy_editor imports.

import 'formula_value.dart';

/// The grammar (a cell's text starts with `=`; spaces between tokens are
/// ignored), lowest precedence first:
///
/// ```
/// comparison := concat (('=' | '<>' | '<' | '>' | '<=' | '>=') concat)*
/// concat     := sum ('&' sum)*
/// sum        := product (('+' | '-') product)*
/// product    := power (('*' | '/') power)*
/// power      := unary ('^' unary)*          left-associative, as in Excel
/// unary      := ('-' | '+') unary | postfix  binds tighter than '^': -2^2 = 4
/// postfix    := primary '%'*
/// primary    := number | "string" | TRUE | FALSE | error | ref | range
///             | NAME '(' [expr (',' expr)*] ')' | '(' expr ')'
/// ref        := '$'? COLUMN '$'? ROW        A1, $A$1, AB12 (case-insensitive)
/// range      := ref ':' ref
/// error      := #REF! | #DIV/0! | #VALUE! | #NAME? | #NUM! | #CYCLE! | #ERROR!
/// ```
///
/// Numbers are `12`, `1.5`, `.5`, `1e3`, `2.5E-2`; strings use `""` for a
/// quote inside. `^` chains to the left as in Excel (`2^3^2` is 64). One
/// deviation from Excel: a missing argument is an error.
///
/// Every expression knows where it sits in the text ([Expr.start],
/// [Expr.end]), which is how references are rewritten without disturbing the
/// rest of the formula.
sealed class Expr {
  const Expr(this.start, this.end);

  /// Offsets into the formula text, including its leading `=`.
  final int start;
  final int end;
}

final class NumberExpr extends Expr {
  const NumberExpr(super.start, super.end, this.value);
  final double value;
}

final class StringExpr extends Expr {
  const StringExpr(super.start, super.end, this.value);
  final String value;
}

final class BoolExpr extends Expr {
  const BoolExpr(super.start, super.end, this.value);
  final bool value;
}

final class ErrorExpr extends Expr {
  const ErrorExpr(super.start, super.end, this.error);
  final FormulaError error;
}

/// A name that is not a function call or a boolean: always `#NAME?`.
final class NameExpr extends Expr {
  const NameExpr(super.start, super.end, this.name);
  final String name;
}

final class RefExpr extends Expr {
  const RefExpr(super.start, super.end, this.ref);
  final CellRef ref;
}

final class RangeExpr extends Expr {
  const RangeExpr(super.start, super.end, this.from, this.to);
  final CellRef from;
  final CellRef to;
}

final class CallExpr extends Expr {
  const CallExpr(super.start, super.end, this.name, this.args);
  final String name;
  final List<Expr> args;
}

final class UnaryExpr extends Expr {
  const UnaryExpr(super.start, super.end, this.op, this.operand);

  /// `-` or `+`.
  final String op;
  final Expr operand;
}

final class PercentExpr extends Expr {
  const PercentExpr(super.start, super.end, this.operand);
  final Expr operand;
}

final class BinaryExpr extends Expr {
  const BinaryExpr(super.start, super.end, this.op, this.left, this.right);

  /// One of `+ - * / ^ & = <> < > <= >=`.
  final String op;
  final Expr left;
  final Expr right;
}

/// A cell address, zero-based, with the `$` markers it was written with.
final class CellRef {
  const CellRef(
    this.row,
    this.col, {
    this.absoluteRow = false,
    this.absoluteCol = false,
  });

  final int row;
  final int col;
  final bool absoluteRow;
  final bool absoluteCol;

  CellRef copyWith({int? row, int? col}) => CellRef(
    row ?? this.row,
    col ?? this.col,
    absoluteRow: absoluteRow,
    absoluteCol: absoluteCol,
  );

  /// `A1`, `$A$1`, `AB12`.
  @override
  String toString() =>
      '${absoluteCol ? r'$' : ''}${columnName(col)}'
      '${absoluteRow ? r'$' : ''}${row + 1}';

  @override
  bool operator ==(Object other) =>
      other is CellRef &&
      other.row == row &&
      other.col == col &&
      other.absoluteRow == absoluteRow &&
      other.absoluteCol == absoluteCol;

  @override
  int get hashCode => Object.hash(row, col, absoluteRow, absoluteCol);
}

/// 0 -> `A`, 25 -> `Z`, 26 -> `AA`.
String columnName(int col) {
  var n = col + 1;
  final b = StringBuffer();
  while (n > 0) {
    final r = (n - 1) % 26;
    b.write(String.fromCharCode(65 + r));
    n = (n - 1) ~/ 26;
  }
  return b.toString().split('').reversed.join();
}

/// `A` -> 0, `AA` -> 26; the letters must be A-Z (any case).
int columnIndex(String letters) {
  var n = 0;
  for (final u in letters.toUpperCase().codeUnits) {
    n = n * 26 + (u - 64);
  }
  return n - 1;
}

/// Thrown by [parseFormula] for text that is not a formula.
final class FormulaParseException implements Exception {
  const FormulaParseException(this.message, this.position);

  final String message;
  final int position;

  @override
  String toString() => 'FormulaParseException($message at $position)';
}

/// True for cell text that is a formula: it starts with `=`.
bool isFormulaText(String text) => text.startsWith('=');

/// Parses [text], which must start with `=`. Throws
/// [FormulaParseException] on malformed input, including nesting deeper
/// than 100 levels.
Expr parseFormula(String text) {
  if (!isFormulaText(text)) {
    throw const FormulaParseException('a formula starts with =', 0);
  }
  return _Parser(_tokenize(text), text.length).parse();
}

enum _T {
  number,
  string,
  ref,
  ident,
  error,
  op,
  lparen,
  rparen,
  comma,
  colon,
  end,
}

final class _Token {
  const _Token(this.kind, this.start, this.end, this.text, [this.value]);

  final _T kind;
  final int start;
  final int end;
  final String text;
  final Object? value;
}

final RegExp _numberToken = RegExp(r'(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?');
final RegExp _refToken = RegExp(r'(\$?)([A-Za-z]{1,3})(\$?)([0-9]+)');
final RegExp _identToken = RegExp(r'[A-Za-z_][A-Za-z0-9_.]*');

bool _isIdentChar(int u) =>
    (u >= 48 && u <= 57) ||
    (u >= 65 && u <= 90) ||
    (u >= 97 && u <= 122) ||
    u == 95 ||
    u == 46;

List<_Token> _tokenize(String s) {
  final tokens = <_Token>[];
  var i = 1;
  while (i < s.length) {
    final c = s[i];
    final u = s.codeUnitAt(i);
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || u == 0xA0) {
      i++;
      continue;
    }
    if (c == '"') {
      final b = StringBuffer();
      var j = i + 1;
      var closed = false;
      while (j < s.length) {
        if (s[j] == '"') {
          if (j + 1 < s.length && s[j + 1] == '"') {
            b.write('"');
            j += 2;
            continue;
          }
          closed = true;
          j++;
          break;
        }
        b.write(s[j]);
        j++;
      }
      if (!closed) throw FormulaParseException('unterminated string', i);
      tokens.add(_Token(_T.string, i, j, s.substring(i, j), b.toString()));
      i = j;
      continue;
    }
    if (c == '#') {
      FormulaError? found;
      for (final e in FormulaError.values) {
        if (s.startsWith(e.code, i)) found = e;
      }
      if (found == null) throw FormulaParseException('unknown error', i);
      tokens.add(_Token(_T.error, i, i + found.code.length, found.code, found));
      i += found.code.length;
      continue;
    }
    final digit = u >= 48 && u <= 57;
    if (digit || (c == '.' && i + 1 < s.length && _isDigit(s, i + 1))) {
      final m = _numberToken.matchAsPrefix(s, i)!;
      final value = double.tryParse(m.group(0)!);
      if (value == null) throw FormulaParseException('bad number', i);
      tokens.add(_Token(_T.number, i, m.end, m.group(0)!, value));
      i = m.end;
      continue;
    }
    if (c == r'$' ||
        (u >= 65 && u <= 90) ||
        (u >= 97 && u <= 122) ||
        c == '_') {
      final r = _refToken.matchAsPrefix(s, i);
      if (r != null &&
          (r.end >= s.length ||
              (!_isIdentChar(s.codeUnitAt(r.end)) && s[r.end] != '(')) &&
          int.parse(r.group(4)!) > 0) {
        final ref = CellRef(
          int.parse(r.group(4)!) - 1,
          columnIndex(r.group(2)!),
          absoluteCol: r.group(1)!.isNotEmpty,
          absoluteRow: r.group(3)!.isNotEmpty,
        );
        tokens.add(_Token(_T.ref, i, r.end, r.group(0)!, ref));
        i = r.end;
        continue;
      }
      final id = _identToken.matchAsPrefix(s, i);
      if (id == null) throw FormulaParseException('unexpected \$', i);
      tokens.add(_Token(_T.ident, i, id.end, id.group(0)!));
      i = id.end;
      continue;
    }
    if (c == '<' || c == '>') {
      final two = i + 1 < s.length ? s.substring(i, i + 2) : '';
      if (two == '<=' || two == '>=' || two == '<>') {
        tokens.add(_Token(_T.op, i, i + 2, two));
        i += 2;
      } else {
        tokens.add(_Token(_T.op, i, i + 1, c));
        i++;
      }
      continue;
    }
    switch (c) {
      case '+' || '-' || '*' || '/' || '^' || '&' || '%' || '=':
        tokens.add(_Token(_T.op, i, i + 1, c));
      case '(':
        tokens.add(_Token(_T.lparen, i, i + 1, c));
      case ')':
        tokens.add(_Token(_T.rparen, i, i + 1, c));
      case ',':
        tokens.add(_Token(_T.comma, i, i + 1, c));
      case ':':
        tokens.add(_Token(_T.colon, i, i + 1, c));
      default:
        throw FormulaParseException('unexpected "$c"', i);
    }
    i++;
  }
  tokens.add(_Token(_T.end, s.length, s.length, ''));
  return tokens;
}

bool _isDigit(String s, int i) {
  final u = s.codeUnitAt(i);
  return u >= 48 && u <= 57;
}

const int _maxDepth = 100;

final class _Parser {
  _Parser(this._tokens, this._length);

  final List<_Token> _tokens;
  final int _length;
  int _i = 0;
  int _depth = 0;

  _Token get _peek => _tokens[_i];

  _Token _take() => _tokens[_i++];

  bool _isOp(String op) => _peek.kind == _T.op && _peek.text == op;

  Expr parse() {
    final e = _comparison();
    if (_peek.kind != _T.end) {
      throw FormulaParseException('unexpected "${_peek.text}"', _peek.start);
    }
    return e;
  }

  Expr _comparison() {
    var left = _concat();
    while (_peek.kind == _T.op &&
        const {'=', '<>', '<', '>', '<=', '>='}.contains(_peek.text)) {
      final op = _take().text;
      final right = _concat();
      left = BinaryExpr(left.start, right.end, op, left, right);
    }
    return left;
  }

  Expr _concat() {
    var left = _sum();
    while (_isOp('&')) {
      _take();
      final right = _sum();
      left = BinaryExpr(left.start, right.end, '&', left, right);
    }
    return left;
  }

  Expr _sum() {
    var left = _product();
    while (_isOp('+') || _isOp('-')) {
      final op = _take().text;
      final right = _product();
      left = BinaryExpr(left.start, right.end, op, left, right);
    }
    return left;
  }

  Expr _product() {
    var left = _power();
    while (_isOp('*') || _isOp('/')) {
      final op = _take().text;
      final right = _power();
      left = BinaryExpr(left.start, right.end, op, left, right);
    }
    return left;
  }

  Expr _power() {
    var left = _unary();
    while (_isOp('^')) {
      _take();
      final right = _nested(_unary);
      left = BinaryExpr(left.start, right.end, '^', left, right);
    }
    return left;
  }

  Expr _unary() {
    if (_isOp('-') || _isOp('+')) {
      final t = _take();
      final operand = _nested(_unary);
      return UnaryExpr(t.start, operand.end, t.text, operand);
    }
    var e = _primary();
    while (_isOp('%')) {
      final t = _take();
      e = PercentExpr(e.start, t.end, e);
    }
    return e;
  }

  Expr _nested(Expr Function() parse) {
    if (++_depth > _maxDepth) {
      throw FormulaParseException('nested too deeply', _peek.start);
    }
    try {
      return parse();
    } finally {
      _depth--;
    }
  }

  Expr _primary() {
    final t = _take();
    switch (t.kind) {
      case _T.number:
        return NumberExpr(t.start, t.end, t.value! as double);
      case _T.string:
        return StringExpr(t.start, t.end, t.value! as String);
      case _T.error:
        return ErrorExpr(t.start, t.end, t.value! as FormulaError);
      case _T.ref:
        final from = t.value! as CellRef;
        if (_peek.kind == _T.colon) {
          _take();
          final to = _take();
          if (to.kind != _T.ref) {
            throw FormulaParseException('a range needs two cells', to.start);
          }
          return RangeExpr(t.start, to.end, from, to.value! as CellRef);
        }
        return RefExpr(t.start, t.end, from);
      case _T.ident:
        if (_peek.kind == _T.lparen) return _call(t);
        final upper = t.text.toUpperCase();
        if (upper == 'TRUE') return BoolExpr(t.start, t.end, true);
        if (upper == 'FALSE') return BoolExpr(t.start, t.end, false);
        return NameExpr(t.start, t.end, t.text);
      case _T.lparen:
        final e = _nested(_comparison);
        final close = _take();
        if (close.kind != _T.rparen) {
          throw FormulaParseException('missing )', close.start);
        }
        // Parentheses are not kept in the tree, but the span of what they
        // enclose is what a rewrite needs, so nothing else is wrapped.
        return e;
      case _T.end:
        throw FormulaParseException('the formula ends too early', _length);
      case _T.op || _T.rparen || _T.comma || _T.colon:
        throw FormulaParseException('unexpected "${t.text}"', t.start);
    }
  }

  Expr _call(_Token name) {
    _take(); // (
    final args = <Expr>[];
    if (_peek.kind == _T.rparen) {
      final close = _take();
      return CallExpr(name.start, close.end, name.text, args);
    }
    while (true) {
      args.add(_nested(_comparison));
      final t = _take();
      if (t.kind == _T.rparen) {
        return CallExpr(name.start, t.end, name.text, args);
      }
      if (t.kind != _T.comma) {
        throw FormulaParseException('expected , or )', t.start);
      }
    }
  }
}
