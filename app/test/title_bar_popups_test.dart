// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Popups with the title bar on: the Navigator starts 40 px below the window
// origin, so global anchors must become overlay-local, and a press on the
// title bar closes open popup routes.

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/window_channel.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart' show Bounds;

import 'support/shell_world.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('noted/window');
  late WindowChannel window;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    window = WindowChannel(channel: channel);
  });

  tearDown(() {
    window.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> fromNative(String method) async {
    final data = const StandardMethodCodec().encodeMethodCall(MethodCall(method));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage('noted/window', data, (_) {});
  }

  Future<void> frames(WidgetTester t) async {
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> rightClick(WidgetTester t, Offset p) async {
    final g = await t.startGesture(p, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await g.up();
    await g.removePointer();
    await frames(t);
  }

  Rect canvasRect(WidgetTester t, ShellWorld w) => w.canvasOrigin(t) & t.getSize(find.byKey(PageCanvas.overlayKey));

  testWidgets('the list opens exactly at the pointer, below the title bar', (t) async {
    final w = await ShellWorld.open(t, window: window);
    final area = canvasRect(t, w);
    expect(area.top, greaterThanOrEqualTo(40));
    final p = Offset(area.center.dx, area.top + 30);
    await rightClick(t, p);
    final at = t.getTopLeft(find.byKey(const ValueKey('context-menu')));
    expect(at, p, reason: 'got $at, canvas $area');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(t);
    await w.close(t);
  });

  testWidgets('the list clamps to the canvas bottom, not 40 px past it', (t) async {
    final w = await ShellWorld.open(t, window: window);
    final area = canvasRect(t, w);
    await rightClick(t, Offset(area.center.dx, area.bottom - 4));
    final menu = t.getRect(find.byKey(const ValueKey('context-menu')));
    expect(menu.bottom, lessThanOrEqualTo(area.bottom - 8 + 0.01));
    expect(menu.bottom, greaterThan(area.bottom - 40), reason: 'flipped up, still next to the pointer');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(t);
    await w.close(t);
  });

  testWidgets('the ring is centred on the pointer, below the title bar', (t) async {
    final w = await ShellWorld.open(t, window: window);
    w.settings.contextMenu = ContextMenuStyle.radial;
    await t.pump();
    final area = canvasRect(t, w);
    final p = area.center;
    await rightClick(t, p);
    await t.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('radial-menu')), findsOneWidget);
    final pills = [
      for (final e in find.descendant(of: find.byKey(const ValueKey('radial-menu')), matching: find.byType(GestureDetector)).evaluate())
        if (e.widget.key is ValueKey<String> && (e.widget.key! as ValueKey<String>).value.startsWith('radial-'))
          t.getCenter(find.byWidget(e.widget)),
    ];
    expect(pills.length, greaterThanOrEqualTo(2));
    final top = pills.map((o) => o.dy).reduce((a, b) => a < b ? a : b);
    final bottom = pills.map((o) => o.dy).reduce((a, b) => a > b ? a : b);
    expect((top + bottom) / 2, closeTo(p.dy, 1));
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(t);
    await w.close(t);
  });

  testWidgets('the box pick list opens at the pointer, below the title bar', (t) async {
    final w = await ShellWorld.open(t, window: window);
    await w.addNote(t, 'n', 'hello', at: const Bounds(100, 100, 300, 40));
    final p = w.canvasOrigin(t) + w.canvas(t).view!.toScreen(const Offset(150, 110));
    await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    final g = await t.startGesture(p, kind: PointerDeviceKind.mouse);
    await g.up();
    await g.removePointer();
    await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await frames(t);
    final list = find.byKey(const ValueKey('box-pick-list'));
    expect(list, findsOneWidget);
    expect(t.getTopLeft(list), p);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(t);
    await w.close(t);
  });

  testWidgets('a page-tree context menu opens at the pointer, below the title bar', (t) async {
    final w = await ShellWorld.open(t, window: window);
    final p = t.getCenter(find.text('Alpha').first);
    await rightClick(t, p);
    final item = find.text('New subpage');
    expect(item, findsOneWidget);
    final at = t.getTopLeft(item);
    expect(at.dx - p.dx, inInclusiveRange(0, 40));
    expect(at.dy - p.dy, inInclusiveRange(0, 30));
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    await w.close(t);
  });

  testWidgets('a press on the title bar closes an open canvas menu', (t) async {
    final w = await ShellWorld.open(t, window: window);
    await rightClick(t, canvasRect(t, w).center);
    expect(find.byKey(const ValueKey('context-menu')), findsOneWidget);
    await fromNative('ncPointerDown');
    await frames(t);
    expect(find.byKey(const ValueKey('context-menu')), findsNothing);
    await w.close(t);
  });

  testWidgets('a press on the title bar leaves a dialog and its typed text alone', (t) async {
    final w = await ShellWorld.open(t, window: window);
    unawaited(
      showDialog<void>(
        context: t.element(find.byType(Scaffold).first),
        builder: (_) => const AlertDialog(content: TextField(key: ValueKey('typed'))),
      ),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('typed')), 'My title');
    await fromNative('ncPointerDown');
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('typed')), findsOneWidget);
    expect(find.text('My title'), findsOneWidget);
    Navigator.of(t.element(find.byKey(const ValueKey('typed')))).pop();
    await t.pumpAndSettle();
    await w.close(t);
  });

  testWidgets('a press on the title bar closes an open popup menu', (t) async {
    final w = await ShellWorld.open(t, window: window);
    await t.tap(find.byKey(const ValueKey('settings-menu')));
    await t.pumpAndSettle();
    expect(find.text('Radial context menu'), findsOneWidget);
    await fromNative('ncPointerDown');
    await t.pumpAndSettle();
    expect(find.text('Radial context menu'), findsNothing);
    await w.close(t);
  });
}
