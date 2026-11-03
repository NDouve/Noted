// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_tree_view.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/settle_saves.dart';

void main() {
  late Directory dir;
  late Notebook nb;
  late AppSettings settings;
  late String second;

  Future<void> open(WidgetTester t, Size size, {ToolbarStyle toolbar = ToolbarStyle.tabs}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('noted_narrow');
      nb = Notebook(
        PageStore(Directory('${dir.path}/pages')..createSync()),
        buildModules(),
        saveDelay: Duration.zero,
      );
      await nb.load();
      final first = nb.currentId!;
      second = await nb.createPage();
      await nb.open(first);
    });
    settings = AppSettings(File('${dir.path}/settings.json'))..toolbar = toolbar;
    await t.pumpWidget(NotedApp(notebook: nb, settings: settings));
    await t.pump();
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await settleSaves(t, nb);
    await t.runAsync(() async {
      nb.dispose();
      await dir.delete(recursive: true);
    });
  }

  testWidgets('phone width: the sidebar is a drawer, closed when a page is chosen', (t) async {
    await open(t, const Size(400, 800));
    expect(find.byType(PageTreeView), findsNothing);
    await t.tap(find.byKey(const ValueKey('sidebar-menu')));
    await t.pumpAndSettle();
    expect(find.byType(PageTreeView), findsOneWidget);

    await t.runAsync(() => nb.open(second));
    await t.pumpAndSettle();
    expect(nb.currentId, second);
    expect(find.byType(PageTreeView), findsNothing);
    await close(t);
  });

  testWidgets('desktop and iPad landscape widths keep the sidebar inline', (t) async {
    for (final w in [1280.0, 1024.0]) {
      await open(t, Size(w, 800));
      expect(find.byType(PageTreeView), findsOneWidget);
      expect(find.byKey(const ValueKey('sidebar-menu')), findsNothing);
      await close(t);
    }
  });

  for (final style in ToolbarStyle.values) {
    testWidgets('phone width: the ${style.name} toolbar uses More, also on touch', (t) async {
      await open(t, const Size(400, 800), toolbar: style);
      // A touch input switches the app to touch sizes, which wrap on a wide
      // window; at this width the More menu stays.
      final g = await t.startGesture(const Offset(380, 500), kind: PointerDeviceKind.touch);
      await g.up();
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('toolbar-more')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('toolbar-more')));
      await t.pumpAndSettle();
      expect(find.byType(NotedMenuItem<String>), findsWidgets);
      await close(t);
    });
  }
}
