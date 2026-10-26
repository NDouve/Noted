// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/src/math_input.dart';
import 'package:noted_core/noted_core.dart';

import '../support/harness.dart';
import '../support/note_helpers.dart';

Future<bool> _run(dynamic shortcut, dynamic editor) async => await shortcut.execute(editor) as bool;

Finder _byType(String name) => find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

Finder get _math => _byType('Math');

dynamic _lastSelection;

void _setCaret(dynamic editor, List<int> path, int offset) {
  // The editor has no selection after some updates; reuse the last one as a
  // template (Selection and Position types are not visible to the app).
  final sel = editor.selection ?? _lastSelection;
  _lastSelection = sel;
  final pos = sel.start.copyWith(path: path, offset: offset);
  editor.selection = sel.copyWith(start: pos, end: pos);
}

String _state(dynamic e) {
  Object? strip(Object? v) {
    if (v is Map) {
      return {
        for (final entry in v.entries)
          if (!const {'height', 'width', 'colsHeight'}.contains(entry.key)) entry.key: strip(entry.value),
      };
    }
    if (v is List) return [for (final x in v) strip(x)];
    return v;
  }

  return jsonEncode(strip(e.document.toJson()));
}

/// A page with one note box holding [children]; returns the box id.
Future<String> _openWith(Session s, List<Map<String, Object?>> children) async {
  final id = addNote(s, children);
  await s.pump(400);
  return id;
}

