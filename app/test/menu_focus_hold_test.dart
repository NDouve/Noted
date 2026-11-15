// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The menu bar and a note being edited (UI shell, B1): the bar never takes the
// focus by pointer, keyboard entry holds the editor focus, and every exit
// releases the hold. (The exact 5 to 9 selection is checked in the note
// module's own test; the app does not depend on appflowy_editor, so here the
// editor's selection is compared as text.)

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';

import 'package:noted/src/notebook.dart' show BinderSection;

import 'support/settle_saves.dart';
import 'support/shell_world.dart';

Future<void> _frames(WidgetTester t, [int n = 4]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

// A page with a note being edited, the caret where the click put it.
Future<ShellWorld> _editing(WidgetTester t, {Future<void> Function(ShellWorld w)? first}) async {
  final w = await ShellWorld.open(t);
  // Binder changes wait for saves, so they come before the note is edited.
  await first?.call(w);
  await w.addNote(t, 'n', 'hello brave new world');
  await w.editNote(t, 'n');
  expect(w.nb.current!.editingId, 'n');
  await _frames(t);
  expect(noteSelection(t), isNotNull);
  return w;
}

void main() {
  testWidgets(
    'a pointer press on Edit and hovering every item keep the editor focused and the caret',
    (t) async {
      final w = await _editing(t);
      final c = w.nb.current!;
      final seen = <String?>[];
      c.addListener(() => seen.add(c.editingId));
      final before = noteSelection(t);
      await t.tap(find.byKey(const ValueKey('menu-top-Edit')));
      await _frames(t);
      expect(find.byKey(const ValueKey('menu-canvas.undo')), findsOneWidget);
      expect(w.bar(t).holding, isFalse, reason: 'a pointer opening holds nothing');
      expect(w.bar(t).excludingFocus, isTrue);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      for (final item in find.byType(MenuItemButton).evaluate().toList()) {
        await mouse.moveTo(t.getCenter(find.byWidget(item.widget)));
        await _frames(t, 1);
      }
      expect(c.editingId, 'n');
      expect(seen, isNot(contains(null)));
      expect(noteEditorFinder, findsOneWidget);
      expect(noteSelection(t), before, reason: 'the caret is where it was');
      await w.close(t);
    },
  );

  testWidgets(
    'F10, arrows through the menus, then Escape: the caret returns, editing never ended',
    (t) async {
      final w = await _editing(t);
      final c = w.nb.current!;
      final seen = <String?>[];
      c.addListener(() => seen.add(c.editingId));
      final before = noteSelection(t);
      await t.sendKeyEvent(LogicalKeyboardKey.f10);
      await _frames(t);
      expect(w.bar(t).holding, isTrue);
      expect(c.editorFocusHeld.value, isTrue);
      expect(noteSelection(t), isNull, reason: 'appflowy clears it while the bar has the focus');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _frames(t, 1);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _frames(t, 1);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _frames(t);
      // One Escape per level: a submenu the keyboard opened, the menu, the bar.
      for (var i = 0; i < 4 && w.bar(t).holding; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await _frames(t);
      }
      expect(w.bar(t).holding, isFalse);
      expect(c.editorFocusHold.count, 0);

      expect(c.editingId, 'n');
      expect(seen, isNot(contains(null)), reason: 'no demote');
      expect(noteEditorFinder, findsOneWidget);
      expect(noteSelection(t), before, reason: 'the caret came back where it was');
      await w.close(t);
    },
  );

  testWidgets('Edit > Undo from the keyboard while editing acts as the toolbar Undo', (t) async {
    final w = await _editing(t);
    final c = w.nb.current!;
    expect(c.canUndo, isTrue, reason: 'the note was added');
    await t.sendKeyEvent(LogicalKeyboardKey.f10);
    await _frames(t);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _frames(t, 1);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _frames(t);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await _frames(t, 8);

    expect(c.page.node('n'), isNull, reason: 'the page undo ran, as the toolbar button does');
    expect(c.editorFocusHold.count, 0);
    await w.close(t);
  });

  group('every exit releases the hold', () {
    Future<void> enter(WidgetTester t, ShellWorld w) async {
      await t.sendKeyEvent(LogicalKeyboardKey.f10);
      await _frames(t);
      expect(w.nb.current!.editorFocusHold.count, 1);
    }

    void released(WidgetTester t, ShellWorld w, CanvasController c) {
      expect(c.editorFocusHold.count, 0);
      expect(c.editorFocusHeld.value, isFalse);
      expect(w.bar(t).holding, isFalse);
    }

    testWidgets('Escape', (t) async {
      final w = await _editing(t);
      final c = w.nb.current!;
      await enter(t, w);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(t);
      released(t, w, c);
      expect(c.editingId, 'n');
      await w.close(t);
    });

    testWidgets('a second F10', (t) async {
      final w = await _editing(t);
      final c = w.nb.current!;
      await enter(t, w);
      await t.sendKeyEvent(LogicalKeyboardKey.f10);
      await _frames(t);
      released(t, w, c);
      await w.close(t);
    });

    testWidgets('a lone Alt', (t) async {
      final w = await _editing(t);
      final c = w.nb.current!;
      await enter(t, w);
      await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await _frames(t);
      released(t, w, c);
      await w.close(t);
    });

    testWidgets('a command run from the bar', (t) async {
      final w = await _editing(t);
      final c = w.nb.current!;
      await enter(t, w);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _frames(t, 1);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _frames(t, 1);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _frames(t);
      await t.tap(find.byKey(const ValueKey('menu-canvas.zoomIn')));
      await _frames(t, 6);
      released(t, w, c);
      expect(c.editingId, 'n');
      await w.close(t);
    });

    testWidgets('a pointer press on the canvas', (t) async {
      final w = await _editing(t);
      final c = w.nb.current!;
      await enter(t, w);
      await t.tapAt(w.canvasOrigin(t) + const Offset(600, 400));
      await _frames(t);
      released(t, w, c);
      await w.close(t);
    });

    testWidgets('window focus loss', (t) async {
      final w = await _editing(t);
      final c = w.nb.current!;
      await enter(t, w);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _frames(t);
      released(t, w, c);
      await w.close(t);
    });

    testWidgets('Tab out of the bar', (t) async {
      final w = await _editing(t);
      final c = w.nb.current!;
      await enter(t, w);
      for (var i = 0; i < 6; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await _frames(t, 1);
        if (!w.bar(t).holding) break;
      }
      await _frames(t);
      released(t, w, c);
      await w.close(t);
    });

    testWidgets('a dialog takes the focus', (t) async {
      final w = await _editing(t);
      final c = w.nb.current!;
      await enter(t, w);
      unawaited(
        showDialog<void>(
          context: t.element(find.byType(Scaffold).first),
          builder: (_) => const AlertDialog(content: Text('hi')),
        ),
      );
      await _frames(t);
      released(t, w, c);
      await t.tapAt(const Offset(5, 5));
      await w.close(t);
    });

    testWidgets('opening another page', (t) async {
      final w = await _editing(t);
      final c = w.nb.current!;
      await enter(t, w);
      await settleSaves(t, w.nb);
      await w.openPage(t, w.second);
      await _frames(t, 6);
      released(t, w, c);
      await w.close(t);
    });

    testWidgets('opening a cover', (t) async {
      late BinderSection b;
      final w = await _editing(t, first: (w) async => b = await w.addBinderWithPage(t, 'Work'));
      final c = w.nb.current!;
      await enter(t, w);
      w.nb.showCover(b.path);

      await _frames(t, 6);
      released(t, w, c);
      await w.close(t);
    });

    testWidgets('the canvas disposing', (t) async {
      final w = await _editing(t);
      final c = w.nb.current!;
      await enter(t, w);
      await t.pumpWidget(const SizedBox());
      await _frames(t, 2);
      expect(c.editorFocusHold.count, 0);
      await settleSaves(t, w.nb);
      await t.runAsync(() async {
        w.nb.dispose();
        await w.dir.delete(recursive: true);
      });
    });
  });

  testWidgets(
    'deleting the edited box from the bar: released, the canvas has the focus, Undo brings it back',
    (t) async {
      final w = await _editing(t);
      final c = w.nb.current!;
      await t.sendKeyEvent(LogicalKeyboardKey.f10);
      await _frames(t);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _frames(t);
      await t.tap(find.byKey(const ValueKey('menu-canvas.delete')));
      await _frames(t, 8);
      expect(c.page.node('n'), isNull);
      expect(c.editorFocusHold.count, 0);
      expect(c.editorFocusHeld.value, isFalse);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'PageCanvas');
      c.undo();
      await _frames(t);
      expect(c.page.node('n'), isNotNull);
      expect(c.editorFocusHold.count, 0);
      await w.close(t);
    },
  );

  testWidgets('exclusion is per entry: pointer, then F10, then pointer again', (t) async {
    final w = await _editing(t);
    final c = w.nb.current!;
    final bar = w.bar(t);
    // Pointer: the editor keeps the focus, the bar cannot take it.
    await t.tap(find.byKey(const ValueKey('menu-top-Edit')));
    await _frames(t);
    expect(bar.excludingFocus, isTrue);
    expect(bar.hasFocus, isFalse);
    expect(c.editingId, 'n');
    await t.tapAt(w.canvasOrigin(t) + const Offset(600, 500));
    await _frames(t);
    await w.editNote(t, 'n');
    // F10: the items can take focus and the arrows move.
    await t.sendKeyEvent(LogicalKeyboardKey.f10);
    await _frames(t);
    expect(bar.excludingFocus, isFalse);
    expect(bar.hasFocus, isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _frames(t);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'menu Edit');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await _frames(t);
    expect(bar.excludingFocus, isTrue);
    // Pointer again.
    await t.tap(find.byKey(const ValueKey('menu-top-View')));
    await _frames(t);
    expect(bar.excludingFocus, isTrue);
    expect(bar.hasFocus, isFalse);
    expect(c.editingId, 'n');
    await w.close(t);
  });
}
