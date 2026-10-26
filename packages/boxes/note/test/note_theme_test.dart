// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_box_note/src/math_blocks.dart';
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

Map<String, Object?> _math(String formula) => {
  'type': 'math_equation',
  'data': {'formula': formula},
};

ThemeData _theme(Brightness b) => notedThemeData(b);

void main() {
  for (final brightness in Brightness.values) {
    group('note box in ${brightness.name} mode', () {
      late ThemeData theme;
      late CanvasController c;

      Future<void> frames(WidgetTester t, [int n = 6]) async {
        for (var i = 0; i < n; i++) {
          await t.pump(const Duration(milliseconds: 50));
        }
      }

      Future<void> pump(WidgetTester t) async {
        t.view.physicalSize = const Size(1200, 800);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        theme = _theme(brightness);
        final data = NoteData({
          'document': {
            'type': 'page',
            'children': [
              {
                'type': 'heading',
                'data': {
                  'level': 1,
                  'delta': [
                    {'insert': 'Field notes'},
                  ],
                },
              },
              _para('hello'),
              _table([
                ['1', '=A1*2', '=1/0'],
              ]),
              _math('x^2'),
              _math(r'\frac{'),
            ],
          },
        });
        final box = BoxRecord.create(
          id: 'n',
          typeId: NoteCodec.id,
          dataVersion: 1,
          bounds: Bounds(100, 100, 500, 40),
          data: RawJson.encode(_codec.encode(data)),
          snapshotText: _codec.snapshotText(data),
          rev: 'r',
        );
        final modules = ModuleRegistry()
          ..register(const NoteModule(), alwaysOn: true, isDefault: true);
        c = CanvasController(
          NotedPage.create(
            PageMeta.create(id: 'p', title: '', order: 0),
          ).insertNode(box),
          modules,
        );
        await t.pumpWidget(
          MaterialApp(
            theme: theme,
            localizationsDelegates: noteLocalizationsDelegates,
            home: Scaffold(body: PageCanvas(controller: c)),
          ),
        );
        await t.pumpAndSettle();
      }

      testWidgets('Heading 1 uses the box-title style', (t) async {
        await pump(t);
        TextSpan? heading;
        for (final r in t.widgetList<RichText>(find.byType(RichText))) {
          r.text.visitChildren((s) {
            if (s is TextSpan && s.text == 'Field notes') heading = s;
            return heading == null;
          });
        }
        expect(heading, isNotNull);
        final style = heading!.style!;
        expect(style.fontSize, DesignType.boxTitle.fontSize);
        expect(style.fontWeight, DesignType.boxTitle.fontWeight);
        expect(style.height, DesignType.boxTitle.height);
        expect(style.color, theme.colorScheme.onSurface);
      });

      testWidgets('text, formulas and equations use the theme', (t) async {
        await pump(t);
        final scheme = theme.colorScheme;

        final values = find.byKey(const ValueKey('formula-value'));
        expect(values, findsNWidgets(2));
        final ok = t.widget<Text>(values.at(0));
        final bad = t.widget<Text>(values.at(1));
        expect(ok.data, '2');
        expect(ok.style?.color, scheme.onSurface);
        expect(bad.data, '#DIV/0!');
        expect(bad.style?.color, scheme.error);

        final maths = t.widgetList<Math>(find.byType(Math)).toList();
        expect(maths, isNotEmpty);
        expect(maths.first.textStyle?.color, scheme.onSurface);
        final placeholder = find.byType(MathErrorPlaceholder);
        expect(placeholder, findsOneWidget);
        final text = t.widget<Text>(
          find.descendant(of: placeholder, matching: find.byType(Text)),
        );
        expect(text.style?.color, scheme.error);
      });

      testWidgets('grid letters and numbers use the theme', (t) async {
        await pump(t);
        final canvas = t.state<PageCanvasState>(find.byType(PageCanvas));
        final b = c.page.node('n')!.bounds!;
        await t.tapAt(canvas.view!.toScreen(Offset(b.x + 20, b.y + 10)) + const Offset(0, CommandToolbar.height));
        await frames(t);
        final editor = t
            .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
            .editorState;
        final cell = editor.document.root.children[2].children.firstWhere(
          (n) =>
              n.attributes['rowPosition'] == 0 &&
              n.attributes['colPosition'] == 0,
        );
        editor.selection = Selection.collapsed(
          Position(path: cell.children.first.path),
        );
        await frames(t, 8);
        final label = find.descendant(
          of: find.byKey(const ValueKey('col-header-A')),
          matching: find.byType(Text),
        );
        expect(label, findsOneWidget);
        expect(t.widget<Text>(label).style?.color, theme.colorScheme.onSurfaceVariant);
        final row = find.descendant(
          of: find.byKey(const ValueKey('row-header-1')),
          matching: find.byType(Text),
        );
        expect(t.widget<Text>(row).style?.color, theme.colorScheme.onSurfaceVariant);
      });
    });
  }
}
