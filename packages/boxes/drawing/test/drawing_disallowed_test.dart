// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// On a page that disallows drawing boxes the pen and the eraser never decode,
// change, delete or add a drawing box (0111).

import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

int _decodes = 0;

/// The drawing codec, counting its decodes.
class _CountingCodec extends BoxCodec<DrawingData> {
  const _CountingCodec();
  static const _real = DrawingCodec();
  @override
  String get typeId => _real.typeId;
  @override
  int get dataVersion => _real.dataVersion;
  @override
  BoxApiVersion get apiVersion => _real.apiVersion;
  @override
  BoxSizing get sizing => _real.sizing;
  @override
  DrawingData create() => _real.create();
  @override
  DrawingData decode(Object? json, int storedVersion) {
    _decodes++;
    return _real.decode(json, storedVersion);
  }

  @override
  Object? encode(DrawingData data) => _real.encode(data);
  @override
  String snapshotText(DrawingData data) => _real.snapshotText(data);
  @override
  bool isEmpty(DrawingData data) => _real.isEmpty(data);
  @override
  AiExposure aiExposure(DrawingData data) => _real.aiExposure(data);
}

/// The real module's tools and views, with the counting codec.
class _CountingModule extends BoxModule<DrawingData> {
  _CountingModule(this.inner);
  final DrawingModule inner;
  @override
  BoxCodec<DrawingData> get codec => const _CountingCodec();
  @override
  List<CanvasTool> get tools => inner.tools;
  @override
  Widget buildEditor(BuildContext context, BoxContext<DrawingData> box) => inner.buildEditor(context, box);
  @override
  Widget buildView(BuildContext context, BoxContext<DrawingData> box) => inner.buildView(context, box);
}

class _Ctx implements ToolContext {
  _Ctx(this.controller);
  @override
  final CanvasController controller;
  @override
  double get scale => 1;
  @override
  Brightness get brightness => Brightness.light;
  @override
  NotedColors get colors => NotedColors.light;
  @override
  void repaintOverlay() {}
}

ToolPointer _at(double x, double y) =>
    ToolPointer(position: Offset(x, y), kind: PointerDeviceKind.mouse, time: Duration.zero);

/// A horizontal stroke at [y] from x 10 to 190 (content coordinates).
Stroke _line(String id, double y, int t0) => Stroke(
  id: id,
  points: Float64List.fromList([10, y, 0.5, 0, 190, y, 0.5, 10]),
  t0: t0,
);

void main() {
  late DrawingModule drawing;
  late CanvasController c;
  late _Ctx ctx;
  const codec = DrawingCodec();
  const boxId = 'b000000000000001';

  /// A drawing box at (100, 100) 200x200, with [ys] one stroke each, then the
  /// controller on it. Decodes are counted from here.
  void setup(List<double> ys) {
    drawing = DrawingModule();
    final modules = ModuleRegistry()..register(_CountingModule(drawing));
    var box = createBox(codec, const Bounds(100, 100, 200, 200)).withId(boxId);
    box = commitBox(box, codec, DrawingData(strokes: [for (var i = 0; i < ys.length; i++) _line('s$i', ys[i], i)]));
    c = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)).insertNode(box),
      modules,
    );
    ctx = _Ctx(c);
    _decodes = 0;
  }

  void disallow() => c.disallowedTypes = {DrawingCodec.id};
  void allow() => c.disallowedTypes = const {};

  String bytes() => writePage(c.page);

  List<String> strokeIds() => [
    for (final s in codec.decode((c.page.node(boxId)! as BoxRecord).data!.decode(), 1).strokes) s.id,
  ];

  test('an eraser drag across a disallowed drawing box changes nothing and decodes nothing', () {
    setup([30, 50, 70]);
    disallow();
    final before = bytes();
    final s = drawing.eraser.start(ctx, _at(250, 100))!;
    s.update(_at(250, 300));
    s.end();
    expect(bytes(), before);
    expect(_decodes, 0);
    expect(c.canUndo, isFalse);
    // The same drag on an allowed page erases.
    allow();
    final s2 = drawing.eraser.start(ctx, _at(250, 100))!;
    s2.update(_at(250, 300));
    s2.end();
    expect(bytes(), isNot(before));
  });

  test('the pen on a disallowed page starts no tool on a disallowed box and adds nothing', () {
    setup([30]);
    disallow();
    final before = bytes();
    final s = drawing.pen.start(ctx, _at(150, 150))!;
    s.update(_at(200, 180));
    s.end();
    expect(bytes(), before);
    expect(_decodes, 0);
  });

  group('disallowed during a drag', () {
    test('(i) the second stroke is kept, one blocked step records the first', () {
      setup([30, 120]);
      final s = drawing.eraser.start(ctx, _at(250, 130))!; // at y 30 on the page
      expect(strokeIds(), ['s1'], reason: 'the first stroke is erased');
      disallow();
      _decodes = 0;
      s.update(_at(250, 230)); // over the second stroke (page y 220)
      s.end();
      expect(_decodes, 0);
      expect(strokeIds(), ['s1'], reason: 'the second stroke is kept');
      expect(c.canUndo, isFalse, reason: 'one content step, blocked');
      allow();
      expect(c.canUndo, isTrue);
      c.undo();
      expect(strokeIds(), ['s0', 's1']);
      expect(c.canUndo, isFalse, reason: 'only the one step was recorded');
    });

    test('(ii) a box emptied by the drag is kept when the type is disallowed before it ends', () {
      setup([30]);
      final s = drawing.eraser.start(ctx, _at(250, 130))!;
      expect(strokeIds(), isEmpty);
      disallow();
      _decodes = 0;
      s.end();
      expect(c.page.node(boxId), isNotNull, reason: 'no emptied-box delete');
      expect(_decodes, 0);
      allow();
      c.undo();
      expect(strokeIds(), ['s0']);
    });

    test('(iii) a pen stroke ending after the disallow adds no stroke and no box', () {
      setup([30]);
      final s = drawing.pen.start(ctx, _at(150, 150))!;
      s.update(_at(200, 180));
      final before = bytes();
      disallow();
      s.end();
      expect(bytes(), before);
      expect(c.page.nodes, hasLength(1));
      expect(c.canUndo, isFalse);
    });

    test('a stroke outside any box on a disallowed page makes no new box', () {
      setup([30]);
      disallow();
      final before = bytes();
      final s = drawing.pen.start(ctx, _at(600, 600))!;
      s.update(_at(650, 650));
      s.end();
      expect(bytes(), before);
    });
  });
}