/// Opens the handle menu of a table row or column and picks [label].
Future<void> _tableMenu(Session s, dynamic editor, String dir, int index, String label) async {
  final t = s.tester;
  final c = cell(editor, dir == 'row' ? index : 0, dir == 'col' ? index : 0);
  final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  final center = t.getCenter(find.byKey(c.key as Key));
  await mouse.moveTo(center + const Offset(5, 0));
  await s.pump(200);
  await mouse.moveTo(center);
  await s.pump(500);
  if (find.byKey(ValueKey('table-handle-$dir-$index')).evaluate().isEmpty) {
    final keys = find
        .byWidgetPredicate((w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('table-handle'))
        .evaluate()
        .map((e) => e.widget.key)
        .toList();
    fail('no handle $dir-$index; present: $keys; mouse at $center');
  }
  await t.tap(find.byKey(ValueKey('table-handle-$dir-$index')));
  await s.pump(500);
  await t.tap(find.text(label).last);
  await s.pump(900);
  await mouse.removePointer();
}

/// Checklist steps 31-55, 119-121, 124-127, 131-138, 143-145 and the
/// equation steps (notes, tables, formulas).
void notesSuite() {
  group('notes, tables, formulas, equations', () {
    testWidgets('step 031-034: the / menu inserts a 2x2 table; the note grows; headers show only while the table is focused', (t) async {
      await withSession(t, 'table', (s) async {
        await clickNewNote(s);
        final id = s.nb.current!.editingId!;
        final before = s.nb.current!.page.node(id)!.bounds!.height;
        var editor = editorState(t);
        unawaited(_run(noteSlashCommand, editor));
        await s.pump(300);
        final item = find.descendant(of: _byType('SelectionMenuWidget'), matching: find.text('Table'));
        await t.scrollUntilVisible(item, 60, scrollable: find.descendant(of: _byType('SelectionMenuWidget'), matching: find.byType(Scrollable)).last, duration: const Duration(milliseconds: 50));
        await t.ensureVisible(item);
        await s.pump(100);
        await t.tap(item.first);
        await s.pump(600);
        editor = editorState(t);
        expect(editor.document.root.children.first.type, 'table');
        expect(editor.document.root.children.first.attributes['rowsLen'], 2);
        expect(editor.document.root.children.first.attributes['colsLen'], 2);
        expect(s.nb.current!.page.node(id)!.bounds!.height, greaterThan(before + 60));
        // 032: typing in a cell.
        await setCellText(s, editor, 0, 0, 'hello');
        expect(snapshotOf(s, id), contains('hello'));
        // 033: headers while focused.
        await tapCell(s, editor, 1, 1);
        expect(find.byKey(const ValueKey('col-header-A')), findsOneWidget);
        expect(find.byKey(const ValueKey('row-header-1')), findsOneWidget);
        // 034: clicking outside the table hides them.
        await t.tapAt(toScreen(t, const Offset(900, 600)));
        await s.pump(500);
        expect(find.byKey(const ValueKey('col-header-A')), findsNothing);
        expect(find.byKey(const ValueKey('row-header-1')), findsNothing);
      });
    });

    testWidgets(r'step 035-036: "$$ " opens the equation dialog with a live preview; Done puts it in the note', (t) async {
      await withSession(t, 'blockmath', (s) async {
        final id = await _openWith(s, [para(r'$$')]);
        final editor = await editNote(s, id);
        _setCaret(editor, [0], 2);
        expect(await _run(blockMathShortcut, editor), isTrue);
        await s.pump(500);
        expect(find.byKey(const ValueKey('math-source')), findsOneWidget);
        await t.enterText(find.byKey(const ValueKey('math-source')), r'\frac{a}{b}');
        await s.pump(300);
        expect(_math, findsOneWidget, reason: 'live preview');
        await t.tap(find.text('Done'));
        await s.pump(600);
        expect(editorState(t).document.root.children.first.type, 'math_equation');
        expect(editorState(t).document.root.children.first.attributes['formula'], r'\frac{a}{b}');
        expect(_math, findsOneWidget);
        expect(snapshotOf(s, id), startsWith(r'$$\frac{a}{b}$$'));
      });
    });

    testWidgets(r'step 037-040: inline $x^2$ renders; prices stay plain; tapping reopens; invalid LaTeX shows a placeholder', (t) async {
      await withSession(t, 'inlinemath', (s) async {
        final id = await _openWith(s, [para(r'see $x^2')]);
        final editor = await editNote(s, id);
        _setCaret(editor, [0], 8);
        expect(await _run(inlineMathShortcut, editor), isTrue); // 037
        await s.pump(400);
        expect(_math, findsOneWidget);
        expect(snapshotOf(s, id), r'see $x^2$');
        // 038: "$5 and $10" is left alone.
        final node = editor.getNodeAtPath([0]);
        await insertTextAt(editor, node, 5, r' $5 and ');
        _setCaret(editor, [0], node.delta.length as int);
        expect(await _run(inlineMathShortcut, editor), isFalse);
        // 039: tapping the rendered equation opens the dialog with its formula.
        await t.tap(_math.first);
        await s.pump(500);
        expect(find.byKey(const ValueKey('math-source')), findsOneWidget);
        expect(t.widget<TextField>(find.byKey(const ValueKey('math-source'))).controller!.text, 'x^2');
        // 040: invalid LaTeX does not crash.
        await t.enterText(find.byKey(const ValueKey('math-source')), r'\frac{');
        await s.pump(300);
        await t.tap(find.text('Done'));
        await s.pump(600);
        expect(_byType('MathErrorPlaceholder'), findsWidgets);
        expect(t.takeException(), isNull);
      });
    });

    testWidgets('step 041-042: equations inside table cells', (t) async {
      await withSession(t, 'cellmath', (s) async {
        final id = await _openWith(s, [
          table([
            [r'$$', r'b $y_1'],
          ]),
        ]);
        final editor = await editNote(s, id);
        final p0 = cell(editor, 0, 0).children.first;
        await tapCell(s, editor, 0, 0);
        _setCaret(editor, p0.path as List<int>, 2);
        expect(await _run(blockMathShortcut, editor), isTrue);
        await s.pump(500);
        expect(find.byKey(const ValueKey('math-source')), findsOneWidget);
        await t.enterText(find.byKey(const ValueKey('math-source')), r'\frac{a}{b}');
        await t.tap(find.text('Done'));
        await s.pump(600);
        expect(_math, findsWidgets);
        expect(cell(editorState(t), 0, 0).children.first.type, 'math_equation');
        // 042: inline in a cell that has text.
        final ed = editorState(t);
        final p1 = cell(ed, 0, 1).children.first;
        await tapCell(s, ed, 0, 1);
        _setCaret(ed, p1.path as List<int>, 6);
        expect(await _run(inlineMathShortcut, ed), isTrue);
        await s.pump(500);
        expect(_math, findsNWidgets(2));
        expect(t.takeException(), isNull);
      });
    });

    testWidgets('step 043-045: a formula cell shows its result, its text when clicked, and follows edits', (t) async {
      await withSession(t, 'formula1', (s) async {
        final id = await _openWith(s, [
          table([
            ['', '', ''],
            ['', '', ''],
          ]),
        ]);
        final editor = await editNote(s, id);
        await setCellText(s, editor, 0, 0, '2');
        await setCellText(s, editor, 0, 1, '3');
        await setCellText(s, editor, 0, 2, '=A1+B1');
        await tapCell(s, editor, 1, 0); // click away
        expect(cellValue(editorState(t), 0, 2), '5');
        expect(t.widget<Text>(formulaShown.first).data, '5');
        // 044: clicking the cell shows the formula text.
        await t.tap(formulaShown.first);
        await s.pump(300);
        expect(find.text('=A1+B1', findRichText: true), findsOneWidget);
        // 045: changing A1 recomputes.
        await setCellText(s, editorState(t), 0, 0, '10');
        await tapCell(s, editorState(t), 1, 0);
        expect(cellValue(editorState(t), 0, 2), '13');
        expect(snapshotOf(s, id), contains('13'));
      });
    });

    testWidgets('step 046-052: functions, errors, cycles and right-associative power', (t) async {
      await withSession(t, 'formula2', (s) async {
        final cases = <(String, String)>[
          ('=SUM(A1:B1)', '13'),
          ('=AVERAGE(A1:B1)', '6.5'),
          ('=MAX(A1:B1)', '10'),
          ('=ROUND(2.567,1)', '2.6'),
          ('=IF(A1>5,"big","small")', 'big'),
          ('=A1/0', '#DIV/0!'),
          ('=FOO(1)', '#NAME?'),
          ('=Z99', '#REF!'),
          ('=2^3^2', '64'),
        ];
        final rows = <List<String>>[
          ['10', '3'],
          for (final c in cases) [c.$1, ''],
          ['=B11', '=A11'],
        ];
        // A cycle: A11 = B11 and B11 = A11 (rows are 1-based in formulas).
        final id = await _openWith(s, [table(rows)]);
        final editor = await editNote(s, id);
        for (var i = 0; i < cases.length; i++) {
          final v = cellValue(editor, i + 1, 0);
          expect(v, cases[i].$2, reason: 'formula ${cases[i].$1}');
        }
        // 051: both cells of a cycle show #CYCLE!.
        expect(cellValue(editor, cases.length + 1, 0), '#CYCLE!');
        expect(cellValue(editor, cases.length + 1, 1), '#CYCLE!');
        // 048: the error text is shown in red.
        final texts = t.widgetList<Text>(formulaShown).where((w) => w.data == '#DIV/0!').toList();
        expect(texts, hasLength(1));
        final color = texts.single.style!.color!;
        expect(color.r, greaterThan(color.g * 1.5), reason: 'error text is reddish: $color');
        expect(color.r, greaterThan(color.b * 1.5));
        expect(t.takeException(), isNull);
      });
    });

    testWidgets('step 053-055: insert row, delete column and undo keep formulas right', (t) async {
      await withSession(t, 'formula3', (s) async {
        final id = await _openWith(s, [
          table([
            ['1', '=A1*2'],
            ['2', '=A2*2'],
            ['3', '=SUM(B1:B2)'],
          ]),
        ]);
        var editor = await editNote(s, id);
        await _tableMenu(s, editor, 'row', 0, 'Add before'); // 053
        editor = editorState(t);
        expect(cellText(editor, 1, 1), '=A2*2');
        expect(cellText(editor, 3, 1), '=SUM(B2:B3)');
        expect([for (var r = 1; r < 4; r++) cellValue(editor, r, 1)], ['2', '4', '6']);
        // Undo the insert so the table is back to the start.
        await tapCell(s, editor, 1, 0);
        await s.ctrl(LogicalKeyboardKey.keyZ);
        editor = editorState(t);
        expect(cellText(editor, 0, 1), '=A1*2');
        // 054: delete column A: formulas that used it show #REF!.
        await _tableMenu(s, editor, 'col', 0, 'Remove');
        editor = editorState(t);
        expect(cellValue(editor, 0, 0), '#REF!');
        // 055: Ctrl+Z brings the column and formula back.
        await tapCell(s, editor, 0, 0);
        await s.ctrl(LogicalKeyboardKey.keyZ);
        editor = editorState(t);
        expect(cellText(editor, 0, 0), '1');
        expect(cellText(editor, 0, 1), '=A1*2');
        expect(cellValue(editor, 0, 1), '2');
      });
    });

    testWidgets('step 119-120, 124-127: duplicating a row or column shifts relative references only; hand-typed formulas stay; insert leaves the new row empty', (t) async {
      await withSession(t, 'duplicate', (s) async {
        final id = await _openWith(s, [
          table([
            ['1', '2', r'=A1+$B$1'],
            ['', '', ''],
          ]),
        ]);
        var editor = await editNote(s, id);
        await _tableMenu(s, editor, 'row', 0, 'Duplicate');
        editor = editorState(t);
        expect(cellText(editor, 1, 2), r'=A2+$B$1');
        expect(cellValue(editor, 1, 2), '3'); // A2 (1) + $B$1 (2)
        // 126: a formula typed by hand into the next row is not shifted.
        await setCellText(s, editor, 2, 2, r'=A1+$B$1');
        expect(cellText(editorState(t), 2, 2), r'=A1+$B$1');
        // 127: inserting an empty row leaves it empty.
        await _tableMenu(s, editorState(t), 'row', 2, 'Add after');
        editor = editorState(t);
        expect(cellText(editor, 3, 0), '');
        expect(cellText(editor, 3, 2), '');
      });
    });

    testWidgets('step 120, 125: duplicating a column shifts column parts only', (t) async {
      await withSession(t, 'dupcol', (s) async {
        final id = await _openWith(s, [
          table([
            ['1', '2', r'=A1+B$1'],
          ]),
        ]);
        var editor = await editNote(s, id);
        await _tableMenu(s, editor, 'col', 2, 'Duplicate');
        editor = editorState(t);
        // The copy is column D; its formula shifts one column right.
        expect(cellText(editor, 0, 3), r'=B1+C$1');
      });
    });

    testWidgets('step 131-134, 136, 138: one Ctrl+Z undoes exactly one table change; Ctrl+Y redoes', (t) async {
      await withSession(t, 'tableundo', (s) async {
        final id = await _openWith(s, [
          table([
            ['1', '=A1*2'],
            ['2', '=A2*2'],
            ['3', '=SUM(B1:B2)'],
          ]),
        ]);
        var editor = await editNote(s, id);

        Future<void> oneStep(String name, Future<void> Function() change) async {
          editor = editorState(t);
          final before = _state(editor);
          await change();
          await s.pump(400);
          editor = editorState(t);
          final after = _state(editor);
          expect(after, isNot(before), reason: '$name did something');
          await tapCell(s, editor, 0, 0);
          await s.ctrl(LogicalKeyboardKey.keyZ);
          expect(_state(editorState(t)), before, reason: '$name: one undo');
          await s.ctrl(LogicalKeyboardKey.keyY);
          expect(_state(editorState(t)), after, reason: '$name: redo');
          await s.ctrl(LogicalKeyboardKey.keyZ);
          expect(_state(editorState(t)), before, reason: '$name: undo again');
        }

        await oneStep('typing a word', () async {
          final p = cell(editor, 0, 0).children.first;
          await insertTextAt(editor, p, 1, 'word');
        });
        await oneStep('insert row', () => _tableMenu(s, editor, 'row', 1, 'Add before'));
        await oneStep('delete row', () => _tableMenu(s, editor, 'row', 1, 'Remove'));
        await oneStep('duplicate row', () => _tableMenu(s, editor, 'row', 0, 'Duplicate'));
        await oneStep('clear row', () => _tableMenu(s, editor, 'row', 0, 'Clear Content'));
        await oneStep('row background', () => _tableMenu(s, editor, 'row', 1, 'Alert'));
        expect(t.takeException(), isNull);
      });
    });

    testWidgets('step 143-145: column colors are stored as roles, so they follow the theme and are not rewritten', (t) async {
      await withSession(t, 'fills', (s) async {
        final id = await _openWith(s, [
          table([
            ['a', 'b'],
            ['c', 'd'],
          ]),
        ]);
        var editor = await editNote(s, id);
        await _tableMenu(s, editor, 'col', 0, 'Accent');
        editor = editorState(t);
        await _tableMenu(s, editor, 'col', 1, 'Alert');
        editor = editorState(t);
        expect(cell(editor, 0, 0).attributes['colBackgroundColor'], 'role:accent');
        expect(cell(editor, 1, 1).attributes['colBackgroundColor'], 'role:alert');
        await s.flush();
        final stored = (s.nb.current!.page.node(id)! as BoxRecord).data.toString();
        expect(stored, contains('role:accent'));
        // Switch to dark: the stored roles are unchanged.
        await s.tapKey('settings-menu', settle: 500);
        await s.tapKey('theme-dark', settle: 800);
        await s.flush();
        expect(Theme.of(t.element(find.byType(Scaffold).first)).brightness, Brightness.dark);
        final after = (s.nb.current!.page.node(id)! as BoxRecord).data.toString();
        expect(after, stored);
        expect(t.takeException(), isNull);
      });
    });
  });
}
