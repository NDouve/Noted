// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The toolbar at the width of a phone (400 px), with the real commands.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/settle_saves.dart';

void main() {
  late Directory dir;
  late Notebook nb;

  Future<void> open(WidgetTester t, double width, ToolbarStyle toolbar) async {
    t.view.physicalSize = Size(width, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('noted_narrow_toolbar');
      nb = Notebook(
        PageStore(Directory('${dir.path}/pages')..createSync()),
        buildModules(),
        saveDelay: Duration.zero,
      );
      await nb.load();
    });
    final settings = AppSettings(File('${dir.path}/settings.json'))..toolbar = toolbar;
    await t.pumpWidget(NotedApp(notebook: nb, settings: settings));
    await t.pump();
    await t.pumpAndSettle();
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await settleSaves(t, nb);
    await t.runAsync(() async {
      nb.dispose();
      await dir.delete(recursive: true);
    });
  }

  testWidgets('tabs at 400 px: every tab is whole and clear of Undo and Search', (t) async {
    await open(t, 400, ToolbarStyle.tabs);
    final strip = t.getRect(
      find.descendant(of: find.byType(CommandToolbar), matching: find.byType(SingleChildScrollView)).first,
    );
    for (final k in ['home', 'insert', 'draw', 'view']) {
      final r = t.getRect(find.byKey(CommandToolbar.tabKey(k)));
      expect(strip.contains(r.centerLeft) && strip.contains(r.centerRight), isTrue, reason: k);
    }
    final undo = t.getRect(find.byKey(const ValueKey('canvas.undo')));
    expect(undo.overlaps(strip), isFalse);
    expect(t.takeException(), isNull);
    await close(t);
  });

  testWidgets('contextual at 400 px: the tools keep their size', (t) async {
    await open(t, 400, ToolbarStyle.contextual);
    expect(t.getSize(find.byKey(const ValueKey('canvas.select'))), const Size.square(36));
    expect(t.getSize(find.byKey(const ValueKey('canvas.undo'))), const Size.square(36));
    expect(find.byTooltip('More'), findsOneWidget);
    expect(t.takeException(), isNull);
    await close(t);
  });
}
