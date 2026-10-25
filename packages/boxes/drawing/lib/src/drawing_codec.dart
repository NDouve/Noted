// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pure Dart: no Flutter imports, so the codec can later move into a package
// a non-UI process can load.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:noted_core/noted_core.dart';

/// One ink stroke. Immutable; edits add or remove whole strokes.
///
/// The stroke model is meant to be shared with reMarkable strokes (0030):
/// position, pressure and time for every point, plus tool, color and size.
final class Stroke {
  Stroke({
    required this.id,
    required this.points,
    this.tool = 'pen',
    this.color = 0xFF202124,
    this.size = 3,
    this.hasPressure = false,
    this.t0 = 0,
  }) : assert(points.length % 4 == 0 && points.isNotEmpty);

  final String id;
  final String tool;

  /// 0xAARRGGBB.
  final int color;

  /// Nominal width in page pixels.
  final double size;

  /// Whether pressure came from the device; if not, it is simulated when
  /// drawing and the stored pressure is 0.5.
  final bool hasPressure;

  /// When the stroke started, in milliseconds since the epoch.
  final int t0;

  /// Four values per point: x, y (content coordinates, see [DrawingData]),
  /// pressure (0 to 1) and time (ms since [t0]).
  final Float64List points;

  int get length => points.length ~/ 4;
  double x(int i) => points[i * 4];
  double y(int i) => points[i * 4 + 1];
  double pressure(int i) => points[i * 4 + 2];
  double time(int i) => points[i * 4 + 3];

  /// The centre line's extent, (minX, minY, maxX, maxY).
  late final (double, double, double, double) extent = () {
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (var i = 0; i < length; i++) {
      minX = math.min(minX, x(i));
      maxX = math.max(maxX, x(i));
      minY = math.min(minY, y(i));
      maxY = math.max(maxY, y(i));
    }
    return (minX, minY, maxX, maxY);
  }();
}

/// A drawing box's content.
///
/// Strokes are stored in content coordinates. A point `c` is drawn at page
/// position `box.topLeft + origin + c - scroll`, where scroll is the view's
/// internal scroll offset (a resized box scrolls the part it crops). When a
/// stroke grows the box to the left or upwards, only [origin] changes: the
/// strokes are never rewritten.
///
/// [erased] holds the ids of deleted strokes, so a sync merge (0020: strokes
/// merge as a union) can't bring an erased stroke back.
final class DrawingData {
  DrawingData({
    this.originX = 0,
    this.originY = 0,
    Iterable<Stroke> strokes = const [],
    Set<String> erased = const {},
  }) : strokes = List.unmodifiable(
         strokes.toList()..sort((a, b) {
           final c = a.t0.compareTo(b.t0);
           return c != 0 ? c : a.id.compareTo(b.id);
         }),
       ),
       erased = Set.unmodifiable(erased);

  final double originX;
  final double originY;

  /// In drawing order: by start time, then id. A fixed order keeps a merge or
  /// an undo from reshuffling overlapping strokes.
  final List<Stroke> strokes;
  final Set<String> erased;

  DrawingData copyWith({
    double? originX,
    double? originY,
    Iterable<Stroke>? strokes,
    Set<String>? erased,
  }) => DrawingData(
    originX: originX ?? this.originX,
    originY: originY ?? this.originY,
    strokes: strokes ?? this.strokes,
    erased: erased ?? this.erased,
  );

  /// The extent of all strokes in content coordinates, including their
  /// width, or null if there are none.
  (double, double, double, double)? get inkExtent {
    if (strokes.isEmpty) return null;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final s in strokes) {
      final (l, t, r, b) = s.extent;
      final half = s.size / 2;
      minX = math.min(minX, l - half);
      minY = math.min(minY, t - half);
      maxX = math.max(maxX, r + half);
      maxY = math.max(maxY, b + half);
    }
    return (minX, minY, maxX, maxY);
  }
}

/// The data side of the drawing box (0016).
final class DrawingCodec extends BoxCodec<DrawingData> {
  const DrawingCodec();

  static const String id = 'noted.drawing';

  @override
  String get typeId => id;

  @override
  int get dataVersion => 1;

  @override
  BoxApiVersion get apiVersion => boxApiVersion;

  /// The box doesn't size itself to its content the way a note does: the
  /// pen grows it to fit each stroke, and a resize crops it (0039).
  @override
  BoxSizing get sizing => BoxSizing.fixed;

  @override
  DrawingData create() => DrawingData();

