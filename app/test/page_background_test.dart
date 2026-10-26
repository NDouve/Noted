// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_commands.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_tree_view.dart';
import 'package:noted_canvas/noted_canvas.dart' show CommandRegistry, NotedMenuItem;
import 'package:noted_core/noted_core.dart';

class _NoActions implements PageTreeActions {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

void main() {
  late Directory dir;
  late Notebook nb;
  late String a;
  late String b;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
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
    await tester.runAsync(() async {
      await nb.flush();
      nb.dispose();
      await dir.delete(recursive: true);
    });
  }

  Future<PageBackground> onDisk(WidgetTester tester, String id) async {
    late PageBackground bg;
    await tester.runAsync(() async {
      await nb.flush();
      bg = (await PageStore(dir).load(id)).meta.background;
    });
    return bg;
  }

  testWidgets('commands: checked follows, other page is saved, open page is undoable', (
    tester,
  ) async {
    await start(tester);
    PageMeta meta(String id) => nb.tree[id]!;
    CommandRegistry cmds(String id) => pageCommands(nb, meta(id), _NoActions());

    expect(cmds(b)[AppCommands.backgroundId(PageBackground.plain)]!.checked, isTrue);
    expect(cmds(b)[AppCommands.backgroundId(PageBackground.dots)]!.checked, isFalse);

    // Another page (not open): loaded, changed in its header, saved.
    final before = await tester.runAsync(() => File('${dir.path}/$b.canvas').readAsString());
    await tester.runAsync(() => cmds(b).invoke(AppCommands.backgroundId(PageBackground.graph)));
    expect(cmds(b)[AppCommands.backgroundId(PageBackground.graph)]!.checked, isTrue);
    expect(cmds(b)[AppCommands.backgroundId(PageBackground.plain)]!.checked, isFalse);
    expect(await onDisk(tester, b), PageBackground.graph);
    final after = await tester.runAsync(() => File('${dir.path}/$b.canvas').readAsString());
    expect(after!.replaceAll(',"background":"graph"', ''), before);

    // The open page: through its controller, one undo step.
    await tester.runAsync(() => cmds(a).invoke(AppCommands.backgroundId(PageBackground.ruled)));
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

  testWidgets('the page right-click menu changes the background and marks the current one', (
    tester,
  ) async {
    await start(tester);
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

    Future<void> rightClick(String id) async {
      final at = tester.getCenter(find.byKey(ValueKey('page-row-$id'))) + const Offset(-40, 0);
      await tester.runAsync(() => tester.tapAt(at, buttons: kSecondaryButton));
      await tester.pumpAndSettle();
    }

    await rightClick(b);
    for (final bg in PageBackground.values) {
      expect(find.text('Page background: ${bg.name[0].toUpperCase()}${bg.name.substring(1)}'),
          findsOneWidget);
    }
    // Plain is the current one: exactly one check mark.
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.tap(find.text('Page background: Dots'));
    await tester.pump();
    await settle(tester);
    expect(await onDisk(tester, b), PageBackground.dots);

    await rightClick(b);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    final checked = find.ancestor(
      of: find.byIcon(Icons.check_rounded),
      matching: find.byType(NotedMenuItem<String>),
    );
    expect(
      find.descendant(of: checked, matching: find.text('Page background: Dots')),
      findsOneWidget,
    );
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
    });
    expect(ro.isReadOnlyPage(page), isTrue);
    final meta = ro.treeOfPage(page)[page]!;
    final cmds = pageCommands(ro, meta, _NoActions());
    for (final bg in PageBackground.values) {
      expect(cmds[AppCommands.backgroundId(bg)]!.enabled, isFalse);
    }
    await tester.runAsync(() async {
      ro.dispose();
      await root.delete(recursive: true);
    });
    await finish(tester);
  });
}
