// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_location.dart';
import 'package:noted/src/page_tree_view.dart';
import 'package:noted/src/settings_panel.dart';
import 'package:noted_core/noted_core.dart';

import 'support/real_io.dart';

void main() {
  late Directory root;
  late Notebook nb;
  late String a;
  String? pickAnswer;
  var picks = 0;

  Future<void> start({bool picker = true}) async {
    root = await Directory.systemTemp.createTemp('noted_location');
    final data = await Directory('${root.path}/app').create();
    nb = Notebook(
      PageStore(await Directory('${root.path}/pages').create()),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${data.path}/binders.json'),
      pickFolder: picker
          ? () async {
              picks++;
              return pickAnswer;
            }
          : null,
    );
    await nb.load();
    a = nb.currentId!;
  }

  setUp(() {
    pickAnswer = null;
    picks = 0;
  });

  tearDown(() async {
    await nb.flush();
    nb.dispose();
    await root.delete(recursive: true);
  });

  Future<void> pumpPanel(WidgetTester t) async {
    t.view.physicalSize = const Size(1000, 1800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: SettingsPanel.page(notebook: nb, pageId: a))));
    await t.pump();
  }

  String pathShown(WidgetTester t) =>
      t.widget<SelectableText>(find.byKey(const ValueKey('settings-location-path'))).data!;

  testWidgets('Location comes first and names the folder in full', (t) async {
    await t.runAsync(start);
    await pumpPanel(t);
    expect(find.text('Location'), findsOneWidget);
    expect(pathShown(t), nb.defaultFolderPath);
    expect(
      t.getTopLeft(find.text('Location')).dy,
      lessThan(t.getTopLeft(find.text('Background')).dy),
    );
    expect(find.byKey(const ValueKey('settings-location-binder')), findsNothing);
  });

  testWidgets('a page in a binder names the binder and its folder', (t) async {
    await t.runAsync(start);

    await t.runAsync(() async {
      final dir = await Directory('${root.path}/Work').create();
      await nb.addBinder(dir.path);
      await nb.createPage(binderPath: nb.binders.single.path);
      a = nb.currentId!;
    });
    await pumpPanel(t);
    expect(find.textContaining('In the binder'), findsOneWidget);
    expect(pathShown(t), nb.binderOfPage(a));
  });

  testWidgets('Show in File Explorer opens the folder; Finder on macOS; hidden on mobile', (t) async {
    await t.runAsync(start);
    final shown = <String>[];
    final old = showFolderInFileManager;
    showFolderInFileManager = (p) async => shown.add(p);
    addTearDown(() => showFolderInFileManager = old);

    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpPanel(t);
    await t.tap(find.text('Show in File Explorer'));
    expect(shown, [nb.defaultFolderPath]);

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await pumpPanel(t);
    await t.pumpWidget(const SizedBox());
    await pumpPanel(t);
    expect(find.text('Show in Finder'), findsOneWidget);

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await t.pumpWidget(const SizedBox());
    await pumpPanel(t);
    expect(find.byKey(const ValueKey('settings-location-show')), findsNothing);
    expect(pathShown(t), nb.defaultFolderPath, reason: 'the path still shows');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Move to folder… moves the page and the Location follows', (t) async {
    await t.runAsync(start);
    final other = await t.runAsync(() => Directory('${root.path}/other').create()) as Directory;
    pickAnswer = other.path;
    await pumpPanel(t);
    await t.runAsync(() async {
      await t.tap(find.byKey(const ValueKey('settings-location-move')));
      await realIoPause(300);
    });
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(picks, 1);
    expect(pathShown(t), isNot(nb.defaultFolderPath));
    expect(Directory(pathShown(t)).absolute.path, Directory(other.path).absolute.path);
  });

  testWidgets('folderOfPage: default folder, another folder, a binder, an unknown page', (t) async {
    await t.runAsync(start);
    final other = await t.runAsync(() => Directory('${root.path}/other').create()) as Directory;
    final bdir = await t.runAsync(() => Directory('${root.path}/Work').create()) as Directory;
    late String inBinder;
    await t.runAsync(() async {
      await nb.addBinder(bdir.path);
      inBinder = await nb.createPage(binderPath: nb.binders.single.path);
    });
    expect(nb.folderOfPage(a), nb.defaultFolderPath);
    expect(nb.folderOfPage(inBinder), nb.binders.single.path);
    expect(nb.folderOfPage('nope'), isNull);
    await t.runAsync(() => nb.moveToFolder(a, other.path));
    expect(Directory(nb.folderOfPage(a)!).absolute.path, Directory(other.path).absolute.path);
  });

  testWidgets('without a folder picker there is no Move to folder…', (t) async {
    await t.runAsync(() => start(picker: false));
    await pumpPanel(t);
    expect(find.byKey(const ValueKey('settings-location-move')), findsNothing);
  });

  testWidgets('Open binder… is a button in the Pages header', (t) async {
    await t.runAsync(start);
    t.view.physicalSize = const Size(800, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            height: 600,
            child: ListenableBuilder(listenable: nb, builder: (context, _) => PageTreeView(notebook: nb)),
          ),
        ),
      ),
    );
    await t.pump();
    expect(find.byTooltip('Open binder…'), findsOneWidget);
    await t.runAsync(() async {
      await t.tap(find.byKey(const ValueKey('open-binder')));
      await realIoPause(50);
    });
    expect(picks, 1);
    await t.pumpWidget(const SizedBox());
  });
}
