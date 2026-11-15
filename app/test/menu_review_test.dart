// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Review fixes for the UI shell: the bar leaves a dialog's keys alone, its
// check marks follow the app commands, and the panel overlay moves its hold
// with the controller.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/context_panel.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/shell_world.dart';

Future<void> _frames(WidgetTester t, [int n = 4]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _keysThatEnterTheBar(WidgetTester t) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await _frames(t);
  await t.sendKeyEvent(LogicalKeyboardKey.f10);
  await _frames(t);
  await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await t.sendKeyEvent(LogicalKeyboardKey.keyF);
  await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await _frames(t);
}

void main() {
  for (final viaHelp in [false, true]) {
    testWidgets('a modal ${viaHelp ? 'Keyboard shortcuts dialog' : 'dialog'}: F10, a lone Alt and Alt+F go to it, not the bar',
        (t) async {
      final w = await ShellWorld.open(t);
      final c = w.nb.current!;
      if (viaHelp) {
        await t.tap(find.byKey(const ValueKey('menu-top-Help')));
        await _frames(t);
        await t.tap(find.byKey(const ValueKey('menu-app.help.shortcuts')));
        await _frames(t, 6);
      } else {
        showDialog<void>(
          context: t.element(find.byType(Scaffold).first),
          builder: (_) => const AlertDialog(content: Text('hi')),
        );
        await _frames(t);
      }
      expect(find.byType(AlertDialog), findsOneWidget);
      final focus = FocusManager.instance.primaryFocus;
      await _keysThatEnterTheBar(t);
      expect(c.editorFocusHold.count, 0);
      expect(w.bar(t).holding, isFalse);
      expect(find.byKey(const ValueKey('menu-app.page.new')), findsNothing, reason: 'no menu opened');
      expect(FocusManager.instance.primaryFocus, same(focus), reason: 'the focus stays in the dialog');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(t, 6);
      expect(find.byType(AlertDialog), findsNothing, reason: 'Escape closed the dialog');
      await w.close(t);
    });
  }

  testWidgets('View > Contextual panel is checked while the panel shows, and follows the toggle', (t) async {
    final w = await ShellWorld.open(t);
    bool checked() => t
        .widget<MenuCheckMark>(
          find.descendant(
            of: find.byKey(const ValueKey('menu-app.view.panel')),
            matching: find.byType(MenuCheckMark),
          ),
        )
        .checked;
    await t.tap(find.byKey(const ValueKey('menu-top-View')));
    await _frames(t);
    expect(checked(), isTrue, reason: 'inline at 1280 px');
    await t.tap(find.byKey(const ValueKey('menu-app.view.panel')));
    await _frames(t, 6);
    await t.tap(find.byKey(const ValueKey('menu-top-View')));
    await _frames(t);
    expect(checked(), isFalse);
    // Chosen with the menu still open it redraws as well.
    await t.tap(find.byKey(const ValueKey('menu-app.view.panel')));
    await _frames(t, 6);
    await t.tap(find.byKey(const ValueKey('menu-top-View')));
    await _frames(t);
    expect(checked(), isTrue);
    await w.close(t);
  });

  testWidgets('the panel overlay moves its hold when the controller changes (A released, B held)', (t) async {
    final w = await ShellWorld.open(t);
    final registry = ValueNotifier<CommandRegistry?>(null);
    CanvasController make(String id) => CanvasController(
      NotedPage.create(PageMeta.create(id: id, title: '', order: 0)),
      w.nb.current!.modules,
    );
    final a = make('a');
    final b = make('b');
    addTearDown(() {
      a.dispose();
      b.dispose();
      registry.dispose();
    });
    Widget overlay(CanvasController c) => MaterialApp(
      home: Scaffold(
        body: ContextPanelOverlay(
          notebook: w.nb,
          controller: c,
          registry: registry,
          onClose: () {},
          focusCanvas: () {},
        ),
      ),
    );
    await t.pumpWidget(overlay(a));
    expect(a.editorFocusHold.count, 1);
    await t.pumpWidget(overlay(b));
    expect(a.editorFocusHold.count, 0, reason: 'A released');
    expect(b.editorFocusHold.count, 1, reason: 'B held');
    await t.pumpWidget(const SizedBox());
    await _frames(t, 4);
    expect(b.editorFocusHold.count, 0, reason: 'the controller it held is released');
    expect(a.editorFocusHold.count, 0);
    await t.pumpWidget(const SizedBox());
    await w.close(t);
  });
}
