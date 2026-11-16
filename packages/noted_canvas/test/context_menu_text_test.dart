// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The context menus draw their text with the app's styles and never cut a
// command label.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';

import 'context_menu_world.dart';

void main() {
  // The real Inter, so bold text is wider than regular (the test font is not).
  setUpAll(() async {
    final loader = FontLoader(DesignType.fontFamily);
    for (final f in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      final bytes = File('../../app/assets/fonts/Inter/Inter-$f.ttf').readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  });

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

    for (final bold in [false, true]) {
      testWidgets('the list is as wide as every row needs: whole labels, in $b, bold $bold', (t) async {
        final w = World(t)
          ..theme = notedThemeData(b)
          ..boldText = bold
          ..disableAnimations = true;
        await w.pump();
        await w.rightClick(w.at(overlapPoint));
        expect(w.menu, findsOneWidget);
        for (final label in ['Bring to front', 'Send to back', 'Bring forward', 'Send backward', 'Delete box']) {
          final f = find.text(label);
          expect(f, findsOneWidget, reason: label);
          final render = t.renderObject<RenderParagraph>(f);
          expect(render.didExceedMaxLines, isFalse, reason: label);
          // The label gets its whole intrinsic width (no rounding slack hides a cut).
          expect(render.size.width, greaterThanOrEqualTo(render.getMaxIntrinsicWidth(double.infinity)), reason: label);
        }
        // Every row is at least as wide as its content needs.
        for (final row in t.renderObjectList<RenderFlex>(
          find.descendant(of: w.menu, matching: find.byType(Row)),
        )) {
          expect(row.size.width, greaterThanOrEqualTo(row.getMinIntrinsicWidth(double.infinity) - 0.01));
        }
        expect(t.takeException(), isNull);
      });

      testWidgets('the ring keeps its labels on one line in $b, bold $bold', (t) async {
        final w = World(t)
          ..theme = notedThemeData(b)
          ..boldText = bold
          ..disableAnimations = true;
        await w.pump(style: ContextMenuStyle.radial);
        await w.rightClick(w.at(overlapPoint));
        expect(w.ring, findsOneWidget);
        // Labels are shortened to the fixed slot on one line, never wrapped.
        for (final e in find.descendant(of: w.ring, matching: find.byType(Text)).evaluate()) {
          final render = e.renderObject! as RenderParagraph;
          expect(render.size.height, lessThan(24));
        }
        // Nothing overflowed (a clipped pill reports a layout exception).
        expect(t.takeException(), isNull);
      });
    }
  }
}
