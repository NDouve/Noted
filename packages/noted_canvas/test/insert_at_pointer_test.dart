// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Insert image and Insert file from the empty-canvas menu land at the point
// the menu opened at (Box API 0.16); from the toolbar or menu bar they land in
// the middle of the view. A page opened, a page turned read-only or a canvas
// closed while the picker is open: nothing is inserted.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'context_menu_world.dart';

void main() {
  late World w;
  late CanvasController other;

  Future<void> setUp(WidgetTester t) async {
    w = World(t)..disableAnimations = true;
    await w.pump(withStore: true);
    pickGate.armed = true;
    other = CanvasController(tpage(const [], id: 'q'), w.modules);
    addTearDown(other.dispose);
  }

  IncomingFile file() => IncomingFile('a.txt', Uint8List.fromList(const [1]));

  List<BoxRecord> files(CanvasController c) =>
      c.page.nodes.whereType<BoxRecord>().where((b) => b.typeId == 'test.file').toList();

  Future<Offset> openMenuAt(WidgetTester t, Offset screen) async {
    await w.rightClick(screen);
    expect(w.open, isTrue);
    return w.state.pageAtGlobal(screen)!;
  }

  for (final id in ['noted.image.insert', 'noted.file.insert']) {
    testWidgets('$id from the canvas menu inserts at the right-click point, zoomed', (t) async {
      await setUp(t);
      w.state.zoomTo(2);
      await t.pump();
      const screen = Offset(700, 500);
      final world = await openMenuAt(t, screen);
      await w.choose(id);
      expect(pickGate.seen, hasLength(1));
      expect(pickGate.seen.single, isNotNull);
      expect(pickGate.seen.single!.anchor, world);
      // The invocation is gone once the synchronous start is over.
      expect(w.state.invocation, isNull);
      expect(pickGate.seen.single!.isCurrent, isTrue);
      pickGate.pickers.single.complete([file()]);
      await t.pump();
      await t.pump();
      final made = files(w.c);
      expect(made, hasLength(1));
      expect(made.single.bounds.x, closeTo(world.dx, 0.001));
      expect(made.single.bounds.y, closeTo(world.dy, 0.001));
    });
  }

  testWidgets('from the toolbar or menu bar it inserts in the middle of the view', (t) async {
    await setUp(t);
    w.state.zoomTo(2);
    await t.pump();
    final centre = w.state.viewCentre!;
    final run = w.state.commands.invoke('noted.file.insert');
    await t.pump();
    expect(pickGate.seen.single, isNull);
    pickGate.pickers.single.complete([file()]);
    await run;
    await t.pump();
    final made = files(w.c).single;
    expect(made.bounds.x, closeTo(centre.dx, 0.001));
    expect(made.bounds.y, closeTo(centre.dy, 0.001));
  });

  testWidgets('invocation is null after the first await, and for a later toolbar run', (t) async {
    await setUp(t);
    await openMenuAt(t, const Offset(700, 500));
    await w.choose('noted.file.insert');
    pickGate.pickers.single.complete(const []);
    await t.pump();
    expect(pickGate.afterAwait, isNull);
    expect(w.state.invocation, isNull);
    final run = w.state.commands.invoke('noted.file.insert');
    await t.pump();
    expect(pickGate.seen.last, isNull);
    pickGate.pickers.last.complete(const []);
    await run;
  });

  testWidgets('a command that throws at its start leaves no invocation; a toolbar insert still lands at the view centre', (t) async {
    await setUp(t);
    final errors = <Object>[];
    await runZonedGuarded(() async {
      await openMenuAt(t, const Offset(700, 500));
      pickGate.throwSync = true;
      await w.choose('noted.file.insert');
    }, (e, _) => errors.add(e))!;
    expect(errors.single, isA<StateError>());
    expect(w.state.invocation, isNull);
    pickGate.throwSync = false;
    final centre = w.state.viewCentre!;
    final run = w.state.commands.invoke('noted.file.insert');
    await t.pump();
    expect(pickGate.seen.single, isNull);
    pickGate.pickers.single.complete([file()]);
    await run;
    await t.pump();
    final made = files(w.c).single;
    expect(made.bounds.x, closeTo(centre.dx, 0.001));
    expect(made.bounds.y, closeTo(centre.dy, 0.001));
  });

  testWidgets('another page opened while the picker is open: nothing on either page', (t) async {
    await setUp(t);
    await openMenuAt(t, const Offset(700, 500));
    await w.choose('noted.file.insert');
    final inv = pickGate.seen.single!;
    await w.rebuild(controller: other);
    expect(inv.isCurrent, isFalse);
    pickGate.pickers.single.complete([file()]);
    await t.pump();
    await t.pump();
    expect(files(w.c), isEmpty);
    expect(files(other), isEmpty);
  });

  testWidgets('the page turned read-only while the picker is open: nothing is inserted', (t) async {
    await setUp(t);
    await openMenuAt(t, const Offset(700, 500));
    await w.choose('noted.file.insert');
    final inv = pickGate.seen.single!;
    await w.rebuild(readOnly: true);
    expect(inv.isCurrent, isFalse);
    pickGate.pickers.single.complete([file()]);
    await t.pump();
    await t.pump();
    expect(files(w.c), isEmpty);
  });

  testWidgets('the canvas closed while the picker is open: isCurrent is false, nothing is inserted', (t) async {
    await setUp(t);
    await openMenuAt(t, const Offset(700, 500));
    await w.choose('noted.file.insert');
    final inv = pickGate.seen.single!;
    await t.pumpWidget(const SizedBox());
    expect(inv.isCurrent, isFalse);
    pickGate.pickers.single.complete([file()]);
    await t.pump();
    expect(files(w.c), isEmpty);
  });
}
