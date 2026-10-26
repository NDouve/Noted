// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/binder_colors.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

String _hex(Color c) =>
    '#${c.toARGB32().toRadixString(16).toUpperCase().padLeft(8, '0')}';

void main() {
  final l = DesignColors.light;
  final d = DesignColors.dark;

  test('pen swatches are default ink and the four ink tokens', () {
    expect(PenSettings.colors, [
      0xFF202124,
      l.inkBlue.toARGB32(),
      l.inkOrange.toARGB32(),
      l.inkGreen.toARGB32(),
      l.inkPurple.toARGB32(),
    ]);
    expect(defaultInkValue, 0xFF202124);
    expect(l.inkDefault.toARGB32(), defaultInkValue);
  });

  test(
    'the binder palette is the binder tokens, stored as the light value',
    () {
      expect(binderPalette, [
        _hex(l.binderGreen),
        _hex(l.binderOrange),
        _hex(l.binderBlue),
        _hex(l.binderPurple),
        _hex(l.binderTeal),
      ]);
    },
  );

  test('a token value shows the theme\'s token; others are adjusted', () {
    for (final (light, dark) in [
      (l.binderGreen, d.binderGreen),
      (l.binderOrange, d.binderOrange),
      (l.binderBlue, d.binderBlue),
      (l.binderPurple, d.binderPurple),
      (l.binderTeal, d.binderTeal),
    ]) {
      expect(binderDisplayColor(light, d.bgApp, Brightness.light), light);
      expect(binderDisplayColor(light, d.bgApp, Brightness.dark), dark);
    }
    // Not a token value: lightness is raised until 3:1 on a dark surface.
    const odd = Color(0xFF3F51B5);
    final shown = binderDisplayColor(odd, d.bgApp, Brightness.dark);
    expect(shown, isNot(odd));
    expect(contrastRatio(shown, d.bgApp), greaterThanOrEqualTo(3));
  });
}
