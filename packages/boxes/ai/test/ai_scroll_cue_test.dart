// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_ai/src/ai_scroll_cue.dart';

void main() {
  double cue(WidgetTester t) => t.widget<AnimatedOpacity>(find.byKey(const ValueKey('ai-scroll-cue'))).opacity;

  testWidgets('a nested scrollable does not switch the cue: only the panel\'s own scroll counts', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            // The panel's content fits; only the list inside it scrolls.
            child: AiScrollCue(
              child: SizedBox(
                height: 200,
                child: ListView(
                  key: const ValueKey('inner'),
                  children: [for (var i = 0; i < 30; i++) SizedBox(height: 40, child: Text('row $i'))],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(cue(t), 0, reason: 'the inner list continues, the panel does not');
    await t.drag(find.byKey(const ValueKey('inner')), const Offset(0, -100));
    await t.pumpAndSettle();
    expect(cue(t), 0);
  });

  testWidgets('the panel\'s own overflow shows the cue and reaching the end hides it', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 200,
            child: AiScrollCue(child: Column(children: [for (var i = 0; i < 20; i++) SizedBox(height: 40, child: Text('row $i'))])),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(cue(t), 1);
    await t.drag(find.text('row 3'), const Offset(0, -3000));
    await t.pumpAndSettle();
    expect(cue(t), 0);
  });
}
