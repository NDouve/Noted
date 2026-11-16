// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The radial presentation of the canvas's context menus: the same entries and
// rules as the list, six fixed slots round a Cancel button, kept inside the
// canvas rect.

import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'context_menu_world.dart';

void main() {
  late World w;

  Future<void> setUpWorld(
    WidgetTester t, {
    List<CanvasNode>? nodes,
    bool withStore = true,
    bool pen = true,
    Set<String> disallowed = const {},
    bool readOnly = false,
    Size size = const Size(1200, 800),
    double textScale = 1,
    bool animate = false,
    ContextMenuStyle style = ContextMenuStyle.radial,
  }) async {
    w = World(t)
      ..size = size
      ..textScale = textScale
      ..disableAnimations = !animate;
    await w.pump(
      nodes: nodes,
      withStore: withStore,
      pen: pen,
      disallowed: disallowed,
      readOnly: readOnly,
      style: style,
    );
  }

  Offset centreOf(WidgetTester t, String id) => t.getCenter(w.slot(id));

  Matcher isSize(Size s) => predicate<Size>((v) => (v.width - s.width).abs() < 0.001 && (v.height - s.height).abs() < 0.001, 'size $s');

  final cancel = find.byKey(const ValueKey('ring-cancel'));

  /// The canvas area: the window below the toolbar.
  Rect area([Size size = const Size(1200, 800)]) =>
      Rect.fromLTWH(0, CommandToolbar.height, size.width, size.height - CommandToolbar.height);

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump();
  }

  const canvasSlots = [
    'canvas.select',
    'noted.drawing.pen',
    'noted.image.insert',
    'canvas.paste',
    'canvas.find',
    'canvas.context.more',
  ];
  const boxSlots = [
    CanvasCommands.bringToFront,
    CanvasCommands.bringForward,
    CanvasCommands.sendBackward,
    CanvasCommands.sendToBack,
    'canvas.pickOverlappingBox',
    'canvas.context.more',
  ];

  testWidgets('a right click on empty canvas shows the ring with the canvas entries and Cancel, no dot', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(const Offset(600, 300)));
    expect(w.ring, findsOneWidget);
    expect(w.menu, findsNothing);
    expect(w.entries(), canvasSlots);
    expect(cancel, findsOneWidget);
    expect(find.byKey(const ValueKey('radial-dot')), findsNothing);
    // Not a mouse-up activation: nothing ran.
    expect(w.c.page.nodes, hasLength(3));
  });

  testWidgets('a box target has its six slots; Delete is not among them', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(overlapPoint));
    expect(w.ring, findsOneWidget);
    expect(w.entries(), boxSlots);
    expect(w.entries(), isNot(contains(CanvasCommands.delete)));
    expect(find.text('Delete box'), findsNothing);
    expect(w.c.selectedId, isNull);
  });

  testWidgets('the slot centres are exactly 118 px from the middle and k x 60 degrees clockwise', (t) async {
    await setUpWorld(t);
    for (final (p, slots) in [(overlapPoint, boxSlots), (const Offset(600, 300), canvasSlots)]) {
      await w.rightClick(w.at(p));
      final ids = w.entries();
      final c = t.getCenter(cancel);
      for (final (i, id) in slots.indexed) {
        expect(ids, contains(id));
        final d = centreOf(t, id) - c;
        var a = math.atan2(d.dx, -d.dy) * 180 / math.pi;
        if (a < 0) a += 360;
        expect(d.distance, closeTo(118, 0.001), reason: id);
        expect(a, closeTo(i * 60.0, 0.01), reason: id);
      }
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      expect(w.open, isFalse);
    }
  });

  testWidgets('slots are 132 x 32 inside 132 x 40 targets, Cancel is 68 x 36 in the middle', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(overlapPoint));
    for (final id in boxSlots) {
      expect(t.getSize(w.slot(id)), isSize(const Size(132, 40)), reason: id);
      final visual = find.descendant(
        of: w.slot(id),
        matching: find.byWidgetPredicate((x) => x is SizedBox && x.width == 132 && x.height == 32),
      );
      expect(visual, findsOneWidget, reason: id);
      expect(t.getCenter(visual), centreOf(t, id), reason: id);
      // No icon in a slot.
      expect(find.descendant(of: w.slot(id), matching: find.byType(Icon)), findsNothing, reason: id);
    }
    expect(t.getSize(cancel), isSize(const Size(68, 36)));
    final c = t.getCenter(cancel);
    expect(
      (centreOf(t, boxSlots[0]) + centreOf(t, boxSlots[3])) / 2,
      offsetMoreOrLessEquals(c, epsilon: 0.001),
    );
  });

  testWidgets('focus starts on Cancel; clockwise from it starts at the top, back at the last enabled slot', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(overlapPoint));
    // Bring to front and Bring forward are off (c is on top).
    expect(w.focused(), 'Cancel');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(w.focused(), 'Send backward');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    expect(w.focused(), 'Send to back');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(w.focused(), 'Pick overlapping');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(w.focused(), 'More…');
    // The arrows go round the slots; Tab has Cancel in its cycle.
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(w.focused(), 'Send backward');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.pump();
    expect(w.focused(), 'More…');
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    expect(w.focused(), 'Cancel');
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    expect(w.focused(), 'Send backward');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.pump();
    expect(w.focused(), 'More…');
    // Back from Cancel goes to the last enabled slot.
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    expect(w.focused(), 'Cancel');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.pump();
    expect(w.focused(), 'More…');
  });

  testWidgets('Enter on Cancel and a click on Cancel close the ring without running anything', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(overlapPoint));
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(t);
    expect(w.open, isFalse);
    expect(w.order, ['a', 'b', 'c']);
    await w.rightClick(w.at(overlapPoint));
    await t.tap(cancel);
    await settle(t);
    await settle(t);
    expect(w.open, isFalse);
    expect(w.order, ['a', 'b', 'c']);
  });

  testWidgets('Shift+Tab goes back through Cancel; Space on Cancel closes; a click on a dimmed slot does nothing', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(overlapPoint));
    // Cancel -> back -> the last enabled slot -> ... -> Send backward -> Cancel.
    for (final want in ['More…', 'Pick overlapping', 'Send to back', 'Send backward', 'Cancel', 'More…']) {
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      expect(w.focused(), want);
    }
    // A dimmed slot takes no click and moves no focus.
    await w.choose(CanvasCommands.bringForward);
    expect(w.ring, findsOneWidget);
    expect(w.order, ['a', 'b', 'c']);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    expect(w.focused(), 'Cancel');
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await settle(t);
    expect(w.open, isFalse);
    expect(w.order, ['a', 'b', 'c']);
  });

  testWidgets('slot text is left-aligned with a 10 px inset; the pick slot shows "Pick overlapping" and keeps its full name', (t) async {
    final handle = t.ensureSemantics();
    await setUpWorld(t);
    await w.rightClick(w.at(overlapPoint));
    final slot = w.slot('canvas.pickOverlappingBox');
    final text = find.descendant(of: slot, matching: find.byType(Text));
    expect(t.widget<Text>(text).data, 'Pick overlapping');
    final visual = find.descendant(
      of: slot,
      matching: find.byWidgetPredicate((x) => x is SizedBox && x.width == 132 && x.height == 32),
    );
    expect(t.getTopLeft(text).dx - t.getTopLeft(visual).dx, closeTo(10, 0.01));
    expect(t.getSemantics(slot).label, 'Pick overlapping box…');
    // The Cancel label stays in the middle.
    final cancelText = find.descendant(of: cancel, matching: find.byType(Text));
    expect(t.getCenter(cancelText).dx, closeTo(t.getCenter(cancel).dx, 0.5));
    expect(find.text('More…'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('an unavailable slot is dimmed and keeps its place', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(overlapPoint));
    final c = t.getCenter(cancel);
    expect(w.enabled(CanvasCommands.bringToFront), isFalse);
    final off = find.descendant(of: w.slot(CanvasCommands.bringToFront), matching: find.byType(Text));
    final on = find.descendant(of: w.slot(CanvasCommands.sendToBack), matching: find.byType(Text));
    final disabled = NotedColors.of(t.element(w.ring)).textDisabled;
    expect(t.widget<Text>(off).style!.color, disabled);
    expect(t.widget<Text>(on).style!.color, isNot(disabled));
    // At 12 o'clock exactly, as when it is on.
    expect(centreOf(t, CanvasCommands.bringToFront), offsetMoreOrLessEquals(c + const Offset(0, -118), epsilon: 0.001));
  });

  testWidgets('a command that is not there leaves its slot blank and moves no other', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(const Offset(600, 300)));
    final c = t.getCenter(cancel);
    final all = {for (final id in canvasSlots) id: centreOf(t, id) - c};
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(t);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(t);
    await t.pumpWidget(const SizedBox());
    // No pen tool: that slot is blank.
    await setUpWorld(t, pen: false);
    await w.rightClick(w.at(const Offset(600, 300)));
    expect(w.entries(), isNot(contains('noted.drawing.pen')));
    final c2 = t.getCenter(cancel);
    for (final id in w.entries()) {
      expect(centreOf(t, id) - c2, offsetMoreOrLessEquals(all[id]!, epsilon: 0.001), reason: id);
    }
  });

  testWidgets('More opens the list at the same anchor with Delete; Escape returns to More on the ring', (t) async {
    await setUpWorld(t);
    final p = w.at(overlapPoint);
    await w.rightClick(p);
    await w.choose('canvas.context.more');
    expect(w.ring, findsNothing);
    expect(w.menu, findsOneWidget);
    expect(w.entries(), contains(CanvasCommands.delete));
    expect(w.entries(), contains(CanvasCommands.bringForward));
    expect(w.focused(), 'Send backward');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(t);
    expect(w.menu, findsNothing);
    expect(w.ring, findsOneWidget);
    expect(w.focused(), 'More…');
    // Escape on the ring itself closes it.
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(t);
    expect(w.open, isFalse);
  });

  testWidgets('a slot runs on a primary click; Undo restores', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(overlapPoint));
    await w.choose(CanvasCommands.sendToBack);
    expect(w.order, ['c', 'a', 'b']);
    w.c.undo();
    expect(w.order, ['a', 'b', 'c']);
  });

  testWidgets('a disabled slot does nothing when clicked', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(overlapPoint));
    await w.choose(CanvasCommands.bringToFront);
    expect(w.ring, findsOneWidget);
    expect(w.order, ['a', 'b', 'c']);
  });

  testWidgets('Escape and a click outside close the ring and focus returns to the canvas', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(const Offset(600, 300)));
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(t);
    expect(w.open, isFalse);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'PageCanvas');
    await w.rightClick(w.at(const Offset(600, 300)));
    expect(w.ring, findsOneWidget);
    await t.tapAt(const Offset(5, 780));
    await settle(t);
    expect(w.open, isFalse);
    // The click was consumed: no note was made.
    expect(w.c.page.nodes, hasLength(3));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'PageCanvas');
  });

  testWidgets('releasing the right button over a slot does nothing', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(const Offset(600, 300)));
    final slotAt = centreOf(t, 'canvas.select');
    final g = await t.startGesture(slotAt, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await g.up();
    await g.removePointer();
    await t.pump();
    expect(w.c.page.nodes, hasLength(3));
    expect(w.ring, findsOneWidget);
  });

  testWidgets('keys inside the ring change nothing', (t) async {
    await setUpWorld(t);
    w.c.select('c');
    await t.pump();
    await w.rightClick(w.at(overlapPoint));
    expect(w.ring, findsOneWidget);
    for (final k in [
      LogicalKeyboardKey.delete,
      LogicalKeyboardKey.backspace,
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.keyP,
      LogicalKeyboardKey.keyE,
    ]) {
      await t.sendKeyEvent(k);
      await t.pump();
    }
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(w.ring, findsOneWidget);
    expect(w.c.page.nodes, hasLength(3));
    expect(w.order, ['a', 'b', 'c']);
    expect(w.selection.active, isNull);
  });

  testWidgets('a disallowed box gets the Delete-only list in radial mode, with no heading', (t) async {
    await setUpWorld(t, nodes: [tbox('x', 'test.off', ba, 'saved')], disallowed: {'test.off'});
    await w.rightClick(w.at(const Offset(200, 200)));
    expect(w.ring, findsNothing);
    expect(w.entries(), [CanvasCommands.delete]);
    expect(find.byKey(const ValueKey('context-heading')), findsNothing);
  });

  testWidgets('a read-only page opens the Find on page / Fit all list for an empty and a box target', (t) async {
    await setUpWorld(t, readOnly: true);
    for (final p in [const Offset(600, 300), overlapPoint]) {
      await w.rightClick(w.at(p));
      expect(w.ring, findsNothing, reason: '$p');
      expect(w.menu, findsOneWidget, reason: '$p');
      expect(w.entries(), [CanvasCommands.find, CanvasCommands.fitAll], reason: '$p');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      expect(w.open, isFalse);
    }
    expect(w.c.selectedId, isNull);
  });

  testWidgets('semantics: a menu container, each slot a button with its full name, Cancel too', (t) async {
    final handle = t.ensureSemantics();
    await setUpWorld(t);
    await w.rightClick(w.at(overlapPoint));
    expect(find.bySemanticsLabel('Context menu'), findsWidgets);
    final pick = t.getSemantics(w.slot('canvas.pickOverlappingBox'));
    expect(pick.label, 'Pick overlapping box…');
    expect(pick.flagsCollection.isButton, isTrue);
    expect(pick.flagsCollection.isEnabled, Tristate.isTrue);
    final off = t.getSemantics(w.slot(CanvasCommands.bringToFront));
    expect(off.flagsCollection.isEnabled, Tristate.isFalse);
    final c = t.getSemantics(cancel);
    expect(c.label, 'Cancel');
    expect(c.flagsCollection.isButton, isTrue);
    handle.dispose();
  });

  group('the focused slot and row', () {
    testWidgets('the focused slot has the accent-soft fill, accent text and a 2 px accent outline', (t) async {
      await setUpWorld(t);
      await w.rightClick(w.at(overlapPoint));
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      final scheme = Theme.of(t.element(w.ring)).colorScheme;
      final box = t.widget<DecoratedBox>(w.focusOutline);
      final d = box.decoration as BoxDecoration;
      expect(d.color, scheme.primaryContainer);
      expect((d.border! as Border).top.color, scheme.primary);
      expect((d.border! as Border).top.width, 2);
      final text = t.widget<Text>(find.descendant(of: w.focusOutline, matching: find.byType(Text)));
      expect(text.style!.color, scheme.primary);
      expect(text.style!.fontWeight, isNot(FontWeight.w700));
    });

    testWidgets('the focused list row has the accent-soft fill and accent bold text, not grey', (t) async {
      await setUpWorld(t, style: ContextMenuStyle.list);
      await w.rightClick(w.at(overlapPoint));
      final scheme = Theme.of(t.element(w.menu)).colorScheme;
      final d = t.widget<DecoratedBox>(w.focusOutline).decoration as BoxDecoration;
      expect(d.color, scheme.primaryContainer);
      final text = t.widget<Text>(find.descendant(of: w.focusOutline, matching: find.byType(Text)));
      expect(text.style!.color, scheme.primary);
      expect(text.style!.fontWeight, FontWeight.w700);
    });
  });

  group('kept inside the canvas rect', () {
    testWidgets('right click 4 px from each edge and corner: the centre is the clamped point, the bounds inside', (t) async {
      await setUpWorld(t);
      final a = area();
      final room = a.deflate(8);
      final inset = a.deflate(4);
      for (final p in [
        inset.topLeft,
        inset.topCenter,
        inset.topRight,
        inset.centerLeft,
        inset.centerRight,
        inset.bottomLeft,
        inset.bottomCenter,
        inset.bottomRight,
        a.center,
      ]) {
        await w.rightClick(p);
        expect(w.ring, findsOneWidget, reason: '$p');
        final want = Offset(
          p.dx.clamp(room.left + 190, room.right - 190).toDouble(),
          p.dy.clamp(room.top + 142, room.bottom - 142).toDouble(),
        );
        expect(t.getCenter(cancel), offsetMoreOrLessEquals(want, epsilon: 0.001), reason: '$p');
        final bounds = Rect.fromCenter(center: want, width: 380, height: 284);
        for (final id in canvasSlots) {
          final r = t.getRect(w.slot(id));
          expect(bounds.inflate(0.01).contains(r.topLeft), isTrue, reason: '$p $id');
          expect(bounds.inflate(0.01).contains(r.bottomRight), isTrue, reason: '$p $id');
        }
        expect(bounds.left, greaterThanOrEqualTo(room.left - 0.01), reason: '$p');
        expect(bounds.top, greaterThanOrEqualTo(room.top - 0.01), reason: '$p');
        expect(bounds.right, lessThanOrEqualTo(room.right + 0.01), reason: '$p');
        expect(bounds.bottom, lessThanOrEqualTo(room.bottom + 0.01), reason: '$p');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(t);
      }
    });

    testWidgets('a canvas smaller than 380 x 284 plus the margins opens the list; one that fits opens the ring', (t) async {
      // Width: 396 fits (380 + 2 x 8), 395 does not.
      await setUpWorld(t, size: const Size(395, 800));
      await w.rightClick(w.at(const Offset(60, 60)));
      await settle(t);
      expect(w.ring, findsNothing);
      expect(w.menu, findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await setUpWorld(t, size: const Size(396, 800));
      await w.rightClick(w.at(const Offset(60, 60)));
      await settle(t);
      expect(w.ring, findsOneWidget);
      await t.pumpWidget(const SizedBox());
      // Height: the canvas below the toolbar must hold 284 + 16.
      final h = CommandToolbar.height + 300 - 1;
      await setUpWorld(t, size: Size(1200, h));
      await w.rightClick(w.at(const Offset(600, 100)));
      await settle(t);
      expect(w.ring, findsNothing);
      expect(w.menu, findsOneWidget);
    });

    testWidgets('the list uses the canvas rect, not the window: the top margin and the flip', (t) async {
      await setUpWorld(t, style: ContextMenuStyle.list);
      final a = area();
      // 4 px under the canvas top: the list is pushed to the 8 px margin.
      await w.rightClick(Offset(600, a.top + 4));
      expect(t.getRect(w.menu).top, closeTo(a.top + 8, 0.01));
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      // 4 px above the bottom: it flips up and stays 8 px clear.
      await w.rightClick(Offset(600, a.bottom - 4));
      expect(t.getRect(w.menu).bottom, lessThanOrEqualTo(a.bottom - 8 + 0.01));
      expect(t.getRect(w.menu).top, greaterThanOrEqualTo(a.top + 8 - 0.01));
    });
  });

  testWidgets('shrinking the window under an open list or ring closes it; focus returns and the next right click works', (t) async {
    for (final style in [ContextMenuStyle.list, ContextMenuStyle.radial]) {
      await setUpWorld(t, style: style);
      final a = Rect.fromLTWH(0, CommandToolbar.height, 1200, 800 - CommandToolbar.height);
      await w.rightClick(a.bottomRight - const Offset(40, 40));
      expect(w.open, isTrue, reason: '$style');
      t.view.physicalSize = const Size(700, 500);
      await t.pump();
      await t.pump();
      await t.pump();
      expect(w.open, isFalse, reason: '$style');
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'PageCanvas', reason: '$style');
      expect(w.c.page.nodes, hasLength(3));
      await w.rightClick(const Offset(300, 300));
      expect(w.open, isTrue, reason: '$style');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump();
      await t.pumpWidget(const SizedBox());
    }
  });

  group('the canvas rect changes under an open menu', () {
    // A bar appearing above the canvas, or the toolbar wrapping after the input
    // mode changed, moves the canvas rect without a resize of the window.
    Rect canvasRect(WidgetTester t) => t.getRect(find.byKey(PageCanvas.overlayKey));

    Future<void> grow(WidgetTester t, double inset) async {
      w.topInset.value = inset;
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('an open ring stays open and re-clamps inside the new rect', (t) async {
      await setUpWorld(t);
      final top = canvasRect(t).top;
      await w.rightClick(Offset(600, top + 10));
      expect(t.getCenter(cancel).dy, closeTo(top + 8 + 142, 0.01));
      await grow(t, 60);
      expect(w.ring, findsOneWidget);
      final a = canvasRect(t);
      expect(a.top, closeTo(top + 60, 0.01));
      expect(t.getCenter(cancel).dy, closeTo(a.top + 8 + 142, 0.01));
      for (final id in canvasSlots) {
        expect(t.getRect(w.slot(id)).top, greaterThanOrEqualTo(a.top + 8 - 0.01), reason: id);
      }
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      expect(w.open, isFalse);
    });

    testWidgets('an open list stays open and re-clamps inside the new rect', (t) async {
      await setUpWorld(t, style: ContextMenuStyle.list);
      final top = canvasRect(t).top;
      await w.rightClick(Offset(600, top + 10));
      expect(t.getRect(w.menu).top, closeTo(top + 10, 0.01));
      await grow(t, 60);
      expect(w.menu, findsOneWidget);
      final a = canvasRect(t);
      expect(t.getRect(w.menu).top, closeTo(a.top + 8, 0.01));
      expect(t.getRect(w.menu).bottom, lessThanOrEqualTo(a.bottom - 8 + 0.01));
      // Back to where it was: the list follows.
      await grow(t, 0);
      expect(w.menu, findsOneWidget);
      expect(t.getRect(w.menu).top, closeTo(top + 10, 0.01));
    });

    testWidgets('a ring that no longer fits the new rect gives way to the list', (t) async {
      await setUpWorld(t);
      await w.rightClick(w.at(const Offset(600, 300)));
      expect(w.ring, findsOneWidget);
      await grow(t, 480);
      await t.pump();
      expect(w.ring, findsNothing);
      expect(w.menu, findsOneWidget);
      final a = canvasRect(t);
      expect(t.getRect(w.menu).top, greaterThanOrEqualTo(a.top + 8 - 0.01));
    });
  });

  group('motion', () {
    testWidgets('the ring fades in over 120 ms; reduced motion has no animation', (t) async {
      await setUpWorld(t, animate: true);
      await w.rightClick(w.at(const Offset(600, 300)));
      var fades = find.ancestor(of: w.ring, matching: find.byType(FadeTransition));
      expect(fades, findsWidgets);
      expect(t.widget<FadeTransition>(fades.first).opacity.value, lessThan(1));
      await t.pump(const Duration(milliseconds: 200));
      expect(t.widget<FadeTransition>(fades.first).opacity.value, 1);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());

      await setUpWorld(t);
      await w.rightClick(w.at(const Offset(600, 300)));
      fades = find.ancestor(of: w.ring, matching: find.byType(FadeTransition));
      for (final f in fades.evaluate()) {
        expect((f.widget as FadeTransition).opacity.value, 1);
      }
    });
  });

  group('themes', () {
    testWidgets('the ring draws under Light and Precision', (t) async {
      for (final b in [Brightness.light, Brightness.dark]) {
        w = World(t)
          ..theme = notedThemeData(b)
          ..disableAnimations = true;
        await w.pump(style: ContextMenuStyle.radial);
        await w.rightClick(w.at(const Offset(600, 300)));
        expect(w.ring, findsOneWidget);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(t);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(t);
      }
    });
  });
}
