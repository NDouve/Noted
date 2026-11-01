// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_tree_view.dart';
import 'package:noted/src/settings_panel.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  testWidgets('the page settings panel sets "Images and files" and converts; the menu no longer does', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late Directory dir;
    late Notebook nb;
    late String a;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('noted_menu');
      nb = Notebook(PageStore(dir), buildModules(), saveDelay: Duration.zero);
      await nb.load();
      a = nb.currentId!;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            height: 700,
            child: ListenableBuilder(listenable: nb, builder: (context, _) => PageTreeView(notebook: nb)),
          ),
        ),
      ),
    );
    await tester.pump();

    // The right-click menu has page actions only.
    final at = tester.getCenter(find.byKey(ValueKey('page-row-$a'))) + const Offset(-40, 0);
    await tester.runAsync(() => tester.tapAt(at, buttons: kSecondaryButton));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    for (final label in [
      'Store images and files',
      'Embed attachments',
      'Move attachments to folder',
      'In the page file',
      'AI access',
    ]) {
      expect(find.text(label), findsNothing, reason: label);
    }
    await tester.tapAt(const Offset(800, 1000));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SettingsPanel.page(notebook: nb, pageId: a))),
    );
    await tester.pump();

    Future<void> tap(String key) async {
      await tester.runAsync(() => tester.tap(find.byKey(ValueKey(key))));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      }
      await tester.pumpAndSettle();
    }

    expect(find.text('Same as parent'), findsNothing);
    expect(find.text('App default (In a folder beside the page)'), findsOneWidget);
    await tap('settings-att-embedded');
    expect(nb.ownAttachmentStorage(a), AttachmentStorage.embedded);
    expect(nb.attachmentStorageFor(a), AttachmentStorage.embedded);

    await tap('settings-att-embed');
    expect(find.text('Embedded 0 attachments.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await nb.flush();
      nb.dispose();
      await dir.delete(recursive: true);
    });
  });
}
