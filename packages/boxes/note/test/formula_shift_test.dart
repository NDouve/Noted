// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/src/formula/formula.dart';

void main() {
  String sh(String f, int dr, int dc) => shiftFormula(f, dr, dc);

  group('shiftFormula', () {
    test('relative references move', () {
      expect(sh('=A1+B2', 1, 0), '=A2+B3');
      expect(sh('=A1+B2', 0, 1), '=B1+C2');
      expect(sh('=A1+B2', 2, 3), '=D3+E4');
      expect(sh('=A5', -2, 0), '=A3');
      expect(sh('=C3', -2, -2), '=A1');
    });

    test('dollar anchors hold their part', () {
      expect(sh(r'=$A$1', 3, 3), r'=$A$1');
      expect(sh(r'=$A1', 3, 3), r'=$A4');
      expect(sh(r'=A$1', 3, 3), r'=D$1');
      expect(sh(r'=A1+$B$1', 1, 0), r'=A2+$B$1');
      expect(sh(r'=A1+$B$1', 0, 1), r'=B1+$B$1');
    });

    test('ranges shift each end on its own', () {
      expect(sh('=SUM(A1:B3)', 1, 1), '=SUM(B2:C4)');
      expect(sh(r'=SUM(A1:$B$3)', 1, 1), r'=SUM(B2:$B$3)');
      expect(sh(r'=SUM($A1:B$2)', 2, 2), r'=SUM($A3:D$2)');
      expect(sh(r'=SUM($A$1:$B$3)', 5, 5), r'=SUM($A$1:$B$3)');
    });

    test('off the sheet is #REF!', () {
      expect(sh('=A1', -1, 0), '=#REF!');
      expect(sh('=A1', 0, -1), '=#REF!');
      expect(sh('=A1+B2', -1, 0), '=#REF!+B1');
      expect(sh('=SUM(A1:B3)', -1, 0), '=SUM(#REF!)');
      expect(sh('=SUM(B2:C3)', -1, -1), '=SUM(A1:B2)');
      expect(sh('=SUM(B2:C3)', -2, 0), '=SUM(#REF!)');
      expect(sh(r'=A$1', -5, 0), r'=A$1');
      expect(sh(r'=$A1', 0, -5), r'=$A1');
      expect(sh(r'=$A1', -1, 0), '=#REF!');
      expect(sh('=B2', -1, -2), '=#REF!');
    });

    test('multi-letter columns', () {
      expect(sh('=Z1', 0, 1), '=AA1');
      expect(sh('=AA10', 1, -1), '=Z11');
      expect(sh('=AZ1+BA1', 0, 1), '=BA1+BB1');
    });

    test('nested functions and operators', () {
      expect(
        sh(r'=IF(A1>$B$1,SUM(A1:A3)*2,-C1%)', 1, 1),
        r'=IF(B2>$B$1,SUM(B2:B4)*2,-D2%)',
      );
      expect(sh('=ROUND(SUM(A1,B1),2)', 1, 0), '=ROUND(SUM(A2,B2),2)');
    });

    test('strings, numbers and error literals stay', () {
      expect(sh('="A1"&A1', 1, 0), '="A1"&A2');
      expect(sh('="say ""B2"""', 1, 1), '="say ""B2"""');
      expect(sh('=#DIV/0!+A1', 1, 0), '=#DIV/0!+A2');
      expect(sh('=1.5e3+A1', 1, 0), '=1.5e3+A2');
    });

    test('spacing and case stay', () {
      expect(sh('= sum( a1 , B2 ) + 1', 1, 1), '= sum( b2 , C3 ) + 1');
      expect(sh('=SUM( A1 : B2 )', 1, 0), '=SUM( A2 : B3 )');
      expect(sh('=sum(a1:b2)', 0, 1), '=sum(b1:c2)');
    });

    test('zero offset, non-formulas and broken formulas are unchanged', () {
      expect(sh('=A1', 0, 0), '=A1');
      expect(sh('A1', 1, 1), 'A1');
      expect(sh('hello', 1, 1), 'hello');
      expect(sh('', 1, 1), '');
      expect(sh('=A1+', 1, 1), '=A1+');
      expect(sh('=SUM(', 1, 1), '=SUM(');
    });

    test('shifted formulas evaluate', () {
      final rows = [
        ['1', '2'],
        ['10', '20'],
        [sh(r'=A1+$B$1', 1, 0), ''],
      ];
      final s = FormulaSheet(rows: 3, cols: 2, textAt: (r, c) => rows[r][c]);
      expect(rows[2][0], r'=A2+$B$1');
      expect(s.displayAt(2, 0), '12');
    });
  });

  group('dollar anchors', () {
    test('parse and evaluate as normal references', () {
      final rows = [
        ['5', '7'],
        [r'=$A$1+B$1+$A1', ''],
      ];
      final s = FormulaSheet(rows: 2, cols: 2, textAt: (r, c) => rows[r][c]);
      expect(s.displayAt(1, 0), '17');
      final tree = parseFormula(r'=$A1+B$2') as BinaryExpr;
      final l = tree.left as RefExpr;
      final r = tree.right as RefExpr;
      expect(l.ref.absoluteCol, isTrue);
      expect(l.ref.absoluteRow, isFalse);
      expect(r.ref.absoluteCol, isFalse);
      expect(r.ref.absoluteRow, isTrue);
    });

    test('insert and delete adjustment keep the markers', () {
      expect(adjustFormula(r'=$A$2+B$3', const InsertRow(0)), r'=$A$3+B$4');
      expect(adjustFormula(r'=$A2+$B$3', const InsertColumn(1)), r'=$A2+$C$3');
      expect(
        adjustFormula(r'=SUM($A$1:$A$4)', const InsertRow(2)),
        r'=SUM($A$1:$A$5)',
      );
      expect(adjustFormula(r'=$A$3+A$4', const DeleteRow(0)), r'=$A$2+A$3');
      expect(
        adjustFormula(r'=$B$1+$A1', const DeleteColumn(0)),
        r'=$A$1+#REF!',
      );
    });
  });
}
