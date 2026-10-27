// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ui' show PointerDeviceKind;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_box_note/src/note_theme.dart';
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

/// A 2 x 2 table; [data] adds attributes to the cell at (row, col).
Map<String, Object?> _table(
  List<List<String>> rows, {
  Map<(int, int), Map<String, Object?>> data = const {},
}) {
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
            'data': {'colPosition': c, 'rowPosition': r, ...?data[(r, c)]},
            'children': [_para(rows[r][c])],
          },
    ],
  };
}

NoteData _doc(Map<String, Object?> table) => NoteData({
  'document': {
    'type': 'page',
    'children': [table],
  },
});

ThemeData _theme(Brightness b) => ThemeData(
  colorSchemeSeed: const Color(0xFF3F51B5),
  brightness: b,
  useMaterial3: true,
);

void main() {
  group('TableFill', () {
    test('a role is stored as role:name and read back', () {
      for (final r in FillRole.values) {
        expect(TableFill.encode(r), 'role:${r.name}');
        expect(TableFill.roleOf(TableFill.encode(r)), r);
      }
      expect(TableFill.encode(FillRole.accent), 'role:accent');
    });

    test('the exact values the first version wrote map to their roles', () {
      const legacy = {
        '0x40515b92': FillRole.accent, // light
        '0x405b5d72': FillRole.secondary,
        '0x4077536d': FillRole.tertiary,
        '0x40ba1a1a': FillRole.alert,
        '0x40bac3ff': FillRole.accent, // dark
        '0x40c3c5dd': FillRole.secondary,
        '0x40e6bad7': FillRole.tertiary,
        '0x40ffb4ab': FillRole.alert,
      };
      legacy.forEach((hex, role) {
        expect(TableFill.roleOf(hex), role, reason: hex);
        expect(
          TableFill.roleOf(hex.toUpperCase().replaceFirst('0X', '0x')),
          role,
        );
      });
    });

    test('any other value stays a fixed color, not a role', () {
      for (final v in <Object?>[
        '0x80123456',
        '0x40515b93', // one off a legacy value
        '0xff515b92', // same color, other alpha
        '#515b92',
        'rgb(1, 2, 3)',
        'role:bogus',
        'role:',
        '',
        null,
        42,
      ]) {
        expect(TableFill.roleOf(v), isNull, reason: '$v');
      }
    });

    test('backgrounds are not in the text snapshot', () {
      final plain = _doc(
        _table([
          ['1', '2'],
          ['3', '4'],
        ]),
      );
      final colored = _doc(
        _table(
          [
            ['1', '2'],
            ['3', '4'],
          ],
          data: {
            (0, 0): {'colBackgroundColor': 'role:accent'},
            (0, 1): {'rowBackgroundColor': 'role:alert'},
            (1, 1): {'colBackgroundColor': '0x80123456'},
          },
        ),
      );
      expect(_codec.snapshotText(colored), '1 | 2\n3 | 4');
      expect(_codec.snapshotText(colored), _codec.snapshotText(plain));
    });

    test('notes written before roles still decode, version 1', () {
      final json = _codec.encode(
        _doc(
          _table(
            [
              ['1', '2'],
            ],
            data: {
              (0, 0): {'colBackgroundColor': '0x40515b92'},
            },
          ),
        ),
      );
      expect(_codec.dataVersion, 1);
      final data = _codec.decode(json, 1);
      expect(_codec.encode(data), json);
    });
  });

  group('table fills in the editor', () {
    late CanvasController c;
    TestGesture? mouseOf;
    setUp(() => mouseOf = null);

    Future<void> frames(WidgetTester t, [int n = 6]) async {
      for (var i = 0; i < n; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    Widget app(Brightness b) => MaterialApp(
      theme: _theme(b),
      localizationsDelegates: noteLocalizationsDelegates,
      home: Scaffold(body: PageCanvas(controller: c)),
    );

    Future<void> pump(WidgetTester t, NoteData data, Brightness b) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
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
      c = CanvasController(
        p,
        ModuleRegistry()
          ..register(const NoteModule(), alwaysOn: true, isDefault: true),
      );
      await t.pumpWidget(app(b));
      await t.pumpAndSettle();
    }

    EditorState editorOf(WidgetTester t) =>
        t.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;

    Node cell(EditorState e, int row, int col) =>
        e.document.root.children.first.children.firstWhere(
          (n) =>
              n.attributes['rowPosition'] == row &&
              n.attributes['colPosition'] == col,
        );

    /// The background the cell at (row, col) is painted with.
    ///
    /// Works for a note being edited and for the light view of one that is
    /// not (its cells are keyed by position).
    Color? shown(WidgetTester t, int row, int col) {
      final Key key = find.byType(AppFlowyEditor).evaluate().isEmpty
          ? ValueKey('note-cell-$row-$col')
          : cell(editorOf(t), row, col).key;
      final boxes = find.descendant(
        of: find.byKey(key),
        matching: find.byType(Container),
      );
      for (final w in t.widgetList<Container>(boxes)) {
        if (w.color != null) return w.color;
      }
      return null;
    }

    Future<EditorState> edit(WidgetTester t) async {
      final canvas = t.state<PageCanvasState>(find.byType(PageCanvas));
      final b = c.page.node('n')!.bounds!;
      // The canvas sits below the default toolbar.
      await t.tapAt(canvas.view!.toScreen(Offset(b.x + 20, b.y + 10)) + const Offset(0, CommandToolbar.height));
      await frames(t);
      expect(c.editingId, 'n');
      return editorOf(t);
    }

    Future<void> pick(
      WidgetTester t,
      EditorState editor,
      TableDirection dir,
      int index,
      String label,
    ) async {
      final cellNode = cell(
        editor,
        dir == TableDirection.row ? index : 0,
        dir == TableDirection.col ? index : 0,
      );
      var mouse = mouseOf;
      if (mouse == null) {
        mouse = mouseOf = await t.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
      }
      await mouse.moveTo(t.getCenter(find.byKey(cellNode.key)));
      await frames(t);
      await t.tap(find.byKey(ValueKey('table-handle-${dir.name}-$index')));
      await frames(t, 12);
      await t.tap(find.text(label));
      await frames(t, 20);
    }

    final plain = _table([
      ['1', '2'],
      ['3', '4'],
    ]);

    for (final b in Brightness.values) {
      final scheme = _theme(b).colorScheme;
      final light = b == Brightness.light;

      testWidgets('picking a color stores its role (${b.name})', (t) async {
        await pump(t, _doc(plain), b);
        final editor = await edit(t);
        await pick(t, editor, TableDirection.col, 0, 'Accent');
        for (var r = 0; r < 2; r++) {
          expect(
            cell(editor, r, 0).attributes['colBackgroundColor'],
            'role:accent',
          );
          expect(cell(editor, r, 1).attributes['colBackgroundColor'], isNull);
        }
        await pick(t, editor, TableDirection.row, 1, 'Tertiary');
        expect(
          cell(editor, 1, 0).attributes['rowBackgroundColor'],
          'role:tertiary',
        );
        expect(
          cell(editor, 1, 1).attributes['rowBackgroundColor'],
          'role:tertiary',
        );
        // The column's color wins over the row's where both are set.
        expect(shown(t, 0, 0), fillColor(scheme, FillRole.accent));
        expect(shown(t, 1, 0), fillColor(scheme, FillRole.accent));
        expect(shown(t, 1, 1), fillColor(scheme, FillRole.tertiary));
        expect(shown(t, 0, 1), isNull);
        // What was committed is the role too.
        final stored = (c.page.node('n')! as BoxRecord).data.toString();
        expect(stored, contains('role:accent'));
        expect(stored, isNot(contains('0x4')));

        await pick(t, editor, TableDirection.col, 0, 'No color');
        expect(cell(editor, 0, 0).attributes['colBackgroundColor'], isNull);
        expect(shown(t, 0, 0), isNull);
      });

      testWidgets('the handle menu follows the Menu guidelines (${b.name})', (t) async {
        await pump(t, _doc(plain), b);
        final editor = await edit(t);
        final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(t.getCenter(find.byKey(cell(editor, 1, 0).key)));
        await frames(t);
        await t.tap(find.byKey(const ValueKey('table-handle-row-1')));
        await frames(t, 12);
        final items = find.byType(NotedMenuItem<Object>);
        expect(items, findsWidgets);
        // Every item is a `row` (32px) high.
        for (final e in items.evaluate()) {
          expect(t.getSize(find.byWidget(e.widget)).height, 32);
        }
        // Delete row is destructive: `error`; the others are `text`.
        final destructive = find.byWidgetPredicate(
          (w) => w is NotedMenuItem<Object> && w.destructive,
        );
        expect(destructive, findsOneWidget);
        Color colorOf(Finder item) => t
            .widget<Text>(find.descendant(of: item, matching: find.byType(Text)).first)
            .style!
            .color!;
        expect(colorOf(destructive), scheme.error);
        final normal = find.byWidgetPredicate(
          (w) => w is NotedMenuItem<Object> && !w.destructive && w.value is Enum,
        );
        expect(colorOf(normal.first), scheme.onSurface);
        // One separator before the colors and one before Clear.
        expect(find.byType(NotedMenuDivider), findsNWidgets(2));
        expect(find.byType(NotedMenuHeading), findsOneWidget);
      });

      testWidgets('the first row handle is reached the way a user reaches it (${b.name})', (t) async {
        // Hover the left of the first cell, then move onto the handle, which
        // straddles the table's left edge, and click it. (Not the middle of
        // the cell: the column handle that shows there covers that point in
        // a one-line row, and the row handle goes away with the hover.)
        await pump(t, _doc(plain), b);
        final editor = await edit(t);
        final rect = t.getRect(find.byKey(cell(editor, 0, 0).key));
        final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(Offset(rect.left + 15, rect.center.dy));
        await frames(t);
        final handle = find.byKey(const ValueKey('table-handle-row-0'));
        expect(handle, findsOneWidget);
        // The handle is not clipped by the note box: it is fully inside it.
        final box = t.getRect(find.byType(AppFlowyEditor));
        expect(box.contains(t.getRect(handle).topLeft), isTrue);
        await mouse.moveTo(t.getCenter(handle));
        await frames(t);
        expect(handle, findsOneWidget);
        await mouse.down(t.getCenter(handle));
        await mouse.up();
        await frames(t, 12);
        expect(find.byType(NotedMenuItem<Object>), findsWidgets);
      });

      testWidgets('each role has its theme color (${b.name})', (t) async {
        await pump(
          t,
          _doc(
            _table(
              [
                ['1', '2'],
                ['3', '4'],
              ],
              data: {
                (0, 0): {'colBackgroundColor': 'role:accent'},
                (0, 1): {'colBackgroundColor': 'role:secondary'},
                (1, 0): {'rowBackgroundColor': 'role:tertiary'},
                (1, 1): {'rowBackgroundColor': 'role:alert'},
              },
            ),
          ),
          b,
        );
        expect(shown(t, 0, 0), fillColor(scheme, FillRole.accent));
        expect(shown(t, 0, 1), fillColor(scheme, FillRole.secondary));
        expect(shown(t, 1, 0), fillColor(scheme, FillRole.tertiary));
        expect(shown(t, 1, 1), fillColor(scheme, FillRole.alert));
        // Pinned to the numbers, so a change of theme is noticed.
        expect(shown(t, 0, 0)!.toARGB32(), light ? 0x40515b92 : 0x40bac3ff);
        expect(shown(t, 1, 1)!.toARGB32(), light ? 0x40ba1a1a : 0x40ffb4ab);
      });
    }

    testWidgets('switching the theme recolors the fills', (t) async {
      await pump(
        t,
        _doc(
          _table(
            [
              ['1', '2'],
            ],
            data: {
              (0, 0): {'colBackgroundColor': 'role:accent'},
              (0, 1): {'colBackgroundColor': '0x80123456'},
            },
          ),
        ),
        Brightness.light,
      );
      expect(shown(t, 0, 0)!.toARGB32(), 0x40515b92);
      await t.pumpWidget(app(Brightness.dark));
      await frames(t, 20);
      expect(shown(t, 0, 0)!.toARGB32(), 0x40bac3ff);
      // A fixed color does not follow the theme.
      expect(shown(t, 0, 1)!.toARGB32(), 0x80123456);
      await t.pumpWidget(app(Brightness.light));
      await frames(t, 20);
      expect(shown(t, 0, 0)!.toARGB32(), 0x40515b92);
    });

    testWidgets('old fixed values follow the theme as their role', (t) async {
      await pump(
        t,
        _doc(
          _table(
            [
              ['1', '2'],
              ['3', '4'],
            ],
            data: {
              (0, 0): {'colBackgroundColor': '0x40515b92'}, // light accent
              (0, 1): {'colBackgroundColor': '0x40ffb4ab'}, // dark alert
              (1, 0): {'rowBackgroundColor': '0x80123456'}, // not a role's
            },
          ),
        ),
        Brightness.light,
      );
      expect(shown(t, 0, 0)!.toARGB32(), 0x40515b92);
      // Written in dark mode, opened in light mode: still the alert role.
      expect(shown(t, 0, 1)!.toARGB32(), 0x40ba1a1a);
      expect(shown(t, 1, 0)!.toARGB32(), 0x80123456);
      await t.pumpWidget(app(Brightness.dark));
      await frames(t, 20);
      expect(shown(t, 0, 0)!.toARGB32(), 0x40bac3ff);
      expect(shown(t, 0, 1)!.toARGB32(), 0x40ffb4ab);
      expect(shown(t, 1, 0)!.toARGB32(), 0x80123456);
    });

    testWidgets('opening and editing never rewrites stored values', (t) async {
      final data = _doc(
        _table(
          [
            ['1', '2'],
            ['3', '4'],
          ],
          data: {
            (0, 0): {'colBackgroundColor': '0x40515b92'},
            (1, 1): {'rowBackgroundColor': '0x80123456'},
          },
        ),
      );
      await pump(t, data, Brightness.light);
      final editor = await edit(t);
      final first = cell(editor, 0, 1).children.first;
      await editor.apply(editor.transaction..insertText(first, 1, 'x'));
      await frames(t, 20);
      expect(cell(editor, 0, 0).attributes['colBackgroundColor'], '0x40515b92');
      expect(cell(editor, 1, 1).attributes['rowBackgroundColor'], '0x80123456');
      final stored = (c.page.node('n')! as BoxRecord).data.toString();
      expect(stored, contains('0x40515b92'));
      expect(stored, contains('0x80123456'));
      expect(stored, isNot(contains('role:')));
      // Picking a color for the row is what writes a role, and only there.
      await pick(t, editor, TableDirection.col, 0, 'Secondary');
      expect(
        cell(editor, 0, 0).attributes['colBackgroundColor'],
        'role:secondary',
      );
      expect(cell(editor, 1, 1).attributes['rowBackgroundColor'], '0x80123456');
    });

    testWidgets('a role this version does not know shows no color', (t) async {
      await pump(
        t,
        _doc(
          _table(
            [
              ['1', '2'],
            ],
            data: {
              (0, 0): {'colBackgroundColor': 'role:future'},
            },
          ),
        ),
        Brightness.light,
      );
      expect(shown(t, 0, 0), isNull);
      expect(tester(t), isNull);
    });
  });
}

// An unknown value must not throw anywhere on the way.
Object? tester(WidgetTester t) => t.takeException();
