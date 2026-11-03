// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/binder_cover.dart';
import 'package:noted/src/page_tree_view.dart';
import 'package:noted/src/search_panel.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/settle_saves.dart';

void main() {
  late Directory dir;
  late Notebook nb;
  late AppSettings settings;
  late String first;
  late String second;
  late BinderSection binder;

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
      first = nb.currentId!;
      second = await nb.createPage();
      await nb.rename(first, 'Alpha');
      await nb.rename(second, 'Beta');
      await nb.open(first);
    });
    settings = AppSettings(File('${dir.path}/settings.json'))..toolbar = toolbar;
    await t.pumpWidget(NotedApp(notebook: nb, settings: settings));
    await t.pump();
  }

  // Work started from the widgets hops between the test clock and real IO.
  Future<void> settleIo(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await t.pumpAndSettle();
  }

  Future<void> until(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
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

  testWidgets('phone width: tapping a page in the drawer opens it and closes the drawer', (t) async {
    await open(t, const Size(400, 800));
    await t.tap(find.byKey(const ValueKey('sidebar-menu')));
    await t.pumpAndSettle();
    await t.tap(find.text('Beta'));
    await settleIo(t);
    expect(nb.currentId, second);
    expect(find.byType(PageTreeView), findsNothing);
  });

  testWidgets('phone width: choosing a search result closes the drawer', (t) async {
    await open(t, const Size(400, 800));
    await t.tap(find.byKey(const ValueKey('sidebar-menu')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('search-field')), 'Alpha');
    final result = find.byKey(ValueKey('search-page-$first'));
    await until(t, () => result.evaluate().isNotEmpty);
    expect(result, findsWidgets);
    await t.tap(find.byKey(ValueKey('search-page-title-$first')));
    await settleIo(t);
    expect(find.byType(PageTreeView), findsNothing);
    expect(find.byType(SearchField), findsNothing);
    // Leave the title match as it was: the title field clears its mark in a
    // microtask when the page closes, which must not outlive the home.
    await t.runAsync(() => nb.open(second));
    await settleIo(t);
  });

  testWidgets('phone width: Ctrl+N makes a page and Ctrl+Shift+F opens the drawer on the search field', (t) async {
    await open(t, const Size(400, 800));
    await t.tap(find.byType(EditableText).first);
    await t.pump();
    final before = nb.currentId;
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyN);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await until(t, () => nb.currentId != before);
    expect(nb.currentId, isNot(before));

    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();
    expect(find.byType(SearchField), findsOneWidget);
    final field = t.widget<TextField>(find.descendant(of: find.byType(SearchField), matching: find.byType(TextField)));
    expect(field.focusNode!.hasFocus, isTrue);
  });

  testWidgets('phone width: Escape closes the drawer and the focus comes back', (t) async {
    await open(t, const Size(400, 800));
    final title = find.byType(EditableText).first;
    await t.tap(title);
    await t.pump();
    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull);
    await t.tap(find.byKey(const ValueKey('sidebar-menu')));
    await t.pumpAndSettle();
    expect(find.byType(PageTreeView), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byType(PageTreeView), findsNothing);
    expect(FocusManager.instance.primaryFocus, same(focused));
  });

  testWidgets('phone width: the menu button does not cover the binder cover', (t) async {
    await open(t, const Size(400, 800));
    await t.runAsync(() async {
      final folder = await Directory('${dir.path}/Work').create();
      binder = await nb.addBinder(folder.path);
      await nb.createPage(binderPath: binder.path);
      nb.showCover(binder.path);
    });
    await t.pumpAndSettle();
    final menu = t.getRect(find.byKey(const ValueKey('sidebar-menu')));
    final header = t.getRect(find.text('Binder cover'));
    expect(menu.overlaps(header), isFalse);
    expect(menu.bottom, lessThanOrEqualTo(header.top));
    // Nor the cover as a whole (its colour bar is at the top).
    expect(menu.overlaps(t.getRect(find.byType(BinderCover))), isFalse);
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
