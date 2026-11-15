// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:noted/main.dart';
import 'package:noted_box_ai/noted_box_ai.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

/// Test modules under their own type ids (an id registers once) that run the
/// real drawing and AI modules and count what the core asks of their codecs:
/// `decode` and `merge`. They are switchable (not always on), so a page, its
/// parents and the binder can disallow them.
const String spyDrawing = 'test.drawing';
const String spyAi = 'test.ai';

/// Calls by type id, as `'<type>.decode'` and `'<type>.merge'`.
class SpyCalls {
  static final Map<String, int> _n = {};
  static int of(String typeId, String call) => _n['$typeId.$call'] ?? 0;
  static int total(String typeId) => of(typeId, 'decode') + of(typeId, 'merge');
  static void reset() => _n.clear();
  static void _count(String typeId, String call) => _n['$typeId.$call'] = of(typeId, call) + 1;
}

class SpyCodec<D> extends BoxCodec<D> {
  const SpyCodec(this.typeId, this.inner);
  @override
  final String typeId;
  final BoxCodec<D> inner;
  @override
  int get dataVersion => inner.dataVersion;
  @override
  BoxApiVersion get apiVersion => inner.apiVersion;
  @override
  BoxSizing get sizing => inner.sizing;
  @override
  D create() => inner.create();
  @override
  D decode(Object? json, int storedVersion) {
    SpyCalls._count(typeId, 'decode');
    return inner.decode(json, storedVersion);
  }

  @override
  Object? encode(D data) => inner.encode(data);
  @override
  String snapshotText(D data) => inner.snapshotText(data);
  @override
  bool isEmpty(D data) => inner.isEmpty(data);
  @override
  AiExposure aiExposure(D data) => inner.aiExposure(data);
  @override
  D? aiWrite(D data, AiWrite write) => inner.aiWrite(data, write);
  @override
  MergeResult<D> merge(D base, D mine, D theirs) {
    SpyCalls._count(typeId, 'merge');
    return inner.merge(base, mine, theirs);
  }
}

class SpyModule<D> extends BoxModule<D> {
  SpyModule(String typeId, this.inner) : codec = SpyCodec<D>(typeId, inner.codec);
  final BoxModule<D> inner;
  @override
  final BoxCodec<D> codec;
  @override
  List<CanvasTool> get tools => inner.tools;
  @override
  BoxFrameStyle get frameStyle => inner.frameStyle;
  @override
  Widget buildEditor(BuildContext context, BoxContext<D> box) => inner.buildEditor(context, box);
  @override
  Widget buildView(BuildContext context, BoxContext<D> box) => inner.buildView(context, box);
}

/// The app's modules plus the two spy modules.
ModuleRegistry spyModules() => buildModules()
  ..register(SpyModule<DrawingData>(spyDrawing, DrawingModule()))
  ..register(SpyModule<AiBoxData>(spyAi, AiModule()));

/// A horizontal stroke at [y], with an id and a start time of its own.
Stroke spyStroke(String id, double y, {int t0 = 0}) =>
    Stroke(id: id, points: Float64List.fromList([10, y, 0.5, 0, 190, y, 0.5, 10]), t0: t0);

/// A spy drawing box with [strokes].
BoxRecord spyDrawingBox(
  String id,
  List<Stroke> strokes, {
  Bounds at = const Bounds(20, 20, 300, 200),
  String type = spyDrawing,
}) {
  final codec = SpyCodec<DrawingData>(type, const DrawingCodec());
  return commitBox(createBox(codec, at).withId(id), codec, DrawingData(strokes: strokes));
}

/// [box] with its strokes replaced by [strokes] (encoding is not counted).
BoxRecord withStrokes(BoxRecord box, List<Stroke> strokes) =>
    commitBox(box, SpyCodec<DrawingData>(box.typeId, const DrawingCodec()), DrawingData(strokes: strokes));
