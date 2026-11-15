// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The Codex R-2 guard (task 6): a menu item runs against the page or cover it
// was chosen on, and runs nothing if that changed before it ran.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settle_saves.dart';
import 'support/shell_world.dart';

Future<void> _open(WidgetTester t, String top) async {
  await t.tap(find.byKey(ValueKey('menu-top-$top')));
  await t.pumpAndSettle();
}

Future<void> _openSub(WidgetTester t, String label) async {
  await t.tap(find.byKey(ValueKey('menu-sub-$label')));
  await t.pumpAndSettle();
}

// Taps the item and lets the menu choose it (its own onPressed is deferred one
// frame); the command's deferred frame then waits at the test hook while
// [change] changes the world, and runs after it.
Future<void> _chooseThen(WidgetTester t, ShellWorld w, String id, Future<void> Function() change) async {
  final gate = Completer<void>();
  w.bar(t).debugBeforeRun = () => gate.future;
  await t.tap(find.byKey(ValueKey('menu-$id')));
  for (var i = 0; i < 3; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
  await change();
  gate.complete();
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}


void main() {
  group('Codex R-2 guard', () {
    testWidgets('Edit > Undo chosen on page A, then page B opened before it runs: nothing changes on either', (t) async {
      final w = await ShellWorld.open(t);
      final a = w.nb.current!;
      await w.addNote(t, 'na', 'a');
      expect(a.canUndo, isTrue);
      // Saved first: opening another page waits for the page's save.
      await settleSaves(t, w.nb);

      await _open(t, 'Edit');
      await _chooseThen(t, w, 'canvas.undo', () async {
        // Page B opens before the deferred callback; it has an undo step too.
        await w.openPage(t, w.second);
        await t.pump();
        await w.addNote(t, 'nb', 'b');
      });
      await w.settle(t);
      final b = w.nb.current!;
      expect(identical(b, a), isFalse);
      expect(a.page.node('na'), isNotNull, reason: 'page A was not undone');
      expect(b.page.node('nb'), isNotNull, reason: 'page B was not undone');
      expect(b.canUndo, isTrue);
      await w.close(t);

    });

    testWidgets('File > Page > Rename on A, then B opened: no rename dialog, through the drawer proxy at 900 px', (t) async {
      final w = await ShellWorld.open(t, size: const Size(900, 800));
      await _open(t, 'File');
      await _openSub(t, 'Page');
      await _chooseThen(t, w, 'app.page.rename', () async {
        await w.openPage(t, w.second);
      });
      await w.settle(t);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(TextField).evaluate().where((e) => e.widget is TextField && (e.widget as TextField).controller?.text == 'Alpha'), isEmpty);
      await w.close(t);
    });

    testWidgets('File > Page > Rename opens the drawer and the rename at 900 px when nothing changed', (t) async {
      final w = await ShellWorld.open(t, size: const Size(900, 800));
      await _open(t, 'File');
      await _openSub(t, 'Page');
      await _chooseThen(t, w, 'app.page.rename', () async {});
      await w.settle(t);
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Rename'), findsWidgets);
      expect(find.byType(AlertDialog), findsOneWidget);
      await w.close(t);
    });

    testWidgets('Page > Move up chosen on A, then a sibling move before it runs: runs nothing', (t) async {
      final w = await ShellWorld.open(t);
      // Beta is second: Move up is on for it.
      await w.openPage(t, w.second);
      await w.settle(t);
      expect(w.nb.treeOfPage(w.second).siblingsOf(w.second).map((p) => p.id).toList(), [w.first, w.second]);
      await _open(t, 'File');
      await _openSub(t, 'Page');
      await _chooseThen(t, w, 'app.page.moveUp', () async {
        // Someone else moves Beta up first; Move up is now off for it.
        await w.run(t, () => w.nb.moveUp(w.second));
      });
      await w.settle(t);
      expect(w.nb.treeOfPage(w.second).siblingsOf(w.second).map((p) => p.id).toList(), [w.second, w.first], reason: 'moved once, not twice');
      await w.close(t);
    });

    testWidgets('cover X to cover Y: Binder settings runs nothing for Y', (t) async {
      final w = await ShellWorld.open(t);
      final x = await w.addBinderWithPage(t, 'X');
      final y = await w.addBinderWithPage(t, 'Y');
      w.nb.showCover(x.path);
      await w.settle(t);
      await _open(t, 'File');
      await _openSub(t, 'Binder');
      await _chooseThen(t, w, 'app.binder.settings', () async {
        w.nb.showCover(y.path);
      });
      await w.settle(t);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(w.nb.coverPath, y.path);
      await w.close(t);
    });

    testWidgets('cover X to cover Y: Remove from sidebar leaves Y in the sidebar', (t) async {
      final w = await ShellWorld.open(t);
      final x = await w.addBinderWithPage(t, 'X');
      final y = await w.addBinderWithPage(t, 'Y');
      w.nb.showCover(x.path);
      await w.settle(t);
      await _open(t, 'File');
      await _openSub(t, 'Binder');
      await _chooseThen(t, w, 'app.binder.remove', () async {
        w.nb.showCover(y.path);
      });
      await w.settle(t);
      expect(find.byType(AlertDialog), findsNothing);
      expect(w.nb.binders.map((b) => b.path), containsAll([x.path, y.path]));
      await w.close(t);
    });

    testWidgets('cover X to cover Y through the drawer proxy at 900 px', (t) async {
      final w = await ShellWorld.open(t, size: const Size(900, 800));
      final x = await w.addBinderWithPage(t, 'X');
      final y = await w.addBinderWithPage(t, 'Y');
      w.nb.showCover(x.path);
      await w.settle(t);
      await _open(t, 'File');
      await _openSub(t, 'Binder');
      await _chooseThen(t, w, 'app.binder.settings', () async {
        w.nb.showCover(y.path);
      });
      await w.settle(t);
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await w.close(t);
    });

    testWidgets('a page chosen on, then the cover shown before it runs: nothing runs', (t) async {
      final w = await ShellWorld.open(t);
      final x = await w.addBinderWithPage(t, 'X');
      await _open(t, 'File');
      await _openSub(t, 'Page');
      await _chooseThen(t, w, 'app.page.rename', () async {
        w.nb.showCover(x.path);
      });
      await w.settle(t);
      expect(find.byType(AlertDialog), findsNothing);
      await w.close(t);
    });

    testWidgets('the key to open the menu is not needed: Escape leaves the world as it was', (t) async {
      final w = await ShellWorld.open(t);
      await _open(t, 'Edit');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(w.nb.currentId, w.first);
      await w.close(t);
    });
  });
}
