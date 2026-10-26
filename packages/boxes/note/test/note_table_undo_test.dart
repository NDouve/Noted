// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:ui' show PointerDeviceKind;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

const _codec = NoteCodec();

Map<String, Object?> _para(String text) => {
  'type': 'paragraph',
  'data': {
    'delta': [
      if (text.isNotEmpty) {'insert': text},
    ],
  },
};

Map<String, Object?> _table(List<List<String>> rows) {
  final cols = rows.first.length;
  return {
    'type': 'table',
    'data': {
      'colsLen': cols,
      'rowsLen': rows.length,
      'colDefaultWidth': 80.0,
      'rowDefaultHeight': 40.0,
      'colMinimumWidth': 40.0,
      'borderWidth': 2.0,
    },
    'children': [
      for (var c = 0; c < cols; c++)
        for (var r = 0; r < rows.length; r++)
          {
            'type': 'table/cell',
            'data': {'colPosition': c, 'rowPosition': r},
            'children': [_para(rows[r][c])],
          },
    ],
  };
}

/// A 3 x 2 table: numbers in column A, formulas in column B.
NoteData _sample() => NoteData({
  'document': {
    'type': 'page',
    'children': [
      _table([
        ['1', '=A1*2'],
        ['2', '=A2*2'],
        ['3', '=SUM(B1:B2)'],
      ]),
    ],
  },
});

Node _cell(EditorState e, int row, int col) =>
    e.document.root.children.first.children.firstWhere(
      (n) =>
          n.attributes['rowPosition'] == row &&
          n.attributes['colPosition'] == col,
    );

/// The document as JSON without what the table measures about itself.
String _state(EditorState e) {
  Object? strip(Object? v) {
    if (v is Map) {
      return {
        for (final entry in v.entries)
          if (!(const {'height', 'width', 'colsHeight'}).contains(entry.key))
            entry.key: strip(entry.value),
      };
    }
    if (v is List) return [for (final x in v) strip(x)];
    return v;
  }

  return jsonEncode(strip(e.document.toJson()));
}

