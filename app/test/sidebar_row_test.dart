// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The SidebarRow guidelines (docs/design/components/SidebarRow): every row
// state, in both themes, and the touch sizes.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/sidebar_row.dart';
import 'package:noted_canvas/noted_canvas.dart';

void main() {
  for (final brightness in Brightness.values) {
    group('in ${brightness.name} mode', () {
      final theme = notedThemeData(brightness);
      final scheme = theme.colorScheme;
      final colors = NotedColors.forBrightness(brightness);
      final m = NotedMetrics.forBrightness(brightness);
      final type = NotedTypography.withColor(scheme.onSurface);

      Future<void> pump(
        WidgetTester t,
        List<Widget> children, {
        bool touch = false,
      }) async {
        await t.pumpWidget(
          MaterialApp(
            theme: touch ? notedThemeData(brightness, touch: true) : theme,
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: m.sidebarWidth,
                  child: ColoredBox(
                    color: colors.bgSidebar,
                    child: Column(children: children),
                  ),
                ),
              ),
            ),
          ),
        );
      }

      Material material(WidgetTester t, Finder row) => t.widget<Material>(
        find
            .descendant(
              of: row,
              matching: find.byWidgetPredicate(
                (w) => w is Material && w.borderRadius != null,
              ),
            )
            .first,
      );

      TextStyle titleStyle(WidgetTester t, String title) =>
          t.widget<Text>(find.text(title)).style!;

      testWidgets('normal row: 32px, radius-md, body in text', (t) async {
        await pump(t, [const SidebarRow(key: ValueKey('r'), title: 'Notes')]);
        final row = find.byKey(const ValueKey('r'));
        expect(t.getSize(row).height, 32);
        final mat = material(t, row);
        expect(mat.borderRadius, m.borderMd);
        expect(mat.color, Colors.transparent);
        final s = titleStyle(t, 'Notes');
        expect(s.color, scheme.onSurface);
        expect(s.fontSize, type.body.fontSize);
        expect(s.fontWeight, type.body.fontWeight);
        // Hover fills surface-hover.
        expect(
          t.widget<InkWell>(find.descendant(of: row, matching: find.byType(InkWell))).hoverColor,
          colors.surfaceHover,
        );
        final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: t.getCenter(row));
        await t.pump();
        expect(t.takeException(), isNull);
      });

      testWidgets('active row: accent-soft fill, body-strong accent', (t) async {
        await pump(t, [
          const SidebarRow(key: ValueKey('r'), title: 'Open', selected: true),
        ]);
        expect(material(t, find.byKey(const ValueKey('r'))).color, scheme.primaryContainer);
        final s = titleStyle(t, 'Open');
        expect(s.color, scheme.primary);
        expect(s.fontWeight, type.bodyStrong.fontWeight);
        expect(s.fontWeight, FontWeight.w600);
      });

      testWidgets('indent is 20px per level', (t) async {
        await pump(t, [
          const SidebarRow(title: 'L0'),
          const SidebarRow(title: 'L1', depth: 1),
          const SidebarRow(title: 'L2', depth: 2),
        ]);
        final x0 = t.getTopLeft(find.text('L0')).dx;
        final x1 = t.getTopLeft(find.text('L1')).dx;
        final x2 = t.getTopLeft(find.text('L2')).dx;
        expect(x1 - x0, 20);
        expect(x2 - x1, 20);
        // Padding space-2 plus the list margin.
        expect(x0, m.space1 + m.space2 + 20);
      });

      testWidgets('divider: a chevron in text-muted before the title', (t) async {
        var collapsed = false;
        var toggles = 0;
        await pump(t, [
          StatefulBuilder(
            builder: (context, set) => SidebarRow(
              title: 'Divider',
              chevron: SidebarChevron(
                collapsed: collapsed,
                onPressed: () {
                  toggles++;
                  set(() => collapsed = !collapsed);
                },
              ),
            ),
          ),
          const SidebarRow(title: 'Plain'),
        ]);
        final chevron = find.byType(SidebarChevron);
        final icon = t.widget<Icon>(
          find.descendant(of: chevron, matching: find.byType(Icon)),
        );
        expect(icon.icon, Icons.expand_more_rounded);
        expect(icon.color, scheme.onSurfaceVariant);
        expect(icon.size, m.icon);
        expect(t.getRect(chevron).right, lessThanOrEqualTo(t.getTopLeft(find.text('Divider')).dx));
        // Plain pages line up with dividers.
        expect(
          t.getTopLeft(find.text('Divider')).dx,
          t.getTopLeft(find.text('Plain')).dx,
        );
        await t.tap(chevron);
        await t.pump();
        expect(toggles, 1);
        expect(
          t.widget<Icon>(find.descendant(of: chevron, matching: find.byType(Icon))).icon,
          Icons.chevron_right_rounded,
        );
        // It's still a page: the title style is the same.
        expect(titleStyle(t, 'Divider').fontWeight, type.body.fontWeight);
      });

      testWidgets('conflict: an 8px conflict dot, labelled for screen readers', (
        t,
      ) async {
        final handle = t.ensureSemantics();
        await pump(t, [
          const SidebarRow(
            key: ValueKey('r'),
            title: 'Clash',
            conflict: true,
            conflictKey: ValueKey('dot'),
          ),
        ]);
        final dot = find.byKey(const ValueKey('dot'));
        expect(t.getSize(dot), const Size(8, 8));
        final d = t.widget<Container>(dot).decoration! as BoxDecoration;
        expect(d.color, colors.conflict);
        expect(d.shape, BoxShape.circle);
        expect(find.bySemanticsLabel(RegExp('Has a conflict')), findsOneWidget);
        // At the right edge of the row.
        final row = t.getRect(find.byKey(const ValueKey('r')));
        expect(row.right - t.getRect(dot).right, lessThanOrEqualTo(m.space4));
        handle.dispose();
      });

      testWidgets('unavailable: text-disabled with a small status line', (
        t,
      ) async {
        await pump(t, [
          const SidebarGroupHeader(
            key: ValueKey('away'),
            title: 'Archive',
            disabled: true,
            status: 'On another device',
          ),
          const SidebarGroupHeader(
            key: ValueKey('bad'),
            title: 'Broken',
            disabled: true,
            status: "Binder file can't be read",
          ),
          const SidebarRow(
            title: 'Old page',
            disabled: true,
            status: 'On another device',
          ),
        ]);
        expect(titleStyle(t, 'ARCHIVE').color, colors.textDisabled);
        expect(titleStyle(t, 'Old page').color, colors.textDisabled);
        final status = t.widget<Text>(find.text("Binder file can't be read")).style!;
        expect(status.fontSize, type.small.fontSize);
        expect(status.color, colors.textDisabled);
        expect(find.text('On another device'), findsNWidgets(2));
        // The chip is grey too: not a binder color.
        final chip = t.widget<Container>(
          find.descendant(
            of: find.byKey(const ValueKey('away')),
            matching: find.byType(Container),
          ).first,
        );
        expect((chip.decoration! as BoxDecoration).color, colors.textDisabled);
      });

      testWidgets('group header: uppercase label, 8px chip in the binder color', (
        t,
      ) async {
        await pump(t, [
          SidebarGroupHeader(
            title: 'Project plans',
            chipColor: colors.binderTeal,
            chipKey: const ValueKey('chip'),
          ),
          const SidebarGroupHeader(title: 'Pages', chipKey: ValueKey('loose')),
        ]);
        final label = t.widget<Text>(find.text('PROJECT PLANS'));
        expect(label.style!.color, scheme.onSurfaceVariant);
        expect(label.style!.fontSize, type.label.fontSize);
        expect(label.style!.fontWeight, type.label.fontWeight);
        expect(find.text('Project plans'), findsNothing);
        final chip = find.byKey(const ValueKey('chip'));
        expect(t.getSize(chip), const Size(8, 8));
        final deco = t.widget<Container>(chip).decoration! as BoxDecoration;
        expect(deco.color, colors.binderTeal);
        expect(deco.borderRadius, m.borderSm);
        // Loose pages: a text-muted chip.
        expect(
          (t.widget<Container>(find.byKey(const ValueKey('loose'))).decoration!
                  as BoxDecoration)
              .color,
          scheme.onSurfaceVariant,
        );
        expect(find.text('PAGES'), findsOneWidget);
      });

      testWidgets('on touch, rows are 40px', (t) async {
        await pump(t, [
          const SidebarRow(key: ValueKey('r'), title: 'Notes'),
          const SidebarGroupHeader(key: ValueKey('h'), title: 'Pages'),
        ], touch: true);
        expect(t.getSize(find.byKey(const ValueKey('r'))).height, 40);
        expect(
          t.getSize(find.descendant(of: find.byKey(const ValueKey('h')), matching: find.byType(InkWell))).height,
          40,
        );
      });
    });
  }
}
