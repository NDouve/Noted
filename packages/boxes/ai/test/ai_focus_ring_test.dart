// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_ai/src/ai_focus_ring.dart';

void main() {
  tearDown(
    () => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic,
  );

  Finder ring() => find.descendant(
    of: find.byType(FocusVisibleRing),
    matching: find.byType(DecoratedBox),
  );

  bool outlined(WidgetTester t) {
    final box = t
        .widgetList<DecoratedBox>(ring())
        .firstWhere((b) => b.position == DecorationPosition.foreground);
    return (box.decoration as BoxDecoration).border != null;
  }

  Future<void> pump(WidgetTester t) => t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FocusVisibleRing(
          child: SwitchListTile(
            key: const ValueKey('s'),
            value: false,
            onChanged: (_) {},
            title: const Text('Ask'),
          ),
        ),
      ),
    ),
  );

  testWidgets('focus by mouse or touch shows no outline', (t) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    await pump(t);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    // The tile really has focus (the ring tracks it), yet nothing is drawn.
    expect(FocusManager.instance.primaryFocus?.hasPrimaryFocus, isTrue);
    expect(outlined(t), isFalse);
  });

  testWidgets(
    'focus by keyboard shows the accent outline, and leaving removes it',
    (t) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      await pump(t);
      expect(outlined(t), isFalse, reason: 'nothing focused yet');
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(outlined(t), isTrue);
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      expect(outlined(t), isFalse);
    },
  );
}
