// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The contextual right panel (UI shell, task 6): its states, and where it is at
// each window width.

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
    testWidgets('no selection: the page, its backgrounds, view controls, find and settings', (
      t,
    ) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      expect(_panel, findsOneWidget);
      expect(find.byKey(const ValueKey('panel-page-title')), findsOneWidget);
      for (final id in [
        'canvas.pageBackground.plain',
        'canvas.pageBackground.dots',
        'canvas.pageBackground.graph',
        'canvas.pageBackground.ruled',
        'canvas.zoomOut',
        'canvas.zoomReset',
        'canvas.zoomIn',
        'canvas.fitAll',
        'canvas.find',
        'app.page.settings',
      ]) {
        expect(find.byKey(ValueKey('panel-$id')), findsOneWidget, reason: id);
      }
      expect(
        find.byKey(const ValueKey('panel-canvas.showIssues')),
        findsNothing,
        reason: 'no issues',
      );
      expect(
        find.byKey(const ValueKey('panel-app.binder.settings')),
        findsNothing,
        reason: 'a standalone page',
      );
      expect(find.byKey(const ValueKey('panel-zoom-readout')), findsOneWidget);
      await w.close(t);
    });

    testWidgets('a focused panel control paints a 2px accent outline, and a press takes no focus', (
      t,
    ) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      final accent = Theme.of(t.element(find.byType(Scaffold).first)).colorScheme.primary;
      final zoomOut = find.byKey(const ValueKey('panel-canvas.zoomOut'));
      bool outlined() => t
          .widgetList<Material>(find.descendant(of: zoomOut, matching: find.byType(Material)))
          .any((m) {
            final s = m.shape;
            return s is OutlinedBorder && s.side.color == accent && s.side.width == 2;
          });
      expect(outlined(), isFalse);
      // A key press puts the focus highlight in keyboard mode.
      await t.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      Focus.of(t.element(find.descendant(of: zoomOut, matching: find.byType(Text)))).requestFocus();
      await t.pump();
      expect(outlined(), isTrue);
      // A pointer press on another control moves no focus (the canvas keeps it).
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      final before = FocusManager.instance.primaryFocus;
      await t.tap(find.byKey(const ValueKey('panel-canvas.zoomIn')));
      await _frames(t);
      expect(FocusManager.instance.primaryFocus, same(before));
      await w.close(t);
    });

    testWidgets(
      'the panel background control is the toolbar command: choosing Dots changes the page',
      (t) async {
        final w = await ShellWorld.open(t, size: const Size(1400, 800));
        await t.tap(find.byKey(const ValueKey('panel-canvas.pageBackground.dots')));
        await _frames(t);
        expect(w.nb.current!.page.meta.background, PageBackground.dots);
        await w.close(t);
      },
    );

    testWidgets(
      'one box: its type, arrange and delete; the panel follows a selection change within a frame',
      (t) async {
        final w = await ShellWorld.open(t, size: const Size(1400, 800));
        await w.addNote(t, 'a', 'one');
        await w.addNote(t, 'b', 'two', at: const Bounds(100, 300, 300, 40));
        final c = w.nb.current!;
        c.select('a');
        await t.pump();
        expect(find.byKey(const ValueKey('panel-box-type')), findsOneWidget);
        expect(t.widget<Text>(find.byKey(const ValueKey('panel-box-type'))).data, 'Note');
        for (final id in [
          'canvas.bringToFront',
          'canvas.bringForward',
          'canvas.sendBackward',
          'canvas.sendToBack',
          'canvas.delete',
        ]) {
          expect(find.byKey(ValueKey('panel-$id')), findsOneWidget, reason: id);
        }
        expect(find.byKey(const ValueKey('panel-canvas.zoomIn')), findsNothing);
        c.select('b');
        await t.pump();
        expect(find.byKey(const ValueKey('panel-box-type')), findsOneWidget);
        c.select(null);
        await t.pump();
        expect(find.byKey(const ValueKey('panel-box-type')), findsNothing);
        expect(find.byKey(const ValueKey('panel-page-title')), findsOneWidget);
        await w.close(t);
      },
    );

    testWidgets('a disallowed box says so and offers Delete only', (t) async {
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
      expect(find.byKey(const ValueKey('panel-not-allowed')), findsOneWidget);
      expect(
        t.widget<OutlinedButton>(find.byKey(const ValueKey('panel-canvas.delete'))).onPressed,
        isNotNull,
      );
      expect(
        t.widget<OutlinedButton>(find.byKey(const ValueKey('panel-canvas.bringToFront'))).onPressed,
        isNull,
      );
      await w.close(t);
    });

    testWidgets('a note being edited keeps its caret after Bring to front in the panel', (t) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      await w.addNote(t, 'a', 'hello brave new world');
      await w.addNote(t, 'b', 'other', at: const Bounds(100, 300, 300, 40));
      await w.editNote(t, 'a');
      final c = w.nb.current!;
      expect(c.editingId, 'a');
      await _frames(t);
      final before = noteSelection(t);
      expect(before, isNotNull);
      expect(
        find.byKey(const ValueKey('panel-box-type')),
        findsOneWidget,
        reason: 'a note being edited shows the box state',
      );
      await t.tap(find.byKey(const ValueKey('panel-canvas.bringToFront')));
      await _frames(t, 5);
      expect(c.editingId, 'a');
      expect(noteSelection(t), before, reason: 'the caret stayed');
      await w.close(t);
    });

    testWidgets('a read-only page: the same layout with every edit command off', (t) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      await w.addNote(t, 'a', 'one');
      final c = w.nb.current!;
      c.select('a');
      await t.pump();
      c.readOnly = true;
      await t.pump();
      expect(find.byKey(const ValueKey('panel-box-type')), findsOneWidget);
      expect(
        t.widget<OutlinedButton>(find.byKey(const ValueKey('panel-canvas.delete'))).onPressed,
        isNull,
      );
      expect(
        t.widget<OutlinedButton>(find.byKey(const ValueKey('panel-canvas.bringToFront'))).onPressed,
        isNull,
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
      expect(panel.width, 264);
      expect(panel.right, 1400);
      expect(
        t.getRect(find.byType(CommandToolbar)).right,
        1400,
        reason: 'the toolbar keeps its full width',
      );
      expect(panel.top, greaterThanOrEqualTo(t.getRect(find.byType(CommandToolbar)).bottom));
      await w.close(t);
    });

    testWidgets('View > Contextual panel hides and shows the inline panel', (t) async {
      final w = await ShellWorld.open(t, size: const Size(1400, 800));
      await _menu(t, 'View', 'app.view.panel');
      expect(_panel, findsNothing);
      await _menu(t, 'View', 'app.view.panel');
      expect(_panel, findsOneWidget);
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
          await w.close(t);
        },
      );
    }
  });
}
