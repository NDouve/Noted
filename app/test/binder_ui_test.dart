// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/binder_cover.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory root;
  late Directory pages;
  late Directory folder;
  late Notebook nb;
  late String a;
  late String b;
  late BinderSection binder;
  late String inBinder;
  String? pickAnswer;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await tester.pumpAndSettle();
  }

  Future<void> start(WidgetTester tester, {bool withBinder = true}) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    pickAnswer = null;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('noted_binder_ui');
      pages = await Directory('${root.path}/pages').create();
      folder = await Directory('${root.path}/Work').create();
      nb = Notebook(
        PageStore(pages),
        buildModules(),
        saveDelay: Duration.zero,
        bindersFile: File('${root.path}/binders.json'),
        pickFolder: () async => pickAnswer,
      );
      await nb.load();
      a = nb.currentId!;
      b = await nb.createPage();
      await nb.rename(a, 'Alpha');
      await nb.rename(b, 'Beta');
      if (withBinder) {
        binder = await nb.addBinder(folder.path);
        inBinder = await nb.createPage(binderPath: binder.path);
        await nb.rename(inBinder, 'Inside');
        await nb.open(a);
      }
    });
    await tester.pumpWidget(MaterialApp(home: Home(notebook: nb)));
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // Work started from the widgets hops between the test clock and real IO.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
    await tester.runAsync(() async {
      await nb.flush();
      nb.dispose();
      await root.delete(recursive: true);
    });
  }

  Finder row(String id) => find.byKey(ValueKey('page-row-$id'));
  Finder header(String path) => find.byKey(ValueKey('binder-header-$path'));

  testWidgets('the sidebar shows a section per binder, tinted with its color', (tester) async {
    await start(tester);
    expect(find.text('Pages'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);
    expect(row(inBinder), findsOneWidget);
    final color = parseBinderColor(binder.binder!.color);
    final stripe = tester.widget<Container>(find.byKey(ValueKey('binder-stripe-${binder.path}')));
    expect(stripe.color, color);
    final rowStripe = tester.widget<DecoratedBox>(find.byKey(ValueKey('page-stripe-$inBinder')));
    final border = (rowStripe.decoration as BoxDecoration).border! as Border;
    expect(border.left.color, color);
    // Standalone rows are not tinted.
    expect(find.byKey(ValueKey('page-stripe-$a')), findsNothing);

    // The chevron collapses the section.
    await tester.tap(find.descendant(of: header(binder.path), matching: find.byIcon(Icons.expand_more)));
    await tester.pump();
    expect(row(inBinder), findsNothing);
    await finish(tester);
  });

  testWidgets('a binder folder that is not there is shown greyed', (tester) async {
    await start(tester);
    await tester.runAsync(() async {
      await nb.flush();
      await folder.delete(recursive: true);
      final again = Notebook(
        PageStore(pages),
        buildModules(),
        bindersFile: File('${root.path}/binders.json'),
      );
      await again.load();
      nb.dispose();
      nb = again;
    });
    await tester.pumpWidget(MaterialApp(home: Home(notebook: nb)));
    await tester.pump();
    expect(find.text('On another device'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
    expect(row(inBinder), findsNothing);
    // It is still in the list.
    expect(nb.binders.single.status, BinderStatus.unavailable);
    await finish(tester);
  });

  testWidgets('clicking a binder header shows its cover; edits are saved', (tester) async {
    await start(tester);
    await tester.tap(find.text('Work'));
    await tester.pump();
    expect(find.text('Binder cover'), findsOneWidget);
    expect(find.byKey(const ValueKey('cover-path')), findsOneWidget);
    expect(find.text(binder.path), findsOneWidget);
    expect(find.byKey(const ValueKey('cover-last-edited')), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('cover-title')), 'Projects');
    await tester.enterText(find.byKey(const ValueKey('cover-owner')), 'Sam');
    // Moving to another field saves.
    await tester.enterText(find.byKey(const ValueKey('cover-description')), 'All my work');
    await tester.tap(find.byKey(const ValueKey('cover-title')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('cover-color-${binderPalette[5]}')));
    await settle(tester);

    final saved = await tester.runAsync(() => BinderStore(folder).read());
    final got = (saved! as BinderFound).binder;
    expect([got.title, got.owner, got.description, got.color], [
      'Projects',
      'Sam',
      'All my work',
      binderPalette[5],
    ]);
    expect(find.text('Projects'), findsWidgets);

    // Opening a page leaves the cover.
    await tester.tap(find.text('Alpha'));
    await settle(tester);
    expect(find.text('Binder cover'), findsNothing);
    await finish(tester);
  });

  testWidgets('New binder asks for a folder and shows the new cover', (tester) async {
    await start(tester, withBinder: false);
    final other = await tester.runAsync(() => Directory('${root.path}/Ideas').create());
    pickAnswer = other!.path;
    await tester.runAsync(() => tester.tap(find.byTooltip('New binder')));
    await settle(tester);
    expect(nb.binders.single.title, 'Ideas');
    expect(find.text('Binder cover'), findsOneWidget);
    expect(find.text('Ideas'), findsWidgets);
    expect(File('${other.path}/$binderFileName').existsSync(), isTrue);
    await finish(tester);
  });

  testWidgets('menu: New page creates a page in the binder folder', (tester) async {
    await start(tester);
    await tester.runAsync(() => tester.tap(find.byKey(ValueKey('binder-menu-${binder.path}'))));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('New page').last));
    await settle(tester);
    expect(binder.tree.roots, hasLength(2));
    expect(folder.listSync().where((f) => f.path.endsWith('.canvas')), hasLength(2));
    await finish(tester);
  });

  testWidgets('Remove from sidebar asks first and keeps the files', (tester) async {
    await start(tester);
    await tester.runAsync(() => tester.tap(find.byKey(ValueKey('binder-menu-${binder.path}'))));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('Remove from sidebar')));
    await tester.pumpAndSettle();
    expect(find.text('Remove binder from sidebar?'), findsOneWidget);
    await tester.runAsync(() => tester.tap(find.text('Remove')));
    await settle(tester);
    expect(nb.binders, isEmpty);
    expect(find.text('Work'), findsNothing);
    expect(File('${folder.path}/$inBinder.canvas').existsSync(), isTrue);
    await finish(tester);
  });

  testWidgets('dragging a standalone page onto a binder header moves it in', (tester) async {
    await start(tester);
    final startAt = tester.getTopLeft(row(b)) + const Offset(60, 18);
    final target = tester.getCenter(header(binder.path));
    final g = await tester.startGesture(startAt);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await g.moveTo(startAt + const Offset(0, 4));
    await tester.pump();
    await g.moveTo(target);
    await tester.pump();
    await g.moveTo(target + const Offset(0, 0.5));
    await tester.pump();
    await tester.runAsync(() => g.up());
    await settle(tester);

    expect(binder.tree.roots.map((p) => p.id), contains(b));
    expect(nb.tree.roots.map((p) => p.id), [a]);
    expect(File('${folder.path}/$b.canvas').existsSync(), isTrue);
    expect(File('${pages.path}/$b.canvas').existsSync(), isFalse);

    // And back: dropping on the "Pages" header makes it standalone again.
    final from = tester.getTopLeft(row(b)) + const Offset(60, 18);
    final pagesHeader = tester.getCenter(find.byKey(const ValueKey('pages-header')));
    final g2 = await tester.startGesture(from);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await g2.moveTo(from + const Offset(0, 4));
    await tester.pump();
    await g2.moveTo(pagesHeader);
    await tester.pump();
    await g2.moveTo(pagesHeader + const Offset(0, 0.5));
    await tester.pump();
    await tester.runAsync(() => g2.up());
    await settle(tester);
    expect(nb.tree.roots.map((p) => p.id), containsAll([a, b]));
    expect(File('${pages.path}/$b.canvas').existsSync(), isTrue);
    expect(File('${folder.path}/$b.canvas').existsSync(), isFalse);
    await finish(tester);
  });
}
