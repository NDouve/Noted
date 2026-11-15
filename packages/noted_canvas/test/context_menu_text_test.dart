// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The context menus draw their text with the app's styles and never cut a
// command label.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';

import 'context_menu_world.dart';

void main() {
  for (final b in [Brightness.light, Brightness.dark]) {
    testWidgets('the ring draws no fallback underline and has a Material, in $b', (t) async {
      final w = World(t)
        ..theme = notedThemeData(b)
        ..disableAnimations = true;
      await w.pump(style: ContextMenuStyle.radial);
      for (final at in [const Offset(900, 600), overlapPoint]) {
        await w.rightClick(w.at(at));
        expect(w.ring, findsOneWidget);
        expect(find.ancestor(of: w.ring, matching: find.byType(Material)), findsWidgets);
        final texts = find.descendant(of: w.ring, matching: find.byType(Text));
        expect(texts, findsWidgets);
        for (final e in texts.evaluate()) {
          final style = DefaultTextStyle.of(e).style.merge((e.widget as Text).style);
          expect(style.decoration ?? TextDecoration.none, TextDecoration.none);
          expect(style.fontFamily, DesignType.fontFamily);
        }
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pump();
        await t.pump();
      }
    });

    testWidgets('the list shows whole command labels, in $b', (t) async {
      final w = World(t)
        ..theme = notedThemeData(b)
        ..disableAnimations = true;
      await w.pump();
      await w.rightClick(w.at(overlapPoint));
      expect(w.menu, findsOneWidget);
      for (final label in ['Bring to front', 'Send to back', 'Bring forward', 'Send backward', 'Delete box']) {
        final f = find.text(label);
        expect(f, findsOneWidget, reason: label);
        final render = t.renderObject<RenderParagraph>(f);
        expect(render.didExceedMaxLines, isFalse, reason: label);
        expect(render.size.width, greaterThanOrEqualTo(render.getMaxIntrinsicWidth(double.infinity) - 0.5), reason: label);
      }
    });
  }
}