void main() {
  late ModuleRegistry modules;

  setUp(() {
    modules = ModuleRegistry()
      ..register(const NoteModule(), alwaysOn: true, isDefault: true);
  });

  Future<void> frames(WidgetTester t, [int n = 6]) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<EditorState> open(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final data = _sample();
    var p = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
    p = p.insertNode(
      BoxRecord.create(
        id: 'n',
        typeId: NoteCodec.id,
        dataVersion: 1,
        bounds: Bounds(100, 100, 400, 40),
        data: RawJson.encode(_codec.encode(data)),
        snapshotText: _codec.snapshotText(data),
        rev: 'r',
      ),
    );
    final c = CanvasController(p, modules);
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: noteLocalizationsDelegates,
        home: Scaffold(body: PageCanvas(controller: c)),
      ),
    );
    await t.pumpAndSettle();
    final canvas = t.state<PageCanvasState>(find.byType(PageCanvas));
    final b = c.page.node('n')!.bounds!;
    // The canvas sits below the default toolbar.
    await t.tapAt(canvas.view!.toScreen(Offset(b.x + 20, b.y + 10)) + const Offset(0, CommandToolbar.height));
    await frames(t);
    expect(c.editingId, 'n');
    return t.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;
  }

  /// Opens the menu on the handle of row or column [index] and picks [label].
  Future<void> menu(
    WidgetTester t,
    EditorState editor,
    TableDirection dir,
    int index,
    String label,
  ) async {
    final cell = _cell(
      editor,
      dir == TableDirection.row ? index : 0,
      dir == TableDirection.col ? index : 0,
    );
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(t.getCenter(find.byKey(cell.key)));
    await frames(t);
    await t.tap(find.byKey(ValueKey('table-handle-${dir.name}-$index')));
    await frames(t, 12);
    await t.tap(find.text(label));
    await frames(t, 20);
  }

  Future<void> key(
    WidgetTester t,
    LogicalKeyboardKey k, {
    bool shift = false,
  }) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.control);
    if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await t.sendKeyEvent(k);
    if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await t.sendKeyUpEvent(LogicalKeyboardKey.control);
    await frames(t, 20);
  }

  /// Puts the caret in the cell at the top left, so the editor has focus.
  Future<void> focus(WidgetTester t, EditorState editor) async {
    editor.selection = Selection.collapsed(
      Position(path: _cell(editor, 0, 0).children.first.path, offset: 0),
    );
    await frames(t);
  }

  /// Runs [change], then one Ctrl+Z must bring the document back exactly and
  /// one redo must apply [change] again.
  Future<void> expectOneStep(
    WidgetTester t,
    EditorState editor,
    Future<void> Function() change,
  ) async {
    final before = _state(editor);
    await change();
    await frames(t, 20);
    final after = _state(editor);
    expect(editor.isDisposed, isFalse, reason: 'the editor was not reloaded');
    expect(after, isNot(before), reason: 'the change did something');

    await focus(t, editor);
    await key(t, LogicalKeyboardKey.keyZ);
    expect(_state(editor), before, reason: 'one undo');
    expect(t.takeException(), isNull);

    await key(t, LogicalKeyboardKey.keyY);
    expect(_state(editor), after, reason: 'one redo');

    // And back again with the other redo shortcut.
    await key(t, LogicalKeyboardKey.keyZ);
    expect(_state(editor), before, reason: 'second undo');
    await key(t, LogicalKeyboardKey.keyZ, shift: true);
    expect(_state(editor), after, reason: 'redo with Ctrl+Shift+Z');
    expect(t.takeException(), isNull);
  }

  group('one Ctrl+Z undoes exactly the table change', () {
    testWidgets('typing in a cell', (t) async {
      final editor = await open(t);
      final a1 = _cell(editor, 0, 0).children.first;
      await expectOneStep(t, editor, () async {
        // One typing burst: no pause long enough to seal the step.
        await editor.apply(editor.transaction..insertText(a1, 1, '5'));
        await editor.apply(editor.transaction..insertText(a1, 2, '6'));
        await editor.apply(editor.transaction..insertText(a1, 3, '7'));
      });
    });

    testWidgets('typing keeps the formula values in step', (t) async {
      final editor = await open(t);
      final a1 = _cell(editor, 0, 0).children.first;
      await editor.apply(editor.transaction..insertText(a1, 1, '5'));
      await frames(t, 20);
      expect(
        _cell(editor, 0, 1).children.first.attributes['formulaValue'],
        '30',
      );
      await focus(t, editor);
      await key(t, LogicalKeyboardKey.keyZ);
      expect(_cell(editor, 0, 0).children.first.delta!.toPlainText(), '1');
      expect(
        _cell(editor, 0, 1).children.first.attributes['formulaValue'],
        '2',
      );
    });

    for (final dir in TableDirection.values) {
      final l10n = AppFlowyEditorL10n.current;
      final isRow = dir == TableDirection.row;
      testWidgets('insert ${dir.name} before', (t) async {
        final editor = await open(t);
        await expectOneStep(
          t,
          editor,
          () => menu(
            t,
            editor,
            dir,
            1,
            isRow ? l10n.rowAddBefore : l10n.colAddBefore,
          ),
        );
      });
      testWidgets('insert ${dir.name} after', (t) async {
        final editor = await open(t);
        await expectOneStep(
          t,
          editor,
          () => menu(
            t,
            editor,
            dir,
            0,
            isRow ? l10n.rowAddAfter : l10n.colAddAfter,
          ),
        );
      });
      testWidgets('delete ${dir.name}', (t) async {
        final editor = await open(t);
        await expectOneStep(
          t,
          editor,
          () =>
              menu(t, editor, dir, 1, isRow ? l10n.rowRemove : l10n.colRemove),
        );
      });
      testWidgets('duplicate ${dir.name}, formulas shift with it', (t) async {
        final editor = await open(t);
        await expectOneStep(
          t,
          editor,
          () => menu(
            t,
            editor,
            dir,
            0,
            isRow ? l10n.rowDuplicate : l10n.colDuplicate,
          ),
        );
      });
      testWidgets('background color of a ${dir.name}', (t) async {
        final editor = await open(t);
        await expectOneStep(t, editor, () => menu(t, editor, dir, 1, 'Alert'));
        expect(
          _cell(editor, 1, 1).attributes[isRow
              ? 'rowBackgroundColor'
              : 'colBackgroundColor'],
          'role:alert',
        );
      });
      testWidgets('clear a ${dir.name}', (t) async {
        final editor = await open(t);
        await expectOneStep(
          t,
          editor,
          () => menu(t, editor, dir, 0, isRow ? l10n.rowClear : l10n.colClear),
        );
      });
    }

    testWidgets('resizing a column', (t) async {
      final editor = await open(t);
      double width(int col) =>
          (_cell(editor, 0, col).attributes['width'] as num).toDouble();
      final w0 = width(0);
      final w1 = width(1);
      final border = find.byWidgetPredicate(
        (w) =>
            w is MouseRegion && w.cursor == SystemMouseCursors.resizeLeftRight,
      );
      expect(border, findsWidgets);
      await t.drag(border.first, const Offset(60, 0));
      await frames(t, 20);
      expect(width(0), greaterThan(w0 + 20));
      final resized = width(0);
      expect(width(1), w1);

      await focus(t, editor);
      await key(t, LogicalKeyboardKey.keyZ);
      expect(width(0), w0, reason: 'one undo');
      await key(t, LogicalKeyboardKey.keyY);
      expect(width(0), resized, reason: 'one redo');
    });

    testWidgets('the table measuring itself adds no undo step', (t) async {
      final editor = await open(t);
      // Opening and focusing the table measured it; nothing to undo.
      expect(editor.undoManager.undoStack.isEmpty, isTrue);
      final a1 = _cell(editor, 0, 0).children.first;
      await editor.apply(
        editor.transaction..insertText(a1, 1, 'long words ' * 6),
      );
      await frames(t, 20);
      // The text wraps, so the row grows and is measured again: no new step.
      expect(
        (_cell(editor, 0, 0).attributes['height'] as num).toDouble(),
        greaterThan(45),
      );
      expect(editor.undoManager.undoStack.length, 1);
      expect(editor.undoManager.redoStack.isEmpty, isTrue);
    });
  });
}
