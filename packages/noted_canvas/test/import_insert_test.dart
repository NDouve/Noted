// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

class _Codec extends BoxCodec<String> {
  const _Codec(this.typeId, this.sizing);
  @override
  final String typeId;
  @override
  final BoxSizing sizing;
  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  String create() => '';
  @override
  String decode(Object? json, int storedVersion) => json! as String;
  @override
  Object? encode(String data) => data;
  @override
  String snapshotText(String data) => data;
  @override
  bool isEmpty(String data) => data.trim().isEmpty;
  @override
  AiExposure aiExposure(String data) => AiText(data);
}

/// A module that takes any file by name; [gate] holds each file back.
class _Module extends BoxModule<String> {
  const _Module(this.id, this.sizing, this.affinity, this.size, [this.gate]);
  final String id;
  final BoxSizing sizing;
  final int affinity;
  final Size size;
  final Future<void> Function()? gate;
  @override
  BoxCodec<String> get codec => _Codec(id, sizing);
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) => Text(box.data);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) => Text(box.data);
  @override
  int fileAffinity(IncomingFile file) => affinity;
  @override
  Future<(String, Size)?> createFromFile(IncomingFile file, AttachmentStore store) async {
    await gate?.call();
    if (file.name.startsWith('bad')) return null;
    return (file.name, size);
  }
}

