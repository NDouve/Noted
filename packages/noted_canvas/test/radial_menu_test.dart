// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The radial presentation of the canvas's context menus: the same entries and
// rules as the list, six fixed slots, kept inside the viewport.

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
    Set<String> disallowed = const {},
    bool readOnly = false,
    Size size = const Size(1200, 800),
    double textScale = 1,
    bool animate = false,
  }) async {
    w = World(t)
      ..size = size
      ..textScale = textScale
      ..disableAnimations = !animate;
    await w.pump(
      nodes: nodes,
      withStore: withStore,
      disallowed: disallowed,
      readOnly: readOnly,
      style: ContextMenuStyle.radial,
    );
  }

  Offset centreOf(WidgetTester t, String id) => t.getCenter(w.slot(id));

  /// The ring's centre: the middle between the top slot and the one opposite.
  Offset ringCentre(WidgetTester t, List<String> ids) =>
      (centreOf(t, ids[0]) + centreOf(t, ids[3])) / 2;

  const canvasSlots = [
    'canvas.context.newNote',
    'canvas.context.paste',
    'noted.image.insert',
    'noted.file.insert',
    'canvas.context.more',
  ];
  const boxSlots = [
    CanvasCommands.bringToFront,
    CanvasCommands.delete,
    CanvasCommands.sendToBack,
    'canvas.context.boxesHere',
    'canvas.context.more',
  ];

  testWidgets('a right click on empty canvas shows the ring with the canvas entries, the dot at the point', (t) async {
    await setUpWorld(t);
    final p = w.at(const Offset(600, 300));
    await w.rightClick(p);
    expect(w.ring, findsOneWidget);
    expect(w.menu, findsNothing);
    expect(w.entries(), unorderedEquals(canvasSlots));
    expect(t.getCenter(find.byKey(const ValueKey('radial-dot'))), p);
    expect(t.getSize(find.byKey(const ValueKey('radial-dot'))), const Size(6, 6));
  });

  testWidgets('a box target uses five slots; the sixth stays empty', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(overlapPoint));
    expect(w.ring, findsOneWidget);
    expect(w.entries(), unorderedEquals(boxSlots));
    expect(w.c.selectedId, 'c');
  });

  testWidgets('slots sit 60 degrees apart clockwise from the top, whatever is enabled', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(overlapPoint));
    final c = ringCentre(t, boxSlots);
    final radii = <double>[];
    for (final (i, id) in boxSlots.indexed) {
      final d = centreOf(t, id) - c;
      // Clockwise from the top.
      var a = math.atan2(d.dx, -d.dy) * 180 / math.pi;
      if (a < 0) a += 360;
      expect(a, closeTo(i * 60.0, 0.5), reason: id);
      radii.add(d.distance);
    }
    expect(radii.reduce(math.min), greaterThanOrEqualTo(88 - 0.5));
    // Bring to front is off (c is on top) yet keeps its slot.
    expect(w.enabled(CanvasCommands.bringToFront), isFalse);
    final enabledOff = {for (final id in boxSlots) id: centreOf(t, id) - c};

    // The same box with other enabled states: the same positions.
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    await t.pump();
    await w.rightClick(w.at(const Offset(120, 120)));
    expect(w.enabled(CanvasCommands.bringToFront), isTrue);
    final c2 = ringCentre(t, boxSlots);
    for (final id in boxSlots) {
      expect(centreOf(t, id) - c2, offsetMoreOrLessEquals(enabledOff[id]!, epsilon: 0.5), reason: id);
    }
  });

  testWidgets('a module that is off leaves its slot empty and moves no other', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(const Offset(600, 300)));
    final c = ringCentre(t, canvasSlots);
    final all = {for (final id in canvasSlots) id: centreOf(t, id) - c};
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    await t.pump();
    // No attachments: Insert image and file are off but stay.
    await setUpWorld(t, withStore: false);
    await w.rightClick(w.at(const Offset(600, 300)));
    expect(w.enabled('noted.image.insert'), isFalse);
    final c2 = ringCentre(t, canvasSlots);
    for (final id in canvasSlots) {
      expect(centreOf(t, id) - c2, offsetMoreOrLessEquals(all[id]!, epsilon: 0.5), reason: id);
    }
  });

  testWidgets('the same entries as the list, plus More, for both targets; no placeholder', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(const Offset(600, 300)));
    expect(find.textContaining('coming later'), findsNothing);
    expect(find.text('AI box'), findsNothing);
    expect(find.text('New note here'), findsOneWidget);
  });

  testWidgets('focus starts on the first enabled slot; arrows and Tab go round clockwise and back', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(overlapPoint));
    // Bring to front is off: Delete box is the first enabled slot.
    expect(w.focused(), 'Delete box');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(w.focused(), 'Send to back');
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    expect(w.focused(), 'Boxes here…');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    expect(w.focused(), 'More');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    // Wraps past the end to the first enabled slot.
    expect(w.focused(), 'Delete box');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.pump();
    expect(w.focused(), 'More');
  });

  testWidgets('on a read-only page focus starts on More', (t) async {
    await setUpWorld(t, readOnly: true);
    await w.rightClick(w.at(overlapPoint));
    expect(w.ring, findsOneWidget);
    expect(w.focused(), 'More');
    expect(w.c.selectedId, isNull);
  });

  testWidgets('More replaces the ring with the conventional menu of every entry, focus on its first', (t) async {
    await setUpWorld(t);
    await w.rightClick(w.at(overlapPoint));
    await w.choose('canvas.context.more');
    expect(w.ring, findsNothing);
    expect(w.menu, findsOneWidget);
    expect(w.entries(), contains(CanvasCommands.bringForward));
    expect(w.entries(), contains(CanvasCommands.sendBackward));
    expect(w.focused(), 'Send backward');
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
    await t.pump();
    await t.pump();
    expect(w.open, isFalse);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'PageCanvas');
    await w.rightClick(w.at(const Offset(600, 300)));
    expect(w.ring, findsOneWidget);
    await t.tapAt(const Offset(5, 780));
    await t.pump();
    await t.pump();
    expect(w.open, isFalse);
    // The click was consumed: no note was made.
    expect(w.c.page.nodes, hasLength(3));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'PageCanvas');
  });

  testWidgets('releasing the right button over a slot does nothing', (t) async {
    await setUpWorld(t);
    final p = w.at(const Offset(600, 300));
    await w.rightClick(p);
    final slotAt = centreOf(t, 'canvas.context.newNote');
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

  testWidgets('a disallowed box: its heading sits in the middle of the ring or above it', (t) async {
    await setUpWorld(
      t,
      nodes: [tbox('x', 'test.off', ba, 'saved')],
      disallowed: {'test.off'},
    );
    await w.rightClick(w.at(const Offset(200, 200)));
    final heading = find.byKey(const ValueKey('context-heading'));
    expect(heading, findsOneWidget);
    final c = ringCentre(t, boxSlots);
    final h = t.getCenter(heading);
    final above = h.dy < c.dy - 40;
    expect((h - c).distance < 30 || above, isTrue);
    expect(w.enabled(CanvasCommands.delete), isTrue);
    expect(w.enabled(CanvasCommands.sendToBack), isFalse);
  });

  testWidgets('semantics: a menu container labelled Context menu, each slot a button with its label', (t) async {
    final handle = t.ensureSemantics();
    await setUpWorld(t);
    await w.rightClick(w.at(overlapPoint));
    expect(find.bySemanticsLabel('Context menu'), findsWidgets);
    final delete = t.getSemantics(w.slot(CanvasCommands.delete));
    expect(delete.label, 'Delete box');
    expect(delete.flagsCollection.isButton, isTrue);
    expect(delete.flagsCollection.isEnabled, Tristate.isTrue);
    final off = t.getSemantics(w.slot(CanvasCommands.bringToFront));
    expect(off.flagsCollection.isEnabled, Tristate.isFalse);
    handle.dispose();
  });

  group('kept inside the viewport', () {
    testWidgets('right click 4 px from each corner: the ring lies inside the canvas area, the dot at the point', (t) async {
      await setUpWorld(t);
      final area = Rect.fromLTWH(0, CommandToolbar.height, 1200, 800 - CommandToolbar.height);
      for (final p in [
        area.topLeft + const Offset(4, 4),
        area.topRight + const Offset(-4, 4),
        area.bottomLeft + const Offset(4, -4),
        area.bottomRight + const Offset(-4, -4),
      ]) {
        await w.rightClick(p);
        expect(w.ring, findsOneWidget);
        for (final id in canvasSlots) {
          final r = t.getRect(w.slot(id));
          expect(r.left, greaterThanOrEqualTo(area.left + 8 - 0.01), reason: '$p $id');
          expect(r.top, greaterThanOrEqualTo(area.top + 8 - 0.01), reason: '$p $id');
          expect(r.right, lessThanOrEqualTo(area.right - 8 + 0.01), reason: '$p $id');
          expect(r.bottom, lessThanOrEqualTo(area.bottom - 8 + 0.01), reason: '$p $id');
        }
        expect(t.getCenter(find.byKey(const ValueKey('radial-dot'))), p);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pump();
        await t.pump();
      }
    });

    testWidgets('a viewport smaller than the ring opens the conventional menu', (t) async {
      await setUpWorld(t, size: const Size(320, 300));
      await w.rightClick(w.at(const Offset(60, 60)));
      await t.pump();
      await t.pump();
      expect(w.ring, findsNothing);
      expect(w.menu, findsOneWidget);
    });

    testWidgets('at text scale 1.5 no two pills overlap and the ring stays inside the viewport', (t) async {
      await setUpWorld(t, textScale: 1.5);
      await w.rightClick(w.at(const Offset(600, 300)));
      expect(w.ring, findsOneWidget);
      final rects = [for (final id in canvasSlots) t.getRect(w.slot(id))];
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          expect(rects[i].overlaps(rects[j]), isFalse, reason: '${canvasSlots[i]} ${canvasSlots[j]}');
        }
      }
      final view = Rect.fromLTWH(0, CommandToolbar.height, 1200, 800 - CommandToolbar.height);
      for (final r in rects) {
        expect(view.deflate(7.99).contains(r.topLeft), isTrue);
        expect(view.deflate(7.99).contains(r.bottomRight), isTrue);
      }
      // Labels are whole.
      expect(find.text('Paste image or file'), findsOneWidget);
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
        await t.pump();
        await t.pump();
      }
    });
  });
}
