// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/app_theme.dart';

double _lum(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double _contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('snackbar action is AA readable in $brightness', (t) async {
      final theme = buildNotedTheme(brightness);
      late SnackBarThemeData resolved;
      await t.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Builder(
            builder: (context) {
              resolved = Theme.of(context).snackBarTheme;
              return const SizedBox();
            },
          ),
        ),
      );
      final background =
          resolved.backgroundColor ?? theme.colorScheme.inverseSurface;
      final action = resolved.actionTextColor!;
      expect(action, isNotNull);
      expect(_contrast(action, background), greaterThanOrEqualTo(4.5));
      final close =
          resolved.closeIconColor ?? theme.colorScheme.onInverseSurface;
      expect(_contrast(close, background), greaterThanOrEqualTo(4.5));
    });
  }
}
