// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_notice.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  // File access needs real time, so it all happens inside runAsync.
  Future<(Directory, Notebook)> setUpNotebook(WidgetTester tester, {required bool pending}) async {
    return (await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('noted_recovery_notice');
      final extra = await Directory('${root.path}/Elsewhere').create();
      final nb = Notebook(
        PageStore(await Directory('${root.path}/pages').create()),
        buildModules(),
        saveDelay: const Duration(hours: 1),
        bindersFile: File('${root.path}/app/binders.json'),
        folderCheckInterval: Duration.zero,
      );
      await nb.load();
      if (pending) {
        final x = await nb.createPage(folderPath: extra.path);
        await nb.flush();
        await nb.open(x);
        nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
        await extra.rename('${root.path}/Elsewhere-away');
        await nb.checkFolders();
      }
      return (root, nb);
    }))!;
  }

  Future<void> tearDownNotebook(WidgetTester tester, Directory root, Notebook nb) async {
    await tester.runAsync(() async {
      await nb.flush();
      nb.dispose();
      await root.delete(recursive: true);
    });
  }

  testWidgets('the quit notice is shown when entries are pending, and ends when dismissed', (tester) async {
    final (root, nb) = await setUpNotebook(tester, pending: true);
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: key, home: const SizedBox()));
    var done = false;
    late Future<void> future;
    await tester.runAsync(() async {
      future = showRecoveryNoticeOnExit(nb, key).then((_) => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('recovery-exit-notice')), findsOneWidget);
    expect(find.textContaining("1 page couldn't be saved"), findsOneWidget);
    expect(done, isFalse);
    await tester.tap(find.byKey(const ValueKey('recovery-exit-ok')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => future);
    expect(done, isTrue);
    await tearDownNotebook(tester, root, nb);
  });

  testWidgets('no quit notice when nothing is pending', (tester) async {
    final (root, nb) = await setUpNotebook(tester, pending: false);
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: key, home: const SizedBox()));
    await tester.runAsync(() => showRecoveryNoticeOnExit(nb, key));
    await tester.pump();
    expect(find.byKey(const ValueKey('recovery-exit-notice')), findsNothing);
    await tearDownNotebook(tester, root, nb);
  });
}
