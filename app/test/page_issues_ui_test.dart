// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The issue sequence in the app shell: shown when a page opens, silenced into
// the corner icon, and kept silenced while the user moves between pages.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_core/noted_core.dart';

import 'search_ui_test.dart' show noteBox, notePage;
import 'support/real_io.dart';
import 'support/settle_saves.dart';

void main() {
  late Directory root;
  late Notebook nb;

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
      await t.runAsync(() => realIoPause(30));
    }
  }

  Future<void> start(WidgetTester t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.runAsync(() async {
      root = await Directory.systemTemp.createTemp('noted_issues_ui');
      final pages = await Directory('${root.path}/pages').create();
      final store = PageStore(pages);
      final mine = noteBox('alpha-b0', ['mine'], y: 40);
      final theirs = noteBox('alpha-b0', ['theirs'], y: 40);
      final alpha = NotedPage.create(PageMeta.create(id: 'alpha', title: 'Alpha', order: 0))
          .insertNode(mine.withConflict(BoxConflict.other(node: theirs.toRaw(), at: 5, device: 'Laptop')))
          .insertNode(noteBox('alpha-b1', ['landed'], y: 500).withLanded(BoxLanded(at: 5, device: 'Laptop')));
      await store.save(alpha);
      await store.save(notePage('beta', 'Beta', [['Nothing here']], order: 1));
      nb = Notebook(
        store,
        buildModules(),
        saveDelay: const Duration(hours: 1),
        bindersFile: File('${root.path}/binders.json'),
      );
      await nb.load();
      await nb.open('alpha');
    });
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: noteLocalizationsDelegates,
        home: Home(notebook: nb),
      ),
    );
    await settle(t);
  }

  Future<void> finish(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await settle(t);
    await settleSaves(t, nb);
    await t.runAsync(() async {
      nb.dispose();
      await root.delete(recursive: true);
    });
  }

  testWidgets('opening a page with issues shows the sequence; Silence leaves the corner icon', (t) async {
    await start(t);
    expect(find.byKey(const ValueKey('issues-dialog')), findsOneWidget);
    expect(t.widget<Text>(find.byKey(const ValueKey('issues-count'))).data, '1 of 2');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(t);
    expect(find.byKey(const ValueKey('issues-dialog')), findsNothing);
    expect(find.byKey(const ValueKey('issues-icon')), findsOneWidget);
    expect(find.byKey(const ValueKey('issue-chip-alpha-b0')), findsOneWidget);
    expect(find.byKey(const ValueKey('issue-chip-alpha-b1')), findsOneWidget);
    // Another page and back: still silenced for this run.
    await t.runAsync(() => nb.open('beta'));
    await settle(t);
    expect(find.byKey(const ValueKey('issues-icon')), findsNothing);
    await t.runAsync(() => nb.open('alpha'));
    await settle(t);
    expect(find.byKey(const ValueKey('issues-dialog')), findsNothing);
    expect(find.byKey(const ValueKey('issues-icon')), findsOneWidget);
    // The icon reopens the sequence at the first issue; settle it.
    await t.tap(find.byKey(const ValueKey('issues-icon')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('conflict-keep-mine')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('issue-leave')));
    await settle(t);
    expect(find.byKey(const ValueKey('issues-dialog')), findsNothing);
    expect(find.byKey(const ValueKey('issues-icon')), findsNothing);
    expect(nb.current!.issues(), isEmpty);
    await finish(t);
  });
}
