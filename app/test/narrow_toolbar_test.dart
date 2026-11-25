// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The toolbar at the width of a phone (400 px) and at 900 px, with the real
// commands.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/settle_saves.dart';
import 'support/notebook_folder.dart';

void main() {
  late Directory dir;
  late Notebook nb;

  Future<void> open(WidgetTester t, double width, ToolbarStyle toolbar) async {
    t.view.physicalSize = Size(width, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('noted_narrow_toolbar');
      nb = Notebook(
        PageStore(Directory('${dir.path}/pages')..createSync()),
        buildModules(),
        saveDelay: Duration.zero,
      );
      await nb.load();
    });
    final settings = AppSettings(File('${dir.path}/settings.json'))..toolbar = toolbar;
    await t.pumpWidget(NotedApp(notebook: nb, settings: settings));
    await t.pump();
    await t.pumpAndSettle();
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await settleSaves(t, nb);
    await t.runAsync(() async {
      nb.dispose();
      await deleteTestFolder(dir);
    });
    // Before the test ends: the framework checks the override then.
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('tabs at 400 px: every tab is whole and clear of Undo and Search', (t) async {
    await open(t, 400, ToolbarStyle.tabs);
    final strip = t.getRect(
      find.descendant(of: find.byType(CommandToolbar), matching: find.byType(SingleChildScrollView)).first,
    );
    for (final k in ['home', 'insert', 'draw', 'view']) {
      final r = t.getRect(find.byKey(CommandToolbar.tabKey(k)));
      expect(strip.contains(r.centerLeft) && strip.contains(r.centerRight), isTrue, reason: k);
    }
    final undo = t.getRect(find.byKey(const ValueKey('canvas.undo')));
    expect(undo.overlaps(strip), isFalse);
    expect(t.takeException(), isNull);
    await close(t);
  });

  testWidgets('contextual at 400 px: the tools keep their size', (t) async {
    await open(t, 400, ToolbarStyle.contextual);
    expect(t.getRect(find.byKey(const ValueKey('canvas.select'))).width, closeTo(36, 0.01));
    expect(t.getRect(find.byKey(const ValueKey('canvas.undo'))).width, closeTo(36, 0.01));
    expect(find.byTooltip('More'), findsOneWidget);
    expect(t.takeException(), isNull);
    await close(t);
  });

  // 900 px (0178): on desktop the tree is inline (220), so the toolbar is 679
  // wide and compact; on a phone or tablet the drawer rule of 1000 holds and
  // the bar is the whole 900.
  for (final style in ToolbarStyle.values) {
    for (final mobile in [false, true]) {
      testWidgets('${style.name} at 900 px on ${mobile ? 'mobile' : 'desktop'}: whole and clear of the edge', (t) async {
        if (mobile) debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        await open(t, 900, style);
        final bar = t.getRect(find.byType(CommandToolbar));
        expect(bar.width, mobile ? 900 : 679);
        final search = find.byKey(const ValueKey('app.search'));
        final undo = find.byKey(const ValueKey('canvas.undo'));
        final redo = find.byKey(const ValueKey('canvas.redo'));
        for (final f in [search, undo, redo]) {
          expect(f, findsOneWidget);
          final r = t.getRect(f);
          // The phone rule scales the ends a little (0.3 share), as it did.
          expect(r.width, mobile ? greaterThan(30) : closeTo(36, 0.01), reason: 'not scaled down');
          expect(r.left, greaterThanOrEqualTo(bar.left));
          expect(r.right, lessThanOrEqualTo(bar.right));
          expect(r.bottom, lessThanOrEqualTo(bar.bottom));
        }
        if (style == ToolbarStyle.tabs && !mobile) {
          // Compact Tabs: the tabs have the first row, Undo, Redo and Search the
          // command row below.
          expect(t.getRect(undo).top, greaterThan(t.getRect(find.byKey(CommandToolbar.tabKey('home'))).bottom));
          expect(t.getRect(search).top, greaterThan(t.getRect(find.byKey(CommandToolbar.tabKey('home'))).bottom));
        }
        expect(t.takeException(), isNull);
        await close(t);
      });
    }
  }

  for (final style in ToolbarStyle.values) {
    testWidgets('${style.name} at 900 px on desktop, after a touch: wraps and nothing clips', (t) async {
      await open(t, 900, style);
      final g = await t.startGesture(const Offset(700, 600), kind: PointerDeviceKind.touch);
      await g.up();
      await t.pumpAndSettle();
      final bar = t.getRect(find.byType(CommandToolbar));
      expect(bar.width, 679);
      expect(find.byKey(const ValueKey('toolbar-more')), findsNothing, reason: 'touch wraps instead of More');
      final search = t.getRect(find.byKey(const ValueKey('app.search')));
      expect(search.right, lessThanOrEqualTo(bar.right));
      expect(search.bottom, lessThanOrEqualTo(bar.bottom));
      expect(t.takeException(), isNull);
      await close(t);
    });
  }
}