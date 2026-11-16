// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Insert image and Insert file from the empty-canvas menu put the box at the
// right-click point; a picker that returns after the page changed adds nothing.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'fake_store.dart';

void main() {
  late CanvasController c;
  late FakeStore store;
  final key = GlobalKey<PageCanvasState>();

  Widget app(CanvasController controller) => MaterialApp(
    theme: notedThemeData(Brightness.light),
    home: Scaffold(
      body: PageCanvas(key: key, controller: controller, attachments: store),
    ),
  );

  Future<void> pump(WidgetTester t, {CanvasController? controller}) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final modules = ModuleRegistry()
      ..register(const ImageModule())
      ..register(const FileModule(), isDefault: true);
    c = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)),
      modules,
    );
    addTearDown(c.dispose);
    await t.pumpWidget(app(controller ?? c));
    await t.pump();
    key.currentState!.zoomTo(2);
    await t.pump();
  }

  setUp(() => store = PageFolderFakeStore());

  List<BoxRecord> boxes(CanvasController x) => x.page.nodes.whereType<BoxRecord>().toList();

  final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7 fake'));

  Future<Offset> choose(WidgetTester t, String id) async {
    const screen = Offset(600, 500);
    final g = await t.startGesture(screen, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await g.up();
    await g.removePointer();
    await t.pump();
    await t.tap(find.byKey(ValueKey('context-$id')));
    for (var i = 0; i < 4; i++) {
      await t.pump();
    }
    return key.currentState!.pageAtGlobal(screen)!;
  }

  for (final (id, typeId, file) in [
    (ImageCommands.insert, ImageCodec.id, IncomingFile('red.png', redPng)),
    (FileCommands.insert, FileCodec.id, IncomingFile('x.pdf', pdf)),
  ]) {
    testWidgets('$id from the canvas menu inserts at the right-click point', (t) async {
      await pump(t);
      store.toPick = [file];
      store.pickGate = Completer<void>();
      final world = await choose(t, id);
      store.pickGate!.complete();
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.pump();
      final made = boxes(c).single;
      expect(made.typeId, typeId);
      expect(made.bounds.x, closeTo(world.dx, 0.001));
      expect(made.bounds.y, closeTo(world.dy, 0.001));
    });

    testWidgets('$id from the toolbar inserts in the middle of the view', (t) async {
      await pump(t);
      store.toPick = [file];
      final centre = key.currentState!.viewCentre!;
      await t.runAsync(() => key.currentState!.commands.invoke(id));
      await t.pump();
      final made = boxes(c).single;
      expect(made.bounds.x, closeTo(centre.dx, 0.001));
      expect(made.bounds.y, closeTo(centre.dy, 0.001));
    });

    testWidgets('$id: a page opened while the picker is open adds nothing', (t) async {
      await pump(t);
      store.toPick = [file];
      store.pickGate = Completer<void>();
      await choose(t, id);
      final other = CanvasController(
        NotedPage.create(PageMeta.create(id: 'q', title: '', order: 0)),
        c.modules,
      );
      addTearDown(other.dispose);
      await t.pumpWidget(app(other));
      store.pickGate!.complete();
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.pump();
      expect(boxes(c), isEmpty);
      expect(boxes(other), isEmpty);
      expect(store.notices, [insertStoppedNotice]);
    });
  }
}
