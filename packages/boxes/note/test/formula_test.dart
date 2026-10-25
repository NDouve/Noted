// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/src/formula/formula.dart';

/// A sheet from rows of cell text; shows the cell at [at] (`A1` style).
FormulaSheet sheet(List<List<String>> rows) => FormulaSheet(
  rows: rows.length,
  cols: rows.first.length,
  textAt: (r, c) => rows[r][c],
);

/// The display value of the formula [f] placed in a cell of a sheet whose
/// other cells are [rows] (the formula cell is appended as an extra row).
String calc(String f, [List<List<String>> rows = const []]) {
  final width = rows.isEmpty ? 1 : rows.first.length;
  final all = [
    ...rows,
    [f, for (var i = 1; i < width; i++) ''],
  ];
  return sheet(all).displayAt(all.length - 1, 0);
}

void main() {
  group('parser', () {
    test('numbers, strings, booleans, errors', () {
      expect(calc('=1'), '1');
      expect(calc('=1.5'), '1.5');
      expect(calc('=.5'), '0.5');
      expect(calc('=1e3'), '1000');
      expect(calc('=2.5E-2'), '0.025');
      expect(calc('="hi"'), 'hi');
      expect(calc('="say ""x"""'), 'say "x"');
      expect(calc('=TRUE'), 'TRUE');
      expect(calc('=false'), 'FALSE');
      expect(calc('=#REF!'), '#REF!');
      expect(calc('=#DIV/0!+1'), '#DIV/0!');
    });

    test('references: case, absolute markers, multi-letter columns', () {
      final rows = [
        ['5', '7'],
      ];
      expect(calc('=A1', rows), '5');
      expect(calc('=a1+b1', rows), '12');
      expect(calc(r'=$A$1+$B1+A$1', rows), '17');
      // Outside the table: AA1 is column 27.
      expect(calc('=AA1', rows), '#REF!');
      expect(columnName(0), 'A');
      expect(columnName(25), 'Z');
      expect(columnName(26), 'AA');
      expect(columnName(27), 'AB');
      expect(columnName(701), 'ZZ');
      expect(columnName(702), 'AAA');
      expect(columnIndex('AA'), 26);
      expect(columnIndex('ab'), 27);
      for (var i = 0; i < 2000; i++) {
        expect(columnIndex(columnName(i)), i);
      }
      final wide = [List.generate(30, (i) => '${i + 1}')];
      expect(calc('=AD1', wide), '30');
      expect(calc('=AA1+AB1', wide), '55');
    });

    test('whitespace is free between tokens', () {
      final rows = [
        ['1', '2', '3'],
      ];
      expect(calc('=  A1  +\tB1 * ( C1 )', rows), '7');
      expect(calc('=SUM( A1 : C1 , 4 )', rows), '10');
    });

    test('malformed input is #ERROR!, never an exception', () {
      for (final f in [
        '=',
        '=1+',
        '=(1',
        '=1)',
        '=1 2',
        '=*3',
        '="open',
        '=SUM(1,)',
        '=SUM(,1)',
        '=A1:',
        '=A1:5',
        '=1 + + ',
        '=@',
        '=#FOO!',
        '=%',
        '=1,2',
        '=SUM(1',
      ]) {
        expect(calc(f), '#ERROR!', reason: f);
      }
      expect(() => parseFormula('=1+'), throwsA(isA<FormulaParseException>()));
      expect(() => parseFormula('1+1'), throwsA(isA<FormulaParseException>()));
    });

    test('absurd nesting is an error, not a stack overflow', () {
      expect(calc('=${'(' * 5000}1${')' * 5000}'), '#ERROR!');
      expect(calc('=${'-' * 5000}1'), '#ERROR!');
      expect(calc('=1${'^1' * 5000}'), '#ERROR!');
      // Long but flat is fine.
      expect(calc('=${List.filled(3000, '1').join('+')}'), '3000');
    });

    test('names that are neither functions nor booleans are #NAME?', () {
      expect(calc('=foo'), '#NAME?');
      expect(calc('=A'), '#NAME?');
      expect(calc('=A0'), '#NAME?');
      expect(calc('=NOPE(1)'), '#NAME?');
      expect(calc('=1+foo'), '#NAME?');
    });

    test('isFormulaText', () {
      expect(isFormulaText('=1'), isTrue);
      expect(isFormulaText(' =1'), isFalse);
      expect(isFormulaText('1'), isFalse);
    });
  });

  group('arithmetic', () {
    test('operators and precedence', () {
      expect(calc('=1+2*3'), '7');
      expect(calc('=(1+2)*3'), '9');
      expect(calc('=10-4-3'), '3');
      expect(calc('=100/10/5'), '2');
      expect(calc('=2*3+4*5'), '26');
      expect(calc('=7/2'), '3.5');
      expect(calc('=0.1+0.2'), '0.3');
      expect(calc('=1/3'), '0.333333333333333');
    });

    test('unary minus binds tighter than ^ (Excel): -2^2 is 4', () {
      expect(calc('=-2^2'), '4');
      expect(calc('=2^-2'), '0.25');
      expect(calc('=-(2^2)'), '-4');
      expect(calc('=+3'), '3');
      expect(calc('=--3'), '3');
      expect(calc('=3--3'), '6');
      expect(calc('=-2*3'), '-6');
    });

    test('^ chains to the left, as in Excel: 2^3^2 is 64', () {
      expect(calc('=2^3^2'), '64');
      expect(calc('=(2^3)^2'), '64');
      expect(calc('=2*3^2'), '18');
    });

    test('percent', () {
      expect(calc('=50%'), '0.5');
      expect(calc('=200*10%'), '20');
      expect(calc('=-50%'), '-0.5');
    });

    test(
      'empty cells are 0, text is #VALUE!, text that looks numeric works',
      () {
        final rows = [
          ['', 'abc', '4'],
        ];
        expect(calc('=A1+1', rows), '1');
        expect(calc('=A1*5', rows), '0');
        expect(calc('=B1+1', rows), '#VALUE!');
        expect(calc('=-B1', rows), '#VALUE!');
        expect(calc('=C1+1', rows), '5');
        expect(calc('="3"+1'), '4');
        expect(calc('="x"+1'), '#VALUE!');
        expect(calc('=""+1'), '#VALUE!');
        expect(calc('=TRUE+1'), '2');
      },
    );

    test('division by zero, overflow, impossible powers', () {
      expect(calc('=1/0'), '#DIV/0!');
      expect(calc('=0/0'), '#DIV/0!');
      expect(calc('=1/(2-2)'), '#DIV/0!');
      expect(calc('=0^-1'), '#DIV/0!');
      expect(calc('=0^0'), '#NUM!');
      expect(calc('=10^1000'), '#NUM!');
      expect(calc('=(-8)^0.5'), '#NUM!');
      expect(calc('=1e308*10'), '#NUM!');
    });

    test('concatenation', () {
      expect(calc('="a"&"b"'), 'ab');
      expect(calc('="n="&1.5'), 'n=1.5');
      expect(calc('=1+2&3'), '33');
      expect(calc('="x"&TRUE'), 'xTRUE');
    });

    test('comparisons', () {
      expect(calc('=1=1'), 'TRUE');
      expect(calc('=1<>1'), 'FALSE');
      expect(calc('=1<2'), 'TRUE');
      expect(calc('=2<=2'), 'TRUE');
      expect(calc('=3>=4'), 'FALSE');
      expect(calc('=3>2'), 'TRUE');
      expect(calc('="a"="A"'), 'TRUE');
      expect(calc('="a"<"b"'), 'TRUE');
      expect(calc('="a"=1'), 'FALSE');
      // Number < text < boolean.
      expect(calc('=1<"a"'), 'TRUE');
      expect(calc('="a"<TRUE'), 'TRUE');
      expect(calc('=1+1=2'), 'TRUE');
      expect(calc('=1&1="11"'), 'TRUE');
      final rows = [
        ['', '0', ''],
      ];
      expect(calc('=A1=B1', rows), 'TRUE');
      expect(calc('=A1=""', rows), 'TRUE');
      expect(calc('=A1=C1', rows), 'TRUE');
    });
  });

  group('functions', () {
    final rows = [
      ['1', '2', '3'],
      ['4', 'text', ''],
      ['5', '-6', 'TRUE'],
    ];

    test('SUM', () {
      expect(calc('=SUM(A1:C1)', rows), '6');
      expect(calc('=SUM(A1:C3)', rows), '9');
      expect(calc('=sum(A1,B1,5)', rows), '8');
      expect(calc('=SUM(A1:A3,10)', rows), '20');
      expect(calc('=SUM(B2)', rows), '0', reason: 'text in a reference');
      expect(calc('=SUM(C2)', rows), '0');
      expect(calc('=SUM(1,TRUE)'), '2');
      expect(calc('=SUM("5",1)'), '6');
      expect(calc('=SUM("x")'), '#VALUE!');
      expect(calc('=SUM()'), '#VALUE!');
      expect(calc('=SUM(C1:A1)', rows), '6', reason: 'reversed range');
    });

    test('AVERAGE skips empty and text', () {
      expect(calc('=AVERAGE(A1:A3)', rows), '3.33333333333333');
      expect(calc('=AVERAGE(A2:C2)', rows), '4');
      expect(calc('=AVERAGE(B2:C2)', rows), '#DIV/0!');
      expect(calc('=AVERAGE(2,4)'), '3');
    });

    test('MIN and MAX', () {
      expect(calc('=MIN(A1:C3)', rows), '-6');
      expect(calc('=MAX(A1:C3)', rows), '5');
      expect(calc('=MAX(B2:C2)', rows), '0', reason: 'no numbers');
      expect(calc('=MIN(3,1,2)'), '1');
      expect(calc('=MAX(A1,A2,A3)', rows), '5');
    });

    test('COUNT counts numbers, ignores errors', () {
      expect(calc('=COUNT(A1:C3)', rows), '6');
      expect(calc('=COUNT(B2:C2)', rows), '0');
      expect(calc('=COUNT(1,"2","x",TRUE)'), '3');
      expect(calc('=COUNT(1/0,2)'), '1');
      expect(calc('=COUNT()'), '#VALUE!');
    });

    test('ROUND', () {
      expect(calc('=ROUND(2.5,0)'), '3');
      expect(calc('=ROUND(-2.5,0)'), '-3');
      expect(calc('=ROUND(2.675,2)'), '2.68');
      expect(calc('=ROUND(1.005,2)'), '1.01');
      expect(calc('=ROUND(1234.5678,-2)'), '1200');
      expect(calc('=ROUND(3.14159,3)'), '3.142');
      expect(calc('=ROUND(7)'), '7');
      expect(calc('=ROUND(1,2,3)'), '#VALUE!');
      expect(calc('=ROUND("a",1)'), '#VALUE!');
    });

    test('ABS', () {
      expect(calc('=ABS(-3)'), '3');
      expect(calc('=ABS(3)'), '3');
      expect(calc('=ABS(-A1)', rows), '1');
      expect(calc('=ABS()'), '#VALUE!');
      expect(calc('=ABS(1,2)'), '#VALUE!');
    });

    test('IF', () {
      expect(calc('=IF(1,"y","n")'), 'y');
      expect(calc('=IF(0,"y","n")'), 'n');
      expect(calc('=IF(A1>A2,"big","small")', rows), 'small');
      expect(calc('=IF(TRUE,1)'), '1');
      expect(calc('=IF(FALSE,1)'), 'FALSE');
      expect(calc('=IF("TRUE",1,2)'), '1');
      expect(calc('=IF("maybe",1,2)'), '#VALUE!');
      expect(calc('=IF(1/0,1,2)'), '#DIV/0!');
      expect(calc('=IF(1)'), 'TRUE');
      expect(calc('=IF()'), '#VALUE!');
      expect(calc('=IF(1,2,3,4)'), '#VALUE!');
      expect(calc('=IF(SUM(A1:A3)>9,"hi","lo")', rows), 'hi');
    });

    test('IF is lazy: the branch not taken is never evaluated', () {
      expect(calc('=IF(TRUE,1,1/0)'), '1');
      expect(calc('=IF(FALSE,1/0,2)'), '2');
      expect(calc('=IF(TRUE,1,NOPE(2))'), '1');
      // Even a circular reference in the untaken branch is harmless.
      final s = sheet([
        ['=IF(TRUE,1,A1)'],
      ]);
      expect(s.displayAt(0, 0), '1');
    });

    test('ranges only where a function takes them', () {
      expect(calc('=A1:C1', rows), '#VALUE!');
      expect(calc('=A1:C1+1', rows), '#VALUE!');
      expect(calc('=ABS(A1:C1)', rows), '#VALUE!');
      expect(calc('=A1:Z9', rows), '#REF!');
      expect(calc('=SUM(A1:Z9)', rows), '#REF!');
    });
  });

  group('errors', () {
    test('propagate through operators and functions, first one wins', () {
      final rows = [
        ['=1/0', '=A1+1', '=#REF!', 'x'],
      ];
      expect(calc('=A1', rows), '#DIV/0!');
      expect(calc('=B1', rows), '#DIV/0!');
      expect(calc('=SUM(A1:B1)', rows), '#DIV/0!');
      expect(calc('=MAX(A1,1)', rows), '#DIV/0!');
      expect(calc('=SUM(C1,A1)', rows), '#REF!');
      expect(calc('=SUM(A1,C1)', rows), '#DIV/0!');
      expect(calc('=D1*2+A1', rows), '#VALUE!');
      expect(calc('="a"&A1', rows), '#DIV/0!');
      expect(calc('=A1=1', rows), '#DIV/0!');
      expect(calc('=ROUND(A1,2)', rows), '#DIV/0!');
      expect(calc('=ABS(A1)', rows), '#DIV/0!');
      expect(calc('=-A1', rows), '#DIV/0!');
      expect(calc('=A1%', rows), '#DIV/0!');
      expect(calc('=IF(A1,1,2)', rows), '#DIV/0!');
    });

    test('references outside the table are #REF!', () {
      final rows = [
        ['1', '2'],
        ['3', '4'],
      ];
      expect(calc('=C1', rows), '#REF!');
      expect(calc('=A9', rows), '#REF!');
      expect(calc('=SUM(A1:C1)', rows), '#REF!');
      expect(calc('=A1+Z99', rows), '#REF!');
    });

    test('a direct cycle is #CYCLE! in every cell on it', () {
      final s = sheet([
        ['=B1', '=A1', '3'],
      ]);
      expect(s.displayAt(0, 0), '#CYCLE!');
      expect(s.displayAt(0, 1), '#CYCLE!');
      expect(s.displayAt(0, 2), '3');
    });

    test('indirect cycles and what depends on them', () {
      final s = sheet([
        ['=B1', '=C1', '=A1', '=A1+10', '5'],
        ['=A2+1', '=B2', '=SUM(A2:B2)', '=IF(TRUE,1,A3)', '=E1+1'],
      ]);
      // A1 -> B1 -> C1 -> A1.
      for (var c = 0; c < 3; c++) {
        expect(s.displayAt(0, c), '#CYCLE!');
      }
      expect(s.displayAt(0, 3), '#CYCLE!', reason: 'depends on the cycle');
      expect(s.displayAt(0, 4), '5');
      // A2 refers to itself; B2 to itself; C2 sums both.
      expect(s.displayAt(1, 0), '#CYCLE!');
      expect(s.displayAt(1, 1), '#CYCLE!');
      expect(s.displayAt(1, 2), '#CYCLE!');
      expect(s.displayAt(1, 3), '1');
      expect(s.displayAt(1, 4), '6');
    });

    test('a cycle does not poison cells that merely sit next to it', () {
      final s = sheet([
        ['=B1', '=A1', '=1+1'],
      ]);
      expect(s.displayAt(0, 0), '#CYCLE!');
      expect(s.displayAt(0, 2), '2');
    });

    test('a self reference', () {
      expect(
        sheet([
          ['=A1+1'],
        ]).displayAt(0, 0),
        '#CYCLE!',
      );
      expect(
        sheet([
          ['=SUM(A1:B1)', '2'],
        ]).displayAt(0, 0),
        '#CYCLE!',
      );
    });

    test('a very long dependency chain does not crash', () {
      final rows = [
        for (var i = 0; i < 3000; i++) [i == 0 ? '1' : '=A$i+1'],
      ];
      final s = sheet(rows);
      // Either computed or reported; never an exception.
      expect(s.displayAt(2999, 0), anyOf('3000', '#ERROR!'));
    });

    test('error codes round trip', () {
      for (final e in FormulaError.values) {
        expect(FormulaError.fromCode(e.code), e);
        expect(formatFormulaValue(e), e.code);
      }
      expect(FormulaError.fromCode('#N/A'), isNull);
    });
  });

  group('recalculation', () {
    test('a formula sees the current text of other cells', () {
      var b = '2';
      final s1 = FormulaSheet(
        rows: 1,
        cols: 3,
        textAt: (r, c) => ['=B1*10', b, '=A1+1'][c],
      );
      expect(s1.displayAt(0, 0), '20');
      expect(s1.displayAt(0, 2), '21');
      b = '5';
      // A new sheet is a new calculation; nothing is cached across them.
      final s2 = FormulaSheet(
        rows: 1,
        cols: 3,
        textAt: (r, c) => ['=B1*10', b, '=A1+1'][c],
      );
      expect(s2.displayAt(0, 0), '50');
      expect(s2.displayAt(0, 2), '51');
    });

    test('dependencies are evaluated first, each cell once', () {
      final reads = <String>[];
      final texts = {'0,0': '=B1+C1', '0,1': '=C1*2', '0,2': '3'};
      final s = FormulaSheet(
        rows: 1,
        cols: 3,
        textAt: (r, c) {
          reads.add('$r,$c');
          return texts['$r,$c']!;
        },
      );
      expect(s.displayAt(0, 0), '9');
      expect(s.displayAt(0, 1), '6');
      expect(s.displayAt(0, 2), '3');
      expect(reads.where((e) => e == '0,2').length, 1);
      expect(reads.where((e) => e == '0,1').length, 1);
    });

    test('formulas may refer to cells later in the sheet', () {
      final s = sheet([
        ['=A2+1', '=B2'],
        ['5', '7'],
      ]);
      expect(s.displayAt(0, 0), '6');
      expect(s.displayAt(0, 1), '7');
    });

    test('booleans and text in cells', () {
      final rows = [
        ['TRUE', 'hello', '1e2'],
      ];
      expect(calc('=A1', rows), 'TRUE');
      expect(calc('=B1', rows), 'hello');
      expect(calc('=C1', rows), '100');
      expect(calc('=B1&"!"', rows), 'hello!');
    });
  });

  group('number formatting', () {
    test('integers, decimals, small and large', () {
      expect(formatFormulaNumber(3), '3');
      expect(formatFormulaNumber(-0.0), '0');
      expect(formatFormulaNumber(2.50), '2.5');
      expect(formatFormulaNumber(0.1 + 0.2), '0.3');
      expect(formatFormulaNumber(1e15), '1000000000000000');
      expect(formatFormulaNumber(123456789012345), '123456789012345');
      expect(formatFormulaNumber(double.infinity), '#NUM!');
      expect(formatFormulaValue(null), '');
      expect(formatFormulaValue(true), 'TRUE');
      expect(formatFormulaValue('t'), 't');
    });

    test('number text', () {
      expect(parseNumberText('12'), 12);
      expect(parseNumberText(' -1.5 '), -1.5);
      expect(parseNumberText('.5'), 0.5);
      expect(parseNumberText('1e3'), 1000);
      expect(parseNumberText('5.'), 5);
      expect(parseNumberText('NaN'), isNull);
      expect(parseNumberText('Infinity'), isNull);
      expect(parseNumberText('0x10'), isNull);
      expect(parseNumberText('1,5'), isNull);
      expect(parseNumberText(''), isNull);
      expect(parseNumberText('-'), isNull);
    });
  });

  group('reference adjustment', () {
    String adj(String f, TableEdit e) => adjustFormula(f, e);

    test('insert row: references at or after the new row move', () {
      expect(adj('=A1+A2+A3', const InsertRow(1)), '=A1+A3+A4');
      expect(adj('=A1', const InsertRow(0)), '=A2');
      expect(adj('=B5', const InsertRow(5)), '=B5');
      expect(adj('=B5', const InsertRow(4)), '=B6');
      expect(adj('=A1', const InsertRow(3)), '=A1');
    });

    test('insert row: ranges shrink, grow or stay', () {
      // Before the range, inside it, at its first row, after it.
      expect(adj('=SUM(A2:A4)', const InsertRow(0)), '=SUM(A3:A5)');
      expect(adj('=SUM(A2:A4)', const InsertRow(1)), '=SUM(A3:A5)');
      expect(adj('=SUM(A2:A4)', const InsertRow(2)), '=SUM(A2:A5)');
      expect(adj('=SUM(A2:A4)', const InsertRow(3)), '=SUM(A2:A5)');
      expect(adj('=SUM(A2:A4)', const InsertRow(4)), '=SUM(A2:A4)');
      expect(adj('=SUM(A2:A4)', const InsertRow(9)), '=SUM(A2:A4)');
    });

    test('insert column', () {
      expect(adj('=A1+B1+C1', const InsertColumn(1)), '=A1+C1+D1');
      expect(adj('=SUM(A1:C1)', const InsertColumn(1)), '=SUM(A1:D1)');
      expect(adj('=SUM(B1:C1)', const InsertColumn(0)), '=SUM(C1:D1)');
      expect(adj('=Z1', const InsertColumn(0)), '=AA1');
      expect(adj('=A5', const InsertColumn(3)), '=A5');
      // A row insert leaves columns alone.
      expect(adj('=C3', const InsertColumn(0)), '=D3');
    });

    test('delete row: references to it are #REF!, later ones move back', () {
      expect(adj('=A1+A2+A3', const DeleteRow(1)), '=A1+#REF!+A2');
      expect(adj('=A1', const DeleteRow(0)), '=#REF!');
      expect(adj('=A3*2', const DeleteRow(0)), '=A2*2');
      expect(adj('=A1', const DeleteRow(5)), '=A1');
    });

    test('delete row: ranges shrink; all of it gone is #REF!', () {
      expect(adj('=SUM(A2:A5)', const DeleteRow(0)), '=SUM(A1:A4)');
      expect(adj('=SUM(A2:A5)', const DeleteRow(1)), '=SUM(A2:A4)');
      expect(adj('=SUM(A2:A5)', const DeleteRow(2)), '=SUM(A2:A4)');
      expect(adj('=SUM(A2:A5)', const DeleteRow(4)), '=SUM(A2:A4)');
      expect(adj('=SUM(A2:A5)', const DeleteRow(5)), '=SUM(A2:A5)');
      expect(adj('=SUM(A2:A3)', const DeleteRow(2)), '=SUM(A2:A2)');
      expect(adj('=SUM(A2:A2)', const DeleteRow(1)), '=SUM(#REF!)');
      expect(adj('=SUM(A2:B2)+1', const DeleteRow(1)), '=SUM(#REF!)+1');
    });

    test('delete column', () {
      expect(adj('=A1+B1+C1', const DeleteColumn(1)), '=A1+#REF!+B1');
      expect(adj('=SUM(A1:C1)', const DeleteColumn(1)), '=SUM(A1:B1)');
      expect(adj('=SUM(B1:B3)', const DeleteColumn(1)), '=SUM(#REF!)');
      expect(adj('=AA1', const DeleteColumn(0)), '=Z1');
    });

    test('absolute markers, case, spacing and strings are kept', () {
      expect(adj(r'= $A$2 +  b3', const InsertRow(1)), r'= $A$3 +  B4');
      expect(adj(r'=SUM($A1:$A$3)', const InsertRow(1)), r'=SUM($A1:$A$4)');
      expect(adj('=sum(a1:a3)', const InsertRow(0)), '=sum(A2:A4)');
      expect(adj('="A1"&A1', const InsertRow(0)), '="A1"&A2');
      expect(adj('=A1&"x"', const DeleteRow(0)), '=#REF!&"x"');
    });

    test('references inside nested calls and operators', () {
      expect(
        adj('=IF(A1>A2,SUM(A1:A3),-A3%)', const InsertRow(1)),
        '=IF(A1>A3,SUM(A1:A4),-A4%)',
      );
    });

    test('a reversed range keeps its corners', () {
      expect(adj('=SUM(A4:A2)', const InsertRow(2)), '=SUM(A5:A2)');
      expect(adj('=SUM(C1:A1)', const InsertColumn(1)), '=SUM(D1:A1)');
    });

    test('text that is not a formula or does not parse is unchanged', () {
      expect(adj('A1', const InsertRow(0)), 'A1');
      expect(adj('=A1+', const InsertRow(0)), '=A1+');
      expect(adj('=1+2', const InsertRow(0)), '=1+2');
      expect(adj('', const InsertRow(0)), '');
    });

    test('an adjusted formula still evaluates the same cells', () {
      // Insert a row between the data and the total.
      final before = [
        ['1'],
        ['2'],
        ['=SUM(A1:A2)'],
      ];
      expect(sheet(before).displayAt(2, 0), '3');
      final after = [
        ['1'],
        ['2'],
        [''],
        [adjustFormula('=SUM(A1:A2)', const InsertRow(2))],
      ];
      expect(sheet(after).displayAt(3, 0), '3');
      // Insert inside the data: the sum covers the new row too.
      final inside = [
        ['1'],
        ['10'],
        ['2'],
        [adjustFormula('=SUM(A1:A2)', const InsertRow(1))],
      ];
      expect(sheet(inside).displayAt(3, 0), '13');
      // Delete a row the sum depends on.
      final del = [
        ['1'],
        [adjustFormula('=SUM(A1:A2)+A2', const DeleteRow(1))],
      ];
      expect(sheet(del).displayAt(1, 0), '#REF!');
    });
  });

  test('the formula files import neither Flutter nor appflowy_editor', () {
    final dir = [
      Directory('lib/src/formula'),
      Directory('packages/boxes/note/lib/src/formula'),
    ].firstWhere((d) => d.existsSync());
    final files = dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.dart'),
    );
    expect(files, isNotEmpty);
    for (final f in files) {
      final imports = f.readAsLinesSync().where(
        (l) => l.startsWith('import ') || l.startsWith('export '),
      );
      expect(imports, everyElement(isNot(contains('flutter'))), reason: f.path);
      expect(
        imports,
        everyElement(isNot(contains('appflowy'))),
        reason: f.path,
      );
    }
  });
}
