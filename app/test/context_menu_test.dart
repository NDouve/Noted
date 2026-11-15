// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The canvas context menus in the app: the saved Radial setting, its
// items in View and the gear menu, and the keys of the menu bar and the home
// while a context menu is open.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart' show Bounds;

import 'support/shell_world.dart';

Future<void> _frames(WidgetTester t, [int n = 4]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _rightClick(WidgetTester t, Offset p) async {
  final g = await t.startGesture(p, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
  await g.up();
  await g.removePointer();
  await _frames(t);
}

void main() {
  group('setting', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('noted_context_setting');
      file = File('${dir.path}/sub/settings.json');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('the default is List and nothing is written', () {
      expect(AppSettings(file).contextMenu, ContextMenuStyle.list);
      expect(AppSettings(null).contextMenu, ContextMenuStyle.list);
      expect(file.existsSync(), isFalse);
    });

    test('Radial is saved: it notifies once, writes the key and a new launch reads it', () {
      final s = AppSettings(file);
      var told = 0;
      s.addListener(() => told++);
      s.contextMenu = ContextMenuStyle.radial;
      expect(s.contextMenu, ContextMenuStyle.radial);
      expect(told, 1);
      s.contextMenu = ContextMenuStyle.radial;
      expect(told, 1);
      expect(file.readAsStringSync(), contains('"contextMenu":"radial"'));
      expect(AppSettings(file).contextMenu, ContextMenuStyle.radial);
      s.contextMenu = ContextMenuStyle.list;
      expect(AppSettings(file).contextMenu, ContextMenuStyle.list);
    });

    test('a missing, unknown or damaged value gives List and the file is left alone', () {
      file.parent.createSync(recursive: true);
      const bodies = [
        '{"format":1,"theme":"light"}',
        '{"format":1,"contextMenu":"ring","future":true}',
        '{"format":1,"contextMenu":7}',
        '{ nope',
      ];
      for (final body in bodies) {
        file.writeAsStringSync(body);
        expect(AppSettings(file).contextMenu, ContextMenuStyle.list, reason: body);
        expect(file.readAsStringSync(), body, reason: 'nothing written: $body');
      }
    });

    test('the saved value is read, and unknown keys are kept when it changes', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{"format":1,"contextMenu":"radial","future":true}');
      final s = AppSettings(file);
      expect(s.contextMenu, ContextMenuStyle.radial);
      s.contextMenu = ContextMenuStyle.list;
      s.toolbar = ToolbarStyle.contextual;
      final written = file.readAsStringSync();
      expect(written, contains('"future":true'));
      expect(written, contains('"contextMenu":"list"'));
    });

    test('settings without a file hold the choice for the session', () {
      final s = AppSettings(null)..contextMenu = ContextMenuStyle.radial;
      expect(s.contextMenu, ContextMenuStyle.radial);
    });
  });

  testWidgets('View > Context menu lists List and Radial, checked; Radial opens the ring', (t) async {
    final w = await ShellWorld.open(t);
    await w.addNote(t, 'n', 'hello', at: const Bounds(100, 100, 300, 40));
    await t.tap(find.byKey(const ValueKey('menu-top-View')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('menu-sub-Context menu')));
    await t.pumpAndSettle();
    final list = find.byKey(const ValueKey('menu-app.contextMenu.list'));
    final radial = find.byKey(const ValueKey('menu-app.contextMenu.radial'));
    expect(find.descendant(of: list, matching: find.byIcon(Icons.check_rounded)), findsOneWidget);
    expect(find.descendant(of: radial, matching: find.byIcon(Icons.check_rounded)), findsNothing);
    await t.tap(radial);
    await t.pump();
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(w.settings.contextMenu, ContextMenuStyle.radial);
    expect(File('${w.dir.path}/settings.json').readAsStringSync(), contains('"contextMenu":"radial"'));
    expect(AppSettings(File('${w.dir.path}/settings.json')).contextMenu, ContextMenuStyle.radial);

    final origin = w.canvasOrigin(t);
    await _rightClick(t, origin + w.canvas(t).view!.toScreen(const Offset(150, 110)));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('radial-menu')), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await _frames(t);
    await w.close(t);
  });

  testWidgets('the gear menu has Context menu: List and Radial', (t) async {
    final w = await ShellWorld.open(t);
    await t.tap(find.byKey(const ValueKey('settings-menu')));
    await t.pumpAndSettle();
    expect(find.text('Context menu'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('context-menu-radial')));
    await t.pumpAndSettle();
    expect(w.settings.contextMenu, ContextMenuStyle.radial);
    await t.tap(find.byKey(const ValueKey('settings-menu')));
    await t.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('context-menu-radial')),
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsOneWidget,
    );
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    await w.close(t);
  });

  testWidgets('Shift+F10 opens the canvas menu and never focuses the menu bar', (t) async {
    final w = await ShellWorld.open(t);
    await w.addNote(t, 'n', 'hello');
    w.nb.current!.select('n');
    await t.pump();
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.f10);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await _frames(t);
    expect(find.byKey(const ValueKey('context-menu')), findsOneWidget);
    expect(w.bar(t).holding, isFalse);
    expect(w.bar(t).hasFocus, isFalse);
    // Keys of the app do nothing under the open menu.
    final open = w.nb.currentId;
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyN);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _frames(t);
    expect(w.nb.currentId, open);
    expect(find.byKey(const ValueKey('context-menu')), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await _frames(t);
    await w.close(t);
  });

  testWidgets('a note being edited: Shift+F10 opens its menu under the hold; F10 and Alt leave the bar alone; Escape restores', (t) async {
    final w = await ShellWorld.open(t);
    await w.addNote(t, 'n', 'hello brave new world');
    await w.editNote(t, 'n');
    final c = w.nb.current!;
    expect(c.editingId, 'n');
    final before = noteSelection(t);
    expect(before, isNotNull);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.f10);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await _frames(t);
    expect(find.byKey(const ValueKey('context-menu')), findsOneWidget);
    expect(c.editorFocusHold.count, 1);
    // F10 and a lone Alt give the bar no focus and no second hold.
    await t.sendKeyEvent(LogicalKeyboardKey.f10);
    await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await _frames(t);
    expect(w.bar(t).holding, isFalse);
    expect(c.editorFocusHold.count, 1);
    expect(find.byKey(const ValueKey('context-menu')), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await _frames(t, 6);
    expect(find.byKey(const ValueKey('context-menu')), findsNothing);
    expect(c.editorFocusHold.count, 0);
    expect(c.editingId, 'n');
    expect(noteSelection(t), before);
    await w.close(t);
  });

  testWidgets('a right click on empty canvas while a note is edited: Escape keeps the selection and editing never ends', (t) async {
    final w = await ShellWorld.open(t);
    await w.addNote(t, 'n', 'hello brave new world');
    await w.editNote(t, 'n');
    final c = w.nb.current!;
    final before = noteSelection(t);
    expect(before, isNotNull);
    final seen = <String?>[];
    c.addListener(() => seen.add(c.editingId));
    await _rightClick(t, w.canvasOrigin(t) + w.canvas(t).view!.toScreen(const Offset(700, 400)));
    expect(find.byKey(const ValueKey('context-menu')), findsOneWidget);
    expect(c.editorFocusHold.count, 1);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await _frames(t, 6);
    expect(find.byKey(const ValueKey('context-menu')), findsNothing);
    expect(c.editorFocusHold.count, 0);
    expect(c.editingId, 'n');
    expect(seen, everyElement(isNotNull));
    expect(noteSelection(t), before);
    await w.close(t);
  });

  for (final size in [const Size(1280, 800), const Size(900, 700)]) {
    testWidgets('clicking View > Context menu opens its submenu, like Theme, at ${size.width.round()} px', (t) async {
      final w = await ShellWorld.open(t, size: size);
      for (final sub in ['Theme', 'Context menu', 'Toolbar', 'Context menu']) {
        await t.tap(find.byKey(const ValueKey('menu-top-View')));
        await t.pumpAndSettle();
        await t.tap(find.byKey(ValueKey('menu-sub-$sub')));
        await t.pumpAndSettle();
        // The submenu is open and the View menu is still there.
        expect(find.byKey(const ValueKey('menu-canvas.zoomIn')), findsOneWidget, reason: sub);
        final first = switch (sub) {
          'Theme' => 'menu-app.theme.system',
          'Toolbar' => 'menu-app.toolbar.tabs',
          _ => 'menu-app.contextMenu.list',
        };
        expect(find.byKey(ValueKey(first)), findsOneWidget, reason: sub);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
      }
      await w.close(t);
    });
  }

  testWidgets('with a real mouse, hovering then clicking View > Context menu leaves its submenu open, like Theme', (t) async {
    final w = await ShellWorld.open(t);
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    for (final sub in ['Theme', 'Context menu']) {
      await mouse.moveTo(t.getCenter(find.byKey(const ValueKey('menu-top-View'))));
      await mouse.down(t.getCenter(find.byKey(const ValueKey('menu-top-View'))));
      await mouse.up();
      await t.pumpAndSettle();
      final target = t.getCenter(find.byKey(ValueKey('menu-sub-$sub')));
      await mouse.moveTo(target);
      await t.pumpAndSettle();
      await mouse.down(target);
      await mouse.up();
      await t.pumpAndSettle();
      final first = sub == 'Theme' ? 'menu-app.theme.system' : 'menu-app.contextMenu.list';
      expect(find.byKey(ValueKey(first)), findsOneWidget, reason: sub);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
    }
    await w.close(t);
  });
}
