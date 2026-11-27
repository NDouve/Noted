// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The menu bar (UI shell, task 6): items, shortcuts, enablement, the load
// predicate and the keyboard.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/app_settings.dart';

import 'support/shell_world.dart';

/// The ids of the items now on screen, in order (submenu buttons by label).
List<String> _shown(WidgetTester t) {
  final out = <String>[];
  final found = find.byWidgetPredicate((w) {
    final k = w.key;
    return (w is MenuItemButton || w is SubmenuButton) &&
        k is ValueKey<String> &&
        !k.value.startsWith('menu-top-');
  });
  for (final w in t.widgetList(found)) {
    out.add(
      (w.key! as ValueKey<String>).value
          .replaceFirst('menu-sub-', 'sub:')
          .replaceFirst('menu-', ''),
    );
  }
  return out;
}

/// Like [_shown] with a '|' where a separator is drawn, top to bottom.
List<String> _layout(WidgetTester t) {
  final found = find.byWidgetPredicate((w) {
    final k = w.key;
    return w is Divider ||
        ((w is MenuItemButton || w is SubmenuButton) &&
            k is ValueKey<String> &&
            !k.value.startsWith('menu-top-'));
  });
  final rows = <(Offset, String)>[];
  for (final e in found.evaluate()) {
    final w = e.widget;
    final at = (e.renderObject! as RenderBox).localToGlobal(Offset.zero);
    rows.add((
      at,
      w is Divider
          ? '|'
          : (w.key! as ValueKey<String>).value
                .replaceFirst('menu-sub-', 'sub:')
                .replaceFirst('menu-', ''),
    ));
  }
  // The menu's own dividers start where its items do; others in the window
  // (the toolbar's) don't.
  final left = rows.firstWhere((r) => r.$2 != '|').$1.dx;
  rows.removeWhere((r) => r.$2 == '|' && r.$1.dx != left);
  rows.sort((a, b) => a.$1.dy.compareTo(b.$1.dy));
  return [for (final r in rows) r.$2];
}

Future<void> _open(WidgetTester t, String top) async {
  await t.tap(find.byKey(ValueKey('menu-top-$top')));
  await t.pumpAndSettle();
}

MenuItemButton _item(WidgetTester t, String id) =>
    t.widget<MenuItemButton>(find.byKey(ValueKey('menu-$id')));

bool _on(WidgetTester t, String id) => _item(t, id).onPressed != null;

String _shortcut(WidgetTester t, String id) => t
    .widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey('menu-$id')),
        matching: find.byKey(const ValueKey('menu-shortcut')),
      ),
    )
    .data!;

