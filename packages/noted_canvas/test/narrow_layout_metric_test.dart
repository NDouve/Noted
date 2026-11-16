// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';

// The width under which the layout is narrow is a theme metric (0178): 1000 by
// default, whatever the host sets otherwise.
void main() {
  Future<bool> narrowAt(
    WidgetTester t,
    double width, {
    ThemeData? theme,
  }) async {
    t.view.physicalSize = Size(width, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    late bool narrow;
    await t.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) {
            narrow = isNarrowLayout(context);
            return const SizedBox();
          },
        ),
      ),
    );
    return narrow;
  }

  test('the default is 1000, for a bare theme and for notedThemeData', () {
    expect(const NotedMetrics().narrowLayoutBelow, 1000);
    expect(
      notedThemeData(Brightness.light)
          .extension<NotedMetrics>()!
          .narrowLayoutBelow,
      1000,
    );
    expect(
      notedThemeData(Brightness.dark)
          .extension<NotedMetrics>()!
          .narrowLayoutBelow,
      1000,
    );
  });

  testWidgets(
    'with no NotedMetrics in the theme, 999 is narrow and 1000 is not',
    (t) async {
      expect(await narrowAt(t, 999), isTrue);
      expect(await narrowAt(t, 1000), isFalse);
    },
  );

  testWidgets('a host value of 720 moves the line to 720', (t) async {
    final theme = notedThemeData(Brightness.light, narrowLayoutBelow: 720);
    expect(await narrowAt(t, 719, theme: theme), isTrue);
    expect(await narrowAt(t, 720, theme: theme), isFalse);
    expect(await narrowAt(t, 900, theme: theme), isFalse);
    final dark = notedThemeData(Brightness.dark, narrowLayoutBelow: 720);
    expect(await narrowAt(t, 900, theme: dark), isFalse);
  });

  test('copyWith and lerp carry it', () {
    const m = NotedMetrics(narrowLayoutBelow: 720);
    expect(m.copyWith().narrowLayoutBelow, 720);
    expect(m.copyWith(narrowLayoutBelow: 800).narrowLayoutBelow, 800);
    expect(m.lerp(const NotedMetrics(), 0.2).narrowLayoutBelow, 720);
    expect(m.lerp(const NotedMetrics(), 0.8).narrowLayoutBelow, 1000);
  });
}
