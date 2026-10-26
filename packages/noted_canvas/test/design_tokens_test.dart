// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';

import '../../../app/scripts/generate_tokens.dart' show generateTokens;

String _normalize(String s) => s.replaceAll('\r\n', '\n');

void main() {
  test('design_tokens.g.dart is up to date with docs/design/tokens.json', () {
    final tokens = File('../../docs/design/tokens.json').readAsStringSync();
    final generated = File('lib/src/design_tokens.g.dart').readAsStringSync();
    expect(
      _normalize(generated),
      _normalize(generateTokens(tokens)),
      reason: 'run: dart run app/scripts/generate_tokens.dart',
    );
  });

  test('the theme maps tokens as the design README says', () {
    for (final (brightness, c) in [
      (Brightness.light, DesignColors.light),
      (Brightness.dark, DesignColors.dark),
    ]) {
      final theme = notedThemeData(brightness);
      final s = theme.colorScheme;
      expect(s.primary, c.accent);
      expect(s.onPrimary, c.onAccent);
      expect(s.primaryContainer, c.accentSoft);
      expect(s.onPrimaryContainer, c.accent);
      expect(s.surface, c.surface);
      expect(s.onSurface, c.text);
      expect(s.onSurfaceVariant, c.textMuted);
      expect(s.outline, c.border);
      expect(s.outlineVariant, c.borderBox);
      expect(s.error, c.error);
      expect(s.surfaceContainerLowest, c.bgCanvas);
      expect(s.surfaceContainerLow, c.bgApp);
      expect(theme.extension<NotedColors>()!.conflict, c.conflict);
      expect(theme.extension<NotedMetrics>()!.radiusLg, 8);
      expect(theme.textTheme.bodyMedium!.fontSize, 14);
      expect(theme.textTheme.bodyMedium!.fontFamily, contains('Inter'));
    }
  });

  group('contrast', () {
    for (final (name, c) in [
      ('light', DesignColors.light),
      ('dark', DesignColors.dark),
    ]) {
      test('text pairs reach 4.5:1 in $name', () {
        final pairs = <(String, Color, Color)>[
          for (final bg in [
            ('bg-app', c.bgApp),
            ('bg-sidebar', c.bgSidebar),
            ('bg-canvas', c.bgCanvas),
            ('surface', c.surface),
            ('surface-hover', c.surfaceHover),
          ]) ...[
            ('text on ${bg.$1}', c.text, bg.$2),
            ('text-muted on ${bg.$1}', c.textMuted, bg.$2),
          ],
          ('accent on accent-soft', c.accent, c.accentSoft),
          ('on-accent on accent', c.onAccent, c.accent),
          ('on-conflict on conflict', c.onConflict, c.conflict),
          ('error on surface', c.error, c.surface),
          ('error on bg-canvas', c.error, c.bgCanvas),
        ];
        for (final (label, fg, bg) in pairs) {
          expect(
            contrastRatio(fg, bg),
            greaterThanOrEqualTo(4.5),
            reason: label,
          );
        }
      });

      test('picked ink swatches stay visible on the canvas in $name', () {
        // The swatches are the same in both themes, so on the dark canvas
        // ink-purple is a little under 3:1 (2.8); that is the token data.
        for (final color in [c.inkBlue, c.inkOrange, c.inkGreen, c.inkPurple]) {
          expect(contrastRatio(color, c.bgCanvas), greaterThanOrEqualTo(2.5));
        }
      });

      test(
        'default ink and binder colors reach 3:1 on the canvas in $name',
        () {
          for (final (label, color) in [
            ('ink-default', c.inkDefault),
            ('binder-green', c.binderGreen),
            ('binder-orange', c.binderOrange),
            ('binder-blue', c.binderBlue),
            ('binder-purple', c.binderPurple),
            ('binder-teal', c.binderTeal),
          ]) {
            expect(
              contrastRatio(color, c.bgCanvas),
              greaterThanOrEqualTo(3),
              reason: label,
            );
          }
        },
      );
    }
  });
}