Future<void> _choose(WidgetTester t, String id) async {
  await t.tap(find.byKey(ValueKey('menu-$id')));
  // The command runs after the frame that closes the menu.
  await t.pump();
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('File lists its items in order, with Page and Binder for a binder page', (t) async {
    final w = await ShellWorld.open(t);
    await _open(t, 'File');
    expect(_shown(t), [
      'app.page.new',
      'app.page.newFromTemplate',
      'app.binder.new',
      'app.binder.newInFolder',
      'app.binder.open',
      'app.binder.newFromTemplate',
      'app.binder.openZip',
      'canvas.exportBox',
      'app.binder.saveZip',
      'sub:Page',
    ]);
    expect(_layout(t), [
      'app.page.new',
      'app.page.newFromTemplate',
      '|',
      'app.binder.new',
      'app.binder.newInFolder',
      'app.binder.open',
      'app.binder.newFromTemplate',
      'app.binder.openZip',
      '|',
      'canvas.exportBox',
      'app.binder.saveZip',
      '|',
      'sub:Page',
    ]);
    expect(
      t.widget<MenuItemButton>(find.byKey(const ValueKey('menu-app.binder.saveZip'))).onPressed,
      isNull,
      reason: 'Save binder as .zip… is off for a standalone page',
    );
    expect(find.text('New page'), findsOneWidget, reason: 'File has one New page');
    expect(_shortcut(t, 'app.page.new'), 'Ctrl+N');
    // Page's submenu, in the order of the page commands.
    await t.tap(find.byKey(const ValueKey('menu-sub-Page')));
    await t.pumpAndSettle();
    expect(_shown(t).skip(10), [
      'app.page.newSubpage',
      'app.page.newSubpageFromTemplate',
      'app.page.saveAsTemplate',
      'app.page.rename',
      'app.page.moveUp',
      'app.page.moveDown',
      'app.page.indent',
      'app.page.outdent',
      'app.page.moveToFolder',
      'app.page.settings',
      'app.page.delete',
    ]);
    await w.close(t);
  });

  testWidgets('Binder has the binder items, without its two new-page items', (t) async {
    final w = await ShellWorld.open(t);
    final b = await w.addBinderWithPage(t, 'Work', open: true);
    await w.settle(t);

    expect(w.nb.binderOfPage(w.nb.currentId!), b.path);
    await _open(t, 'File');
    await t.tap(find.byKey(const ValueKey('menu-sub-Binder')));
    await t.pumpAndSettle();
    final ids = _shown(t);
    final saveZip = t.widget<MenuItemButton>(find.byKey(const ValueKey('menu-app.binder.saveZip')));
    expect(saveZip.onPressed, isNotNull, reason: 'Save binder as .zip… is on for a binder page');
    expect(find.text('Save binder as .zip…'), findsOneWidget);
    expect(find.text('Open binder from .zip…'), findsOneWidget);
    expect(ids.skipWhile((s) => s != 'app.binder.cover'), [
      'app.binder.cover',
      'app.binder.settings',
      'app.binder.saveAsTemplate',
      'app.binder.remove',
    ]);
    expect(ids, isNot(contains('app.binder.newPage')));
    await w.close(t);
  });

  testWidgets('Edit and View list their items in order with shortcut text', (t) async {
    final w = await ShellWorld.open(t);
    await _open(t, 'Edit');
    expect(_layout(t), [
      'canvas.undo',
      'canvas.redo',
      'canvas.paste',
      'canvas.delete',
      '|',
      'canvas.find',
      'canvas.findNext',
      'canvas.findPrevious',
      'app.search',
      '|',
      'canvas.bringToFront',
      'canvas.bringForward',
      'canvas.sendBackward',
      'canvas.sendToBack',
    ]);
    expect(find.text('Paste'), findsOneWidget);
    for (final (id, keys) in [
      ('canvas.undo', 'Ctrl+Z'),
      ('canvas.redo', 'Ctrl+Y'),
      ('canvas.paste', 'Ctrl+V'),
      ('canvas.delete', 'Delete'),
      ('canvas.bringToFront', 'Ctrl+Shift+]'),
      ('canvas.bringForward', 'Ctrl+]'),
      ('canvas.sendBackward', 'Ctrl+['),
      ('canvas.sendToBack', 'Ctrl+Shift+['),
      ('canvas.find', 'Ctrl+F'),
      ('canvas.findNext', 'F3'),
      ('canvas.findPrevious', 'Shift+F3'),
      ('app.search', 'Ctrl+Shift+F'),
    ]) {
      expect(_shortcut(t, id), keys, reason: id);
    }
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    await _open(t, 'View');
    expect(_layout(t), [
      'canvas.zoomIn',
      'canvas.zoomOut',
      'canvas.zoomReset',
      'canvas.fitAll',
      '|',
      'sub:Toolbar',
      'sub:Appearance',
      '|',
      'sub:Page background',
      'canvas.showIssues',
      'app.view.panel',
      'sub:Context menu',
    ]);
    // The menu item and the toggle at the bar's right end.
    expect(find.text('Details'), findsNWidgets(2));
    expect(_shortcut(t, 'canvas.zoomIn'), 'Ctrl+=');
    expect(_shortcut(t, 'canvas.zoomOut'), 'Ctrl+-');
    expect(_shortcut(t, 'canvas.zoomReset'), 'Ctrl+0');
    expect(_shortcut(t, 'canvas.showIssues'), 'F8');
    await t.tap(find.byKey(const ValueKey('menu-sub-Appearance')));
    await t.pumpAndSettle();
    expect(find.text('Follow system'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Precision'), findsOneWidget);
    expect(find.text('Dark'), findsNothing);
    await w.close(t);
  });

  testWidgets('Help lists Keyboard shortcuts, and About only with a Microsoft client id', (
    t,
  ) async {
    final w = await ShellWorld.open(t);
    await _open(t, 'Help');
    expect(_shown(t), ['app.help.shortcuts']);
    await _choose(t, 'app.help.shortcuts');
    expect(find.text('Keyboard shortcuts'), findsWidgets);
    expect(find.byKey(const ValueKey('shortcuts-list')), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();
    await w.close(t);
  });

  testWidgets('macOS shows the Cmd alternates and nothing for keys without one', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final w = await ShellWorld.open(t);
    await _open(t, 'Edit');
    expect(_shortcut(t, 'canvas.undo'), 'Cmd+Z');
    expect(_shortcut(t, 'canvas.redo'), 'Cmd+Shift+Z');
    expect(_shortcut(t, 'canvas.paste'), 'Cmd+V');
    expect(_shortcut(t, 'canvas.find'), 'Cmd+F');
    expect(_shortcut(t, 'canvas.delete'), 'Delete');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    await _open(t, 'View');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('menu-canvas.zoomIn')),
        matching: find.byKey(const ValueKey('menu-shortcut')),
      ),
      findsNothing,
    );
    await w.close(t);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('choosing an item runs its command once; a key with the menu shut runs it once', (
    t,
  ) async {
    final w = await ShellWorld.open(t);
    final canvas = w.canvas(t);
    final base = canvas.scale;
    await _open(t, 'View');
    await _choose(t, 'canvas.zoomIn');
    expect(canvas.scale, closeTo(base * 1.25, 1e-6));
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.equal);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(
      canvas.scale,
      closeTo(base * 1.25 * 1.25, 1e-6),
      reason: 'the key resolved once, the menu binds nothing',
    );
    await w.close(t);
  });

  testWidgets('View > Theme chooses a theme through the same commands, checked live', (t) async {
    final w = await ShellWorld.open(t);
    expect(w.settings.theme, ThemeSetting.light);
    await _open(t, 'View');
    await t.tap(find.byKey(const ValueKey('menu-sub-Appearance')));
    await t.pumpAndSettle();
    await _choose(t, 'app.theme.dark');
    expect(w.settings.theme, ThemeSetting.dark);
    await w.close(t);
  });

  group('enablement', () {
    testWidgets(
      'Undo goes on after an edit while Edit is open; layering and Delete follow the selection',
      (t) async {
        final w = await ShellWorld.open(t);
        await _open(t, 'Edit');
        final c = w.nb.current!;
        expect(_on(t, 'canvas.undo'), isFalse);
        expect(_on(t, 'canvas.delete'), isFalse);
        // An edit while the menu is open: the box is added and selected.
        c.insertBox(shellNote('n', 'hello'));
        c.select('n');
        await t.pump();
        await t.pump();
        expect(_on(t, 'canvas.undo'), isTrue, reason: 'the menu follows the undo stack while open');
        expect(_on(t, 'canvas.delete'), isTrue);
        expect(
          _on(t, 'canvas.bringToFront'),
          isFalse,
          reason: 'a lone box has nothing to go in front of',
        );
        c.select(null);
        await t.pump();
        expect(_on(t, 'canvas.delete'), isFalse);
        expect(_on(t, 'canvas.bringToFront'), isFalse);
        await w.close(t);
      },
    );

    testWidgets(
      'a read-only page keeps zoom, find and File on, and turns edits off in the same frame',
      (t) async {
        final w = await ShellWorld.open(t);
        await w.addNote(t, 'n', 'hello');
        w.nb.current!.select('n');
        await t.pump();
        await _open(t, 'Edit');
        expect(_on(t, 'canvas.delete'), isTrue);
        w.nb.current!.readOnly = true;
        await t.pump();
        expect(_on(t, 'canvas.delete'), isFalse);
        expect(_on(t, 'canvas.undo'), isFalse);
        expect(_on(t, 'canvas.paste'), isFalse);
        expect(_on(t, 'canvas.find'), isTrue);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        await _open(t, 'View');
        expect(_on(t, 'canvas.zoomIn'), isTrue);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        await _open(t, 'File');
        expect(_on(t, 'app.page.new'), isTrue);
        await w.close(t);
      },
    );

    testWidgets('before the first load succeeded File is off and Theme works', (t) async {
      final w = await ShellWorld.open(t, checked: false);
      await _open(t, 'File');
      expect(_on(t, 'app.page.new'), isFalse);
      expect(_on(t, 'app.binder.new'), isFalse);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      await _open(t, 'View');
      await t.tap(find.byKey(const ValueKey('menu-sub-Appearance')));
      await t.pumpAndSettle();
      expect(_on(t, 'app.theme.light'), isTrue);
      await w.close(t);
    });

    testWidgets('after the first load succeeded File is on', (t) async {
      final w = await ShellWorld.open(t);
      await _open(t, 'File');
      expect(_on(t, 'app.page.new'), isTrue);
      expect(_on(t, 'app.binder.new'), isTrue);
      await w.close(t);
    });
  });

  group('the cover', () {
    testWidgets(
      'with Edit open on a page, opening the cover turns the canvas items off and runs nothing',
      (t) async {
        final w = await ShellWorld.open(t);
        final b = await w.addBinderWithPage(t, 'Work');
        final before = w.nb.current!.page.nodes.length;
        await _open(t, 'Edit');
        expect(_on(t, 'canvas.find'), isTrue);
        w.nb.showCover(b.path);
        await t.pump();
        await t.pump();
        expect(_on(t, 'canvas.find'), isFalse);
        expect(_on(t, 'canvas.undo'), isFalse);
        expect(t.takeException(), isNull);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        expect(w.nb.coverPath, b.path);
        expect(before, isNonNegative);
        await w.close(t);
      },
    );
  });

  group('the keyboard', () {
    testWidgets('F10 focuses File without opening it; a second F10 returns focus', (t) async {
      final w = await ShellWorld.open(t);
      final before = FocusManager.instance.primaryFocus;
      await t.sendKeyEvent(LogicalKeyboardKey.f10);
      await t.pump();
      await t.pump();
      expect(w.bar(t).holding, isTrue);
      expect(w.bar(t).hasFocus, isTrue);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'menu File');
      expect(find.byKey(const ValueKey('menu-app.page.new')), findsNothing);
      await t.sendKeyEvent(LogicalKeyboardKey.f10);
      await t.pump();
      await t.pump();
      expect(w.bar(t).holding, isFalse);
      expect(FocusManager.instance.primaryFocus, same(before));
      await w.close(t);
    });

    testWidgets('a lone Alt focuses File', (t) async {
      final w = await ShellWorld.open(t);
      await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await t.pump();
      await t.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'menu File');
      await w.close(t);
    });

    testWidgets('Alt+V opens View', (t) async {
      final w = await ShellWorld.open(t);
      await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyV);
      await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('menu-canvas.zoomIn')), findsOneWidget);
      await w.close(t);
    });

    testWidgets(
      'Alt with a pointer press, Ctrl+Alt (AltGr), or another key between does not enter the bar',
      (t) async {
        final w = await ShellWorld.open(t);
        // Alt down, a press, Alt up.
        await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        final g = await t.startGesture(const Offset(600, 500), kind: PointerDeviceKind.mouse);
        await g.up();
        await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await t.pump();
        expect(w.bar(t).holding, isFalse);
        // AltGr: Ctrl and Alt together.
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await t.sendKeyDownEvent(LogicalKeyboardKey.altRight);
        await t.sendKeyUpEvent(LogicalKeyboardKey.altRight);
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await t.pump();
        expect(w.bar(t).holding, isFalse);
        await w.close(t);
      },
    );

    testWidgets(
      'Alt, then the window loses focus, then a synthesized Alt key-up: the bar does not take focus',
      (t) async {
        final w = await ShellWorld.open(t);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);

        await t.pump();
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await t.pump();
        expect(w.bar(t).holding, isFalse);
        await w.close(t);
      },
    );

    testWidgets('a synthesized Alt key-up (sent on focus regain) does not enter the bar', (
      t,
    ) async {
      final w = await ShellWorld.open(t);
      await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      // ignore: deprecated_member_use
      ServicesBinding.instance.keyEventManager.handleKeyData(
        ui.KeyData(
          timeStamp: Duration.zero,
          type: ui.KeyEventType.up,
          physical: PhysicalKeyboardKey.altLeft.usbHidUsage,
          logical: LogicalKeyboardKey.altLeft.keyId,
          character: null,
          synthesized: true,
        ),
      );
      await t.pump();
      expect(w.bar(t).holding, isFalse);
      await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await w.close(t);
    });

    testWidgets('Escape closes level by level and returns the focus', (t) async {
      final w = await ShellWorld.open(t);
      final before = FocusManager.instance.primaryFocus;
      await t.sendKeyEvent(LogicalKeyboardKey.f10);
      await t.pump();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('menu-app.page.new')), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('menu-app.page.new')), findsNothing);
      expect(w.bar(t).holding, isTrue, reason: 'the first Escape closed the menu only');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(w.bar(t).holding, isFalse);
      expect(FocusManager.instance.primaryFocus, same(before));
      await w.close(t);
    });
  });

  group('shortcuts with a menu open', () {
    testWidgets(
      'File opened by keyboard: Ctrl+N, Ctrl+Z and Ctrl+Shift+F do nothing and the menu stays',
      (t) async {
        final w = await ShellWorld.open(t);
        final pages = w.nb.currentId;
        await t.sendKeyEvent(LogicalKeyboardKey.f10);
        await t.pump();
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await t.pumpAndSettle();
        for (final (key, shift) in [
          (LogicalKeyboardKey.keyN, false),
          (LogicalKeyboardKey.keyZ, false),
          (LogicalKeyboardKey.keyF, true),
        ]) {
          await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await t.sendKeyEvent(key);
          if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await t.pumpAndSettle();
        }
        expect(w.nb.currentId, pages, reason: 'Ctrl+N made no page');
        expect(
          find.byKey(const ValueKey('menu-app.page.new')),
          findsOneWidget,
          reason: 'the menu stayed',
        );
        await w.close(t);
      },
    );

    testWidgets(
      'File opened by pointer: Escape closes it and is consumed, Down enters it, Ctrl+Z closes it and undoes once',
      (t) async {
        final w = await ShellWorld.open(t);
        await w.addNote(t, 'n', 'hello');
        final c = w.nb.current!;
        await _open(t, 'File');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('menu-app.page.new')), findsNothing);
        expect(c.page.node('n'), isNotNull, reason: 'Escape did not reach the canvas');
        await _open(t, 'File');
        await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await t.pumpAndSettle();
        expect(w.bar(t).holding, isTrue);
        expect(find.byKey(const ValueKey('menu-app.page.new')), findsOneWidget);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        // A pointer-opened menu, then Ctrl+Z.
        await _open(t, 'File');
        expect(c.canUndo, isTrue);
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('menu-app.page.new')), findsNothing);
        expect(c.page.node('n'), isNull, reason: 'the canvas undid the note, once');
        expect(c.canUndo, isFalse);
        await w.close(t);
      },
    );
  });

  testWidgets('a focused menu button, item and panel control paint a 2px accent outline', (
    t,
  ) async {
    final w = await ShellWorld.open(t);
    final accent = Theme.of(t.element(find.byType(Scaffold).first)).colorScheme.primary;
    // The ring is a foreground decoration around the button: a solid, opaque 2px
    // accent border, inside the bounds.
    bool outlined(Finder f) => t
        .widgetList<DecoratedBox>(
          find.ancestor(of: f, matching: find.byType(DecoratedBox)),

        )
        .any((d) {
          final b = (d.decoration as BoxDecoration).border;
          if (b is! Border || d.position != DecorationPosition.foreground) return false;
          return b.top.width == 2 && b.top.color == accent && accent.a == 1.0;
        });

    await t.sendKeyEvent(LogicalKeyboardKey.f10);
    await t.pump();
    await t.pump();
    expect(outlined(find.byKey(const ValueKey('menu-top-File'))), isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pumpAndSettle();
    // The first item took the focus when the menu opened by keyboard.
    expect(outlined(find.byKey(const ValueKey('menu-app.page.new'))), isTrue);

    await w.close(t);
  });
}
