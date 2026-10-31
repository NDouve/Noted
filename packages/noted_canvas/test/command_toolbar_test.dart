// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

class _Codec extends BoxCodec<String> {
  const _Codec();
  @override
  String get typeId => 'test.text';
  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.fixed;
  @override
  String create() => '';
  @override
  String decode(Object? json, int storedVersion) => json! as String;
  @override
  Object? encode(String data) => data;
  @override
  String snapshotText(String data) => data;
  @override
  AiExposure aiExposure(String data) => AiText(data);
}

class _Tool extends CanvasTool {
  _Tool(this.id, this.label, this.shortcut);
  @override
  final String id;
  @override
  final String label;
  @override
  final LogicalKeyboardKey shortcut;
  @override
  IconData get icon => Icons.edit;
  @override
  ToolSession? start(ToolContext context, ToolPointer pointer) => null;
}

/// A module with two tools and one extra command whose state the test sets.
class _Module extends BoxModule<String> {
  _Module(this.tools, this.extraEnabled);
  @override
  final List<CanvasTool> tools;
  final ValueNotifier<bool> extraEnabled;
  int extraRuns = 0;
  @override
  BoxCodec<String> get codec => const _Codec();
  @override
  List<Command> commands(CommandHost host) => [
    Command(
      id: 'test.extra',
      label: 'Extra',
      icon: Icons.star,
      shortcut: const SingleActivator(LogicalKeyboardKey.keyX, control: true),
      enabled: () => extraEnabled.value,
      listenable: extraEnabled,
      invoke: () => extraRuns++,
    ),
  ];
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) =>
      Text(box.data);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) =>
      Text(box.data);
}

