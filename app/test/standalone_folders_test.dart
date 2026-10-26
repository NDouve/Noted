// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory root;
  late Directory pages;
  late Directory extra;
  late Directory binderDir;
  late File settings;
  late List<Notebook> opened;

  Future<void> setUpDirs() async {
    root = await Directory.systemTemp.createTemp('noted_folders');
    pages = await Directory('${root.path}/pages').create();
    extra = await Directory('${root.path}/Elsewhere').create();
    binderDir = await Directory('${root.path}/Work').create();
    settings = File('${root.path}/app/binders.json');
    opened = [];
  }

  Notebook make({
    Future<String?> Function()? pick,
    bool watch = false,
    Duration saveDelay = Duration.zero,
  }) {
    final nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: saveDelay,
      bindersFile: settings,
      pickFolder: pick,
      watchFiles: watch,
      watchDebounce: const Duration(milliseconds: 50),
    );
    opened.add(nb);
    return nb;
  }

  Future<void> tearDownDirs() async {
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    await root.delete(recursive: true);
  }

  Map<String, Object?> savedSettings() =>
      jsonDecode(settings.readAsStringSync()) as Map<String, Object?>;

  List<String> canvasFiles(Directory d) => [
    for (final f in d.listSync())
      if (f is File && f.path.endsWith('.canvas')) f.path,
  ];

  String norm(String p) => p.replaceAll(r'\', '/');

  group('model', () {
    setUp(setUpDirs);
    tearDown(tearDownDirs);

    test('a page created in another folder lives there and the folder is remembered', () async {
      final nb = make();
      await nb.load();
      final id = await nb.createPage(folderPath: extra.path);
      expect(File('${extra.path}/$id.canvas').existsSync(), isTrue);
      expect(nb.tree[id], isNotNull);
      expect(nb.binderOfPage(id), isNull);
      expect(nb.standaloneFolders.single.available, isTrue);
      expect(savedSettings()['standaloneFolders'], hasLength(1));
      expect(savedSettings()['binders'], isEmpty);

      // Asking again for the same folder adds nothing.
      await nb.createPage(folderPath: extra.path);
      expect(savedSettings()['standaloneFolders'], hasLength(1));
      // The default folder is not an extra folder.
      await nb.createPage(folderPath: pages.path);
      expect(nb.standaloneFolders, hasLength(1));
      expect(canvasFiles(pages), hasLength(2)); // first page + this one

      // A fresh start brings the pages back in one tree.
      await nb.flush();
      final again = make();
      await again.load();
      expect(again.tree[id], isNotNull);
      expect(again.tree.roots.length, 4);
      expect(again.standaloneFolders.single.available, isTrue);
    });

    test('a subpage lives in its parent\'s folder, and all page operations work', () async {
      final nb = make();
      await nb.load();
      final parent = await nb.createPage(folderPath: extra.path);
      final child = await nb.createPage(parentId: parent);
      expect(File('${extra.path}/$child.canvas').existsSync(), isTrue);
      expect(nb.tree.childrenOf(parent).single.id, child);

      await nb.rename(parent, 'Renamed');
      final sibling = await nb.createPage(folderPath: extra.path);
      await nb.moveDown(parent);
      expect(nb.tree.roots.map((p) => p.id), isNot(contains(null)));
      await nb.outdent(child);
      expect(nb.tree.parentIdOf(child), isNull);
      expect(File('${extra.path}/$child.canvas').existsSync(), isTrue);

      final deleted = await nb.delete(sibling);
      expect(File('${extra.path}/$sibling.canvas').existsSync(), isFalse);
      await nb.undoDelete(deleted);
      expect(File('${extra.path}/$sibling.canvas').existsSync(), isTrue);
      expect((await PageStore(extra).load(parent)).meta.title, 'Renamed');

      // Moving into a binder moves the file; back to "Pages" lands in the
      // default folder.
      final binder = await nb.addBinder(binderDir.path);
      await nb.moveToLocation(parent, binderPath: binder.path);
      expect(File('${binderDir.path}/$parent.canvas').existsSync(), isTrue);
      expect(File('${extra.path}/$parent.canvas').existsSync(), isFalse);
      await nb.moveToLocation(parent);
      expect(File('${pages.path}/$parent.canvas').existsSync(), isTrue);
    });

    test('a binder folder cannot be a standalone folder', () async {
      final nb = make();
      await nb.load();
      // A folder with a binder file.
      await BinderStore(binderDir).create(Binder.create(title: 'W', color: binderPalette.first));
      await expectLater(nb.checkStandaloneFolder(binderDir.path), throwsA(isA<NotebookException>()));
      await expectLater(
        nb.createPage(folderPath: binderDir.path),
        throwsA(isA<NotebookException>()),
      );
      // A folder listed as a binder.
      final other = await Directory('${root.path}/Other').create();
      await nb.addBinder(other.path);
      await expectLater(nb.checkStandaloneFolder(other.path), throwsA(isA<NotebookException>()));
      expect(nb.standaloneFolders, isEmpty);
      expect(nb.tree.roots, hasLength(1));
      // And the other way round.
      await nb.createPage(folderPath: extra.path);
      await expectLater(nb.addBinder(extra.path), throwsA(isA<NotebookException>()));
    });

    test('binders.json: old files load, unknown fields stay', () async {
      await settings.parent.create(recursive: true);
      settings.writeAsStringSync(
        '{"format":1,"binders":[],"x-future":{"a": 1.50}}\n',
      );
      final nb = make();
      await nb.load();
      expect(nb.standaloneFolders, isEmpty);
      // Nothing is added to the file until a folder is used.
      await nb.createPage();
      await nb.addBinder(binderDir.path);
      expect(savedSettings().containsKey('standaloneFolders'), isFalse);
      await nb.createPage(folderPath: extra.path);
      final text = settings.readAsStringSync();
      expect(text, contains('"x-future":{"a": 1.50}'));
      expect((savedSettings()['standaloneFolders']! as List).map((p) => norm('$p')), [norm(extra.path)]);
      expect(savedSettings()['binders'], hasLength(1));
    });

    test('a missing remembered folder is unavailable and stays listed', () async {
      var nb = make();
      await nb.load();
      final id = await nb.createPage(folderPath: extra.path);
      await nb.flush();
      nb.dispose();
      opened.clear();
      await extra.delete(recursive: true);

      nb = make();
      await nb.load();
      final f = nb.standaloneFolders.single;
      expect(f.available, isFalse);
      expect(nb.tree[id], isNull);
      await nb.createPage(); // saving the settings keeps the folder
      expect(savedSettings()['standaloneFolders'], hasLength(1));
      await expectLater(nb.createPage(folderPath: extra.path), throwsA(isA<NotebookException>()));

      await nb.removeStandaloneFolder(f.path);
      expect(nb.standaloneFolders, isEmpty);
      expect(savedSettings()['standaloneFolders'], isEmpty);
    });

    test('nesting across folders moves the files; the Pages header keeps a page in its folder', () async {
      final nb = make();
      await nb.load();
      final inDefault = nb.currentId!;
      final inExtra = await nb.createPage(folderPath: extra.path);
      final child = await nb.createPage(parentId: inExtra);
      expect(await nb.move(child, parentId: inDefault), isTrue);
      expect(File('${pages.path}/$child.canvas').existsSync(), isTrue);
      expect(File('${extra.path}/$child.canvas').existsSync(), isFalse);
      expect(await nb.move(child, parentId: inExtra), isTrue);
      expect(File('${extra.path}/$child.canvas').existsSync(), isTrue);

      // Dropping on the "Pages" header: a top-level page of its own folder.
      expect(await nb.moveToLocation(child), isTrue);
      expect(nb.tree.parentIdOf(child), isNull);
      expect(File('${extra.path}/$child.canvas').existsSync(), isTrue);
      expect(File('${pages.path}/$child.canvas').existsSync(), isFalse);
      // Dropping next to a page of the other folder moves it to that folder.
      expect(await nb.moveRelative(child, inDefault, after: false), isTrue);
      expect(File('${pages.path}/$child.canvas').existsSync(), isTrue);
      expect(File('${extra.path}/$child.canvas').existsSync(), isFalse);
    });

    test('a watcher sees a page file added to another folder', () async {
      final nb = make(watch: true);
      await nb.load();
      await nb.createPage(folderPath: extra.path);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await PageStore(extra).save(
        NotedPage.create(PageMeta.create(id: 'outside', title: 'Outside', order: 9)),
      );
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (nb.tree['outside'] == null) {
        if (DateTime.now().isAfter(end)) fail('the watcher did not report the new page');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(nb.binderOfPage('outside'), isNull);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('storage dialog', () {
    String? pickAnswer;
    late Notebook nb;

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      await tester.pumpAndSettle();
    }

    Future<void> start(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      pickAnswer = null;
      await tester.runAsync(() async {
        await setUpDirs();
        nb = make(pick: () async => pickAnswer);
        await nb.load();
      });
      await tester.pumpWidget(MaterialApp(home: Home(notebook: nb)));
      await tester.pump();
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      }
      await tester.runAsync(tearDownDirs);
    }

    Future<void> openDialog(WidgetTester tester) async {
      await tester.tap(find.byTooltip('New page'));
      await tester.pumpAndSettle();
      expect(find.text('Where should this page be stored?'), findsOneWidget);
    }

    testWidgets('Enter accepts the preselected default folder', (tester) async {
      await start(tester);
      final before = canvasFiles(pages).length;
      await openDialog(tester);
      expect(find.textContaining('Default ('), findsOneWidget);
      expect(find.textContaining(nb.defaultFolderPath), findsOneWidget);
      expect(find.text('Choose another folder…'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.text('Where should this page be stored?'), findsNothing);
      expect(canvasFiles(pages), hasLength(before + 1));
      expect(nb.standaloneFolders, isEmpty);
      await finish(tester);
    });

    testWidgets('Cancel creates nothing', (tester) async {
      await start(tester);
      final before = canvasFiles(pages).length;
      await openDialog(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(canvasFiles(pages), hasLength(before));
      expect(nb.tree.roots, hasLength(before));
      await finish(tester);
    });

    testWidgets('choosing another folder creates the page there and remembers it', (tester) async {
      await start(tester);
      pickAnswer = extra.path;
      await openDialog(tester);
      await tester.runAsync(() => tester.tap(find.text('Choose another folder…')));
      await settle(tester);
      // Selected now; Enter creates it.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      for (var i = 0; i < 60 && canvasFiles(extra).isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await settle(tester);
      expect(canvasFiles(extra), hasLength(1));
      expect(norm(nb.standaloneFolders.single.path), norm(extra.path));
      expect(savedSettings()['standaloneFolders'], hasLength(1));
      final id = File(canvasFiles(extra).single).uri.pathSegments.last.replaceAll('.canvas', '');
      expect(nb.currentId, id);

      // Next time the folder is offered, and the default is still preselected.
      await openDialog(tester);
      expect(find.text(nb.standaloneFolders.single.path), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(canvasFiles(extra), hasLength(1));
      expect(canvasFiles(pages), hasLength(2));
      await finish(tester);
    });

    testWidgets('a binder folder is refused with a message', (tester) async {
      await start(tester);
      await tester.runAsync(() => nb.addBinder(binderDir.path));
      await tester.pump();
      pickAnswer = binderDir.path;
      await openDialog(tester);
      await tester.runAsync(() => tester.tap(find.text('Choose another folder…')));
      await settle(tester);
      expect(find.byKey(const ValueKey('storage-error')), findsOneWidget);
      expect(nb.standaloneFolders, isEmpty);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(canvasFiles(binderDir), isEmpty);
      await finish(tester);
    });

    testWidgets('pages of another folder are listed in the Pages section', (tester) async {
      await start(tester);
      late String id;
      await tester.runAsync(() async {
        id = await nb.createPage(folderPath: extra.path);
        await nb.rename(id, 'Far away');
      });
      await tester.pump();
      expect(find.text('Far away'), findsWidgets);
      expect(find.byKey(ValueKey('page-row-$id')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a remembered folder that is missing is shown as unavailable', (tester) async {
      await start(tester);
      await tester.runAsync(() async {
        await nb.createPage(folderPath: extra.path);
        await nb.flush();
        nb.dispose();
        opened.clear();
        await extra.delete(recursive: true);
        nb = make(pick: () async => null);
        await nb.load();
      });
      await tester.pumpWidget(MaterialApp(home: Home(notebook: nb)));
      await tester.pump();
      expect(find.text('On another device'), findsOneWidget);
      expect(find.byKey(ValueKey('folder-header-${nb.standaloneFolders.single.path}')), findsOneWidget);
      await finish(tester);
    });
  });
}
