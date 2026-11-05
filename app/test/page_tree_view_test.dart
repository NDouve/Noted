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
import 'package:noted/src/sidebar_row.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMenuItem, notedThemeData;
import 'package:noted_core/noted_core.dart';
import 'support/busy_retry.dart';
import 'support/real_io.dart';
import 'support/settle_saves.dart';

/// A store that runs [beforeDelete] once, right before the next
/// compare-and-delete: a sync client landing a newer version of the file.
class _ChangingStore extends PageStore {
  _ChangingStore(super.directory);

  void Function()? beforeDelete;

  @override
  Future<DeleteResult> deleteIfUnchanged(
    String pageId,
    String expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    Future<void> Function()? beforeDelete,
    void Function()? beforeRestore,
  }) {
    final f = this.beforeDelete;
    this.beforeDelete = null;
    f?.call();
    return super.deleteIfUnchanged(
      pageId,
      expectedText,
      beforeMoveAside: beforeMoveAside,
      afterRead: afterRead,
      beforeDelete: beforeDelete,
      beforeRestore: beforeRestore,
    );
  }
}

/// A store whose delete fails for [failDelete], and that won't write back the
/// pages in [failNew]: a delete that fails part way and can't be rolled back.
class _FailingStore extends PageStore {
  _FailingStore(super.directory);

  final Set<String> failDelete = {};
  final Set<String> failNew = {};

  @override
  Future<DeleteResult> deleteIfUnchanged(
    String pageId,
    String expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    Future<void> Function()? beforeDelete,
    void Function()? beforeRestore,
  }) {
    if (failDelete.contains(pageId)) throw const FileSystemException('source gone');
    return super.deleteIfUnchanged(
      pageId,
      expectedText,
      beforeMoveAside: beforeMoveAside,
      afterRead: afterRead,
      beforeDelete: beforeDelete,
      beforeRestore: beforeRestore,
    );
  }

  @override
  Future<bool> saveNewText(NotedPage page, String text, {Future<void> Function()? beforePublish}) {
    if (failNew.contains(page.id)) throw const FileSystemException('destination gone');
    return super.saveNewText(page, text, beforePublish: beforePublish);
  }
}

/// A notebook that records which deletes were discarded, and can make Undo
/// leave the delete pending (a partial Undo).
class _SpyNotebook extends Notebook {
  _SpyNotebook(
    super.store,
    super.modules, {
    super.saveDelay,
    super.bindersFile,
    super.watchFiles,
    super.watchDebounce,
    super.folderCheckInterval,
  });

  final List<DeletedPages> discarded = [];
  bool partialUndo = false;
  bool undoing = false; // the real Undo takes the delete out of reach while it runs
  int undoCalls = 0;
  DeletedPages? undone;

  @override
  void discardDeleted(DeletedPages deleted) {
    discarded.add(deleted);
    super.discardDeleted(deleted);
  }

  @override
  Future<void> undoDelete(DeletedPages deleted) async {
    undoCalls++;
    undone = deleted;
    if (partialUndo) {
      undoing = true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      undoing = false;
      throw const NotebookException('still available to Undo', needsAction: true);
    }
    await super.undoDelete(deleted);
  }

