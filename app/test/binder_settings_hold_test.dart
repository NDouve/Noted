// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A binder list that can't be read is held (see Notebook.retrySettings): the
// open page that can't be left stops the adoption, and the app shows the
// refusal and re-reads the list when it resumes.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'support/real_io.dart';
import 'support/settle_saves.dart';
import 'support/trouble_world.dart';

// A notebook that counts the retries the app asks for.
class _CountingNotebook extends Notebook {
  _CountingNotebook(super.store, super.modules);

  int retries = 0;

  @override
  Future<bool> retrySettings() {
    retries++;
    return Future.value(false);
  }
}

void main() {
  const id = 'a000000000000001';
  const stoppedNote =
      'Noted can read its binder list, but the open page cannot be saved yet, so binders and extra page '
      'folders stay hidden. They will appear once the open page saves or another page is opened.';

  group('13: a page that can\'t be left stops the adoption', () {
    late TroubleWorld w;
    late Directory c;
    late Notebook nb;
    late String pageId;
    late List<int> before;
    var locked = true;
    var reads = 0;
    var asked = 0;

    List<String> heldNotes() => [
      for (final n in nb.discoveryNotes)
        if (n.path.endsWith('binders.json')) n.reason,
    ];

    setUp(() async {
      w = TroubleWorld();
      await w.init();
      c = w.other; // the chosen default page folder
      w.settings.parent.createSync(recursive: true);
      w.settings.writeAsStringSync(
        jsonEncode({
          'format': 1,
          'binders': [c.path],
          'binderIds': {c.path: id},
        }),
      );
      before = w.settings.readAsBytesSync();
      locked = true;
      reads = 0;
      asked = 0;
      nb = w.make(
        appSettings: AppSettings(null)..defaultPageFolder = c.path,
        backoffFirst: const Duration(milliseconds: 20),
        backoffMax: const Duration(milliseconds: 20),
      );
      nb.binderHook = (point, path) async {
        if (point != 'settings-read') return;
        reads++;
        if (locked) throw FileSystemException('locked by another program', path);
      };
      nb.questioner = (q, t) async {
        asked++;
        return true;
      };
      await nb.load();
      pageId = nb.currentId!;
      await nb.flush();
      // The folder is a binder, as the list says; the list can't be read to say so.
      await BinderStore(c).create(Binder.create(title: 'C', id: id, color: binderPalette.first));
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      await w.rec.parent.create(recursive: true);
      File(w.rec.path).writeAsStringSync('in the way');
      w.storeFor(c).failWith = accessDenied();
      await nb.flush();
      locked = false;
    });

    tearDown(() => w.dispose());

    Future<void> allowSaves() async {
      w.storeFor(c).failWith = null;
      File(w.rec.path).deleteSync();
      await until(() => !nb.trouble.isTrouble, what: 'the page to save');
    }

    test('nothing is asked or changed, no retry runs meanwhile, and the next one keeps the page', () async {
      expect(reads, 1);
      expect(await nb.retrySettings(), isFalse);
      expect(reads, 2, reason: 'the retry read the list');
      expect(nb.leaveAttemptsForTest, 1);
      expect(asked, 0, reason: 'the stop asks nothing');
      expect(nb.settingsHoldForTest, 'locked');
      expect(nb.binders, isEmpty);
      expect(nb.standaloneFolders.single.path, c.absolute.path);
      expect(w.settings.readAsBytesSync(), before);
      expect(heldNotes(), [stoppedNote]);
      // The same page is still current and its last save failed: no retry runs, from
      // any trigger, until it saves or another page is opened.
      expect(await nb.retrySettings(), isFalse);
      await expectLater(nb.createBinder(), throwsA(isA<NotebookException>()));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(nb.leaveAttemptsForTest, 1);
      expect(reads, 2, reason: 'no read while the page stays unsaved');
      // The page saves: the next retry adopts the list.
      await allowSaves();
      await nb.flush();
      expect(await nb.retrySettings(), isTrue);
      expect(reads, 3);
      expect(nb.leaveAttemptsForTest, 2);
      expect(asked, 0);
      expect(nb.binders.single.path, c.absolute.path);
      expect(nb.standaloneFolders, isEmpty);
      expect(heldNotes(), isEmpty);
      expect(nb.currentId, pageId, reason: 'the page the user was on is open again');
      nb.current!.createBoxAt(const Bounds(60, 60, 0, 0));
      await nb.flush();
      expect((await PageStore(c).load(pageId)).nodes.whereType<BoxRecord>(), hasLength(2));
    });

    test('a page that is gone after the adoption gives a fallback page', () async {
      expect(await nb.retrySettings(), isFalse);
      await allowSaves();
      await nb.flush();
      File('${c.path}/$pageId.canvas').deleteSync();
      expect(await nb.retrySettings(), isTrue);
      expect(nb.currentId, isNotNull);
      expect(nb.currentId, isNot(pageId));
      expect(nb.binders.single.path, c.absolute.path);
    });
  });

  group('widgets', () {
    late Directory root;
    late Notebook nb;

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => realIoPause(30));
      }
      await settleSaves(tester, nb);
      await tester.runAsync(() async {
        nb.dispose();
        await root.delete(recursive: true);
      });
    }

    testWidgets('10: coming back to the app asks for one retry of the binder list', (tester) async {
      late _CountingNotebook counting;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('noted_hold_ui');
        counting = _CountingNotebook(PageStore(Directory('${root.path}/pages')..createSync()), buildModules());
        nb = counting;
        await nb.load();
      });
      await tester.pumpWidget(NotedApp(notebook: counting, settings: AppSettings(null)));
      await tester.pump();
      expect(counting.retries, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(counting.retries, 1);
      await finish(tester);
    });

    testWidgets('Remove from sidebar while the list is held shows the refusal as a message', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late String b1;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('noted_hold_ui');
        final dir = await Directory('${root.path}/B1').create();
        await BinderStore(dir).create(Binder.create(title: 'Work', id: id, color: binderPalette.first));
        b1 = dir.path;
        final file = File('${root.path}/binders.json')
          ..writeAsStringSync(
            jsonEncode({
              'format': 1,
              'binders': [b1, '${root.path}/B2'],
              'binderIds': {b1: id},
            }),
          );
        nb = Notebook(
          PageStore(Directory('${root.path}/pages')..createSync()),
          buildModules(),
          saveDelay: Duration.zero,
          bindersFile: file,
        );
        // Load stops after B1 is open: the list stays held with B1 listed.
        nb.binderHook = (point, path) async {
          if (point == 'load-open' && path.endsWith('B2')) throw StateError('stop');
        };
        await expectLater(nb.load(), throwsA(isA<StateError>()));
        await nb.createPage(); // a page on screen, so the sidebar settles
      });
      expect(nb.settingsHoldForTest, 'locked');
      expect(nb.binders.map((b) => b.path), [b1]);
      await tester.pumpWidget(MaterialApp(home: Home(notebook: nb)));
      await tester.pump();
      await tester.runAsync(() => tester.tap(find.byKey(ValueKey('binder-menu-$b1'))));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('Remove from sidebar')));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('Remove')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        await tester.runAsync(() => realIoPause(30));
      }
      expect(find.text("Noted can't read its binder list right now. Try again in a moment."), findsOneWidget);
      expect(nb.binders.map((b) => b.path), contains(b1), reason: 'refused');
      await finish(tester);
    });
  });
}
