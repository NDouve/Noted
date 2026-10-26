// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late DrawingModule module;
  late CanvasToolSelection tools;

  Future<void> pump(WidgetTester t, {ThemeData? theme}) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    module = DrawingModule();
    tools = CanvasToolSelection();
    addTearDown(tools.dispose);
    final c = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)),
      ModuleRegistry()..register(module),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: PageCanvas(controller: c, tools: tools),
        ),
      ),
    );
  }

  PageCanvasState canvas(WidgetTester t) =>
      t.state<PageCanvasState>(find.byType(PageCanvas));

  Finder button(String tooltip) => find.ancestor(
    of: find.byTooltip(tooltip),
    matching: find.byType(IconButton),
  );

  // Ink colors are swatches (a disc with a ring), not icon buttons.
  Finder swatch(String tooltip) => find.descendant(
    of: find.byTooltip(tooltip),
    matching: find.byType(ToolbarSwatch),
  );

  bool checked(WidgetTester t, String tooltip) {
    if (swatch(tooltip).evaluate().isNotEmpty) {
      return t.widget<ToolbarSwatch>(swatch(tooltip)).selected;
    }
    return t.widget<IconButton>(button(tooltip)).isSelected ?? false;
  }

  bool enabled(WidgetTester t, String tooltip) {
    if (swatch(tooltip).evaluate().isNotEmpty) {
      final ink = find.descendant(
        of: find.byTooltip(tooltip),
        matching: find.byType(InkResponse),
      );
      return t.widget<InkResponse>(ink).onTap != null;
    }
    return t.widget<IconButton>(button(tooltip)).onPressed != null;
  }

  testWidgets('the default toolbar has the pen, eraser, colors and widths', (t) async {
    await pump(t);
    for (final tip in [
      'Select and type (V)',
      'Pen (P)',
      'Eraser (E)',
      'Ink color: Default ink',
      'Ink color: Blue',
      'Ink color: Orange',
      'Ink color: Green',
      'Pen width 2',
      'Pen width 4',
      'Pen width 8',
    ]) {
      expect(find.byTooltip(tip), findsOneWidget, reason: tip);
    }
    // The note module isn't on, so its commands are skipped, not errors.
    expect(find.byTooltip('Insert table'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('P and E select the tools and the toolbar follows', (t) async {
    await pump(t);
    expect(checked(t, 'Select and type (V)'), isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.keyP);
    await t.pump();
    expect(tools.active, module.pen);
    expect(checked(t, 'Pen (P)'), isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.keyE);
    await t.pump();
    expect(tools.active, module.eraser);
    expect(checked(t, 'Eraser (E)'), isTrue);
    expect(checked(t, 'Pen (P)'), isFalse);
    await t.sendKeyEvent(LogicalKeyboardKey.keyV);
    await t.pump();
    expect(checked(t, 'Select and type (V)'), isTrue);
  });

  testWidgets('colors and widths are always enabled', (t) async {
    await pump(t);
    expect(enabled(t, 'Ink color: Blue'), isTrue);
    expect(enabled(t, 'Pen width 8'), isTrue);
    await t.tap(find.byTooltip('Eraser (E)'));
    await t.pump();
    expect(enabled(t, 'Ink color: Blue'), isTrue);
    expect(enabled(t, 'Pen width 8'), isTrue);
  });

  testWidgets('clicking a color with Select active selects the Pen', (t) async {
    await pump(t);
    expect(tools.active, isNull);
    await t.tap(find.byTooltip('Ink color: Orange'));
    await t.pump();
    expect(tools.active, module.pen);
    expect(module.settings.color, PenSettings.colors[2]);
    expect(checked(t, 'Pen (P)'), isTrue);
    expect(checked(t, 'Select and type (V)'), isFalse);
    expect(checked(t, 'Ink color: Orange'), isTrue);
  });

  testWidgets('clicking a width with the Eraser active selects the Pen', (t) async {
    await pump(t);
    await t.tap(find.byTooltip('Eraser (E)'));
    await t.pump();
    await t.tap(find.byTooltip('Pen width 8'));
    await t.pump();
    expect(tools.active, module.pen);
    expect(module.settings.size, 8);
    expect(checked(t, 'Pen (P)'), isTrue);
    expect(checked(t, 'Pen width 8'), isTrue);
  });

  testWidgets('clicking a color or a width sets the pen and shows it checked', (t) async {
    await pump(t);
    await t.tap(find.byTooltip('Pen (P)'));
    await t.pump();
    expect(checked(t, 'Ink color: Default ink'), isTrue);
    expect(checked(t, 'Pen width 4'), isTrue);

    await t.tap(find.byTooltip('Ink color: Orange'));
    await t.pump();
    expect(module.settings.color, PenSettings.colors[2]);
    expect(checked(t, 'Ink color: Orange'), isTrue);
    expect(checked(t, 'Ink color: Default ink'), isFalse);

    await t.tap(find.byTooltip('Pen width 8'));
    await t.pump();
    expect(module.settings.size, 8);
    expect(checked(t, 'Pen width 8'), isTrue);
    expect(checked(t, 'Pen width 4'), isFalse);
  });

  testWidgets('the commands have stable ids', (t) async {
    await pump(t);
    final r = canvas(t).commands;
    expect(r['noted.drawing.pen']!.shortcut!.trigger, LogicalKeyboardKey.keyP);
    expect(r['noted.drawing.eraser']!.shortcut!.trigger, LogicalKeyboardKey.keyE);
    for (var i = 0; i < PenSettings.colors.length; i++) {
      expect(r[penColorCommandId(i)], isNotNull);
    }
    for (final s in PenSettings.sizes) {
      expect(r[penWidthCommandId(s)], isNotNull);
    }
    expect(penWidthCommandId(4), 'noted.drawing.width.4');
    // Invoking a color selects the pen too.
    expect(tools.active, isNull);
    await r.invoke('noted.drawing.color.1');
    expect(module.settings.color, PenSettings.colors[1]);
    expect(tools.active, module.pen);
    await r.invoke('noted.drawing.eraser');
    await r.invoke(penWidthCommandId(8));
    expect(module.settings.size, 8);
    expect(tools.active, module.pen);
  });

  testWidgets('the default ink swatch follows the theme', (t) async {
    for (final brightness in Brightness.values) {
      await pump(
        t,
        theme: ThemeData(brightness: brightness),
      );
      await t.pumpAndSettle(); // the theme change animates
      final disc = t.widget<ToolbarSwatch>(swatch('Ink color: Default ink'));
      expect(
        disc.color,
        NotedColors.forBrightness(brightness).inkDefault,
      );
    }
  });
}