  @override
  bool isPendingDelete(DeletedPages deleted) => !undoing && super.isPendingDelete(deleted);
}

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
      await tester.runAsync(() => realIoPause(50));
    }
    await tester.pumpAndSettle();
  }

  /// Alternates the test clock and real IO until [done] (at most 300 rounds,
  /// each with a real pause of 30 ms, 120 ms on CI: about 9 s, or 36 s on
  /// CI), then settles. Fails, naming [what], if [done] never becomes true.
  Future<void> until(WidgetTester tester, bool Function() done, {String what = 'the condition'}) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => realIoPause(30));
    }
    if (!done()) fail('Gave up waiting for $what.');
    await settle(tester);
  }

  _ChangingStore? changing;

  Future<void> start(
    WidgetTester tester, {
    ThemeData? theme,
    bool watch = false,
    PageStore Function(Directory)? store,
    Directory? appDir,
  }) async {
    // Room for the whole page menu.
    if (tester.view.physicalSize.height / tester.view.devicePixelRatio < 1400) {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('noted_tree_ui');
      nb = _SpyNotebook(
        store != null ? store(dir) : PageStore(dir),
        buildModules(),
        saveDelay: Duration.zero,
        bindersFile: appDir == null ? null : File('${appDir.path}/binders.json'),
        watchFiles: watch,
        watchDebounce: const Duration(milliseconds: 40),
        folderCheckInterval: watch ? const Duration(milliseconds: 100) : Duration.zero,
      );
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
    await settleSaves(tester, nb);
    await tester.runAsync(() async {
      nb.dispose();
      // dispose does not await closing a watcher, so on Windows its handle
      // can still be on the folder for a moment.
      await busyRetry(() => dir.delete(recursive: true));
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
  Future<void> dragTo(
    WidgetTester tester,
    String from,
    Offset target, {
    PointerDeviceKind kind = PointerDeviceKind.touch,
    bool hold = true,
  }) async {
    final start = tester.getTopLeft(row(from)) + const Offset(60, 18);
    final g = await tester.startGesture(start, kind: kind);
    if (hold) await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
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
    await until(tester, () => rootIds().join() == [b, a, c].join());
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
    // The move is saved through real file IO; wait for it, not a fixed time.
    await until(tester, () => kids(a).isNotEmpty);
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
    await until(tester, () => rootIds().join() == [c, a, b].join());
    expect(rootIds(), [c, a, b]);
    await finish(tester);
  });

  testWidgets('dropping on the lower edge places a page after the row', (tester) async {
    await start(tester);
    await dragTo(tester, a, at(tester, b, 0.92));
    await until(tester, () => rootIds().join() == [b, a, c].join());
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

  // Deletes page [b] with an attachment folder, leaving the Deleted bar up.
  // Returns the folder its attachments are set aside in.
  Future<Directory> deleteWithAttachment(WidgetTester tester, Directory appDir) async {
    await start(tester, appDir: appDir);
    await tester.runAsync(() async {
      final assets = await Directory('${dir.path}/${assetsFolderName(b)}').create();
      await File('${assets.path}/x.bin').writeAsBytes([1, 2, 3]);
    });
    await rightClick(tester, b);
    await tester.tap(find.text('Delete'));
    await settle(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.pump();
    await until(tester, () => find.text('Undo').evaluate().isNotEmpty);
    return Directory('${appDir.path}/deleted-attachments');
  }

  bool trashHasFiles(Directory trash) =>
      trash.existsSync() && trash.listSync(recursive: true).whereType<File>().isNotEmpty;

  testWidgets('the Deleted bar has a close button and a time limit, even with Undo', (tester) async {
    final app = await tester.runAsync(() => Directory.systemTemp.createTemp('noted_tree_app')) as Directory;
    addTearDown(() => app.deleteSync(recursive: true));
    final trash = await deleteWithAttachment(tester, app);
    final bar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(bar.persist, isFalse, reason: 'a bar with an action persists unless told not to');
    expect(bar.showCloseIcon, isTrue);
    expect(trashHasFiles(trash), isTrue, reason: 'set aside while the bar is up');
    await tester.pump(const Duration(seconds: 11));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Undo'), findsNothing, reason: 'the bar timed out');
    await until(tester, () => !trashHasFiles(trash), what: 'the set-aside attachments to be cleaned up');
    await finish(tester);
  });

  /// Deletes page [id] through its menu, leaving the Deleted bar up.
  Future<void> deleteVia(WidgetTester tester, String id) async {
    await rightClick(tester, id);
    await tester.tap(find.text('Delete'));
    await settle(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.pump();
    await until(tester, () => find.text('Undo').evaluate().isNotEmpty);
  }

  testWidgets('saveBeforeExit (the exit handler) drops a pending delete and its set-aside attachments',
      (tester) async {
    final app = await tester.runAsync(() => Directory.systemTemp.createTemp('noted_tree_app')) as Directory;
    addTearDown(() => app.deleteSync(recursive: true));
    final trash = await deleteWithAttachment(tester, app);
    expect(trashHasFiles(trash), isTrue);
    await tester.runAsync(() => saveBeforeExit(nb));
    expect(trashHasFiles(trash), isFalse, reason: 'awaited: gone when it returns');
    await tester.runAsync(() => saveBeforeExit(nb)); // nothing pending: no error
    await finish(tester);
  });

  testWidgets('a second delete discards the first once; the old bar does not discard it again', (tester) async {
    await start(tester);
    final spy = nb as _SpyNotebook;
    await deleteVia(tester, b);
    await deleteVia(tester, c);
    await tester.pump(const Duration(seconds: 11));
    await tester.pump(const Duration(seconds: 1));
    await until(tester, () => spy.discarded.length >= 2, what: 'both deletes to be discarded');
    await settle(tester);
    expect(spy.discarded.length, 2, reason: 'once for the first delete, once for the second');
    expect(spy.discarded.toSet().length, 2);
    await finish(tester);
  });

  testWidgets('a partial Undo shows a new Deleted bar with Undo that times out and discards', (tester) async {
    await start(tester);
    final spy = nb as _SpyNotebook;
    await deleteVia(tester, b);
    spy.partialUndo = true;
    await tester.runAsync(() => tester.tap(find.text('Undo')));
    await until(tester, () => spy.undoCalls == 1);
    // The explanation shows first (it stays until closed); the new Deleted bar is queued behind it.
    expect(find.textContaining('still available to Undo'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await settle(tester);
    expect(find.text('Undo'), findsOneWidget, reason: 'the Deleted bar is offered again');
    expect(find.text("Some pages weren't restored"), findsOneWidget);
    spy.partialUndo = false;
    spy.discarded.clear();
    await tester.pump(const Duration(seconds: 11));
    await tester.pump(const Duration(seconds: 1));
    await until(tester, () => spy.discarded.isNotEmpty, what: 'the delete to be discarded');
    expect(spy.discarded.single, same(spy.undone), reason: 'discarded once, and it is the delete');
    expect(find.text('Undo'), findsNothing);
    await finish(tester);
  });

  testWidgets('pages recovery did not take are offered back with Undo, and closing the message lets them go', (
    tester,
  ) async {
    late _FailingStore failing;
    await start(tester, store: (d) => failing = _FailingStore(d));
    late String child;
    await tester.runAsync(() async {
      child = await nb.createPage(parentId: b);
      failing.failDelete.add(child);
      failing.failNew.add(b);
    });
    await tester.pump();
    await rightClick(tester, b);
    await tester.tap(find.text('Delete'));
    await settle(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.pump();
    await until(tester, () => find.textContaining('Recovery could not keep').evaluate().isNotEmpty);
    expect(find.textContaining('Recovery holds'), findsNothing);
    expect(find.text('Undo'), findsOneWidget);
    expect(File('${dir.path}/$b.canvas').existsSync(), isFalse);

    failing.failNew.clear();
    await tester.runAsync(() => tester.tap(find.text('Undo')));
    await until(tester, () => File('${dir.path}/$b.canvas').existsSync());
    expect(rootIds(), contains(b));
    await finish(tester);
  });

  testWidgets('closing the Deleted bar releases the pages and cleans up the attachments', (tester) async {
    final app = await tester.runAsync(() => Directory.systemTemp.createTemp('noted_tree_app')) as Directory;
    addTearDown(() => app.deleteSync(recursive: true));
    final trash = await deleteWithAttachment(tester, app);
    expect(trashHasFiles(trash), isTrue);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    await until(tester, () => !trashHasFiles(trash), what: 'the set-aside attachments to be cleaned up');
    expect(find.text('Undo'), findsNothing);
    await finish(tester);
  });

  testWidgets('Page settings is in the page menu and the right-click menu, and the row has no icon', (tester) async {
    await start(tester);
    expect(find.byTooltip('Page settings'), findsNothing);
    // From the row's ⋯ menu.
    await tester.tap(find.byTooltip('Page options').at(1));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('Page settings…')));
    await settle(tester);
    expect(find.byKey(const ValueKey('settings-panel')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-close')));
    await tester.pumpAndSettle();
    // From the right-click menu.
    await rightClick(tester, b);
    await tester.runAsync(() => tester.tap(find.text('Page settings…')));
    await settle(tester);
    expect(find.byKey(const ValueKey('settings-panel')), findsOneWidget);
    expect(find.text('Location'), findsOneWidget);
    expect(tester.widget<SelectableText>(find.byKey(const ValueKey('settings-location-path'))).data, dir.path);
    await tester.tap(find.byKey(const ValueKey('settings-close')));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('a page whose file changed before it was deleted is kept: the note shows, no Undo, not "Deleted"', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await start(tester, store: (d) => changing = _ChangingStore(d));
    await rightClick(tester, b);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await settle(tester);
    // A newer version lands after the page was read, right before it is deleted.
    changing!.beforeDelete = () {
      final f = File('${dir.path}/$b.canvas');
      f.writeAsStringSync(f.readAsStringSync().replaceFirst('"title":"', '"title":"Synced '));
    };
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.pump();
    await until(tester, () => find.textContaining('not deleted').evaluate().isNotEmpty);
    expect(find.textContaining('changed on another device'), findsOneWidget);
    expect(find.text('Undo'), findsNothing);
    expect(find.textContaining('Deleted "'), findsNothing);
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

  for (final needsAction in [true, false]) {
    testWidgets(
      needsAction
          ? 'a move error that needs action stays on screen with a close icon'
          : 'an ordinary move error is a plain SnackBar that fades',
      (tester) async {
        await tester.runAsync(() async {
          dir = await Directory.systemTemp.createTemp('noted_tree_ui');
          nb = _FailingCreate(PageStore(dir), needsAction);
          await nb.load();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: PageTreeView(notebook: nb)),
          ),
        );
        await tester.pump();
        (nb as _FailingCreate).armed = true;
        final state = tester.state<PageTreeViewState>(find.byType(PageTreeView));
        await tester.runAsync(() => state.newStandalonePage());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        final bar = tester.widget<SnackBar>(find.byType(SnackBar));
        expect(bar.persist, needsAction);
        expect(bar.showCloseIcon, needsAction);
        expect(find.byIcon(Icons.close), needsAction ? findsOneWidget : findsNothing);
        await tester.pump(const Duration(seconds: 30));
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(SnackBar), needsAction ? findsOneWidget : findsNothing);
        await finish(tester);
      },
    );
  }

  Future<void> longPress(WidgetTester tester, String id, PointerDeviceKind kind) async {
    final at = tester.getCenter(row(id)) + const Offset(-40, 0);
    final g = await tester.startGesture(at, kind: kind);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await tester.runAsync(() => g.up());
    await tester.pumpAndSettle();
  }

  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.stylus]) {
    testWidgets('a ${kind.name} long press opens the page menu at the press point', (tester) async {
      await start(tester);
      await longPress(tester, b, kind);
      expect(find.text('New subpage'), findsOneWidget);
      expect(find.text('Outdent'), findsOneWidget);
      final pressed = tester.getCenter(row(b)) + const Offset(-40, 0);
      expect((tester.getTopLeft(find.text('New subpage')) - pressed).distance, lessThan(200));
      await tester.tapAt(const Offset(790, 5));
      await tester.pumpAndSettle();
      await finish(tester);
    });
  }


  testWidgets('a held mouse press does not open the menu, and a held mouse drag reorders', (
    tester,
  ) async {
    await start(tester);
    await longPress(tester, b, PointerDeviceKind.mouse);
    expect(find.text('New subpage'), findsNothing);
    // No pre-hold: a mouse drag starts at once.
    await dragTo(tester, c, at(tester, a, 0.08), kind: PointerDeviceKind.mouse, hold: false);
    await until(tester, () => rootIds().join() == [c, a, b].join());
    expect(find.text('New subpage'), findsNothing);
    expect(rootIds(), [c, a, b]);
    await finish(tester);
  });

  testWidgets('a touch swipe on a row scrolls the list and moves no page', (tester) async {
    await start(tester);
    await tester.runAsync(() async {
      for (var i = 0; i < 25; i++) {
        await nb.createPage();
      }
    });
    await tester.pumpAndSettle();
    final before = rootIds();
    final scrollable = find.descendant(
      of: find.byType(PageTreeView),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable.first).position;
    expect(position.pixels, 0);
    await tester.drag(row(b), const Offset(0, -300), kind: PointerDeviceKind.touch);
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    expect(rootIds(), before);
    expect(find.text('New subpage'), findsNothing);
    await finish(tester);
  });

  testWidgets('a cancelled held touch opens no menu', (tester) async {
    await start(tester);
    final at = tester.getCenter(row(b)) + const Offset(-40, 0);
    final g = await tester.startGesture(at, kind: PointerDeviceKind.touch);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await g.cancel();
    await tester.pumpAndSettle();
    expect(find.text('New subpage'), findsNothing);
    await finish(tester);
  });

  testWidgets('a second finger on another row does not open a dragged row menu', (tester) async {
    await start(tester);
    final g = await tester.startGesture(
      tester.getTopLeft(row(b)) + const Offset(20, 3),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await g.moveBy(const Offset(0, 19)); // past the slop, still over its own row
    await tester.pump();
    final g2 = await tester.startGesture(
      tester.getCenter(row(c)) + const Offset(-40, 0),
      kind: PointerDeviceKind.touch,
    );
    await g2.up();
    await tester.pump();
        await tester.runAsync(() => g.up());
    await tester.pumpAndSettle();
    expect(find.text('New subpage'), findsNothing);
    await finish(tester);
  });

  testWidgets('a long press by touch opens nothing on a read-only row', (tester) async {
    await start(tester, watch: true);
    late String page;
    await tester.runAsync(() async {
      final folder = await Directory('${dir.path}/Away').create();
      final binder = await nb.addBinder(folder.path);
      page = await nb.createPage(binderPath: binder.path);
      await nb.flush();
      try {
        // A file in it can be open for a moment.
        await busyRetry(() async => folder.renameSync('${dir.path}/Away-gone'));
      } on FileSystemException catch (e) {
        fail('the folder could not be renamed: $e');
      }
    });
    // An added check: the row itself is asserted locked before the press, as
    // well as the model.
    bool rowLocked() {
      final rows = find.descendant(of: row(page), matching: find.byType(SidebarRow));
      return nb.isReadOnlyPage(page) && rows.evaluate().isNotEmpty && tester.widget<SidebarRow>(rows).disabled;
    }

    await until(tester, rowLocked, what: 'the renamed binder folder to make its row read-only');
    expect(nb.isReadOnlyPage(page), isTrue);
    expect(rowLocked(), isTrue);
    await longPress(tester, page, PointerDeviceKind.touch);
    expect(find.text('New subpage'), findsNothing);
    expect(find.byType(PopupMenuItem<String>), findsNothing);
    await finish(tester);
  });

  testWidgets('a long press on a binder header opens the binder menu', (tester) async {
    await start(tester);
    await tester.runAsync(() async {
      final folder = await Directory('${dir.path}/Work').create();
      await nb.addBinder(folder.path);
    });
    await tester.pumpAndSettle();
    final header = find.byWidgetPredicate(
      (w) => w.key is ValueKey && (w.key! as ValueKey).value.toString().startsWith('binder-header-'),
    );
    final g = await tester.startGesture(
      tester.getCenter(header) + const Offset(-40, 0),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await tester.runAsync(() => g.up());
    await tester.pumpAndSettle();
    expect(find.text('New page'), findsWidgets);
    expect(find.text('Remove from sidebar'), findsOneWidget);
    await tester.tapAt(const Offset(790, 5));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('a right click on a binder header opens the binder menu', (tester) async {
    await start(tester);
    await tester.runAsync(() async {
      final folder = await Directory('${dir.path}/Work').create();
      await nb.addBinder(folder.path);
    });
    await tester.pumpAndSettle();
    final header = find.byWidgetPredicate(
      (w) => w.key is ValueKey && (w.key! as ValueKey).value.toString().startsWith('binder-header-'),
    );
    await tester.runAsync(
      () => tester.tapAt(tester.getCenter(header) + const Offset(-40, 0), buttons: kSecondaryButton),
    );
    await tester.pumpAndSettle();
    expect(find.text('Remove from sidebar'), findsOneWidget);
    await tester.tapAt(const Offset(790, 5));
    await tester.pumpAndSettle();
    await finish(tester);
  });
}

/// A notebook whose page creation fails with a [NotebookException].
class _FailingCreate extends Notebook {
  _FailingCreate(PageStore store, this._needsAction) : super(store, buildModules(), saveDelay: Duration.zero);

  final bool _needsAction;
  bool armed = false;

  @override
  Future<String> createPage({
    String? parentId,
    String? binderPath,
    String? folderPath,
    bool focusTitle = false,
  }) async => armed ? throw NotebookException('A failure.', needsAction: _needsAction) : super.createPage();
}
