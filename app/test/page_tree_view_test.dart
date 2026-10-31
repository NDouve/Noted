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
import 'package:noted_canvas/noted_canvas.dart' show NotedMenuItem, notedThemeData;
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory dir;
  late Notebook nb;
  late String a;
  late String b;
  late String c;

  /// Lets real file IO finish. Work started from a pumped frame (a menu
  /// closing) hops between real IO and the test clock, so alternate a few
  /// times.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await tester.pumpAndSettle();
  }

  /// Alternates the test clock and real IO until [done] (at most about 9 s
  /// of real time, for a slow CI runner), then settles.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
    await settle(tester);
  }

  Future<void> start(WidgetTester tester, {ThemeData? theme}) async {
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('noted_tree_ui');
      nb = Notebook(PageStore(dir), buildModules(), saveDelay: Duration.zero);
      await nb.load();
      a = nb.currentId!;
      b = await nb.createPage();
      c = await nb.createPage();
      await nb.rename(a, 'Alpha');
      await nb.rename(b, 'Beta');
      await nb.rename(c, 'Gamma');
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
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
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await nb.flush();
      nb.dispose();
      await dir.delete(recursive: true);
    });
  }

  /// Opens a row's context menu. The tap runs in the real-async zone because
  /// the menu's follow-up work awaits real file IO, which would otherwise
  /// never complete under the test clock.
  Future<void> rightClick(WidgetTester tester, String id) async {
    final at = tester.getCenter(find.byKey(ValueKey('page-row-$id'))) + const Offset(-40, 0);
    await tester.runAsync(() => tester.tapAt(at, buttons: kSecondaryButton));
    await tester.pumpAndSettle();
  }

  Finder row(String id) => find.byKey(ValueKey('page-row-$id'));

  List<String> rootIds() => nb.tree.roots.map((p) => p.id).toList();
  List<String> kids(String id) => nb.tree.childrenOf(id).map((p) => p.id).toList();

  /// Drags row [from] to [to] at [fraction] of the target row's height (or
  /// to the given point), holding long enough for a touch long press.
  Future<void> dragTo(WidgetTester tester, String from, Offset target) async {
    final start = tester.getTopLeft(row(from)) + const Offset(60, 18);
    final g = await tester.startGesture(start);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await g.moveTo(start + const Offset(0, 4));
    await tester.pump();
    await g.moveTo(target);
    await tester.pump();
    await g.moveTo(target + const Offset(0, 0.5));
    await tester.pump();
    await tester.runAsync(() => g.up());
    await settle(tester);
  }

  Offset at(WidgetTester tester, String id, double fraction) {
    final r = tester.getRect(row(id));
    return Offset(r.left + 80, r.top + r.height * fraction);
  }

  testWidgets('right click opens the menu and Move up works', (tester) async {
    await start(tester);
    await rightClick(tester, b);
    await tester.pumpAndSettle();
    expect(find.text('New subpage'), findsOneWidget);
    expect(find.text('Outdent'), findsOneWidget);
    await tester.tap(find.text('Move up'));
    await tester.pump();
    await settle(tester);
    expect(rootIds(), [b, a, c]);
    await finish(tester);
  });

  testWidgets('menu items that do not apply are disabled', (tester) async {
    await start(tester);
    await rightClick(tester, a);
    await tester.pumpAndSettle();
    final up = tester.widget<NotedMenuItem<String>>(
      find.ancestor(of: find.text('Move up'), matching: find.byType(NotedMenuItem<String>)),
    );
    expect(up.enabled, isFalse);
    await tester.tap(find.text('Move up'), warnIfMissed: false);
    await tester.pump();
    expect(rootIds(), [a, b, c]);
    await finish(tester);
  });

  testWidgets('Indent from the menu nests the page', (tester) async {
    await start(tester);
    await rightClick(tester, b);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Indent'));
    await tester.pump();
    await settle(tester);
    expect(kids(a), [b]);
    expect(find.byTooltip('Collapse'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('dropping on the middle of a row makes a subpage', (tester) async {
    await start(tester);
    await dragTo(tester, c, at(tester, a, 0.5));
    expect(kids(a), [c]);
    expect(rootIds(), [a, b]);
    final disk = await tester.runAsync(() async {
      final e = await PageStore(dir).scan();
      return PageTree.build(e.whereType<ReadablePage>().map((x) => x.meta));
    });
    expect(disk!.parentIdOf(c), a);
    await finish(tester);
  });

  testWidgets('dropping on the upper edge places a page before the row', (tester) async {
    await start(tester);
    await dragTo(tester, c, at(tester, a, 0.08));
    expect(rootIds(), [c, a, b]);
    await finish(tester);
  });

  testWidgets('dropping on the lower edge places a page after the row', (tester) async {
    await start(tester);
    await dragTo(tester, a, at(tester, b, 0.92));
    expect(rootIds(), [b, a, c]);
    await finish(tester);
  });

  testWidgets('dropping on the empty area moves a subpage to the end of the top level',
      (tester) async {
    await start(tester);
    await tester.runAsync(() => nb.move(b, parentId: a));
    await tester.pump();
    expect(rootIds(), [a, c]);
    await dragTo(tester, b, const Offset(100, 400));
    expect(rootIds(), [a, c, b]);
    await finish(tester);
  });

  testWidgets('a page cannot be dropped into its own subtree', (tester) async {
    await start(tester);
    await tester.runAsync(() => nb.move(b, parentId: a));
    await tester.pump();
    await dragTo(tester, a, at(tester, b, 0.5));
    expect(rootIds(), [a, c]);
    expect(kids(a), [b]);
    await finish(tester);
  });

  testWidgets('delete asks first, then Undo restores the page', (tester) async {
    // The page menu is taller now; give it room.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await start(tester);
    await rightClick(tester, b);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await settle(tester);
    expect(find.text('Delete page?'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.pump();
    await until(tester, () => rootIds().length == 2 && find.text('Undo').evaluate().isNotEmpty);
    expect(rootIds(), [a, c]);
    expect(find.text('Undo'), findsOneWidget);
    // Undo's handler awaits file IO, so tap it in the real-async zone.
    await tester.runAsync(() => tester.tap(find.text('Undo')));
    await until(tester, () => rootIds().length == 3 && File('${dir.path}/$b.canvas').existsSync());
    expect(rootIds(), [a, b, c]);
    expect(File('${dir.path}/$b.canvas').existsSync(), isTrue);
    await finish(tester);
  });

  for (final brightness in Brightness.values) {
    testWidgets('page menu and dialogs follow the design (${brightness.name})', (tester) async {
      final theme = notedThemeData(brightness);
      await start(tester, theme: theme);
      await rightClick(tester, b);
      await tester.pumpAndSettle();
      // Menu items are 32px; Delete page is destructive (error), others text.
      final del = find.byKey(const ValueKey('menu-${AppCommands.delete}'));
      expect(tester.getSize(del).height, 32);
      expect(
        tester.widget<Text>(find.descendant(of: del, matching: find.text('Delete'))).style!.color,
        theme.colorScheme.error,
      );
      final up = find.byKey(const ValueKey('menu-${AppCommands.moveUp}'));
      expect(
        tester.widget<Text>(find.descendant(of: up, matching: find.text('Move up'))).style!.color,
        theme.colorScheme.onSurface,
      );
      // Delete asks first: a destructive button, no primary.
      await tester.tap(find.text('Delete'));
      await settle(tester);
      expect(find.byType(FilledButton), findsNothing);
      final confirm = find.widgetWithText(OutlinedButton, 'Delete');
      expect(
        DefaultTextStyle.of(tester.element(find.descendant(of: confirm, matching: find.text('Delete')))).style.color,
        theme.colorScheme.error,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);
      // Rename has exactly one primary button.
      await rightClick(tester, b);
      await tester.tap(find.byKey(const ValueKey('menu-${AppCommands.rename}')));
      await settle(tester);
      expect(find.text('Rename page'), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Rename'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);
      await finish(tester);
    });
  }

  testWidgets('a damaged recovery entry is listed under Can\'t open and kept', (tester) async {
    late Directory rec;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('noted_tree_ui');
      rec = await Directory('${dir.path}/rec').create();
      File('${rec.path}/bad-1.json').writeAsStringSync('{ nope');
      File('${rec.path}/bad-1.canvas').writeAsStringSync('not a page');
      nb = Notebook(
        PageStore(await Directory('${dir.path}/pages').create()),
        buildModules(),
        saveDelay: Duration.zero,
        recoveryDirectory: rec,
      );
      await nb.load();
    });
    expect(nb.recoveryProblems, hasLength(1));
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
    expect(find.text("CAN'T OPEN"), findsOneWidget);
    expect(find.text('bad-1'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message ?? '').startsWith("Recovery entry can't be read"),
      ),
      findsOneWidget,
    );
    // The app never deletes it.
    expect(File('${rec.path}/bad-1.json').existsSync(), isTrue);
    expect(File('${rec.path}/bad-1.canvas').existsSync(), isTrue);
    await finish(tester);
  });
}
