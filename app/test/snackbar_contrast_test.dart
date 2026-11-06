// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/app_theme.dart';
import 'package:noted_canvas/noted_canvas.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'snackbar action and close icon are AA readable in $brightness',
      (t) async {
        final theme = buildNotedTheme(brightness);
        await t.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('Deleted'),
                      showCloseIcon: true,
                      action: SnackBarAction(label: 'Undo', onPressed: () {}),
                    ),
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.text('go'));
        await t.pumpAndSettle();

        final background = t
            .widget<Material>(
              find
                  .descendant(
                    of: find.byType(SnackBar),
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .color!;
        final button = t.widget<TextButton>(
          find.descendant(
            of: find.byType(SnackBarAction),
            matching: find.byType(TextButton),
          ),
        );
        final action = button.style!.foregroundColor!.resolve({})!;
        final closeIcon = t.widget<Icon>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byIcon(Icons.close),
          ),
        );
        final close =
            closeIcon.color ??
            IconTheme.of(t.element(find.byIcon(Icons.close))).color!;

        expect(contrastRatio(action, background), greaterThanOrEqualTo(4.5));
        expect(contrastRatio(close, background), greaterThanOrEqualTo(4.5));
      },
    );
  }
}
