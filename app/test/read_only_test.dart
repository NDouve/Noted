// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory root;
  late Directory pages;
  late Directory folder;
  late Directory extra;
  late List<Notebook> opened;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_readonly');
    pages = await Directory('${root.path}/pages').create();
    folder = await Directory('${root.path}/Work').create();
    extra = await Directory('${root.path}/Elsewhere').create();
    opened = [];
  });

  Notebook make({bool watch = false, Duration? check}) {
    final nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
      watchFiles: watch,
      watchDebounce: const Duration(milliseconds: 40),
      folderCheckInterval: check ?? Duration.zero,
    );
    opened.add(nb);
    return nb;
  }

  Future<void> cleanUp() async {
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    opened.clear();
    if (root.existsSync()) await root.delete(recursive: true);
  }

  File binderFile() => File('${folder.path}/$binderFileName');
  File pageFile(Directory d, String id) => File('${d.path}/$id.canvas');

  Future<void> until(bool Function() ok, {int ms = 4000}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('condition not reached in time');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  // A binder with a page that has a box, then the binder file is damaged.
  Future<({String page, String sub, String text})> damagedBinder() async {
    final first = make();
    await first.load();
    final s = await first.addBinder(folder.path);
    final p = await first.createPage(binderPath: s.path);
    final sub = await first.createPage(parentId: p);
    await first.open(p);
    first.current!.createBoxAt(const Bounds(40, 40, 0, 0));
    await first.flush();
    first.dispose();
    opened.clear();
    final text = binderFile().readAsStringSync();
    binderFile().writeAsStringSync('{ not json');
    return (page: p, sub: sub, text: text);
  }

  group('damaged binder file', () {
    tearDown(cleanUp);

    test('at startup: listed with its pages, read-only, nothing written', () async {
      final d = await damagedBinder();
      final pageBytes = pageFile(folder, d.page).readAsBytesSync();
      final subBytes = pageFile(folder, d.sub).readAsBytesSync();
      final modified = pageFile(folder, d.page).lastModifiedSync();

      final nb = make();
      await nb.load();
      final s = nb.binders.single;
      expect(s.status, BinderStatus.unreadable);
      expect(s.readOnly, isTrue);
      expect(s.binder, isNull);
      expect(s.tree.descendantsOf(d.page), [d.sub]);
      expect(nb.isReadOnlyPage(d.page), isTrue);

      // Opening a page gives a read-only view.
      await nb.open(d.page);
      final c = nb.current!;
      expect(c.readOnly, isTrue);
      expect(nb.readOnlyReason, isNotNull);
      expect(() => c.createBoxAt(const Bounds(0, 0, 0, 0)), throwsStateError);
      expect(c.commit(c.page.nodes.first.id, 'x'), isNull);
      c.delete(c.page.nodes.first.id);

      // Nothing about the binder can be changed.
      await expectLater(nb.createPage(binderPath: s.path), throwsA(isA<NotebookException>()));
      await expectLater(nb.createPage(parentId: d.page), throwsA(isA<NotebookException>()));
      await expectLater(nb.rename(d.page, 'x'), throwsA(isA<NotebookException>()));
      await expectLater(nb.delete(d.page), throwsA(isA<NotebookException>()));
      await expectLater(nb.move(d.sub, parentId: null), throwsA(isA<NotebookException>()));
      await expectLater(nb.moveToLocation(d.page), throwsA(isA<NotebookException>()));
      final standalone = nb.tree.roots.first.id;
      await expectLater(
        nb.move(standalone, parentId: d.page),
        throwsA(isA<NotebookException>()),
      );
      await expectLater(
        nb.moveRelative(standalone, d.page, after: true),
        throwsA(isA<NotebookException>()),
      );
      await nb.updateBinder(s.path, title: 'x');
      await nb.flush();

      expect(binderFile().readAsStringSync(), '{ not json');
      expect(pageFile(folder, d.page).readAsBytesSync(), pageBytes);
      expect(pageFile(folder, d.sub).readAsBytesSync(), subBytes);
      expect(pageFile(folder, d.page).lastModifiedSync(), modified);
    });

    test('while running: pending edits are saved first, then the open page turns read-only', () async {
      final nb = make();
      await nb.load();
      final s = await nb.addBinder(folder.path);
      final p = await nb.createPage(binderPath: s.path);
      nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      binderFile().writeAsStringSync('{ not json');
      await nb.checkBinderFile(binderFile().path);

      expect(s.status, BinderStatus.unreadable);
      expect(nb.currentId, p);
      expect(nb.current!.readOnly, isTrue);
      expect(nb.readOnlyReason, isNotNull);
      // The edit made before the damage reached the disk.
      expect(readPage(pageFile(folder, p).readAsStringSync()).nodes, hasLength(1));
      final after = pageFile(folder, p).readAsBytesSync();
      nb.current!.updateMeta(nb.current!.page.meta.withTitle('Late'));
      await nb.flush();
      expect(pageFile(folder, p).readAsBytesSync(), after);
      expect(binderFile().readAsStringSync(), '{ not json');
    });

    test('repaired: pages are editable again and the cover returns', () async {
      final d = await damagedBinder();
      final nb = make(watch: true);
      await nb.load();
      await nb.open(d.page);
      expect(nb.current!.readOnly, isTrue);

      binderFile().writeAsStringSync(d.text);
      await until(() => nb.binders.single.available);
      final s = nb.binders.single;
      expect(s.binder, isNotNull);
      expect(nb.isReadOnlyPage(d.page), isFalse);
      expect(nb.currentId, d.page);
      expect(nb.current!.readOnly, isFalse);
      expect(nb.readOnlyReason, isNull);
      nb.showCover(s.path);
      expect(nb.coverPath, s.path);
      await nb.rename(d.sub, 'Renamed');
      expect(s.tree[d.sub]!.title, 'Renamed');
      nb.current!.createBoxAt(const Bounds(200, 200, 0, 0));
      await nb.flush();
      expect(readPage(pageFile(folder, d.page).readAsStringSync()).nodes, hasLength(2));
    });

    test('a deleted binder file still makes the binder unavailable', () async {
      final d = await damagedBinder();
      final nb = make();
      await nb.load();
      await nb.open(d.page);
      binderFile().deleteSync();
      await nb.checkBinderFile(binderFile().path);
      final s = nb.binders.single;
      expect(s.status, BinderStatus.unavailable);
      expect(nb.tree[d.page], isNull);
      expect(s.tree[d.page], isNull);
      expect(nb.currentId, isNot(d.page));
      expect(binderFile().existsSync(), isFalse);
    });

    testWidgets('the sidebar says so, greys the pages and opens them read-only', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late ({String page, String sub, String text}) d;
      late Notebook nb;
      await tester.runAsync(() async {
        d = await damagedBinder();
        nb = make();
        await nb.load();
      });
      await tester.pumpWidget(MaterialApp(home: Home(notebook: nb)));
      await tester.pump();

      expect(find.text("Binder file can't be read"), findsOneWidget);
      final row = find.byKey(ValueKey('page-row-${d.page}'));
      expect(row, findsOneWidget);
      // No page menu on a read-only row.
      expect(
        find.descendant(of: row, matching: find.byType(PopupMenuButton<String>)),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('read-only-banner')), findsNothing);

      await tester.runAsync(() async {
        await tester.tap(row);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump();
      expect(nb.currentId, d.page);
      expect(find.byKey(const ValueKey('read-only-banner')), findsOneWidget);
      // No tool bar on a read-only page.
      expect(find.byIcon(Icons.text_fields), findsNothing);
      expect(find.byType(PageCanvas), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(cleanUp);
    });
  });

  group('standalone folder that goes away', () {
    tearDown(cleanUp);

    test('removed while running: pages unavailable, open page read-only; restored: back', () async {
      final nb = make();
      await nb.load();
      final x = await nb.createPage(folderPath: extra.path);
      final y = await nb.createPage(folderPath: extra.path);
      await nb.open(x);
      await nb.flush();
      final moved = Directory('${root.path}/Elsewhere-away');

      await extra.rename(moved.path);
      await nb.checkFolders();

      final f = nb.standaloneFolders.single;
      expect(f.available, isFalse);
      expect(f.missing, isTrue);
      expect(nb.tree[x], isNull);
      expect(nb.tree[y], isNull);
      // The open page stays open, read-only.
      expect(nb.currentId, x);
      expect(nb.current!.readOnly, isTrue);
      expect(nb.readOnlyReason, isNotNull);
      expect(nb.current!.page.id, x);
      // Edits are impossible and the folder is not created again.
      expect(() => nb.current!.createBoxAt(const Bounds(0, 0, 0, 0)), throwsStateError);
      await expectLater(nb.createPage(folderPath: extra.path), throwsA(isA<NotebookException>()));
      await nb.flush();
      expect(extra.existsSync(), isFalse);

      await moved.rename(extra.path);
      await nb.checkFolders();
      expect(f.available, isFalse); // the old object is replaced
      final back = nb.standaloneFolders.single;
      expect(back.available, isTrue);
      expect(nb.tree[x], isNotNull);
      expect(nb.tree[y], isNotNull);
      expect(nb.currentId, x);
      expect(nb.current!.readOnly, isFalse);
      expect(nb.readOnlyReason, isNull);
      nb.current!.createBoxAt(const Bounds(5, 5, 0, 0));
      await nb.flush();
      expect(readPage(pageFile(extra, x).readAsStringSync()).nodes, hasLength(1));
    });

    test('a page changed while the folder was away is merged when it comes back', () async {
      final nb = make();
      await nb.load();
      final x = await nb.createPage(folderPath: extra.path);
      await nb.flush();
      final moved = Directory('${root.path}/Elsewhere-away');
      await extra.rename(moved.path);
      await nb.checkFolders();

      // Someone else adds a box to the page file meanwhile.
      final other = CanvasController(
        readPage(File('${moved.path}/$x.canvas').readAsStringSync()),
        buildModules(),
      )..createBoxAt(const Bounds(30, 30, 0, 0));
      File('${moved.path}/$x.canvas').writeAsStringSync(writePage(other.page));
      other.dispose();

      await moved.rename(extra.path);
      await nb.checkFolders();
      expect(nb.current!.page.nodes, hasLength(1));
      expect(nb.current!.readOnly, isFalse);
    });

    test('the default folder is checked too', () async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      final moved = Directory('${root.path}/pages-away');
      await pages.rename(moved.path);
      await nb.checkFolders();
      expect(nb.defaultFolderAvailable, isFalse);
      expect(nb.tree[a], isNull);
      expect(nb.current!.readOnly, isTrue);
      await nb.flush();
      expect(pages.existsSync(), isFalse);

      await moved.rename(pages.path);
      await nb.checkFolders();
      expect(nb.defaultFolderAvailable, isTrue);
      expect(nb.tree[a], isNotNull);
      expect(nb.current!.readOnly, isFalse);
    });

    test('the timer notices both ways and the watcher works again afterwards', () async {
      final nb = make(watch: true, check: const Duration(milliseconds: 40));
      await nb.load();
      final x = await nb.createPage(folderPath: extra.path);
      await nb.flush();
      final moved = Directory('${root.path}/Elsewhere-away');

      await extra.rename(moved.path);
      await until(() => !nb.standaloneFolders.single.available);
      expect(nb.tree[x], isNull);
      expect(nb.current!.readOnly, isTrue);

      await moved.rename(extra.path);
      await until(() => nb.standaloneFolders.single.available);
      expect(nb.tree[x], isNotNull);
      expect(nb.current!.readOnly, isFalse);

      // A page file that appears now is seen by the restarted watcher.
      final id = newId();
      final page = NotedPage.create(PageMeta.create(id: id, title: 'New', order: 9));
      File('${extra.path}/$id.canvas').writeAsStringSync(writePage(page));
      await until(() => nb.tree[id] != null);
    });

    testWidgets('the sidebar lists a vanished folder as on another device', (tester) async {
      late Notebook nb;
      late String x;
      await tester.runAsync(() async {
        nb = make();
        await nb.load();
        x = await nb.createPage(folderPath: extra.path);
        await nb.flush();
        await extra.rename('${root.path}/Elsewhere-away');
        await nb.checkFolders();
      });
      await tester.pumpWidget(MaterialApp(home: Home(notebook: nb)));
      await tester.pump();
      expect(find.byKey(ValueKey('folder-header-${nb.standaloneFolders.single.path}')), findsOneWidget);
      expect(find.text('On another device'), findsOneWidget);
      expect(find.byKey(const ValueKey('read-only-banner')), findsOneWidget);
      expect(nb.currentId, x);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Directory('${root.path}/Elsewhere-away').rename(extra.path);
        await cleanUp();
      });
    });
  });
}
