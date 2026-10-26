// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The Menu and Button guidelines (docs/design/components/Menu, Button), in
// both themes and for touch.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';

void main() {
  for (final brightness in Brightness.values) {
    group('in ${brightness.name} mode', () {
      final colors = NotedColors.forBrightness(brightness);
      final type = NotedTypography.withColor(
        notedColorScheme(brightness).onSurface,
      );

      Future<void> openMenu(WidgetTester t, ThemeData theme) async {
        final undo = Command(
          id: 'undo',
          label: 'Undo',
          icon: Icons.undo_rounded,
          shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, control: true),
          invoke: () {},
        );
        final off = Command(
          id: 'off',
          label: 'Not now',
          icon: Icons.block_rounded,
          enabled: () => false,
          invoke: () {},
        );
        final del = Command(
          id: 'delete',
          label: 'Delete page',
          icon: Icons.delete_outline_rounded,
          invoke: () {},
        );
        addTearDown(undo.dispose);
        addTearDown(off.dispose);
        addTearDown(del.dispose);
        t.view.physicalSize = const Size(800, 800);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Center(
                child: PopupMenuButton<String>(
                  key: const ValueKey('open'),
                  itemBuilder: (_) => [
                    NotedMenuItem.forCommand(undo),
                    NotedMenuItem.forCommand(off),
                    const NotedMenuDivider(),
                    NotedMenuItem.forCommand(del, destructive: true),
                  ],
                ),
              ),
            ),
          ),
        );
        await t.tap(find.byKey(const ValueKey('open')));
        await t.pumpAndSettle();
      }

      Color labelColor(WidgetTester t, String label) =>
          t.widget<Text>(find.text(label)).style!.color!;

      testWidgets('container: surface, 1px border, radius-lg, min width 220', (
        t,
      ) async {
        final theme = notedThemeData(brightness);
        await openMenu(t, theme);
        final material = t.widget<Material>(
          find
              .ancestor(
                of: find.byType(NotedMenuItem<String>).first,
                matching: find.byWidgetPredicate(
                  (w) => w is Material && w.shape is RoundedRectangleBorder,
                ),
              )
              .first,
        );
        final drawn = material.shape! as RoundedRectangleBorder;
        expect(drawn.borderRadius, BorderRadius.circular(8));
        expect(drawn.side.color, theme.colorScheme.outline);
        expect(material.color, theme.colorScheme.surface);
        // The theme's popup menu theme draws the container.
        final pm = theme.popupMenuTheme;
        expect(pm.color, theme.colorScheme.surface);
        final shape = pm.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, BorderRadius.circular(8));
        expect(shape.side.color, theme.colorScheme.outline);
        expect(shape.side.width, 1);
        expect(pm.menuPadding, const EdgeInsets.all(4));
        expect(pm.shadowColor, NotedMetrics.forBrightness(brightness).shadowPopover.first.color);
        expect(material.color ?? pm.color, theme.colorScheme.surface);
        final menuWidth = t.getSize(find.byType(NotedMenuItem<String>).first).width +
            2 * 4;
        expect(menuWidth, greaterThanOrEqualTo(220));
      });

      testWidgets('items: 32px, body text, shortcut column, separator', (
        t,
      ) async {
        await openMenu(t, notedThemeData(brightness));
        final item = find.byKey(const ValueKey('menu-undo'));
        expect(t.getSize(item).height, 32);
        expect(labelColor(t, 'Undo'), notedColorScheme(brightness).onSurface);
        expect(t.widget<Text>(find.text('Undo')).style!.fontSize, type.body.fontSize);
        // The shortcut is right-aligned in small, text-muted.
        final sc = find.descendant(
          of: item,
          matching: find.byKey(const ValueKey('menu-shortcut')),
        );
        expect(t.widget<Text>(sc).data, 'Ctrl+Z');
        expect(t.widget<Text>(sc).style!.color, notedColorScheme(brightness).onSurfaceVariant);
        expect(t.widget<Text>(sc).style!.fontSize, type.small.fontSize);
        expect(
          t.getRect(sc).right,
          closeTo(t.getRect(item).right - 10, 0.5),
          reason: 'right-aligned with the item padding',
        );
        // The separator is a 1px border-colored rule with space-1 margins.
        final divider = t.widget<Divider>(find.byType(Divider));
        expect(divider.color, notedColorScheme(brightness).outline);
        expect(divider.thickness, 1);
        expect(t.getSize(find.byType(NotedMenuDivider)).height, 1 + 2 * 4);
      });

      testWidgets('disabled is text-disabled; destructive is error', (t) async {
        await openMenu(t, notedThemeData(brightness));
        expect(labelColor(t, 'Not now'), colors.textDisabled);
        expect(labelColor(t, 'Delete page'), notedColorScheme(brightness).error);
        // A disabled item doesn't respond.
        await t.tap(find.text('Not now'));
        await t.pumpAndSettle();
        expect(find.text('Undo'), findsOneWidget, reason: 'menu still open');
      });

      testWidgets('on touch, items are 40px high', (t) async {
        await openMenu(t, notedThemeData(brightness, touch: true));
        expect(t.getSize(find.byKey(const ValueKey('menu-undo'))).height, 40);
      });

      testWidgets('choosing an item returns its value', (t) async {
        await openMenu(t, notedThemeData(brightness));
        await t.tap(find.text('Undo'));
        await t.pumpAndSettle();
        expect(find.text('Undo'), findsNothing);
      });
    });
  }

  for (final brightness in Brightness.values) {
    group('buttons in ${brightness.name} mode', () {
      final theme = notedThemeData(brightness);
      final scheme = theme.colorScheme;
      final colors = NotedColors.forBrightness(brightness);

      Future<void> pumpButtons(WidgetTester t, ThemeData theme) async {
        await t.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton(onPressed: () {}, child: const Text('Primary')),
                    OutlinedButton(
                      onPressed: () {},
                      child: const Text('Secondary'),
                    ),
                    TextButton(onPressed: () {}, child: const Text('Ghost')),
                    Builder(
                      builder: (context) => OutlinedButton(
                        style: notedDestructiveButtonStyle(context),
                        onPressed: () {},
                        child: const Text('Delete'),
                      ),
                    ),
                    const FilledButton(onPressed: null, child: Text('Off')),
                  ],
                ),
              ),
            ),
          ),
        );
      }

      Color fg(WidgetTester t, String text) =>
          DefaultTextStyle.of(t.element(find.text(text))).style.color!;

      testWidgets('36px high, radius-md, semibold body, padding 14', (t) async {
        await pumpButtons(t, theme);
        for (final label in ['Primary', 'Secondary', 'Ghost', 'Delete']) {
          final button = find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          );
          expect(t.getSize(button).height, 36, reason: label);
          final style = DefaultTextStyle.of(t.element(find.text(label))).style;
          expect(style.fontSize, 14);
          expect(style.fontWeight, FontWeight.w600);
        }
        final shape = theme.filledButtonTheme.style!.shape!.resolve({})!
            as RoundedRectangleBorder;
        expect(shape.borderRadius, BorderRadius.circular(6));
        expect(
          theme.filledButtonTheme.style!.padding!.resolve({}),
          const EdgeInsets.symmetric(horizontal: 14),
        );
      });

      testWidgets('primary, secondary, ghost and destructive colors', (t) async {
        await pumpButtons(t, theme);
        final f = theme.filledButtonTheme.style!;
        expect(f.backgroundColor!.resolve({}), scheme.primary);
        expect(fg(t, 'Primary'), scheme.onPrimary);
        final o = theme.outlinedButtonTheme.style!;
        expect(o.backgroundColor!.resolve({}), scheme.surface);
        expect(o.side!.resolve({})!.color, scheme.outline);
        expect(o.side!.resolve({})!.width, 1);
        expect(fg(t, 'Secondary'), scheme.onSurface);
        final g = theme.textButtonTheme.style!;
        expect(g.backgroundColor!.resolve({}), isNull);
        expect(g.side!.resolve({}), BorderSide.none);
        expect(g.overlayColor!.resolve({WidgetState.hovered}), colors.surfaceHover);
        expect(fg(t, 'Delete'), scheme.error);
        // Focus: a 2px accent outline.
        final focus = f.side!.resolve({WidgetState.focused})!;
        expect(focus.color, scheme.primary);
        expect(focus.width, 2);
        // Disabled: text-disabled.
        expect(fg(t, 'Off'), colors.textDisabled);
      });

      testWidgets('on touch, buttons are 44px high', (t) async {
        await pumpButtons(t, notedThemeData(brightness, touch: true));
        final button = find.ancestor(
          of: find.text('Primary'),
          matching: find.byType(FilledButton),
        );
        expect(t.getSize(button).height, 44);
      });
    });
  }
}
