// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  group('setting', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('noted_toolbar_setting');
      file = File('${dir.path}/sub/settings.json');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('default is Tabs and nothing is written', () {
      expect(AppSettings(file).toolbar, ToolbarStyle.tabs);
      expect(AppSettings(null).toolbar, ToolbarStyle.tabs);
      expect(file.existsSync(), isFalse);
    });

    test('Contextual persists next to the theme and survives a new instance', () {
      final s = AppSettings(file);
      s.toolbar = ToolbarStyle.contextual;
      expect(jsonDecode(file.readAsStringSync()), {
        'format': 1,
        'theme': 'system',
        'toolbar': 'contextual',
      });
      expect(AppSettings(file).toolbar, ToolbarStyle.contextual);
      s.theme = ThemeSetting.dark;
      expect(AppSettings(file).toolbar, ToolbarStyle.contextual);
      s.toolbar = ToolbarStyle.tabs;
      expect(AppSettings(file).toolbar, ToolbarStyle.tabs);
    });

    test('an unknown or damaged value reads as Tabs; other fields are kept', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{"format":1,"toolbar":"ribbon","future":true}');
      final s = AppSettings(file);
      expect(s.toolbar, ToolbarStyle.tabs);
      s.toolbar = ToolbarStyle.contextual;
      expect(jsonDecode(file.readAsStringSync())['future'], isTrue);
      file.writeAsStringSync('{ nope');
      expect(AppSettings(file).toolbar, ToolbarStyle.tabs);
    });
  });

  testWidgets('choosing Contextual in the gear menu switches the toolbar at once', (t) async {
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    late Directory dir;
    late Notebook nb;
    late File file;
    await t.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('noted_toolbar_ui');
      file = File('${dir.path}/settings.json');
      nb = Notebook(
        PageStore(Directory('${dir.path}/pages')..createSync()),
        buildModules(),
        saveDelay: Duration.zero,
      );
      await nb.load();
    });
    final settings = AppSettings(file);
    await t.pumpWidget(NotedApp(notebook: nb, settings: settings));
    await t.pump();
    final canvasState = t.state<PageCanvasState>(find.byType(PageCanvas));

    // Tabs by default.
    expect(find.byKey(CommandToolbar.tabKey('home')), findsOneWidget);
    expect(find.byKey(CommandToolbar.sectionKey('insert')), findsNothing);

    Future<void> choose(String key) async {
      await t.tap(find.byKey(const ValueKey('settings-menu')));
      await t.pumpAndSettle();
      expect(find.text('Toolbar'), findsOneWidget);
      await t.tap(find.byKey(ValueKey(key)));
      await t.pumpAndSettle();
    }

    await choose('toolbar-contextual');
    expect(settings.toolbar, ToolbarStyle.contextual);
    expect(find.byKey(CommandToolbar.tabKey('home')), findsNothing);
    expect(find.byKey(CommandToolbar.sectionKey('insert')), findsOneWidget);
    expect(find.byKey(const ValueKey('canvas.select')), findsOneWidget);
    expect(find.byKey(const ValueKey('app.search')), findsOneWidget);
    expect(jsonDecode(file.readAsStringSync())['toolbar'], 'contextual');
    // The same canvas: switching rebuilt the toolbar, not the page.
    expect(t.state<PageCanvasState>(find.byType(PageCanvas)), same(canvasState));

    await choose('toolbar-tabs');
    expect(settings.toolbar, ToolbarStyle.tabs);
    expect(find.byKey(CommandToolbar.tabKey('home')), findsOneWidget);
    expect(jsonDecode(file.readAsStringSync())['toolbar'], 'tabs');

    await t.pumpWidget(const SizedBox());
    await t.runAsync(() async {
      await nb.flush();
      nb.dispose();
      await dir.delete(recursive: true);
    });
  });
}
