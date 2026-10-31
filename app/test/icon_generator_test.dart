// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import '../scripts/generate_icons.dart';

void main() {
  // flutter test runs from app/.
  final master = Svg.parse(
    File('../docs/design/icon/noted-icon.svg').readAsStringSync(),
  );

  int alpha(Image img, int x, int y) => img.rgba[(y * img.size + x) * 4 + 3];

  int rgb(Image img, int x, int y) {
    final o = (y * img.size + x) * 4;
    return img.rgba[o] << 16 | img.rgba[o + 1] << 8 | img.rgba[o + 2];
  }

  test('a two-stop linear gradient interpolates and pads', () {
    const paint = Paint.linear(
      start: math.Point(0, 0),
      end: math.Point(10, 0),
      from: 0xFF000000,
      to: 0xFFC86420,
    );
    expect(paint.at(0, 5), 0xFF000000);
    expect(paint.at(10, -3), 0xFFC86420);
    expect(paint.at(5, 0), 0xFF643210);
    expect(paint.at(-4, 0), 0xFF000000);
    expect(paint.at(14, 0), 0xFFC86420);
  });

  test('stop offsets narrow the gradient', () {
    const paint = Paint.linear(
      start: math.Point(0, 0),
      end: math.Point(0, 10),
      from: 0xFF000000,
      to: 0xFFFFFFFF,
      fromOffset: 0.2,
      toOffset: 0.6,
    );
    expect(paint.at(0, 2), 0xFF000000);
    expect(paint.at(0, 4), 0xFF808080);
    expect(paint.at(0, 6), 0xFFFFFFFF);
  });

  test('the master strokes with its gradient, lighter top left', () {
    final img = render(master, 48);
    // Left stem near the top, right stem near the bottom.
    final top = rgb(img, 8, 10), bottom = rgb(img, 28, 40);
    expect(alpha(img, 8, 10), 255);
    expect(alpha(img, 28, 40), 255);
    int luma(int c) => (c >> 16) + ((c >> 8) & 0xFF) + (c & 0xFF);
    expect(luma(top), greaterThan(luma(bottom)));
    // Both within the two stop colors.
    for (final c in [top, bottom]) {
      expect(c >> 16, inInclusiveRange(0x0d, 0x2f));
      expect(c & 0xFF, inInclusiveRange(0x78, 0xc8));
    }
  });

  int inkInTopRight(Image img) {
    var n = 0;
    for (var y = 0; y < img.size * 0.3; y++) {
      for (var x = (img.size * 0.85).ceil(); x < img.size; x++) {
        if (alpha(img, x, y) > 0) n++;
      }
    }
    return n;
  }

  for (final size in [16, 20]) {
    test('$size px draws the N only, centred', () {
      final img = render(master, size);
      expect(inkInTopRight(img), 0);
      final cols = [
        for (var x = 0; x < size; x++)
          if (List.generate(size, (y) => alpha(img, x, y)).any((a) => a > 0)) x,
      ];
      expect(cols.first + cols.last, size - 1);
    });
  }

  for (final size in [24, 29, 32, 48]) {
    test('$size px keeps the d, a clear column from the N', () {
      final img = render(master, size);
      expect(inkInTopRight(img), greaterThan(0));
      // Across the d's rows, the right half has an empty column with ink on
      // both sides: the N's right stem, then the d.
      bool inked(int x) =>
          [for (var y = 0; y < size * 0.4; y++) alpha(img, x, y)]
              .any((a) => a > 0);
      final cols = List.generate(size, inked);
      expect(
        [
          for (var x = size ~/ 2; x < size - 1; x++)
            if (!cols[x] && cols[x - 1] && cols.skip(x + 1).any((c) => c)) x,
        ],
        isNotEmpty,
        reason: [for (final c in cols) c ? '#' : '.'].join(),
      );
    });
  }

  for (final size in [16, 24, 32]) {
    test('$size px: the N stems are whole opaque pixels', () {
      final img = render(master, size);
      // The master's N stroke width, rounded to whole pixels.
      final width = (72 * size / 410).round();
      // From the outside in, the first inked pixel of a stem row starts a
      // run of `width` opaque pixels: no partly covered edge column.
      List<int> fromEdge(int y, {required bool left}) {
        final xs = left
            ? List.generate(size, (i) => i)
            : List.generate(size, (i) => size - 1 - i);
        final start = xs.indexWhere((x) => alpha(img, x, y) > 0);
        return [
          for (final x in xs.skip(start).take(width + 1)) alpha(img, x, y),
        ];
      }

      // A row low down crosses the left stem clear of the diagonal; a row
      // below the d crosses the right stem (the d is right of it).
      final left = fromEdge((size * 0.75).round(), left: true);
      expect(left.take(width), everyElement(255), reason: '$left');
      expect(left.last, 0, reason: '$left');
      final y = (size * 0.45).round();
      final row = [for (var x = 0; x < size; x++) alpha(img, x, y)];
      final stemEnd = row.lastIndexWhere((a) => a > 0);
      expect(
        row.sublist(stemEnd + 1 - width, stemEnd + 1),
        everyElement(255),
        reason: '$row',
      );
      expect(row[stemEnd - width], lessThan(255), reason: '$row');
    });
  }
}
