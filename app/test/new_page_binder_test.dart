// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

/// A store whose writes always fail, to test that a failed move keeps the
/// sources.
class _FailingStore extends PageStore {
  _FailingStore(super.directory);

  @override
  Future<void> save(NotedPage page) async {
    throw const FileSystemException('disk full');
  }
}

void main() {
  late Directory root;
  late Directory pages;
  late Directory extra;
  late File binders;
  late File settingsFile;
  late List<Notebook> opened;
  late List<AppSettings> openedSettings;
  late int picks;
  String? pickAnswer;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_newpage');
    pages = Directory('${root.path}/pages'); // not created: first run
    extra = await Directory('${root.path}/Elsewhere').create();
    binders = File('${root.path}/app/binders.json');
    settingsFile = File('${root.path}/app/settings.json');
    opened = [];
    openedSettings = [];
    picks = 0;
    pickAnswer = null;
  });

  // Idempotent: widget tests run it inside runAsync (see finish), because
  // real file IO cannot complete in the fake-async test zone.
  Future<void> cleanup() async {

    final all = [...opened];
    opened.clear();
    for (final nb in all) {
      await nb.flush();
      nb.dispose();
    }
    for (final s in openedSettings) {
      s.dispose();
    }

    openedSettings.clear();
    if (root.existsSync()) await root.delete(recursive: true);
  }

  tearDown(cleanup);

  AppSettings makeSettings() {
    final s = AppSettings(settingsFile);
    openedSettings.add(s);
    return s;
  }

  Notebook make({
    AppSettings? settings,
    PageStore Function(Directory)? factory,
    bool pick = true,
  }) {
    final nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: binders,
      settings: settings,
      storeFactory: factory ?? PageStore.new,
      pickFolder: pick
          ? () async {
              picks++;
              return pickAnswer;
            }
          : null,
    );
    opened.add(nb);
    return nb;
  }

  String norm(String p) => p.replaceAll(r'\', '/');

  List<String> canvasFiles(Directory d) => [
    for (final f in d.listSync())
      if (f is File && f.path.endsWith('.canvas')) f.path,
  ];

  Map<String, Object?> savedSettings() =>
      jsonDecode(settingsFile.readAsStringSync()) as Map<String, Object?>;

  Directory binderRoot() => Directory('${root.path}/app/binders');

  group('default page folder', () {
    test('first run never asks: the built-in folder is created and used', () async {
      final nb = make(settings: makeSettings());
      await nb.load();
      expect(picks, 0);
      expect(pages.existsSync(), isTrue);
      expect(canvasFiles(pages), hasLength(1));
      final id = await nb.createPage();
      expect(File('${pages.path}/$id.canvas').existsSync(), isTrue);
      expect(picks, 0);
      expect(settingsFile.existsSync(), isFalse, reason: 'nothing is written until a setting changes');
    });

    test('a changed default is saved, keeps unknown fields, and is used for new pages', () async {
      settingsFile.parent.createSync(recursive: true);
      settingsFile.writeAsStringSync('{"format":1,"theme":"dark","future":{"a":[1,2]}}');
      final settings = makeSettings();
      final nb = make(settings: settings);
      await nb.load();
      final first = nb.currentId!;
      expect(nb.newPageFolderPath, nb.defaultFolderPath);

      await nb.setDefaultPageFolder(extra.path);
      expect(norm(settings.defaultPageFolder!), norm(extra.path));
      final saved = savedSettings();
      expect(norm(saved['defaultPageFolder']! as String), norm(extra.path));
      expect(saved['theme'], 'dark');
      expect(saved['future'], {'a': [1, 2]});
      expect(saved.containsKey('defaultBinderFolder'), isFalse);

      // The folder is a standalone folder in use; the old default stays.
      expect(norm(nb.standaloneFolders.single.path), norm(extra.path));
      expect(nb.tree[first], isNotNull);
      final id = await nb.createPage();
      expect(File('${extra.path}/$id.canvas').existsSync(), isTrue);
      expect(canvasFiles(pages), hasLength(1));
      expect(nb.tree[id], isNotNull);

      // A subpage inherits its parent's location.
      final sub = await nb.createPage(parentId: first);
      expect(File('${pages.path}/$sub.canvas').existsSync(), isTrue);
      final sub2 = await nb.createPage(parentId: id);
      expect(File('${extra.path}/$sub2.canvas').existsSync(), isTrue);

      // A new session reads the setting, lists the pages there and uses it.
      await nb.flush();
      final again = make(settings: makeSettings());
      await again.load();
      expect(again.tree[id], isNotNull);
      expect(again.tree[first], isNotNull);
      final next = await again.createPage();
      expect(File('${extra.path}/$next.canvas').existsSync(), isTrue);
    });

    test('a default folder that holds a binder or is missing is refused', () async {
      final settings = makeSettings();
      final nb = make(settings: settings);
      await nb.load();
      final bin = await Directory('${root.path}/Work').create();
      await nb.addBinder(bin.path);
      await expectLater(nb.setDefaultPageFolder(bin.path), throwsA(isA<NotebookException>()));
      await expectLater(
        nb.setDefaultPageFolder('${root.path}/nowhere'),
        throwsA(isA<NotebookException>()),
      );
      expect(settings.defaultPageFolder, isNull);
      expect(Directory('${root.path}/nowhere').existsSync(), isFalse);
    });

    test('a chosen default that is gone is not recreated; new pages say so', () async {
      final settings = makeSettings();
      final nb = make(settings: settings);
      await nb.load();
      await nb.setDefaultPageFolder(extra.path);
      await nb.flush();
      extra.deleteSync(recursive: true);

      final again = make(settings: makeSettings());
      await again.load(); // still opens, with the built-in folder's page
      expect(extra.existsSync(), isFalse);
      expect(again.standaloneFolders.single.available, isFalse);
      await expectLater(again.createPage(), throwsA(isA<NotebookException>()));
      expect(extra.existsSync(), isFalse);
    });

    test('an empty notebook whose default is gone gets its first page in the built-in folder', () async {
      final settings = makeSettings();
      settings.defaultPageFolder = '${root.path}/gone';
      final nb = make(settings: settings);
      await nb.load();
      expect(canvasFiles(pages), hasLength(1));
      expect(Directory('${root.path}/gone').existsSync(), isFalse);
    });
  });

  group('move to folder', () {
    test('moves the page and its subpages, verified, and the sources are gone', () async {
      final settings = makeSettings();
      final nb = make(settings: settings);
      await nb.load();
      final a = nb.currentId!;
      final b = await nb.createPage(parentId: a);
      final c = await nb.createPage(parentId: b);
      final other = await nb.createPage();
      await nb.flush();
      final before = {for (final id in [a, b, c]) id: File('${pages.path}/$id.canvas').readAsStringSync()};

      expect(await nb.moveToFolder(a, extra.path), isTrue);
      await nb.flush();
      for (final id in [a, b, c]) {
        expect(File('${pages.path}/$id.canvas').existsSync(), isFalse, reason: 'source of $id');
        expect(File('${extra.path}/$id.canvas').existsSync(), isTrue, reason: 'copy of $id');
      }
      // Only the moved page's own header changed (its order in the new folder).
      expect(
        File('${extra.path}/$b.canvas').readAsStringSync(),
        before[b],
      );
      expect(File('${pages.path}/$other.canvas').existsSync(), isTrue);
      expect(norm(nb.standaloneFolders.single.path), norm(extra.path));
      expect(nb.tree.childrenOf(a).single.id, b);
      expect(nb.tree.childrenOf(b).single.id, c);
      // Moving it to the folder it is in does nothing.
      expect(await nb.moveToFolder(a, extra.path), isFalse);
      // And back to the default folder.
      expect(await nb.moveToFolder(a, pages.path), isTrue);
      expect(File('${pages.path}/$c.canvas').existsSync(), isTrue);
      expect(File('${extra.path}/$c.canvas').existsSync(), isFalse);
    });

    test('a binder folder is refused', () async {
      final nb = make(settings: makeSettings());
      await nb.load();
      final bin = await Directory('${root.path}/Work').create();
      await nb.addBinder(bin.path);
      final a = nb.currentId!;
      await expectLater(nb.moveToFolder(a, bin.path), throwsA(isA<NotebookException>()));
      expect(File('${pages.path}/$a.canvas').existsSync(), isTrue);
      expect(canvasFiles(bin), isEmpty);
    });

    test('a failed move keeps the sources and leaves nothing in the target', () async {
      final nb = make(
        settings: makeSettings(),
        factory: (d) => norm(d.path) == norm(extra.path) ? _FailingStore(d) : PageStore(d),
      );
      await nb.load();
      final a = nb.currentId!;
      final b = await nb.createPage(parentId: a);
      await nb.flush();
      await expectLater(nb.moveToFolder(a, extra.path), throwsA(isA<NotebookException>()));
      expect(File('${pages.path}/$a.canvas').existsSync(), isTrue);
      expect(File('${pages.path}/$b.canvas').existsSync(), isTrue);
      expect(canvasFiles(extra), isEmpty);
      expect(nb.tree[a], isNotNull);
      expect(nb.currentId, b); // the open page is still open
    });
  });

  group('new binder', () {
    test('is created at once in a subfolder of the default binder folder, with its cover open', () async {
      final nb = make(settings: makeSettings());
      await nb.load();
      expect(binderRoot().existsSync(), isFalse);
      final s = await nb.createBinder();
      expect(picks, 0);
      expect(s.available, isTrue);
      expect(norm(s.path), norm('${binderRoot().path}/New binder'));
      expect(File('${s.path}/$binderFileName').existsSync(), isTrue);
      expect(s.binder!.title, 'New binder');
      expect(nb.coverPath, s.path);
      expect(nb.takeTitleFocus('cover:${s.path}'), isTrue);
      expect(nb.takeTitleFocus('cover:${s.path}'), isFalse, reason: 'asked once');
      expect(nb.binders, hasLength(1));
    });

    test('a name that is taken gets a number', () async {
      final nb = make(settings: makeSettings());
      await nb.load();
      final a = await nb.createBinder();
      final b = await nb.createBinder();
      final c = await nb.createBinder();
      expect([a, b, c].map((s) => s.path.split(RegExp(r'[\\/]')).last), [
        'New binder',
        'New binder 2',
        'New binder 3',
      ]);
      // A plain file or folder in the way counts too.
      Directory('${binderRoot().path}/New binder 4').createSync();
      final d = await nb.createBinder();
      expect(d.path.split(RegExp(r'[\\/]')).last, 'New binder 5');
    });

    test('characters invalid in file names are replaced', () {
      expect(binderFolderName(r'a:b/c\d*e?f"g<h>i|j'), 'a_b_c_d_e_f_g_h_i_j');
      expect(binderFolderName('  Plans...  '), 'Plans');
      expect(binderFolderName('con'), 'con_');
      expect(binderFolderName('Lpt1.txt'), 'Lpt1.txt_');
      expect(binderFolderName('   '), 'New binder');
      expect(binderFolderName('...'), 'New binder');
    });

    test('a created binder uses the sanitized name for its folder', () async {
      final nb = make(settings: makeSettings());
      await nb.load();
      final s = await nb.createBinder(name: 'Q1: plans?');
      expect(s.path.split(RegExp(r'[\\/]')).last, 'Q1_ plans_');
    });

    test('uses the chosen default binder folder, which is never created', () async {
      final settings = makeSettings();
      final nb = make(settings: settings);
      await nb.load();
      final mine = await Directory('${root.path}/MyBinders').create();
      await nb.setDefaultBinderFolder(mine.path);
      expect(norm(savedSettings()['defaultBinderFolder']! as String), norm(mine.path));
      final s = await nb.createBinder();
      expect(norm(s.path), norm('${mine.path}/New binder'));
      expect(binderRoot().existsSync(), isFalse);

      mine.deleteSync(recursive: true);
      await expectLater(nb.createBinder(), throwsA(isA<NotebookException>()));
      expect(mine.existsSync(), isFalse);
    });

    test('New binder in another folder and Open binder keep their pickers', () async {
      final nb = make(settings: makeSettings());
      await nb.load();
      expect(await nb.newBinderInFolder(), isNull, reason: 'cancelled');
      expect(await nb.openBinder(), isNull);
      expect(picks, 2);
      pickAnswer = extra.path;
      await expectLater(nb.openBinder(), throwsA(isA<NotebookException>()));
      expect(File('${extra.path}/$binderFileName').existsSync(), isFalse);
      final s = await nb.newBinderInFolder();
      expect(norm(s!.path), norm(extra.path));
      expect(nb.coverPath, s.path);
    });
  });

  group('screen', () {
    late Notebook nb;
    late AppSettings settings;

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      }
    }

    Future<void> until(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      }
      await settle(tester);
    }

    Future<void> start(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        settings = makeSettings();
        nb = make(settings: settings);
        await nb.load();
      });
      await tester.pumpWidget(MaterialApp(home: Home(notebook: nb, settings: settings)));
      await tester.pump();
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      // Saves started from the widgets hop between the test clock and real IO.
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      }
      await tester.runAsync(cleanup);
    }

    bool titleFocused(WidgetTester tester) {
      final f = find.byKey(const ValueKey('page-title-field'));
      return f.evaluate().isNotEmpty && tester.widget<TextField>(f).focusNode!.hasFocus;
    }

    Future<void> ctrlN(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }

    testWidgets('+ creates the page at once in the default folder and focuses its title', (
      tester,
    ) async {
      await start(tester);
      final before = nb.tree.roots.length;
      await tester.runAsync(() => tester.tap(find.byTooltip('New page')));
      await until(tester, () => nb.tree.roots.length > before);
      expect(find.byType(AlertDialog), findsNothing);
      expect(canvasFiles(pages), hasLength(before + 1));
      expect(titleFocused(tester), isTrue);

      // Typing renames the page; Enter commits.
      await tester.enterText(find.byKey(const ValueKey('page-title-field')), 'Fresh idea');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await until(tester, () => nb.tree[nb.currentId!]!.title == 'Fresh idea');
      expect(nb.tree[nb.currentId!]!.title, 'Fresh idea');
      await finish(tester);
    });

    testWidgets('the Pages menu item shows Ctrl+N and creates the page at once', (tester) async {
      await start(tester);
      final before = nb.tree.roots.length;
      await tester.tap(find.byKey(const ValueKey('pages-menu')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('Ctrl+N'), findsOneWidget);
      await tester.runAsync(() => tester.tap(find.text('New page').last));
      await until(tester, () => nb.tree.roots.length > before);
      expect(find.byType(AlertDialog), findsNothing);
      expect(titleFocused(tester), isTrue);
      await finish(tester);
    });

    testWidgets('Ctrl+N with the canvas focused creates a page and focuses its title', (
      tester,
    ) async {
      await start(tester);
      final before = nb.tree.roots.length;
      await ctrlN(tester);
      await until(tester, () => nb.tree.roots.length > before);
      expect(canvasFiles(pages), hasLength(before + 1));
      expect(titleFocused(tester), isTrue);
      await finish(tester);
    });

    testWidgets('Ctrl+N works while a note editor has focus', (tester) async {
      await start(tester);
      // A click on the empty canvas makes a note box with its editor focused.
      await tester.tapAt(const Offset(700, 400));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(nb.current!.editingId, isNotNull);
      final before = nb.tree.roots.length;
      await ctrlN(tester);
      await until(tester, () => nb.tree.roots.length > before);
      expect(nb.tree.roots.length, before + 1);
      expect(titleFocused(tester), isTrue);
      await finish(tester);
    });

    testWidgets('a new subpage lands in its parent\'s folder', (tester) async {
      await start(tester);
      await tester.runAsync(() => nb.setDefaultPageFolder(extra.path));
      final parent = nb.currentId!; // in the built-in folder
      await tester.runAsync(() => nb.createPage(parentId: parent));
      expect(canvasFiles(pages), hasLength(2));
      expect(canvasFiles(extra), isEmpty);
      await finish(tester);
    });

    testWidgets('New binder (+ in the header) creates it at once and focuses the cover title', (
      tester,
    ) async {
      await start(tester);
      await tester.runAsync(() => tester.tap(find.byTooltip('New binder')));
      await until(tester, () => nb.binders.isNotEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      expect(picks, 0);
      expect(find.text('Binder cover'), findsOneWidget);
      expect(norm(nb.binders.single.path), norm('${binderRoot().path}/New binder'));
      final title = tester.widget<TextField>(find.byKey(const ValueKey('cover-title')));
      expect(title.focusNode!.hasFocus, isTrue);
      expect(title.controller!.text, 'New binder');
      await finish(tester);
    });

    testWidgets('the Pages menu offers New binder, in another folder, and Open binder', (
      tester,
    ) async {
      await start(tester);
      await tester.tap(find.byKey(const ValueKey('pages-menu')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('New binder'), findsOneWidget);
      expect(find.text('New binder in another folder…'), findsOneWidget);
      expect(find.text('Open binder…'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the gear shows both default folders and changes them with the picker', (
      tester,
    ) async {
      await start(tester);
      await tester.tap(find.byKey(const ValueKey('settings-menu')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('Default page folder'), findsOneWidget);
      expect(find.text(nb.defaultFolderPath), findsOneWidget);
      expect(find.text(nb.builtinBinderFolderPath), findsOneWidget);

      pickAnswer = extra.path;
      await tester.runAsync(() => tester.tap(find.byKey(const ValueKey('settings-default-page-folder'))));
      await until(tester, () => settings.defaultPageFolder != null);
      expect(norm(savedSettings()['defaultPageFolder']! as String), norm(extra.path));
      expect(picks, 1);

      final before = canvasFiles(extra).length;
      await tester.runAsync(() => tester.tap(find.byTooltip('New page')));
      await until(tester, () => canvasFiles(extra).length > before);
      expect(canvasFiles(extra), hasLength(before + 1));

      // The binder folder, the same way.
      final mine = await tester.runAsync(() => Directory('${root.path}/MyBinders').create());
      pickAnswer = mine!.path;
      await tester.tap(find.byKey(const ValueKey('settings-menu')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text(nb.newPageFolderPath), findsOneWidget); // the new default
      await tester.runAsync(() => tester.tap(find.byKey(const ValueKey('settings-default-binder-folder'))));
      await until(tester, () => settings.defaultBinderFolder != null);
      expect(norm(savedSettings()['defaultBinderFolder']! as String), norm(mine.path));
      await tester.runAsync(() => tester.tap(find.byTooltip('New binder')));
      await until(tester, () => nb.binders.isNotEmpty);
      expect(norm(nb.binders.single.path), norm('${mine.path}/New binder'));
      await finish(tester);
    });
  });
}
