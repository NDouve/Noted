// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Run 2026-11-14-02, task 3 (Codex R-1): focus-loss cleanup decodes a box to
// ask whether it is empty and removes it if its codec says so. A box whose
// type the page disallows is never decoded and is kept (0111).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_box_ai/noted_box_ai.dart';
import 'package:noted_canvas/noted_canvas.dart' show BoxHost;
import 'package:noted_core/noted_core.dart';

import 'support/real_io.dart';
import 'support/settle_saves.dart';
import 'support/spy_modules.dart';

void main() {
  late Directory root;
  late Directory pages;
  late Directory folder;
  late Notebook nb;
  late BinderSection section;
  late String inBinder;
  late String elsewhere;
  late BoxRecord box;
  late NotedPage before;

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
      await t.runAsync(() => realIoPause(30));
    }
  }

  /// The binder page is open, an empty `test.ai` box on it is being edited
  /// through its real editor, and the page is saved with it.
  Future<void> start(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.runAsync(() async {
      root = await Directory.systemTemp.createTemp('noted_disallowed_focus');
      pages = await Directory('${root.path}/pages').create();
      folder = await Directory('${root.path}/Work').create();
      nb = Notebook(
        PageStore(pages),
        spyModules(),
        saveDelay: Duration.zero,
        bindersFile: File('${root.path}/binders.json'),
      );
      await nb.load();
      section = await nb.addBinder(folder.path);
      inBinder = await nb.createPage(binderPath: section.path);
      elsewhere = await nb.createPage();
      await nb.open(inBinder);
    });
    await t.pumpWidget(MaterialApp(home: Home(notebook: nb)));
    await t.pump();
    final codec = SpyCodec<AiBoxData>(spyAi, const AiCodec(), emptyWithoutText: true);
    box = createBox(codec, const Bounds(100, 100, 360, 80));
    nb.current!.insertBox(box, autofocus: true);
    await settle(t);
    expect(nb.current!.editingId, box.id, reason: 'the real editor took the focus and told the page');
    await settleSaves(t, nb);
    before = nb.current!.page;
  }

  /// Disallows `test.ai` through the binder (the file), and waits until it is.
  Future<void> disallow(WidgetTester t, {required bool frames}) async {
    SpyCalls.reset();
    await t.runAsync(() async {
      await nb.setBinderBoxType(section.path, spyAi, false);
      await realIoUntil(() => !nb.boxTypeAvailabilityFor(inBinder, spyAi).allowed, 'the binder write');
    });
    expect(nb.boxTypeAvailabilityFor(inBinder, spyAi).allowed, isFalse);
    if (frames) await settle(t);
  }

  Future<void> expectKept(WidgetTester t) async {
    final c = nb.current;
    final page = nb.currentId == inBinder ? c!.page : null;
    if (page != null) {
      expect(page.node(box.id), isNotNull, reason: 'the box is kept on the page');
      expect(writePage(page), writePage(before), reason: 'the page is unchanged');
    }
    expect(SpyCalls.of(spyAi, 'decode'), 0, reason: 'the box was not decoded');
    await settleSaves(t, nb);
    // A fresh notebook finds the box in the file.
    final file = File('${folder.path}/$inBinder.canvas');
    expect(readPage(file.readAsStringSync()).node(box.id), isNotNull, reason: 'the box is in the saved file');
    await t.runAsync(() async {
      final fresh = Notebook(
        PageStore(pages),
        spyModules(),
        saveDelay: Duration.zero,
        bindersFile: File('${root.path}/binders.json'),
      );
      try {
        await fresh.load();
        await fresh.open(inBinder);
        expect(fresh.current!.page.node(box.id), isNotNull, reason: 'a fresh notebook shows the box');
      } finally {
        fresh.dispose();
      }
    });
  }

  Future<void> finish(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
      await t.runAsync(() => realIoPause(30));
    }
    await settleSaves(t, nb);
    await t.runAsync(() async {
      nb.dispose();
      await root.delete(recursive: true);
    });
  }

  testWidgets(
    '11a (guard: the unmount does not reach setEditing here, so it passes at the base) the box turns to its snapshot and the editor unmounts: the box is kept, never decoded',
    (t) async {
      await start(t);
      await disallow(t, frames: true);
      expect(
        find.descendant(of: find.byType(BoxHost), matching: find.text('Not allowed on this page')),
        findsOneWidget,
        reason: 'shown from its snapshot',
      );
      await expectKept(t);
      await finish(t);
    },
  );

  testWidgets('11b the user opens another page while the box is being edited: the box is kept, never decoded', (
    t,
  ) async {
    await start(t);
    await disallow(t, frames: false);
    expect(nb.current!.editingId, box.id, reason: 'no frame ran: the editor still has the focus');
    await t.runAsync(() => nb.open(elsewhere));
    await settle(t);
    expect(nb.currentId, elsewhere);
    await expectKept(t);
    await finish(t);
  });
}
