// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The contextual right panel (UI shell, task 6): its states, and where it is at
// each window width.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/shell_world.dart';

final _panel = find.byKey(const ValueKey('context-panel'));

Future<void> _frames(WidgetTester t, [int n = 3]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _menu(WidgetTester t, String top, String id) async {
  await t.tap(find.byKey(ValueKey('menu-top-$top')));
  // Not pumpAndSettle: a note being edited blinks its caret for ever.
  await _frames(t, 4);
  await t.tap(find.byKey(ValueKey('menu-$id')));

  await _frames(t, 4);
}

void main() {
  group('states', () {
    testWidgets('no selection: Page header, title, background dropdown, Page settings, Fit all', (
      t,
    ) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      expect(_panel, findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('panel-header-title'))).data, 'Page');
      // Top to bottom.
      final ys = [
        for (final k in [
          'panel-page-title',
          'panel-background-dropdown',
          'panel-app.page.settings',
          'panel-canvas.fitAll',
        ])
          t.getTopLeft(find.byKey(ValueKey(k))).dy,
      ];
      expect([...ys]..sort(), ys, reason: 'in order');
      expect(find.byKey(const ValueKey('panel-binder-name')), findsNothing, reason: 'standalone');
      // The rows the spec moved out of the panel.
      for (final id in [
        'canvas.zoomOut',
        'canvas.zoomReset',
        'canvas.zoomIn',
        'canvas.find',
        'canvas.showIssues',
        'app.binder.settings',
        'canvas.pageBackground.dots',
      ]) {
        expect(find.byKey(ValueKey('panel-$id')), findsNothing, reason: id);
      }
      expect(find.byKey(const ValueKey('panel-zoom-readout')), findsNothing);
      expect(find.byKey(const ValueKey('panel-read-only-card')), findsNothing);
      await w.close(t);
    });

    testWidgets('a page in a binder names the binder', (t) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      await w.addBinderWithPage(t, 'Work', open: true);
      await w.settle(t);
      expect(t.widget<Text>(find.byKey(const ValueKey('panel-binder-name'))).data, 'Work');
      await w.close(t);
    });

    testWidgets('the header is 48 high with a 36 px Close at the trailing edge', (t) async {
      final w = await ShellWorld.open(t, size: const Size(1100, 800));
      await _menu(t, 'View', 'app.view.panel');
      final header = find
          .ancestor(
            of: find.byKey(const ValueKey('panel-header-title')),
            matching: find.byType(SizedBox),
          )
          .first;
      expect(t.getSize(header).height, 48);
      final close = find.byKey(const ValueKey('context-panel-close'));
      expect(t.getSize(close), const Size(36, 36));
      expect(t.getRect(close).right, t.getRect(_panel).right - 8);
      await w.close(t);
    });

    testWidgets('a focused panel control paints a 2px accent outline, and a press takes no focus', (
      t,
    ) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      final accent = Theme.of(t.element(find.byType(Scaffold).first)).colorScheme.primary;
      final fit = find.byKey(const ValueKey('panel-canvas.fitAll'));
      bool outlined() => t
          .widgetList<Material>(find.descendant(of: fit, matching: find.byType(Material)))
          .any((m) {
            final s = m.shape;
            return s is OutlinedBorder && s.side.color == accent && s.side.width == 2;
          });
      expect(outlined(), isFalse);
      // A key press puts the focus highlight in keyboard mode.
      await t.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      Focus.of(t.element(find.descendant(of: fit, matching: find.byType(Text)))).requestFocus();
      await t.pump();
      expect(outlined(), isTrue);
      // A pointer press on another control moves no focus (the canvas keeps it).
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      final before = FocusManager.instance.primaryFocus;
      await t.tap(find.byKey(const ValueKey('panel-canvas.fitAll')));
      await _frames(t);
      expect(FocusManager.instance.primaryFocus, same(before));
      await w.close(t);
    });

    testWidgets('actions are outlined with outline-control', (t) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      final colors = NotedColors.of(t.element(find.byType(Scaffold).first));
      final fit = find.byKey(const ValueKey('panel-canvas.fitAll'));
      final outlined = t
          .widgetList<Material>(find.descendant(of: fit, matching: find.byType(Material)))
          .any((m) {
            final s = m.shape;
            return s is OutlinedBorder && s.side.color == colors.outlineControl && s.side.width == 1;
          });
      expect(outlined, isTrue);
      await w.close(t);
    });

    testWidgets(
      'the background dropdown shows the checked choice; picking Graph runs the command once',
      (t) async {
        final w = await ShellWorld.open(t, size: const Size(1400, 800));
        final c = w.nb.current!;
        final current = find.byKey(const ValueKey('panel-background-current'));
        expect(t.widget<Text>(current).data, pageBackgroundLabel(c.page.meta.background));
        c.setBackground(PageBackground.dots);
        await t.pump();
        expect(t.widget<Text>(current).data, pageBackgroundLabel(PageBackground.dots));
        // The four choices are not rows of the panel until it opens.
        expect(find.byKey(const ValueKey('menu-canvas.pageBackground.graph')), findsNothing);
        await t.tap(find.byKey(const ValueKey('panel-background-dropdown')));
        await _frames(t, 4);
        final labels = [
          for (final b in PageBackground.values)
            t
                .widget<NotedMenuItem<String>>(
                  find.byKey(ValueKey('menu-canvas.pageBackground.${b.name}')),
                )
                .label,
        ];
        expect(labels, [for (final b in PageBackground.values) pageBackgroundLabel(b)]);
        expect(PageBackground.values.map((b) => b.name).toList(), ['plain', 'dots', 'graph', 'ruled']);
        await t.tap(find.byKey(const ValueKey('menu-canvas.pageBackground.graph')));
        await _frames(t, 4);
        expect(c.page.meta.background, PageBackground.graph);
        expect(t.widget<Text>(current).data, pageBackgroundLabel(PageBackground.graph));
        await t.pump(const Duration(milliseconds: 500));
        expect(
          find.byKey(const ValueKey('menu-canvas.pageBackground.graph')),
          findsNothing,
          reason: 'closed',
        );
        // One command run: one undo step back to Dots.
        c.undo();
        await t.pump();
        expect(c.page.meta.background, PageBackground.dots);
        await w.close(t);
      },
    );

    testWidgets('one Note: header, the 2x2 Arrange grid in row-major order, a separator, Delete box', (
      t,
    ) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      await w.addNote(t, 'a', 'one');
      await w.addNote(t, 'b', 'two', at: const Bounds(100, 300, 300, 40));
      final c = w.nb.current!;
      c.select('a');
      await t.pump();
      expect(t.widget<Text>(find.byKey(const ValueKey('panel-header-title'))).data, 'Note box');
      Offset at(String id) => t.getTopLeft(find.byKey(ValueKey('panel-$id')));
      final front = at('canvas.bringToFront');
      final forward = at('canvas.bringForward');
      final back = at('canvas.sendToBack');
      final backward = at('canvas.sendBackward');
      expect(forward.dy, front.dy);
      expect(forward.dx, greaterThan(front.dx));
      expect(back.dy, greaterThan(front.dy));
      expect(backward.dy, back.dy);
      expect(backward.dx, forward.dx);
      expect(back.dx, front.dx);
      final sep = t.getTopLeft(find.byKey(const ValueKey('panel-separator'))).dy;
      expect(sep, greaterThan(back.dy));
      expect(at('canvas.delete').dy, greaterThan(sep));
      expect(
        t.widget<TextButton>(find.byKey(const ValueKey('panel-canvas.delete'))).onPressed,
        isNotNull,
      );
      // The page's rows are gone.
      expect(find.byKey(const ValueKey('panel-background-dropdown')), findsNothing);
      expect(find.byKey(const ValueKey('panel-canvas.fitAll')), findsNothing);
      c.select(null);
      await t.pump();
      expect(t.widget<Text>(find.byKey(const ValueKey('panel-header-title'))).data, 'Page');
      await w.close(t);
    });

    testWidgets('the grid enables each cell from canRestack', (t) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      await w.addNote(t, 'a', 'one');
      await w.addNote(t, 'b', 'two', at: const Bounds(150, 110, 300, 40));
      final c = w.nb.current!;
      bool on(String id) => t.widget<OutlinedButton>(find.byKey(ValueKey('panel-$id'))).onPressed != null;
      // 'b' is on top.
      c.select('b');
      await t.pump();
      expect(c.canRestack('b', StackMove.front), isFalse);
      expect(on('canvas.bringToFront'), isFalse);
      expect(on('canvas.bringForward'), isFalse);
      expect(on('canvas.sendToBack'), isTrue);
      expect(on('canvas.sendBackward'), isTrue);
      c.select('a');
      await t.pump();
      expect(on('canvas.bringToFront'), isTrue);
      expect(on('canvas.bringForward'), isTrue);
      expect(on('canvas.sendToBack'), isFalse);
      expect(on('canvas.sendBackward'), isFalse);
      await t.tap(find.byKey(const ValueKey('panel-canvas.bringToFront')));
      await _frames(t);
      expect(c.canRestack('a', StackMove.front), isFalse);
      await w.close(t);
    });

    testWidgets('a Drawing says Drawing box and has the same Arrange grid', (t) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      final c = w.nb.current!;
      c.insertBox(
        BoxRecord.create(
          id: 'd',
          typeId: 'noted.drawing',
          dataVersion: 1,
          bounds: const Bounds(100, 100, 200, 100),
          data: RawJson.parse('{}'),
          snapshotText: '',
          rev: 'r',
        ),
      );
      c.select('d');
      await t.pump();
      expect(t.widget<Text>(find.byKey(const ValueKey('panel-header-title'))).data, 'Drawing box');
      expect(find.byKey(const ValueKey('panel-canvas.sendToBack')), findsOneWidget);
      await w.close(t);
    });

    testWidgets('a disallowed box: header Box, Delete box only, no type data', (t) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      final b = await w.addBinderWithPage(t, 'Work', open: true);
      final c = w.nb.current!;
      // A drawing box whose type the binder then disallows (its data is never
      // decoded once it is off).
      c.insertBox(
        BoxRecord.create(
          id: 'd',
          typeId: 'noted.drawing',
          dataVersion: 1,
          bounds: const Bounds(100, 100, 200, 100),
          data: RawJson.parse('{}'),
          snapshotText: '',
          rev: 'r',
        ),
      );
      await t.runAsync(() async {
        await w.nb.setBinderBoxType(b.path, 'noted.drawing', false);
        for (
          var i = 0;
          i < 100 && w.nb.boxTypeAvailabilityFor(w.nb.currentId!, 'noted.drawing').allowed;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await w.settle(t);
      c.select('d');
      await t.pump();
      expect(t.widget<Text>(find.byKey(const ValueKey('panel-header-title'))).data, 'Box');
      expect(
        t.widget<TextButton>(find.byKey(const ValueKey('panel-canvas.delete'))).onPressed,
        isNotNull,
      );
      for (final id in [
        'canvas.bringToFront',
        'canvas.bringForward',
        'canvas.sendBackward',
        'canvas.sendToBack',
      ]) {
        expect(find.byKey(ValueKey('panel-$id')), findsNothing, reason: id);
      }
      expect(find.byKey(const ValueKey('panel-not-allowed')), findsNothing);
      expect(find.text('Drawing'), findsNothing, reason: 'no type data');
      await w.close(t);
    });

    testWidgets('while a note is being edited, Arrange and Delete are disabled and the caret is kept', (
      t,
    ) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      await w.addNote(t, 'a', 'hello brave new world');
      await w.addNote(t, 'b', 'other', at: const Bounds(100, 300, 300, 40));
      await w.editNote(t, 'a');
      final c = w.nb.current!;
      expect(c.editingId, 'a');
      await _frames(t);
      final before = noteSelection(t);
      expect(before, isNotNull);
      expect(t.widget<Text>(find.byKey(const ValueKey('panel-header-title'))).data, 'Note box');
      for (final id in [
        'canvas.bringToFront',
        'canvas.bringForward',
        'canvas.sendToBack',
        'canvas.sendBackward',
      ]) {
        expect(
          t.widget<OutlinedButton>(find.byKey(ValueKey('panel-$id'))).onPressed,
          isNull,
          reason: id,
        );
      }
      expect(
        t.widget<TextButton>(find.byKey(const ValueKey('panel-canvas.delete'))).onPressed,
        isNull,
      );
      await t.tap(find.byKey(const ValueKey('panel-canvas.bringToFront')), warnIfMissed: false);
      await _frames(t, 5);
      expect(c.editingId, 'a');
      expect(noteSelection(t), before, reason: 'the caret stayed');
      await w.close(t);
    });

    testWidgets('a read-only page: the card, Find on page and Fit all, and no mutating widget', (
      t,
    ) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      await w.addNote(t, 'a', 'one');
      final c = w.nb.current!;
      c.select('a');
      await t.pump();
      c.readOnly = true;
      await t.pump();
      // Page, whatever was selected.
      expect(t.widget<Text>(find.byKey(const ValueKey('panel-header-title'))).data, 'Page');
      expect(find.byKey(const ValueKey('panel-page-title')), findsOneWidget);
      final card = find.byKey(const ValueKey('panel-read-only-card'));
      expect(card, findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Read-only')), findsOneWidget);
      final fill = t.widget<DecoratedBox>(card).decoration as BoxDecoration;
      expect(fill.color, NotedColors.of(t.element(card)).conflictSoft);
      expect(fill.borderRadius, NotedMetrics.of(t.element(card)).borderMd);
      final findAt = t.getTopLeft(find.byKey(const ValueKey('panel-canvas.find')));
      final fitAt = t.getTopLeft(find.byKey(const ValueKey('panel-canvas.fitAll')));
      expect(findAt.dy, lessThan(fitAt.dy));
      expect(t.getTopLeft(card).dy, lessThan(findAt.dy));
      expect(
        t.widget<OutlinedButton>(find.byKey(const ValueKey('panel-canvas.find'))).onPressed,
        isNotNull,
      );
      expect(
        t.widget<OutlinedButton>(find.byKey(const ValueKey('panel-canvas.fitAll'))).onPressed,
        isNotNull,
      );
      // No mutating row at all, not merely disabled.
      for (final id in [
        'canvas.bringToFront',
        'canvas.bringForward',
        'canvas.sendToBack',
        'canvas.sendBackward',
        'canvas.delete',
        'app.page.settings',
        'canvas.pageBackground.dots',
      ]) {
        expect(find.byKey(ValueKey('panel-$id')), findsNothing, reason: id);
      }
      expect(find.byKey(const ValueKey('panel-background-dropdown')), findsNothing);
      await w.close(t);
    });

    testWidgets('the read-only card carries the same reason as the banner', (t) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      final id = w.nb.currentId!;
      final file = '${w.nb.folderOfPage(id)}/$id.canvas';
      await t.runAsync(() async {
        // The open page's file turns unreadable: the notebook blocks the page.
        File(file).writeAsStringSync('not a page');
        await w.nb.checkFile(file);
      });
      await w.settle(t);
      final reason = w.nb.readOnlyReason;
      expect(reason, isNotNull);
      expect(
        t.widget<Text>(find.byKey(const ValueKey('panel-read-only-reason'))).data,
        reason,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('read-only-banner')),
          matching: find.text(reason!),
        ),
        findsOneWidget,
      );
      await w.close(t);
    });

    testWidgets('a page change shows the new page', (t) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      expect(t.widget<Text>(find.byKey(const ValueKey('panel-page-title'))).data, 'Alpha');
      await w.openPage(t, w.second);
      await w.settle(t);
      expect(t.widget<Text>(find.byKey(const ValueKey('panel-page-title'))).data, 'Beta');
      await w.close(t);
    });

    testWidgets('the cover has no panel', (t) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      final b = await w.addBinderWithPage(t, 'Work');
      w.nb.showCover(b.path);
      await w.settle(t);
      expect(_panel, findsNothing);
      await w.close(t);
    });
  });

  group('width', () {
    testWidgets('at 1400 px the panel is inline, right of the canvas, below the toolbar', (
      t,
    ) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      final panel = t.getRect(_panel);
      expect(panel.width, 288);
      expect(panel.right, 1400);
      expect(
        t.getRect(find.byType(CommandToolbar)).right,
        1400,
        reason: 'the toolbar keeps its full width',
      );
      expect(panel.top, greaterThanOrEqualTo(t.getRect(find.byType(CommandToolbar)).bottom));
      await w.close(t);
    });

    testWidgets('the docked panel has a Close x that closes it and returns the focus', (t) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      await w.addNote(t, 'a', 'hello');
      await w.editNote(t, 'a');
      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNotNull);
      await t.tap(find.byKey(const ValueKey('context-panel-close')));
      await _frames(t, 4);
      expect(_panel, findsNothing);
      expect(FocusManager.instance.primaryFocus, same(focused), reason: 'focus returned to the editor');
      await _menu(t, 'View', 'app.view.panel');
      expect(_panel, findsOneWidget, reason: 'it opens again');
      await w.close(t);
    });

    testWidgets('View > Details hides and shows the inline panel', (t) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      await _menu(t, 'View', 'app.view.panel');
      expect(_panel, findsNothing);
      await _menu(t, 'View', 'app.view.panel');
      expect(_panel, findsOneWidget);
      await w.close(t);
    });

    testWidgets('the overlay is 288 px wide over a 16% scrim, and 1120 px docks it', (t) async {
      var w = await ShellWorld.open(t, size: const Size(1100, 800));
      await _menu(t, 'View', 'app.view.panel');
      expect(t.getSize(_panel).width, 288);
      final scrim = t.widget<ColoredBox>(
        find.descendant(
          of: find.byKey(const ValueKey('context-panel-scrim')),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(scrim.color, const Color(0x29000000));
      await w.close(t);
      w = await ShellWorld.open(t, size: const Size(1120, 800));
      expect(_panel, findsOneWidget, reason: 'docked from the breakpoint');
      await w.close(t);
    });

    for (final width in [1100.0, 900.0]) {
      testWidgets(
        'at ${width.toInt()} px it is hidden; the overlay opens from View, Escape and the scrim close it, and focus returns',
        (t) async {
          final w = await ShellWorld.open(t, size: Size(width, 800));
          expect(_panel, findsNothing);
          await w.addNote(t, 'a', 'hello');
          await w.editNote(t, 'a');
          final focused = FocusManager.instance.primaryFocus;
          await _menu(t, 'View', 'app.view.panel');
          expect(_panel, findsOneWidget);
          expect(find.byKey(const ValueKey('context-panel-scrim')), findsOneWidget);
          await t.sendKeyEvent(LogicalKeyboardKey.escape);
          await _frames(t, 4);
          expect(_panel, findsNothing);
          expect(
            FocusManager.instance.primaryFocus,
            same(focused),
            reason: 'focus returned to the editor',
          );
          await _menu(t, 'View', 'app.view.panel');
          expect(_panel, findsOneWidget);
          await t.tapAt(const Offset(500, 400));
          await _frames(t, 4);
          expect(_panel, findsNothing);
          await _menu(t, 'View', 'app.view.panel');
          await t.tap(find.byKey(const ValueKey('context-panel-close')));
          await _frames(t, 4);
          expect(_panel, findsNothing);
          expect(FocusManager.instance.primaryFocus, same(focused), reason: 'Close returns focus');
          await w.close(t);
        },
      );
    }
  });
}
