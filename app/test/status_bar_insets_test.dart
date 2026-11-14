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
import 'package:noted_core/noted_core.dart';

import 'support/settle_saves.dart';

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
      await dir.delete(recursive: true);
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
}
