// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// What binder discovery shows: a note under "Can't open" for a binder it saw
// and did not add, and "Also in … (not used)" with Show folder in the page
// settings' Location section.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/page_tree_view.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_location.dart';
import 'package:noted/src/settings_panel.dart';
import 'package:noted_core/noted_core.dart';

import 'support/real_io.dart';

void main() {
  late Directory root;
  late Notebook nb;

  Future<void> makeBinder(String rel, String id, {List<String> pages = const []}) async {
    final dir = await Directory('${root.path}/$rel').create(recursive: true);
    await BinderStore(dir).create(Binder.create(title: rel, id: id, color: binderPalette.first));
    for (final p in pages) {
      await PageStore(dir).save(NotedPage.create(PageMeta.create(id: p, title: 'Page $p', order: 0)));
    }
  }

  Future<void> start({Map<String, Object?>? settings}) async {
    root = await Directory.systemTemp.createTemp('noted_discovery_ui');
    await Directory('${root.path}/pages').create();
    if (settings != null) File('${root.path}/binders.json').writeAsStringSync(jsonEncode(settings));
  }

  Future<void> load() async {
    nb = Notebook(
      PageStore(Directory('${root.path}/pages')),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/binders.json'),
    );
    await nb.load();
    await nb.discoveryIdle;
  }

  tearDown(() async {
    await nb.flush();
    nb.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('a binder recorded as removed by the first pass is listed under Can\'t open', (t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.runAsync(() async {
      await start(settings: {'format': 1, 'binders': <String>[]});
      await makeBinder('binders/Older', 'a000000000000001');
      await load();
    });
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PageTreeView(notebook: nb)),
      ),
    );
    await t.pump();
    expect(find.text("CAN'T OPEN"), findsOneWidget);
    expect(find.text('Older'), findsOneWidget, reason: 'the row is named after the folder');
    final tip = find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').contains("wasn't added"));
    expect(tip, findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a copy of a listed binder shows as "Also in … (not used)" with Show folder', (t) async {
    t.view.physicalSize = const Size(1000, 1800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    late String pageId;
    late String copy;
    await t.runAsync(() async {
      await start();
      await makeBinder('binders/Orig', 'a000000000000001', pages: ['p1']);
      File('${root.path}/binders.json').writeAsStringSync(
        jsonEncode({
          'format': 1,
          'binders': ['${root.path}/binders/Orig'],
          'binderIds': {'${root.path}/binders/Orig': 'a000000000000001'},
        }),
      );
      copy = '${root.path}/binders/Copy';
      await Directory(copy).create();
      File('${root.path}/binders/Orig/$binderFileName').copySync('$copy/$binderFileName');
      await load();
      pageId = 'p1';
    });
    expect(nb.binders, hasLength(1));
    expect(nb.binderAlsoIn(nb.binders.single.path).map((p) => p.replaceAll(r'\', '/').toLowerCase()), [
      copy.replaceAll(r'\', '/').toLowerCase(),
    ]);
    final shown = <String>[];
    final old = showFolderInFileManager;
    showFolderInFileManager = (p) async {
      shown.add(p);
      return true;
    };
    addTearDown(() => showFolderInFileManager = old);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPanel.page(notebook: nb, pageId: pageId),
        ),
      ),
    );
    await t.pump();
    final line = find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').startsWith('Also in ') && (w.data ?? '').endsWith('(not used)'),
    );
    expect(line, findsOneWidget);
    final show = find.byWidgetPredicate(
      (w) => w.key is ValueKey && (w.key! as ValueKey).value.toString().startsWith('settings-location-also-show-'),
    );
    expect(show, findsOneWidget);
    expect(find.descendant(of: show, matching: find.text(showFolderLabel())), findsOneWidget);
    await t.tap(show);
    expect(shown.single.replaceAll(r'\', '/').toLowerCase(), copy.replaceAll(r'\', '/').toLowerCase());
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => realIoPause(50));
  });
}
