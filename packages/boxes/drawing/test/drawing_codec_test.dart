// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_core/noted_core.dart';

Stroke stroke(String id, {int t0 = 0, List<double>? pts}) => Stroke(
  id: id,
  t0: t0,
  points: Float64List.fromList(pts ?? [0, 0, 0.5, 0, 10, 5, 0.5, 16]),
);

void main() {
  const codec = DrawingCodec();

  test('round-trips through JSON, rounded to storage precision', () {
    final data = DrawingData(
      originX: 3,
      originY: -2.5,
      strokes: [
        Stroke(
          id: 's1',
          color: 0xFF1A73E8,
          size: 4,
          hasPressure: true,
          t0: 1700000000000,
          points: Float64List.fromList([
            1.234,
            5.678,
            0.4567,
            0.4,
            9,
            9,
            1,
            16.6,
          ]),
        ),
      ],
      erased: {'old'},
    );
    final json = RawJson.encode(codec.encode(data)).text;
    expect(json, contains('"pts":[1.2,5.7,0.46,0,9,9,1,17]'));
    expect(json, contains('"color":"#ff1a73e8"'));
    expect(json, contains('"erased":["old"]'));
    final back = codec.decode(RawJson.parse(json).decode(), 1);
    expect(back.originX, 3);
    expect(back.originY, -2.5);
    final s = back.strokes.single;
    expect(s.color, 0xFF1A73E8);
    expect(s.hasPressure, isTrue);
    expect(s.length, 2);
    expect(s.x(0), 1.2);
    expect(back.erased, {'old'});
  });

  test('strokes keep drawing order by start time, then id', () {
    final d = DrawingData(
      strokes: [stroke('b', t0: 2), stroke('c', t0: 1), stroke('a', t0: 2)],
    );
    expect(d.strokes.map((s) => s.id), ['c', 'a', 'b']);
  });

  test('rejects malformed data', () {
    expect(() => codec.decode('x', 1), throwsFormatException);
    expect(
      () => codec.decode({
        'origin': [0, 0],
      }, 1),
      throwsFormatException,
    );
    expect(
      () => codec.decode({
        'origin': [0, 0],
        'strokes': [
          {
            'id': 's',
            'color': '#ff000000',
            'size': 1,
            'pts': [1, 2, 3],
          },
        ],
      }, 1),
      throwsFormatException,
    );
  });

  test('a stroke edit removes into erased and its inverse adds back', () {
    final d = DrawingData(strokes: [stroke('a'), stroke('b')]);
    final (next, inverse) = const StrokeEdit(
      remove: {'a'},
      origin: (5, 6),
    ).apply(d);
    final n = next! as DrawingData;
    expect(n.strokes.map((s) => s.id), ['b']);
    expect(n.erased, {'a'});
    expect((n.originX, n.originY), (5.0, 6.0));

    final (back, _) = inverse.apply(n);
    final b = back! as DrawingData;
    expect(b.strokes.map((s) => s.id), ['a', 'b']);
    expect(b.erased, isEmpty);
    expect((b.originX, b.originY), (0.0, 0.0));
  });

  test('merge is a union of strokes minus everything either side erased', () {
    final base = DrawingData(strokes: [stroke('a'), stroke('b')]);
    final mine = DrawingData(
      strokes: [stroke('a'), stroke('b'), stroke('m')],
      erased: {'x'},
    );
    final theirs = DrawingData(
      strokes: [stroke('b'), stroke('t')],
      erased: {'a'},
    );
    final merged =
        (codec.merge(base, mine, theirs) as Merged<DrawingData>).data;
    expect(merged.strokes.map((s) => s.id).toSet(), {'b', 'm', 't'});
    expect(merged.erased, {'a', 'x'});
  });

  test('empty, no text, and only a placeholder for AI', () {
    expect(codec.isEmpty(codec.create()), isTrue);
    expect(codec.isEmpty(DrawingData(strokes: [stroke('a')])), isFalse);
    expect(codec.snapshotText(DrawingData(strokes: [stroke('a')])), '');
    expect(codec.aiExposure(codec.create()), isA<AiPlaceholder>());
  });

  test('the codec file imports no Flutter', () {
    final f = [
      File('lib/src/drawing_codec.dart'),
      File('packages/boxes/drawing/lib/src/drawing_codec.dart'),
    ].firstWhere((f) => f.existsSync());
    final imports = f.readAsLinesSync().where((l) => l.startsWith('import '));
    expect(imports, everyElement(isNot(contains('flutter'))));
    expect(imports, everyElement(isNot(contains('perfect_freehand'))));
  });
}