  @override
  DrawingData decode(Object? json, int storedVersion) {
    if (json is! Map) throw const FormatException('not a drawing');
    final origin = json['origin'];
    final strokes = json['strokes'];
    final erased = json['erased'];
    if (origin is! List || origin.length != 2 || strokes is! List) {
      throw const FormatException('not a drawing');
    }
    return DrawingData(
      originX: (origin[0] as num).toDouble(),
      originY: (origin[1] as num).toDouble(),
      strokes: [for (final s in strokes) _decodeStroke(s)],
      erased: {if (erased is List) ...erased.cast<String>()},
    );
  }

  Stroke _decodeStroke(Object? s) {
    if (s is! Map) throw const FormatException('not a stroke');
    final pts = s['pts'];
    if (pts is! List || pts.isEmpty || pts.length % 4 != 0) {
      throw const FormatException('bad stroke points');
    }
    return Stroke(
      id: s['id'] as String,
      tool: s['tool'] as String? ?? 'pen',
      color: int.parse((s['color'] as String).substring(1), radix: 16),
      size: (s['size'] as num).toDouble(),
      hasPressure: s['pressure'] == true,
      t0: (s['t0'] as num?)?.toInt() ?? 0,
      points: Float64List.fromList([
        for (final v in pts) (v as num).toDouble(),
      ]),
    );
  }

  @override
  Object? encode(DrawingData data) => {
    'origin': [_num(data.originX), _num(data.originY)],
    'strokes': [
      for (final s in data.strokes)
        {
          'id': s.id,
          'tool': s.tool,
          'color': '#${s.color.toRadixString(16).padLeft(8, '0')}',
          'size': _num(s.size),
          'pressure': s.hasPressure,
          't0': s.t0,
          'pts': [
            for (var i = 0; i < s.length; i++) ...[
              _round(s.x(i), 10),
              _round(s.y(i), 10),
              _round(s.pressure(i), 100),
              s.time(i).round(),
            ],
          ],
        },
    ],
    if (data.erased.isNotEmpty) 'erased': (data.erased.toList()..sort()),
  };

  /// A drawing has no text.
  @override
  String snapshotText(DrawingData data) => '';

  @override
  bool isEmpty(DrawingData data) => data.strokes.isEmpty;

  /// No handwriting recognition yet: the AI only learns there is a drawing.
  @override
  AiExposure aiExposure(DrawingData data) => const AiPlaceholder('Drawing');

  /// Strokes merge as a union (0020), minus every stroke either side erased.
  /// Content coordinates don't depend on [DrawingData.origin] (only the
  /// box's anchor does), so the strokes need no conversion; [mine]'s origin
  /// is kept.
  @override
  MergeResult<DrawingData> merge(
    DrawingData base,
    DrawingData mine,
    DrawingData theirs,
  ) {
    final erased = {...mine.erased, ...theirs.erased};
    final byId = <String, Stroke>{
      for (final s in theirs.strokes) s.id: s,
      for (final s in mine.strokes) s.id: s,
    }..removeWhere((id, _) => erased.contains(id));
    return Merged(mine.copyWith(strokes: byId.values, erased: erased));
  }

  static num _num(double v) => v == v.roundToDouble() ? v.toInt() : v;

  static num _round(double v, int precision) =>
      _num((v * precision).roundToDouble() / precision);
}

/// A diff to a drawing for page undo: strokes to add, stroke ids to remove,
/// and optionally a new origin. Removing records the ids as erased; adding
/// clears them.
final class StrokeEdit implements BoxEdit {
  const StrokeEdit({this.add = const [], this.remove = const {}, this.origin});

  final List<Stroke> add;
  final Set<String> remove;
  final (double, double)? origin;

  @override
  (Object?, BoxEdit) apply(Object? data) {
    final d = data! as DrawingData;
    final removed = [
      for (final s in d.strokes)
        if (remove.contains(s.id)) s,
    ];
    final addIds = {for (final s in add) s.id};
    final next = d.copyWith(
      originX: origin?.$1,
      originY: origin?.$2,
      strokes: [
        for (final s in d.strokes)
          if (!remove.contains(s.id) && !addIds.contains(s.id)) s,
        ...add,
      ],
      erased: {...d.erased.difference(addIds), ...remove},
    );
    final inverse = StrokeEdit(
      add: removed,
      remove: addIds,
      origin: origin == null ? null : (d.originX, d.originY),
    );
    return (next, inverse);
  }
}
