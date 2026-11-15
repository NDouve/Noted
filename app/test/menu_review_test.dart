// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Review fixes for the UI shell: the bar leaves a dialog's keys alone, its
// check marks follow the app commands, and the panel overlay moves its hold
// with the controller.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/app_settings.dart';
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

  testWidgets('View > Details is checked while the panel shows, and follows the toggle', (t) async {
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
    final registry = CommandRegistry();
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

  testWidgets('the focus ring is a 2px accent border in Precision too', (t) async {
    final w = await ShellWorld.open(t);
    w.settings.theme = ThemeSetting.dark;
    await _frames(t);
    final accent = DesignColors.dark.accent;
    await t.sendKeyEvent(LogicalKeyboardKey.f10);
    await _frames(t);
    final ring = t
        .widgetList<DecoratedBox>(find.ancestor(of: find.byKey(const ValueKey('menu-top-File')), matching: find.byType(DecoratedBox)))
        .firstWhere((d) => d.position == DecorationPosition.foreground && (d.decoration as BoxDecoration).border != null);

    final border = (ring.decoration as BoxDecoration).border! as Border;
    expect(border.top.width, 2);
    expect(border.top.color, accent);
    expect(border.top.color.a, 1.0);
    expect(contrastRatio(accent, DesignColors.dark.bgApp), greaterThanOrEqualTo(3));
    await w.close(t);
  });

  testWidgets('the overlay panel and its scrim start below the toolbar', (t) async {
    final w = await ShellWorld.open(t, size: const Size(1100, 800));
    await t.tap(find.byKey(const ValueKey('menu-top-View')));
    await _frames(t);
    await t.tap(find.byKey(const ValueKey('menu-app.view.panel')));
    await _frames(t, 6);
    final toolbarBottom = t.getRect(find.byType(CommandToolbar)).bottom;
    expect(t.getRect(find.byKey(const ValueKey('context-panel-overlay'))).top, greaterThanOrEqualTo(toolbarBottom));
    expect(t.getRect(find.byKey(const ValueKey('context-panel-scrim'))).top, greaterThanOrEqualTo(toolbarBottom));
    await w.close(t);
  });

  testWidgets('items of a menu with a checkable item share the leading column, checked or not', (t) async {
    final w = await ShellWorld.open(t);
    await t.tap(find.byKey(const ValueKey('menu-top-View')));
    await _frames(t);
    double left(String id) => t.getTopLeft(find.descendant(of: find.byKey(ValueKey('menu-$id')), matching: find.byType(Text)).first).dx;
    final plain = left('canvas.zoomIn');
    expect(left('app.view.panel'), plain, reason: 'the label of a checkable item lines up with the others');
    await t.tap(find.byKey(const ValueKey('menu-app.view.panel')));
    await _frames(t, 6);
    await t.tap(find.byKey(const ValueKey('menu-top-View')));
    await _frames(t);
    expect(left('app.view.panel'), plain, reason: 'and stays there unchecked');
    await w.close(t);
  });

  bool within(WidgetTester t, Finder root) {
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus == null) return false;
    final rootElement = t.element(root);
    var found = false;
    focus.visitAncestorElements((e) {
      if (identical(e, rootElement)) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  for (final (_, rights, sub, first) in [
    ('File', 0, 'Page', 'app.page.newSubpage'),
    ('View', 2, 'Appearance', 'app.theme.system'),
  ]) {
    testWidgets('keyboard: F10, Down to $sub, Right opens it with its first item focused; Escape closes one level', (t) async {
      final w = await ShellWorld.open(t);
      await t.sendKeyEvent(LogicalKeyboardKey.f10);
      await _frames(t);
      for (var i = 0; i < rights; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await _frames(t, 1);
      }
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _frames(t);
      final subFinder = find.byKey(ValueKey('menu-sub-$sub'));
      for (var i = 0; i < 20 && !within(t, subFinder); i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await _frames(t, 1);
      }
      expect(within(t, subFinder), isTrue, reason: 'focus reached $sub');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _frames(t);
      expect(find.byKey(ValueKey('menu-$first')), findsOneWidget, reason: 'the submenu is open');
      expect(within(t, find.byKey(ValueKey('menu-$first'))), isTrue, reason: 'its first item has the focus');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(t);
      expect(find.byKey(ValueKey('menu-$first')), findsNothing, reason: 'one level closed');
      expect(find.byKey(ValueKey('menu-sub-$sub')), findsOneWidget, reason: 'the menu stays');
      expect(w.bar(t).holding, isTrue);
      // Then the menu, then the bar: exactly three Escapes in all.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(t);
      expect(find.byKey(ValueKey('menu-sub-$sub')), findsNothing, reason: 'the menu closed');
      expect(w.bar(t).holding, isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(t);
      expect(w.bar(t).holding, isFalse);
      await w.close(t);
    });
  }


  testWidgets('overlay open, then another page: Escape still closes the overlay', (t) async {
    final w = await ShellWorld.open(t, size: const Size(1100, 800));
    await t.tap(find.byKey(const ValueKey('menu-top-View')));
    await _frames(t);
    await t.tap(find.byKey(const ValueKey('menu-app.view.panel')));
    await _frames(t, 6);
    expect(find.byKey(const ValueKey('context-panel')), findsOneWidget);
    await w.openPage(t, w.second);
    await _frames(t, 6);
    expect(find.byKey(const ValueKey('context-panel')), findsOneWidget, reason: 'still open on the new page');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await _frames(t, 6);
    expect(find.byKey(const ValueKey('context-panel')), findsNothing);
    await w.close(t);
  });

  testWidgets('closing the overlay with Escape puts the focus back in the page title field', (t) async {
    final w = await ShellWorld.open(t, size: const Size(1100, 800));
    await t.tap(find.descendant(of: find.byKey(ValueKey('title-${w.first}')), matching: find.byType(EditableText)));
    await _frames(t);
    final before = FocusManager.instance.primaryFocus;
    expect(before, isNotNull);
    await t.tap(find.byKey(const ValueKey('menu-top-View')));
    await _frames(t);
    await t.tap(find.byKey(const ValueKey('menu-app.view.panel')));
    await _frames(t, 6);
    expect(FocusManager.instance.primaryFocus, isNot(same(before)), reason: 'the overlay took the focus');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await _frames(t, 8);
    expect(find.byKey(const ValueKey('context-panel')), findsNothing);
    expect(FocusManager.instance.primaryFocus, same(before));
    await w.close(t);
  });

  int rings(WidgetTester t) => t
      .widgetList<DecoratedBox>(find.byType(DecoratedBox))
      .where((d) {
        final b = (d.decoration as BoxDecoration).border;
        return d.position == DecorationPosition.foreground && b is Border && b.top.width == 2;
      })
      .length;

  testWidgets('menus built on a cover, then a page: no focus node is shared, one ring on Zoom in', (t) async {
    final w = await ShellWorld.open(t);
    final b = await w.addBinderWithPage(t, 'Work');
    w.nb.showCover(b.path);
    await w.settle(t);
    // On the cover View has no canvas items: Page background is the first one.
    await t.sendKeyEvent(LogicalKeyboardKey.f10);
    await _frames(t);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _frames(t, 1);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _frames(t, 1);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _frames(t);
    for (var i = 0; i < 4 && w.bar(t).holding; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(t);
    }
    expect(w.bar(t).holding, isFalse);
    await w.openPage(t, w.first);
    await _frames(t, 6);
    await t.sendKeyEvent(LogicalKeyboardKey.f10);
    await _frames(t);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _frames(t, 1);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _frames(t, 1);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _frames(t);
    expect(within(t, find.byKey(const ValueKey('menu-canvas.zoomIn'))), isTrue);
    expect(rings(t), 1);
    await w.close(t);
  });

  testWidgets('a submenu removed while open (the cover shows) is not a level: Escape still leaves the bar', (t) async {
    final w = await ShellWorld.open(t);
    final b = await w.addBinderWithPage(t, 'Work');
    await t.sendKeyEvent(LogicalKeyboardKey.f10);
    await _frames(t);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _frames(t);
    final sub = find.byKey(const ValueKey('menu-sub-Page'));
    for (var i = 0; i < 20 && !within(t, sub); i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _frames(t, 1);
    }
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _frames(t);
    expect(find.byKey(const ValueKey('menu-app.page.newSubpage')), findsOneWidget);
    w.nb.showCover(b.path);
    await _frames(t, 6);
    for (var i = 0; i < 3 && w.bar(t).holding; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(t);
    }
    expect(w.bar(t).holding, isFalse);
    await w.close(t);
  });
}
