// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The kept-edits notice of a held folder in the window: it comes down when the
// edit lands, and never takes another snackbar with it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'support/real_io.dart';
import 'support/notebook_folder.dart';

void main() {
  final sep = Platform.pathSeparator;
  late Directory root;
  late Directory folder;
  late Notebook nb;
  late String pageId;
  late String original;
  late Future<void> Function() land;

  File binderFile() => File('${folder.path}$sep$binderFileName');

  Future<void> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('noted_kept_home');
      final pages = await Directory('${root.path}${sep}pages').create();
      folder = await Directory('${root.path}${sep}Work').create();
      nb = Notebook(
        PageStore(pages),
        buildModules(),
        saveDelay: const Duration(minutes: 10),
        bindersFile: File('${root.path}${sep}binders.json'),
        recoveryDirectory: Directory('${root.path}${sep}recovery'),
        binderRecheckDelay: const Duration(milliseconds: 300),
        backoffFirst: const Duration(milliseconds: 100),
        backoffMax: const Duration(milliseconds: 200),
      );
      nb.questioner = (q, t) async => true;
      await nb.load();
      final s = await nb.addBinder(folder.path);
      pageId = await nb.createPage(binderPath: s.path);
      await nb.flush();
      original = binderFile().readAsStringSync();
    });
    await tester.pumpWidget(MaterialApp(home: Home(notebook: nb)));
    await tester.pump();
    await tester.runAsync(() async {
      nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      binderFile().writeAsStringSync(Binder.create(title: 'Other', color: binderPalette[2]).write());
      await nb.checkBinderFile(binderFile().path);
    });
    await tester.pump();
    land = () async {
      await tester.runAsync(() async {
        binderFile().writeAsStringSync(original);
        await nb.checkBinderFile(binderFile().path);
        await nb.flush();
        await realIoUntil(() => nb.recoveryStoreForTest!.indexEntries.isEmpty, 'the kept edits to land');
        await realIoPause(50);
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    };
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await nb.flush();
      nb.dispose();
      await deleteTestFolder(root);
    });
  }

  testWidgets('the kept notice shows, and is gone once the edit lands', (tester) async {
    await start(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('kept-notice')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('kept-notice')),
        matching: find.textContaining('saved in this folder if you choose Use this binder'),
      ),
      findsOneWidget,
    );
    await land();
    expect(find.byKey(const ValueKey('kept-notice')), findsNothing);
    expect(pageId, isNotEmpty);
    await finish(tester);
  });

  testWidgets('an edit that lands while the notice is still sliding in takes it down once it shows', (tester) async {
    await start(tester);
    // No pump for the slide-in: the notice is not visible yet.
    await land();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('kept-notice')), findsNothing);
    await finish(tester);
  });

  testWidgets('another snackbar that replaced the notice stays when the edit lands', (tester) async {
    await start(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('kept-notice')), findsOneWidget);
    final messenger = ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first));
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(const SnackBar(content: Text('Deleted Q'), duration: Duration(minutes: 5)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await land();
    expect(find.text('Deleted Q'), findsOneWidget);
    await finish(tester);
  });
}
