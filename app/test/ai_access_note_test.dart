// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/ai_access_note.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory root;
  late PageStore store;
  late Notebook nb;
  late AppSettings settings;
  late String parent;
  late String lost;
  late String stillOpen;

  Notebook open() => Notebook(
    store,
    buildModules(),
    saveDelay: Duration.zero,
    bindersFile: File('${root.path}/app/binders.json'),
  );

  // Writes the legacy "page" value as an older version did.
  Future<void> writeLegacy(String id) async {
    final page = await store.load(id);
    final meta = PageMeta.tryRead(
      page.meta.fields.set(aiAccessKey, RawJson.encode('page')),
    )!;
    await store.save(page.withMeta(meta));
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_ai_note');
    store = PageStore(await Directory('${root.path}/pages').create());
    final first = open();
    await first.load();
    parent = first.currentId!;
    lost = await first.createPage(parentId: parent);
    stillOpen = await first.createPage();
    await first.setAiAccess(parent, AiAccess.privileged);
    await first.flush();
    first.dispose();
    await writeLegacy(lost);
    await writeLegacy(stillOpen);
    nb = open();
    await nb.load();
    settings = AppSettings(File('${root.path}/settings.json'));
  });

  tearDown(() async {
    await nb.flush();
    nb.dispose();
    settings.dispose();
    await root.delete(recursive: true);
  });

  Future<void> pumpHost(WidgetTester t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('go'),
            onPressed: () => showAiAccessNoteIfNeeded(context, nb, settings),
            child: const Text('go'),
          ),
        ),
      ),
    );
  }

  test('lists the pages stored as "page" that inheritance now keeps from being Open', () {
    expect(nb.pagesThatLostAiAccess(), [lost]);
    expect(nb.aiAccessFor(lost).value, AiAccess.privileged);
    expect(nb.aiAccessFor(stillOpen).value, AiAccess.open);
  });

  testWidgets(
    'shown once, with a button that opens the page settings, and remembered',
    (t) async {
      await pumpHost(t);
      await t.tap(find.byKey(const ValueKey('go')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-access-note')), findsOneWidget);
      expect(find.byKey(ValueKey('ai-access-note-$lost')), findsOneWidget);
      expect(find.byKey(ValueKey('ai-access-note-$stillOpen')), findsNothing);
      expect(settings.aiAccessNoteShown, isTrue);

      await t.tap(find.byKey(ValueKey('ai-access-note-open-$lost')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-panel')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('settings-close')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ai-access-note-close')));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const ValueKey('go')));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ai-access-note')),
        findsNothing,
        reason: 'only once',
      );
    },
  );

  testWidgets('Home shows it once after the notebook has loaded', (t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: Home(notebook: nb, settings: settings),
      ),
    );
    // The notebook's load future belongs to the real zone: let it call back.
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-access-note')), findsOneWidget);
    expect(settings.aiAccessNoteShown, isTrue);
  });

  testWidgets('the rows follow changes to the pages', (t) async {
    await pumpHost(t);
    await t.tap(find.byKey(const ValueKey('go')));
    await t.pumpAndSettle();
    expect(find.textContaining('Privileged'), findsWidgets);
    await t.runAsync(() => nb.setAiAccess(lost, AiAccess.guarded));
    await t.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(ValueKey('ai-access-note-$lost')),
        matching: find.textContaining('Guarded'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'an unreadable settings file is neither replaced nor does it show the note',
    (t) async {
      settings.dispose();
      final file = File('${root.path}/settings.json');
      file.writeAsStringSync('{ this is not json');
      settings = AppSettings(file);
      await pumpHost(t);
      await t.tap(find.byKey(const ValueKey('go')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-access-note')), findsNothing);
      expect(file.readAsStringSync(), '{ this is not json');
      settings.aiAccessNoteShown = true;
      expect(
        file.readAsStringSync(),
        '{ this is not json',
        reason: 'the note never writes over it',
      );
    },
  );

  testWidgets(
    'not shown while a binder or folder is not readable; shown once all is',
    (t) async {
      // A binder whose folder is gone: its pages are not listed as a basis.
      final gone = Directory('${root.path}/Away');
      final away = Directory('${root.path}/Elsewhere');
      await t.runAsync(() async {
        await gone.create();
        await nb.addBinder(gone.path);
        await gone.rename(away.path);
        await nb.load();
      });
      expect(nb.everythingReadable, isFalse);
      await pumpHost(t);
      await t.tap(find.byKey(const ValueKey('go')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-access-note')), findsNothing);
      expect(settings.aiAccessNoteShown, isFalse);

      await t.runAsync(() async {
        await away.rename(gone.path);
        await nb.load();
      });
      expect(nb.everythingReadable, isTrue);
      await t.tap(find.byKey(const ValueKey('go')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-access-note')), findsOneWidget);
    },
  );

  testWidgets('not shown when no page lost access', (t) async {
    await t.runAsync(() => nb.setAiAccess(parent, AiAccess.open));
    expect(nb.pagesThatLostAiAccess(), isEmpty);
    await pumpHost(t);
    await t.tap(find.byKey(const ValueKey('go')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-access-note')), findsNothing);
    expect(
      settings.aiAccessNoteShown,
      isFalse,
      reason: 'it can still appear later',
    );
  });
}
