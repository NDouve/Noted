// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_title_field.dart';
import 'package:noted/src/search_panel.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/settle_saves.dart';
import 'support/notebook_folder.dart';

void main() {
  late Directory dir;
  late Notebook nb;

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  // The page's title row, with the system status bar [top] pixels tall, on a
  // [size] screen of [platform]. Returns the top of the title field.
  Future<double> titleTop(WidgetTester t, TargetPlatform platform, Size size, double top) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    t.view.padding = FakeViewPadding(top: top);
    t.view.viewPadding = FakeViewPadding(top: top);
    addTearDown(t.view.reset);
    debugDefaultTargetPlatformOverride = platform;
    await t.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('noted_insets');
      nb = Notebook(PageStore(Directory('${dir.path}/pages')..createSync()), buildModules(), saveDelay: Duration.zero);
      await nb.load();
    });
    await t.pumpWidget(NotedApp(notebook: nb));
    await t.pump();
    final y = t.getTopLeft(find.byType(PageTitleField)).dy;
    await t.pumpWidget(const SizedBox());
    await settleSaves(t, nb);
    await t.runAsync(() async {
      nb.dispose();
      await deleteTestFolder(dir);
    });
    debugDefaultTargetPlatformOverride = null;
    return y;
  }

  const sizes = {
    'phone portrait': Size(400, 800),
    'phone landscape': Size(800, 400),
    'tablet portrait': Size(768, 1024),
    'tablet landscape': Size(1024, 768),
  };

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final e in sizes.entries) {
      testWidgets('$platform, ${e.key}: the toolbar starts below the status bar', (t) async {
        final flat = await titleTop(t, platform, e.value, 0);
        final barred = await titleTop(t, platform, e.value, 40);
        expect(barred, greaterThanOrEqualTo(40));
        expect(barred, flat + 40);
      });
    }
  }

  for (final e in sizes.entries) {
    testWidgets('desktop, ${e.key}: the top padding is unchanged', (t) async {
      final flat = await titleTop(t, TargetPlatform.windows, e.value, 0);
      final barred = await titleTop(t, TargetPlatform.windows, e.value, 40);
      expect(barred, flat);
    });
  }

  // The app on a [size] screen of [platform] with the system bars [pad] thick,
  // checked by [body].
  Future<void> withInsets(
    WidgetTester t,
    TargetPlatform platform,
    Size size,
    FakeViewPadding pad,
    Future<void> Function() body,
  ) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    t.view.padding = pad;
    t.view.viewPadding = pad;
    addTearDown(t.view.reset);
    debugDefaultTargetPlatformOverride = platform;
    await t.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('noted_insets');
      nb = Notebook(PageStore(Directory('${dir.path}/pages')..createSync()), buildModules(), saveDelay: Duration.zero);
      await nb.load();
    });
    await t.pumpWidget(NotedApp(notebook: nb));
    await t.pump();
    await body();
    await t.pumpWidget(const SizedBox());
    await settleSaves(t, nb);
    await t.runAsync(() async {
      nb.dispose();
      await deleteTestFolder(dir);
    });
    debugDefaultTargetPlatformOverride = null;
  }

  const pad = FakeViewPadding(top: 30, bottom: 34, left: 44, right: 40);
  const phone = Size(400, 800);

  // [r] lies inside the screen minus the insets, on all four edges.
  void within(Rect r, Size size, String what) {
    expect(r.top, greaterThanOrEqualTo(pad.top), reason: '$what: top');
    expect(r.left, greaterThanOrEqualTo(pad.left), reason: '$what: left');
    expect(r.right, lessThanOrEqualTo(size.width - pad.right), reason: '$what: right');
    expect(r.bottom, lessThanOrEqualTo(size.height - pad.bottom), reason: '$what: bottom');
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform, narrow: the page controls and the drawer keep inside every inset', (t) async {
      await withInsets(t, platform, phone, pad, () async {
        for (final key in ['sidebar-menu', 'page-settings']) {
          within(t.getRect(find.byKey(ValueKey(key))), phone, key);
        }
        within(t.getRect(find.byType(PageTitleField)), phone, 'title');
        within(t.getRect(find.byType(PageCanvas)), phone, 'canvas');

        t.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
        await t.pumpAndSettle();
        final drawer = find.byType(Drawer);
        expect(drawer, findsOneWidget);
        within(t.getRect(find.descendant(of: drawer, matching: find.byType(Column)).first), phone, 'drawer column');
        within(t.getRect(find.descendant(of: drawer, matching: find.byType(SearchField))), phone, 'drawer search');
      });
    });
  }

  testWidgets('tablet: the sidebar and the page controls keep inside every inset', (t) async {
    const tablet = Size(1024, 768);
    await withInsets(t, TargetPlatform.iOS, tablet, pad, () async {
      expect(find.byType(Drawer), findsNothing);
      within(t.getRect(find.byKey(const ValueKey('page-settings'))), tablet, 'page settings');
      within(t.getRect(find.byType(PageTitleField)), tablet, 'title');
      within(t.getRect(find.byType(PageCanvas)), tablet, 'canvas');
      within(t.getRect(find.byType(SearchField)), tablet, 'sidebar search');
    });
  });

  testWidgets('desktop: insets on all four edges leave the layout unchanged', (t) async {
    Future<List<Rect>> rects(FakeViewPadding p) async {
      late List<Rect> r;
      await withInsets(t, TargetPlatform.windows, const Size(1024, 768), p, () async {
        r = [
          t.getRect(find.byType(PageTitleField)),
          t.getRect(find.byType(PageCanvas)),
          t.getRect(find.byType(SearchField)),
        ];
      });
      return r;
    }

    final flat = await rects(FakeViewPadding.zero);
    expect(await rects(pad), flat);
  });
}
