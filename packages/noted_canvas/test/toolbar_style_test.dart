// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The Toolbar guidelines (docs/design/components/Toolbar), in both themes and
// for touch: sizes, colors and states read back from the widget tree.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';

void main() {
  late CommandRegistry registry;
  late ValueNotifier<String> active;
  late ValueNotifier<bool> tableEnabled;
  late List<String> ran;

  Command cmd(
    String id,
    String label, {
    IconData icon = Icons.circle_rounded,
    SingleActivator? shortcut,
    bool Function()? checked,
    bool Function()? enabled,
    Listenable? listenable,
    String Function()? text,
    bool readout = false,
    bool showLabel = false,
    CommandIconBuilder? iconBuilder,
  }) => Command(
    id: id,
    label: label,
    icon: icon,
    shortcut: shortcut,
    checked: checked,
    enabled: enabled,
    listenable: listenable,
    text: text,
    readout: readout,
    showLabel: showLabel,
    iconBuilder: iconBuilder,
    invoke: () => ran.add(id),
  );

  setUp(() {
    ran = [];
    active = ValueNotifier('select');
    tableEnabled = ValueNotifier(false);
    registry = CommandRegistry()
      ..registerAll([
        cmd(
          'select',
          'Select and type',
          icon: Icons.text_fields_rounded,
          shortcut: const SingleActivator(LogicalKeyboardKey.keyV),
          checked: () => active.value == 'select',
          listenable: active,
        ),
        cmd(
          'pen',
          'Pen',
          icon: Icons.edit_rounded,
          shortcut: const SingleActivator(LogicalKeyboardKey.keyP),
          checked: () => active.value == 'pen',
          listenable: active,
        ),
        for (final (i, c) in [Colors.black, Colors.blue].indexed)
          cmd(
            'color.$i',
            'Ink color $i',
            checked: () => i == 0,
            iconBuilder: (_, checked) =>
                ToolbarSwatch(color: c, selected: checked),
          ),
        cmd('undo', 'Undo', icon: Icons.undo_rounded),
        cmd(
          'table',
          'Insert table',
          text: () => 'Table',
          enabled: () => tableEnabled.value,
          listenable: tableEnabled,
        ),
        cmd('fit', 'Fit all', showLabel: true),
        cmd(
          'zoom',
          'Zoom to 100%',
          text: () => '100%',
          readout: true,
          shortcut: const SingleActivator(LogicalKeyboardKey.digit0, control: true),
        ),
      ]);
  });

  tearDown(() {
    registry.dispose();
    active.dispose();
    tableEnabled.dispose();
  });

  const layout = [
    ['select', 'pen'],
    ['color.0', 'color.1'],
    ['undo'],
    ['table'],
    ['fit', 'zoom'],
  ];

  Future<void> pump(
    WidgetTester t,
    ThemeData theme, {
    double width = 1000,
  }) async {
    t.view.physicalSize = Size(width, 600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: CommandToolbar(registry: registry, layout: layout),
          ),
        ),
      ),
    );
  }

  Finder icon(String tooltip) => find.ancestor(
    of: find.byTooltip(tooltip),
    matching: find.byType(IconButton),
  );

  for (final brightness in Brightness.values) {
    group('in ${brightness.name} mode', () {
      final theme = notedThemeData(brightness);
      final scheme = theme.colorScheme;
      final colors = NotedColors.forBrightness(brightness);
      final m = NotedMetrics.forBrightness(brightness);

      testWidgets('the bar: 52px, surface, bottom hairline, padding space-4', (
        t,
      ) async {
        await pump(t, theme);
        expect(t.getSize(find.byType(CommandToolbar)).height, 52);
        expect(m.toolbarHeight, 52);
        final material = t.widget<Material>(
          find
              .descendant(
                of: find.byType(CommandToolbar),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(material.color, scheme.surface);
        final deco =
            t
                    .widget<DecoratedBox>(
                      find
                          .descendant(
                            of: find.byType(CommandToolbar),
                            matching: find.byType(DecoratedBox),
                          )
                          .first,
                    )
                    .decoration
                as BoxDecoration;
        final bottom = (deco.border! as Border).bottom;
        expect(bottom.color, scheme.outline);
        expect(bottom.width, 1);
        // The first button starts after the side padding.
        expect(t.getTopLeft(icon('Select and type (V)')).dx, m.space4);
        // Gap between buttons in a group.
        final a = t.getRect(icon('Select and type (V)'));
        final b = t.getRect(icon('Pen (P)'));
        expect(b.left - a.right, m.space1);
      });

      testWidgets('buttons: 36px squares, radius-md, 18px icons in text', (
        t,
      ) async {
        await pump(t, theme);
        final undo = icon('Undo');
        expect(t.getSize(undo), Size.square(m.control));
        expect(t.widget<IconButton>(undo).iconSize, m.icon);
        final shape = theme.iconButtonTheme.style!.shape!.resolve({})!
            as RoundedRectangleBorder;
        expect(shape.borderRadius, m.borderMd);
        expect(
          theme.iconButtonTheme.style!.foregroundColor!.resolve({}),
          scheme.onSurface,
        );
        // Hover fills surface-hover.
        expect(
          theme.iconButtonTheme.style!.overlayColor!.resolve({WidgetState.hovered}),
          colors.surfaceHover,
        );
        // The icon is drawn at 18px.
        final iconSize = t.getSize(
          find.descendant(of: undo, matching: find.byType(Icon)),
        );
        expect(iconSize, Size.square(m.icon));
      });

      testWidgets('the active tool: accent-soft fill, accent icon, pressed', (
        t,
      ) async {
        await pump(t, theme);
        final style = t.widget<IconButton>(icon('Select and type (V)')).style!;
        expect(style.backgroundColor!.resolve({}), scheme.primaryContainer);
        expect(style.foregroundColor!.resolve({}), scheme.primary);
        expect(t.widget<IconButton>(icon('Pen (P)')).style, isNull);
        // Pressed state for assistive technology.
        Semantics toggled(String id) => t.widget<Semantics>(
          find.descendant(
            of: find.byKey(ValueKey(id)),
            matching: find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.toggled != null,
            ),
          ),
        );
        expect(toggled('select').properties.toggled, isTrue);
        expect(toggled('pen').properties.toggled, isFalse);
        // Choosing the pen moves the fill.
        await t.tap(icon('Pen (P)'));
        active.value = 'pen';
        await t.pump();
        await t.pump();
        expect(
          t.widget<IconButton>(icon('Pen (P)')).style!.backgroundColor!.resolve({}),
          scheme.primaryContainer,
        );
        expect(ran, ['pen']);
      });

      testWidgets('separators: 1x24 border rule with space-2 each side', (
        t,
      ) async {
        await pump(t, theme);
        final seps = find.byType(ToolbarSeparator);
        // Four groups before the view group: three rules.
        expect(seps, findsNWidgets(3));
        final rule = find.descendant(
          of: seps.first,
          matching: find.byType(ColoredBox),
        );
        expect(t.getSize(rule), const Size(1, 24));
        expect(t.widget<ColoredBox>(rule).color, scheme.outline);
        expect(t.getSize(seps.first).width, 1 + 2 * m.space2);
      });

      testWidgets('view controls sit at the far right', (t) async {
        await pump(t, theme);
        final fit = t.getRect(find.text('Fit all'));
        final zoom = t.getRect(find.text('100%'));
        final width = t.getSize(find.byType(CommandToolbar)).width;
        expect(zoom.right, lessThan(width));
        expect(width - t.getRect(find.byType(OutlinedButton)).right, m.space4);
        expect(fit.right, lessThan(zoom.left));
        expect(fit.left, greaterThan(t.getRect(find.text('Table')).right));
        expect(fit.left, greaterThan(width / 2));
      });

      testWidgets('ink swatches: 28px discs, selected has a 2px accent ring', (
        t,
      ) async {
        await pump(t, theme);
        final swatches = find.byType(ToolbarSwatch);
        expect(swatches, findsNWidgets(2));
        expect(t.getSize(swatches.first), const Size.square(28));
        Decoration ring(int i) => t
            .widget<Container>(
              find
                  .descendant(of: swatches.at(i), matching: find.byType(Container))
                  .first,
            )
            .decoration!;
        final selected = ring(0) as BoxDecoration;
        expect(selected.shape, BoxShape.circle);
        expect((selected.border! as Border).top.color, scheme.primary);
        expect((selected.border! as Border).top.width, 2);
        expect((ring(1) as BoxDecoration).border, isNull);
        // The swatch is always enabled: tapping it runs the command.
        await t.tap(swatches.last);
        expect(ran, ['color.1']);
      });

      testWidgets('text commands are ghost buttons with a body label', (
        t,
      ) async {
        await pump(t, theme);
        final fit = find.widgetWithText(TextButton, 'Fit all');
        expect(fit, findsOneWidget);
        expect(t.getSize(fit).height, m.control);
        final text = t.widget<Text>(find.text('Fit all'));
        final defaults = DefaultTextStyle.of(t.element(find.text('Fit all')));
        expect(text.style, isNull);
        expect(defaults.style.fontSize, 14);
        expect(defaults.style.color, scheme.onSurface);
        // Disabled: text-disabled.
        expect(find.widgetWithText(TextButton, 'Table'), findsOneWidget);
        expect(
          DefaultTextStyle.of(t.element(find.text('Table'))).style.color,
          colors.textDisabled,
        );
        tableEnabled.value = true;
        await t.pumpAndSettle();
        expect(
          DefaultTextStyle.of(t.element(find.text('Table'))).style.color,
          scheme.onSurface,
        );
      });

      testWidgets('zoom: an outlined numeric button', (t) async {
        await pump(t, theme);
        final zoom = find.widgetWithText(OutlinedButton, '100%');
        expect(zoom, findsOneWidget);
        final style = DefaultTextStyle.of(t.element(find.text('100%'))).style;
        expect(style.fontSize, DesignType.numeric.fontSize);
        expect(style.fontFeatures, DesignType.numeric.fontFeatures);
        expect(t.getSize(zoom).height, m.control);
        expect(t.getSize(zoom).width, greaterThanOrEqualTo(56));
        // The outline is the border token.
        expect(
          theme.outlinedButtonTheme.style!.side!.resolve({})!.color,
          scheme.outline,
        );
        await t.tap(zoom);
        expect(ran, ['zoom']);
      });

      testWidgets('tooltips: label and shortcut', (t) async {
        await pump(t, theme);
        expect(find.byTooltip('Pen (P)'), findsOneWidget);
        expect(find.byTooltip('Select and type (V)'), findsOneWidget);
        expect(find.byTooltip('Zoom to 100% (Ctrl+0)'), findsOneWidget);
        expect(find.byTooltip('Ink color 1'), findsOneWidget);
        expect(find.byTooltip('Insert table'), findsOneWidget);
        // The tooltip itself is a text-on-text bubble with the small style.
        expect(theme.tooltipTheme.textStyle!.fontSize, DesignType.small.fontSize);
      });

      testWidgets('touch: controls grow to 44px and the toolbar wraps', (
        t,
      ) async {
        final touch = notedThemeData(brightness, touch: true);
        await pump(t, touch, width: 700);
        expect(NotedMetrics.of(t.element(find.byType(CommandToolbar))).touch, isTrue);
        expect(t.getSize(icon('Undo')), const Size.square(44));
        expect(
          t.getSize(find.widgetWithText(OutlinedButton, '100%')).height,
          44,
        );
        expect(t.getSize(find.widgetWithText(TextButton, 'Fit all')).height, 44);
        // A narrow screen wraps to a second row instead of scrolling.
        await pump(t, touch, width: 360);
        final height = t.getSize(find.byType(CommandToolbar)).height;
        expect(height, greaterThan(52));
        expect(find.byType(Wrap), findsOneWidget);
        expect(find.byType(SingleChildScrollView), findsNothing);
        expect(t.takeException(), isNull);
      });
    });
  }

  testWidgets('a pointer of kind touch switches the input mode', (t) async {
    final notifier = InputModeNotifier();
    addTearDown(notifier.dispose);
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: InputModeScope(notifier: notifier, child: const SizedBox.expand()),
      ),
    );
    expect(notifier.value, isFalse);
    final touch = await t.startGesture(
      const Offset(20, 20),
      kind: PointerDeviceKind.touch,
    );
    await touch.up();
    expect(notifier.value, isTrue);
    final mouse = await t.startGesture(
      const Offset(30, 30),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.up();
    expect(notifier.value, isFalse);
  });
}
