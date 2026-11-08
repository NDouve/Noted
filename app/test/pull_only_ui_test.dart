// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A pull-only binder in the sidebar (OneDrive stage 3, G1): its pages are not
// greyed but have no drag or edit menu, and its cover and settings are read-only.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/sidebar_row.dart';
import 'package:noted_core/noted_core.dart';

import 'support/real_io.dart';
import 'support/settle_saves.dart';

void main() {
  late Directory root;
  late Directory work;
  late Notebook nb;
  late String plain; // a page in the default folder
  late String inBinder; // a page of the pull-only binder

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() => realIoPause(50));
    }
    await tester.pumpAndSettle();
  }

  Future<void> start(WidgetTester tester, {required bool pullOnly}) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('noted_pull_ui');
      final pages = await Directory('${root.path}/pages').create();
      work = await Directory('${root.path}/onedrive/Work').create(recursive: true);
      final settings = File('${root.path}/binders.json');
      final first = Notebook(PageStore(pages), buildModules(), saveDelay: Duration.zero, bindersFile: settings);
      await first.load();
      plain = first.currentId!;
      final s = await first.addBinder(work.path);
      inBinder = await first.createPage(binderPath: s.path);
      await first.rename(inBinder, 'Inside');
      await first.open(plain);
      await first.flush();
      first.dispose();
      nb = Notebook(
        PageStore(pages),
        buildModules(),
        saveDelay: Duration.zero,
        bindersFile: settings,
        readOnlyRoots: pullOnly ? ['${root.path}/onedrive'] : const [],
      );
      await nb.load();
    });
    await tester.pumpWidget(MaterialApp(home: Home(notebook: nb)));
    await tester.pump();
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => realIoPause(30));
    }
    await settleSaves(tester, nb);
    await tester.runAsync(() async {
      nb.dispose();
      await root.delete(recursive: true);
    });
  }

  Finder row(String id) => find.byKey(ValueKey('page-row-$id'));

  for (final pullOnly in [true, false]) {
    testWidgets(
      pullOnly
          ? 'a pull-only page row is not greyed and has no page menu; a writable one has'
          : 'with no read-only roots the same page row has its menu',
      (tester) async {
        await start(tester, pullOnly: pullOnly);
        final sidebarRow = tester.widget<SidebarRow>(find.descendant(of: row(inBinder), matching: find.byType(SidebarRow)));
        expect(sidebarRow.disabled, isFalse, reason: 'not greyed either way');
        final menu = find.descendant(of: row(inBinder), matching: find.byTooltip('Page options'));
        expect(menu, pullOnly ? findsNothing : findsOneWidget);
        expect(find.descendant(of: row(plain), matching: find.byTooltip('Page options')), findsOneWidget);
        expect(nb.isReadOnlyPage(inBinder), pullOnly);
        await finish(tester);
      },
    );
  }

  testWidgets('a pull-only binder cover: the fields are read-only and say why', (tester) async {
    await start(tester, pullOnly: true);
    await tester.runAsync(() async => nb.showCover(work.path));
    await tester.pump();
    await settle(tester);
    expect(find.byKey(const ValueKey('cover-read-only')), findsOneWidget);
    expect(find.text(Notebook.pullOnlyMessage), findsOneWidget);
    for (final k in ['cover-title', 'cover-description', 'cover-owner']) {
      expect(tester.widget<TextField>(find.byKey(ValueKey(k))).readOnly, isTrue, reason: k);
      expect(tester.widget<TextField>(find.byKey(ValueKey(k))).enabled, isFalse, reason: '$k looks read-only');
    }
    final before = nb.binders.single.binder!.color;
    await tester.tap(find.byKey(ValueKey('cover-color-${binderPalette.last}')));
    await tester.pump();
    expect(nb.binders.single.binder!.color, before, reason: 'a colour can not be chosen');
    await finish(tester);
  });

  testWidgets('the settings panel of a pull-only binder is read-only with the same message', (tester) async {
    await start(tester, pullOnly: true);
    await tester.runAsync(() async => nb.showCover(work.path));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cover-settings')));
    await settle(tester);
    expect(find.byKey(const ValueKey('settings-panel')), findsOneWidget);
    final note = tester.widget<Text>(find.byKey(const ValueKey('settings-read-only')));
    expect(note.data, Notebook.pullOnlyMessage);
    await finish(tester);
  });
}
