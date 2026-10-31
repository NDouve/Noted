// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/binder_cover.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';
import 'support/real_io.dart';

void main() {
  late Directory root;
  late Directory pages;
  late Directory folder;
  late Notebook nb;
  late BinderSection section;
  late String inBinder;
  late String standalone;

  File binderFile() => File('${folder.path}${Platform.pathSeparator}$binderFileName');

  Future<void> start({bool watch = false}) async {
    root = await Directory.systemTemp.createTemp('noted_binder_watch');
    pages = await Directory('${root.path}/pages').create();
    folder = await Directory('${root.path}/Work').create();
    nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/binders.json'),
      watchFiles: watch,
      watchDebounce: const Duration(milliseconds: 50),
    );
    await nb.load();
    standalone = nb.currentId!;
    section = await nb.addBinder(folder.path);
    inBinder = await nb.createPage(binderPath: section.path);
  }

  Future<void> stop() async {
    await nb.flush();
    nb.dispose();
    await root.delete(recursive: true);
  }

  /// Another machine edits the cover.
  Future<void> externalCover({String? title, String? description, String? owner, String? color}) async {
    var b = (await BinderStore(folder).read() as BinderFound).binder;
    if (title != null) b = b.withTitle(title);
    if (description != null) b = b.withDescription(description);
    if (owner != null) b = b.withOwner(owner);
    if (color != null) b = b.withColor(color);
    await BinderStore(folder).save(b);
  }

  group('binder file changes', () {
    test('a cover edit made elsewhere updates the section and notifies', () async {
      await start();
      var notified = 0;
      nb.addListener(() => notified++);
      await externalCover(title: 'Renamed', owner: 'Sam', color: binderPalette[3]);
      await nb.checkBinderFile(binderFile().path);
      expect(section.title, 'Renamed');
      expect(section.binder!.owner, 'Sam');
      expect(section.color, binderPalette[3]);
      expect(section.available, isTrue);
      expect(notified, greaterThan(0));
      // The pages are still there.
      expect(nb.currentId, inBinder);
      expect(section.tree[inBinder], isNotNull);
      await stop();
    });

    test('fields this build does not know are taken from the file as they are', () async {
      await start();
      final text = binderFile().readAsStringSync();
      final withExtra = text.replaceFirst('{', '{"future":{"a":[1,2]},');
      await binderFile().writeAsString(withExtra);
      await nb.checkBinderFile(binderFile().path);
      expect(section.binder!.fields['future']!.text, '{"a":[1,2]}');
      await stop();
    });

    test('the app\'s own write is not taken for an outside change', () async {
      await start();
      await nb.updateBinder(section.path, title: 'Mine');
      final before = section.binder;
      var notified = 0;
      nb.addListener(() => notified++);
      await nb.checkBinderFile(binderFile().path);
      expect(identical(section.binder, before), isTrue);
      expect(notified, 0);
      await stop();
    });

    test('a damaged file marks the binder cannot-open and is not overwritten', () async {
      await start();
      await binderFile().writeAsString('{ not json');
      await nb.checkBinderFile(binderFile().path);
      expect(section.status, BinderStatus.unreadable);
      expect(section.binder, isNull);
      // Its pages stay listed, read-only; the open page stays open.
      expect(section.tree[inBinder], isNotNull);
      expect(nb.isReadOnlyPage(inBinder), isTrue);
      expect(nb.currentId, inBinder);
      expect(nb.current!.readOnly, isTrue);
      await nb.updateBinder(section.path, title: 'Nope');
      await nb.flush();
      expect(binderFile().readAsStringSync(), '{ not json');
      await stop();
    });

    test('a file from a newer format marks the binder cannot-open', () async {
      await start();
      final text = binderFile().readAsStringSync().replaceFirst('"format": 1', '"format": 99');
      final newer = text == binderFile().readAsStringSync()
          ? binderFile().readAsStringSync().replaceFirst('"format":1', '"format":99')
          : text;
      expect(newer, contains('99'));
      await binderFile().writeAsString(newer);
      await nb.checkBinderFile(binderFile().path);
      expect(section.status, BinderStatus.unreadable);
      expect(section.reason, contains('99'));
      expect(binderFile().readAsStringSync(), newer);
      // Fixing the file brings the binder and its pages back.
      await binderFile().writeAsString(
        Binder.create(title: 'Back', color: binderPalette.first).write(),
      );
      final fixed = binderFile().readAsStringSync();
      expect(fixed, isNot(contains('"format":99')));
      await nb.checkBinderFile(binderFile().path);
      final again = nb.binders.single;
      expect(again.status, BinderStatus.available);
      expect(again.title, 'Back');
      expect(again.tree[inBinder], isNotNull);
      await stop();
    });

    test('a deleted file makes the binder unavailable, as at startup', () async {
      await start();
      nb.showCover(section.path);
      expect(nb.coverPath, section.path);
      await binderFile().delete();
      await nb.checkBinderFile(binderFile().path);
      expect(section.status, BinderStatus.unavailable);
      expect(nb.coverPath, isNull);
      expect(nb.tree[inBinder], isNull);
      expect(nb.currentId, standalone);
      // The page file itself was not touched.
      expect(File('${folder.path}/$inBinder.canvas').existsSync(), isTrue);
      expect(binderFile().existsSync(), isFalse);
      // It stays in the list, and comes back when the file does.
      expect(nb.binders, hasLength(1));
      await binderFile().writeAsString(
        Binder.create(title: 'Restored', color: binderPalette.first).write(),
      );
      await nb.checkBinderFile(binderFile().path);
      expect(nb.binders.single.status, BinderStatus.available);
      expect(nb.binders.single.title, 'Restored');
      expect(nb.tree.roots.length, 1);
      expect(nb.binders.single.tree[inBinder], isNotNull);
      await stop();
    });

    test('an open page of the binder is saved before the binder goes away', () async {
      await start();
      final c = nb.current!;
      final box = c.createBoxAt(const Bounds(10, 10, 0, 0));
      c.commit(box.id, buildModules().codecs.codecFor('noted.note')!.decode({
        'document': {
          'type': 'page',
          'children': [
            {
              'type': 'paragraph',
              'data': {
                'delta': [
                  {'insert': 'unsaved'},
                ],
              },
            },
          ],
        },
      }, 1));
      await binderFile().delete();
      await nb.checkBinderFile(binderFile().path);
      final saved = readPage(File('${folder.path}/$inBinder.canvas').readAsStringSync());
      expect(saved.node(box.id), isNotNull);
      await stop();
    });

    test('a watcher notices a changed binder file', () async {
      await start(watch: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await externalCover(title: 'Via watcher');
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (section.title != 'Via watcher') {
        if (DateTime.now().isAfter(end)) fail('the watcher did not report the change in time');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      // And the app's own write does not come back.
      await nb.updateBinder(section.path, owner: 'Me');
      final before = section.binder;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(identical(section.binder, before), isTrue);
      await stop();
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('cover', () {
    Future<void> showCover(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(start);
      nb.showCover(section.path);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BinderCover(notebook: nb, path: section.path)),
        ),
      );
      await tester.pump();
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => realIoPause(30));
      }
      await tester.runAsync(() async {
        await stop();
      });
    }

    String textOf(WidgetTester tester, String key) =>
        tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

    testWidgets('an outside edit shows in the cover', (tester) async {
      await showCover(tester);
      await tester.runAsync(() async {
        await externalCover(title: 'Elsewhere', description: 'New text', color: binderPalette[4]);
        await nb.checkBinderFile(binderFile().path);
      });
      await tester.pump();
      expect(textOf(tester, 'cover-title'), 'Elsewhere');
      expect(textOf(tester, 'cover-description'), 'New text');
      await finish(tester);
    });

    testWidgets('a field being edited keeps its text; the other fields update', (tester) async {
      await showCover(tester);
      await tester.tap(find.byKey(const ValueKey('cover-title')));
      await tester.enterText(find.byKey(const ValueKey('cover-title')), 'My draft title');
      await tester.pump();
      await tester.runAsync(() async {
        await externalCover(title: 'Their title', owner: 'Their owner');
        await nb.checkBinderFile(binderFile().path);
      });
      await tester.pump();
      expect(textOf(tester, 'cover-title'), 'My draft title');
      expect(textOf(tester, 'cover-owner'), 'Their owner');
      expect(section.binder!.title, 'Their title'); // the model has the file's value

      // Leaving the field saves the user's text.
      await tester.tap(find.byKey(const ValueKey('cover-owner')));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => realIoPause(50));
      }
      final saved = (await tester.runAsync(() => BinderStore(folder).read()))! as BinderFound;
      expect(saved.binder.title, 'My draft title');
      expect(saved.binder.owner, 'Their owner');
      await finish(tester);
    });
  });
}