void main() {
  late _Tool pen;
  late _Tool eraser;
  late ValueNotifier<bool> extraEnabled;
  late _Module module;
  late CanvasController c;
  late CanvasToolSelection selection;

  Future<void> pump(
    WidgetTester t, {
    ToolbarLayout layout = const [
      ['canvas.select', 'test.pen', 'test.eraser'],
      ['canvas.undo', 'canvas.redo', 'test.extra'],
      ['canvas.fitAll', 'canvas.zoomReset'],
    ],
    bool readOnly = false,
    ThemeData? theme,
  }) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    pen = _Tool('test.pen', 'Pen', LogicalKeyboardKey.keyP);
    eraser = _Tool('test.eraser', 'Eraser', LogicalKeyboardKey.keyE);
    extraEnabled = ValueNotifier(false);
    addTearDown(extraEnabled.dispose);
    module = _Module([pen, eraser], extraEnabled);
    final modules = ModuleRegistry()..register(module, isDefault: true);
    c = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0))
          .insertNode(
            BoxRecord.create(
              id: 'b',
              typeId: 'test.text',
              dataVersion: 1,
              bounds: const Bounds(0, 0, 200, 100),
              data: RawJson.encode('box'),
              snapshotText: 'box',
              rev: 'r',
            ),
          ),
      modules,
    );
    selection = CanvasToolSelection();
    addTearDown(selection.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: PageCanvas(
            controller: c,
            tools: selection,
            toolbar: _flat(layout),
            readOnly: readOnly,
          ),
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

  bool checked(WidgetTester t, String tooltip) =>
      t.widget<IconButton>(button(tooltip)).isSelected ?? false;

  bool enabled(WidgetTester t, String tooltip) =>
      t.widget<IconButton>(button(tooltip)).onPressed != null;

  testWidgets('the toolbar is built from commands: tooltips show label and shortcut', (t) async {
    await pump(t);
    for (final tip in [
      'Select and type (V)',
      'Pen (P)',
      'Eraser (E)',
      'Undo (Ctrl+Z)',
      'Redo (Ctrl+Y)',
      'Extra (Ctrl+X)',
    ]) {
      expect(find.byTooltip(tip), findsOneWidget, reason: tip);
    }
    expect(find.byTooltip('Fit all'), findsOneWidget);
    expect(find.byTooltip('Zoom to 100% (Ctrl+0)'), findsOneWidget);
    // Fixed along the top, full width, above the canvas.
    final bar = t.getRect(find.byType(CommandToolbar));
    expect(bar.top, 0);
    expect(bar.width, 1200);
    expect(bar.height, CommandToolbar.height);
    expect(
      t.getTopLeft(find.byType(Listener).first).dy,
      greaterThanOrEqualTo(0),
    );
  });

  testWidgets('P, E, V and Escape change the tool and the toolbar follows at once', (t) async {
    await pump(t);
    expect(checked(t, 'Select and type (V)'), isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.keyP);
    await t.pump();
    expect(selection.active, pen);
    expect(checked(t, 'Pen (P)'), isTrue);
    expect(checked(t, 'Select and type (V)'), isFalse);
    await t.sendKeyEvent(LogicalKeyboardKey.keyE);
    await t.pump();
    expect(selection.active, eraser);
    expect(checked(t, 'Eraser (E)'), isTrue);
    expect(checked(t, 'Pen (P)'), isFalse);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(selection.active, isNull);
    expect(checked(t, 'Select and type (V)'), isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.keyP);
    await t.sendKeyEvent(LogicalKeyboardKey.keyV);
    await t.pump();
    expect(selection.active, isNull);
    expect(checked(t, 'Pen (P)'), isFalse);
  });

  testWidgets('clicking a toolbar tool works like its key', (t) async {
    await pump(t);
    await t.tap(find.byTooltip('Pen (P)'));
    await t.pump();
    expect(selection.active, pen);
    expect(checked(t, 'Pen (P)'), isTrue);
    await t.tap(find.byTooltip('Eraser (E)'));
    await t.pump();
    expect(selection.active, eraser);
    await t.tap(find.byTooltip('Select and type (V)'));
    await t.pump();
    expect(selection.active, isNull);
    expect(checked(t, 'Select and type (V)'), isTrue);
  });

  testWidgets('undo and redo are disabled until there is something to undo or redo', (t) async {
    await pump(t);
    expect(enabled(t, 'Undo (Ctrl+Z)'), isFalse);
    expect(enabled(t, 'Redo (Ctrl+Y)'), isFalse);

    c.delete('b');
    await t.pump();
    expect(c.page.nodes, isEmpty);
    expect(enabled(t, 'Undo (Ctrl+Z)'), isTrue);
    expect(enabled(t, 'Redo (Ctrl+Y)'), isFalse);

    await t.tap(find.byTooltip('Undo (Ctrl+Z)'));
    await t.pump();
    expect(c.page.nodes, hasLength(1));
    expect(enabled(t, 'Undo (Ctrl+Z)'), isFalse);
    expect(enabled(t, 'Redo (Ctrl+Y)'), isTrue);

    await t.tap(find.byTooltip('Redo (Ctrl+Y)'));
    await t.pump();
    expect(c.page.nodes, isEmpty);
  });

  testWidgets('Ctrl+Z, Ctrl+Y, Ctrl+Shift+Z and Delete go through the commands', (t) async {
    await pump(t);
    c.select('b');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await t.pump();
    expect(c.page.nodes, isEmpty);

    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await t.pump();
    expect(c.page.nodes, hasLength(1));
    await t.sendKeyEvent(LogicalKeyboardKey.keyY);
    await t.pump();
    expect(c.page.nodes, isEmpty);
    await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await t.pump();
    expect(c.page.nodes, hasLength(1));
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    expect(c.page.nodes, isEmpty, reason: 'Ctrl+Shift+Z is redo');
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets('a module command shows its enabled state and runs from the toolbar and its key', (t) async {
    await pump(t);
    expect(enabled(t, 'Extra (Ctrl+X)'), isFalse);
    extraEnabled.value = true;
    await t.pump();
    expect(enabled(t, 'Extra (Ctrl+X)'), isTrue);
    await t.tap(find.byTooltip('Extra (Ctrl+X)'));
    expect(module.extraRuns, 1);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyX);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(module.extraRuns, 2);
    extraEnabled.value = false;
    await t.pump();
    expect(enabled(t, 'Extra (Ctrl+X)'), isFalse);
  });

  testWidgets('the zoom level shows the percentage; clicking it zooms to 100%; Fit all fits', (t) async {
    await pump(t);
    expect(find.text('100%'), findsOneWidget);
    canvas(t).zoomTo(0.5);
    await t.pump();
    await t.pump();
    expect(find.text('50%'), findsOneWidget);
    await t.tap(find.text('50%'));
    await t.pump();
    await t.pump();
    expect(canvas(t).view!.scale, closeTo(1, 1e-9));
    expect(find.text('100%'), findsOneWidget);

    // Zoom keys, also through the registry.
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.equal);
    await t.pump();
    await t.pump();
    expect(canvas(t).view!.scale, greaterThan(1));
    await t.sendKeyEvent(LogicalKeyboardKey.digit0);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    await t.pump();
    expect(find.text('100%'), findsOneWidget);

    await t.tap(find.text('Fit all'));
    await t.pump();
    expect(canvas(t).view, isNotNull);
  });

  testWidgets('the layout decides order; unknown ids are skipped', (t) async {
    await pump(
      t,
      layout: const [
        ['test.eraser', 'no.such.command', 'canvas.select'],
        ['also.missing'],
        ['canvas.undo'],
      ],
    );
    final x = [
      for (final tip in [
        'Eraser (E)',
        'Select and type (V)',
        'Undo (Ctrl+Z)',
      ])
        t.getCenter(find.byTooltip(tip)).dx,
    ];
    expect(x[0], lessThan(x[1]));
    expect(x[1], lessThan(x[2]));
    expect(find.byTooltip('Pen (P)'), findsNothing);
    expect(find.byTooltip('Redo (Ctrl+Y)'), findsNothing);
    // The last group is the view group at the far right; no rule before it.
    expect(find.byType(ToolbarSeparator), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('a read-only page keeps only the commands that work there', (t) async {
    await pump(t, readOnly: true);
    expect(find.byTooltip('Pen (P)'), findsNothing);
    expect(find.byTooltip('Undo (Ctrl+Z)'), findsNothing);
    expect(find.text('Fit all'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    // Tool keys do nothing there; zoom keys do.
    await t.sendKeyEvent(LogicalKeyboardKey.keyP);
    expect(selection.active, isNull);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.equal);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(canvas(t).view!.scale, greaterThan(1));
  });

  for (final brightness in Brightness.values) {
    testWidgets('the toolbar uses the theme colors in ${brightness.name} mode', (t) async {
      final theme = notedThemeData(brightness);
      await pump(t, theme: theme);
      final scheme = theme.colorScheme;
      final material = t.widget<Material>(
        find
            .descendant(
              of: find.byType(CommandToolbar),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color, scheme.surface);
      final border = t
          .widget<DecoratedBox>(
            find
                .descendant(
                  of: find.byType(CommandToolbar),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          )
          .decoration as BoxDecoration;
      expect((border.border! as Border).bottom.color, scheme.outline);

      // The checked tool is drawn with the theme's container colors.
      final style = t.widget<IconButton>(button('Select and type (V)')).style!;
      expect(
        style.backgroundColor!.resolve({}),
        scheme.primaryContainer,
      );
      expect(
        style.foregroundColor!.resolve({}),
        scheme.primary,
      );
    });
  }

  testWidgets('each tool is also a command with its id, label and shortcut', (t) async {
    await pump(t);
    final r = canvas(t).commands;
    final p = r['test.pen']!;
    expect((p.label, p.icon, p.checked), ('Pen', Icons.edit, false));
    expect(p.shortcut!.trigger, LogicalKeyboardKey.keyP);
    await r.invoke('test.pen');
    expect(selection.active, pen);
    expect(p.checked, isTrue);
    expect(r['canvas.select']!.checked, isFalse);
    // The canvas's own commands are all there, with stable ids.
    for (final id in [
      'canvas.select',
      'canvas.undo',
      'canvas.redo',
      'canvas.delete',
      'canvas.escape',
      'canvas.zoomIn',
      'canvas.zoomOut',
      'canvas.zoomReset',
      'canvas.fitAll',
      'test.extra',
    ]) {
      expect(r[id], isNotNull, reason: id);
    }
  });
}


/// A one-bar layout like the earlier fixed toolbar: every group but the last
/// at the left, the last at the far right.
ContextualToolbarLayout _flat(ToolbarLayout groups) => ContextualToolbarLayout(
  leading: groups.sublist(0, groups.length - 1),
  sections: const [],
  trailing: [groups.last],
);
