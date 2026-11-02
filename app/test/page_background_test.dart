// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_tree_view.dart';
import 'package:noted/src/settings_panel.dart';
import 'package:noted_core/noted_core.dart';
import 'support/real_io.dart';
import 'support/settle_saves.dart';

void main() {
  late Directory dir;
  late Notebook nb;
  late String a;
  late String b;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() => realIoPause(50));
    }
    await tester.pumpAndSettle();
  }

  Future<void> start(WidgetTester tester) async {
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('noted_bg');
      nb = Notebook(PageStore(dir), buildModules(), saveDelay: Duration.zero);
      await nb.load();
      a = nb.currentId!;
      b = await nb.createPage();
      await nb.open(a);
    });
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await settleSaves(tester, nb);
    await tester.runAsync(() async {
      nb.dispose();
      await dir.delete(recursive: true);
    });
  }

  Future<PageBackground> onDisk(WidgetTester tester, String id) async {
    late PageBackground bg;
    await settleSaves(tester, nb);
    await tester.runAsync(() async {
      bg = (await PageStore(dir).load(id)).meta.background;
    });
    return bg;
  }

  testWidgets('setting it: the page follows, other page is saved, open page is undoable', (
    tester,
  ) async {
    await start(tester);
    PageMeta meta(String id) => nb.tree[id]!;
    Future<void> setBg(String id, PageBackground bg) => nb.setBackground(id, bg);

    expect(meta(b).background, PageBackground.plain);
    expect(meta(b).background, isNot(PageBackground.dots));

    // Another page (not open): loaded, changed in its header, saved.
    final before = await tester.runAsync(() => File('${dir.path}/$b.canvas').readAsString());
    await tester.runAsync(() => setBg(b, PageBackground.graph));
    expect(meta(b).background, PageBackground.graph);
    expect(meta(b).background, isNot(PageBackground.plain));
    expect(await onDisk(tester, b), PageBackground.graph);
    final after = await tester.runAsync(() => File('${dir.path}/$b.canvas').readAsString());
    expect(after!.replaceAll(',"background":"graph"', ''), before);

    // The open page: through its controller, one undo step.
    await tester.runAsync(() => setBg(a, PageBackground.ruled));
    expect(nb.current!.page.meta.background, PageBackground.ruled);
    expect(await onDisk(tester, a), PageBackground.ruled);
    nb.current!.undo();
    expect(nb.current!.page.meta.background, PageBackground.plain);
    expect(await onDisk(tester, a), PageBackground.plain);
    expect(nb.current!.canUndo, isFalse);
    nb.current!.redo();
    expect(nb.current!.page.meta.background, PageBackground.ruled);

    // Reopening the page keeps it.
    await tester.runAsync(() async {
      await nb.open(b);
      await nb.open(a);
    });
    expect(nb.current!.page.meta.background, PageBackground.ruled);
    await finish(tester);
  });

  testWidgets('the page settings panel changes the background and marks the current one', (
    tester,
  ) async {
    await start(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsPanel.page(notebook: nb, pageId: a)),
      ),
    );
    await tester.pump();

    ChoiceChip chip(PageBackground bg) =>
        tester.widget<ChoiceChip>(find.byKey(ValueKey('settings-bg-${bg.name}')));
    for (final bg in PageBackground.values) {
      expect(chip(bg).selected, bg == PageBackground.plain);
    }
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('settings-bg-dots')));
      await realIoPause(50);
    });
    await settle(tester);
    expect(chip(PageBackground.dots).selected, isTrue);
    expect(chip(PageBackground.plain).selected, isFalse);
    expect(nb.current!.page.meta.background, PageBackground.dots);
    expect(await onDisk(tester, a), PageBackground.dots);

    // The page's right-click menu no longer has it.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            height: 600,
            child: ListenableBuilder(
              listenable: nb,
              builder: (context, _) => PageTreeView(notebook: nb),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final at = tester.getCenter(find.byKey(ValueKey('page-row-$b'))) + const Offset(-40, 0);
    await tester.runAsync(() => tester.tapAt(at, buttons: kSecondaryButton));
    await tester.pumpAndSettle();
    expect(find.textContaining('background'), findsNothing);
    expect(find.text('Rename'), findsOneWidget);
    await tester.tapAt(const Offset(500, 500));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('a new page from a template keeps the background', (tester) async {
    await start(tester);
    await tester.runAsync(() async {
      nb.current!.setBackground(PageBackground.graph);
      final t = NotedTemplate.forPage(
        name: 'Grid',
        page: nb.current!.page,
        id: 'aaaaaaaaaaaaaaaa',
        created: DateTime.utc(2026, 1, 1),
      );
      final id = await nb.createPageFromTemplate(t);
      expect(nb.current!.page.id, id);
      expect(nb.current!.page.meta.background, PageBackground.graph);
      await nb.flush();
      expect((await PageStore(dir).load(id)).meta.background, PageBackground.graph);
    });
    await finish(tester);
  });

  testWidgets('read-only pages cannot change background', (tester) async {
    await start(tester);
    late Directory root;
    late Directory folder;
    late String page;
    late Notebook ro;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('noted_bg_ro');
      folder = await Directory('${root.path}/Work').create();
      final first = Notebook(
        PageStore(Directory('${root.path}/pages')..createSync()),
        buildModules(),
        saveDelay: Duration.zero,
        bindersFile: File('${root.path}/app/binders.json'),
      );
      await first.load();
      final s = await first.addBinder(folder.path);
      page = await first.createPage(binderPath: s.path);
      await first.flush();
      first.dispose();
      File('${folder.path}/$binderFileName').writeAsStringSync('{ not json');
      ro = Notebook(
        PageStore(Directory('${root.path}/pages')),
        buildModules(),
        saveDelay: Duration.zero,
        bindersFile: File('${root.path}/app/binders.json'),
      );
      await ro.load();
      // Open, so the chips are off because of the read-only guard, not because
      // the page is not the open one.
      await ro.open(page);
    });
    expect(ro.isReadOnlyPage(page), isTrue);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SettingsPanel.page(notebook: ro, pageId: page))),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('settings-read-only')), findsOneWidget);
    for (final bg in PageBackground.values) {
      expect(
        tester.widget<ChoiceChip>(find.byKey(ValueKey('settings-bg-${bg.name}'))).onSelected,
        isNull,
      );
    }
    await tester.runAsync(() async {
      ro.dispose();
      await root.delete(recursive: true);
    });
    await finish(tester);
  });
}