class _Store implements AttachmentStore {
  final List<String> notices = [];
  @override
  void notify(String message) => notices.add(message);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

IncomingFile _f(String name) => IncomingFile(name, Uint8List.fromList(const [1]));

void main() {
  Future<void> Function()? gate;
  late ModuleRegistry modules;
  late _Store store;

  setUp(() {
    gate = null;
    store = _Store();
    modules = ModuleRegistry()
      ..register(_Module('test.note', BoxSizing.growsWithContent, 0, const Size(200, 40), () => gate?.call() ?? Future.value()), alwaysOn: true, isDefault: true)
      ..register(const _Module('test.img', BoxSizing.fixed, 5, Size(100, 80)));
  });

  CanvasController controller(String id) =>
      CanvasController(NotedPage.create(PageMeta.create(id: id, title: id, order: 0)), modules);

  Future<PageCanvasState> pump(
    WidgetTester t,
    CanvasController c, {
    Set<String> disallowed = const {},
    bool readOnly = false,
    AttachmentStore? attachments,
  }) async {
    t.view.physicalSize = const Size(1000, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    c.disallowedTypes = {for (final id in disallowed) if (c.modules.isSwitchable(id)) id};
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageCanvas(
            key: const ValueKey('canvas'),
            controller: c,
            attachments: attachments ?? store,
            disallowedTypes: disallowed,
            readOnly: readOnly,
          ),
        ),
      ),
    );
    return t.state<PageCanvasState>(find.byType(PageCanvas));
  }

  List<BoxRecord> boxes(CanvasController c) => c.page.nodes.whereType<BoxRecord>().toList();

  testWidgets('the named module takes every file; notes keep their auto height and go side by side', (t) async {
    final c = controller('a');
    final s = await pump(t, c);
    final target = s.captureImportTarget(const Offset(100, 50))!;
    final r = await s.insertImportInto(target, [_f('a.x'), _f('b.x'), _f('c.x')], module: 'test.note');
    await t.pump();
    expect(r.added, 3);
    final b = boxes(c);
    expect(b.map((e) => e.typeId), everyElement('test.note'), reason: 'affinity 0, so only the name chooses');
    expect(b.map((e) => e.bounds.x), [100, 324, 548]);
    expect(b.map((e) => e.bounds.y), everyElement(50));
    expect(b.map((e) => e.fixedHeight), everyElement(isFalse));
    expect(target.point.dx, 772, reason: 'the next import goes on past them');
    c.dispose();
  });

  testWidgets('other modules\' boxes are stacked down and keep a fixed height', (t) async {
    final c = controller('a');
    final s = await pump(t, c);
    final target = s.captureImportTarget(const Offset(100, 50))!;
    await s.insertImportInto(target, [_f('a.x'), _f('b.x')], module: 'test.img');
    await t.pump();
    final b = boxes(c);
    expect(b.map((e) => e.bounds.x), [100, 100]);
    expect(b.map((e) => e.bounds.y), [50, 146]);
    expect(b.map((e) => e.fixedHeight), everyElement(isTrue));
    c.dispose();
  });

  testWidgets('without a module the file chooses, as a paste does; a file that makes no box is named', (t) async {
    final c = controller('a');
    final s = await pump(t, c);
    final target = s.captureImportTarget(null)!;
    final r = await s.insertImportInto(target, [_f('a.x'), _f('bad.x')]);
    expect(boxes(c).map((e) => e.typeId), ['test.img']);
    expect(r.failed, ['bad.x']);
    expect(r.stopped, isFalse);
    c.dispose();
  });

  testWidgets('a type the page disallows is refused, and nothing is made', (t) async {
    final c = controller('a');
    final s = await pump(t, c, disallowed: {'test.img'});
    final target = s.captureImportTarget(Offset.zero)!;
    final r = await s.insertImportInto(target, [_f('a.x')], module: 'test.img');
    expect(r.refused, isTrue);
    expect(r.added, 0);
    expect(boxes(c), isEmpty);
    expect((await s.insertImportInto(target, [_f('a.x')], module: 'test.nothing')).refused, isTrue);
    c.dispose();
  });

  testWidgets('a read-only page or one without a store captures no target', (t) async {
    final c = controller('a');
    var s = await pump(t, c, readOnly: true);
    expect(s.captureImportTarget(null), isNull);
    c.dispose();
    final c2 = controller('b');
    t.view.physicalSize = const Size(1000, 700);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PageCanvas(key: const ValueKey('c2'), controller: c2)),
      ),
    );
    s = t.state<PageCanvasState>(find.byType(PageCanvas));
    expect(s.captureImportTarget(null), isNull);
    c2.dispose();
  });

  testWidgets('the target captured first stops the import when the page changes during conversion', (t) async {
    final a = controller('a');
    final b = controller('b');
    final release = Completer<void>();
    gate = () => release.future;
    final s = await pump(t, a);
    final target = s.captureImportTarget(const Offset(10, 10))!;
    expect(target.holds, isTrue);
    final done = s.insertImportInto(target, [_f('a.x'), _f('b.x')], module: 'test.note', stopNotice: 'Stopped.');
    await t.pump();
    // The other page opens while the first file is being made.
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageCanvas(key: const ValueKey('canvas'), controller: b, attachments: store),
        ),
      ),
    );
    expect(target.holds, isFalse);
    release.complete();
    final r = await done;
    await t.pump();
    expect(r.stopped, isTrue);
    expect(boxes(a), isEmpty);
    expect(boxes(b), isEmpty);
    expect(store.notices, ['Stopped.']);
    a.dispose();
    b.dispose();
  });

  testWidgets('a page that changes after the first box keeps that box and gets no more', (t) async {
    final a = controller('a');
    final b = controller('b');
    final s = await pump(t, a);
    final target = s.captureImportTarget(const Offset(10, 10))!;
    var n = 0;
    gate = () async {
      if (++n == 2) {
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PageCanvas(key: const ValueKey('canvas'), controller: b, attachments: store),
            ),
          ),
        );
      }
    };
    final r = await s.insertImportInto(target, [_f('a.x'), _f('b.x'), _f('c.x')], module: 'test.note');
    expect(r.added, 1);
    expect(r.stopped, isTrue);
    expect(boxes(a), hasLength(1));
    expect(boxes(b), isEmpty);
    expect(store.notices, [importStoppedNotice]);
    expect(importStoppedNotice, 'Import stopped: the page changed.');
    a.dispose();
    b.dispose();
  });

  testWidgets('a type disallowed after the capture stops the import', (t) async {
    final c = controller('a');
    final s = await pump(t, c);
    final target = s.captureImportTarget(Offset.zero)!;
    await pump(t, c, disallowed: {'test.img'});
    final r = await s.insertImportInto(target, [_f('a.x')], module: 'test.img');
    expect(r.stopped, isTrue);
    expect(store.notices, [importStoppedNotice]);
    expect(boxes(c), isEmpty);
    c.dispose();
  });
}
