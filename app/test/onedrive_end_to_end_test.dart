// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The pull end to end (sync stage 3): the real controller, engine and Graph
// client against the noted_sync tests' fake OneDrive, on a notebook with no
// folder watching and a read-only root, as on an iPad. A first sync brings a
// page into the tree; a remote edit reaches the open page.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/device_storage.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/onedrive_sync.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_sync/noted_sync.dart';

import '../../packages/noted_sync/test/fake_graph.dart';
import 'support/onedrive_world.dart';
import 'support/real_io.dart';

const String _pageId = 'cccc000000000001';

Map<String, Object?> _doc(String text) => {
  'document': {
    'type': 'page',
    'children': [
      {
        'type': 'paragraph',
        'data': {
          'delta': [
            {'insert': text},
          ],
        },
      },
    ],
  },
};

String _pageWith(String text) {
  final codec = buildModules().codecs.codecFor('noted.note')!;
  final box = commitBox(
    createBox(codec, const Bounds(10, 10, 300, 40)).withId('bremote0000001'),
    codec,
    codec.decode(_doc(text), 1),
  );
  final page = NotedPage.create(PageMeta.create(id: _pageId, title: 'From OneDrive', order: 1)).insertNode(box);
  return writePage(page);
}

void main() {
  // The widget test binding refuses every real request; this test makes them.
  setUpAll(() => HttpOverrides.global = null);

  testWidgets('a first sync brings a page in, and a remote edit reaches the open page', (t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);

    late FakeGraph fake;
    late Directory top;
    late Directory workingRoot;
    late Notebook nb;
    late OneDriveSync sync;
    late String rootId;
    var accountKey = '';

    Future<void> until(bool Function() done, String what) async {
      for (var i = 0; i < 200; i++) {
        if (done()) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      fail('timed out waiting for $what');
    }

    await t.runAsync(() async {
      fake = await FakeGraph.start();
      fake.expectedToken = 'A'; // what the test account hands out
      rootId = fake.addFolder('Noted');
      fake.addFile('Noted/$_pageId.canvas', utf8.encode(_pageWith('first version')));
      top = await Directory.systemTemp.createTemp('noted_onedrive_e2e');
      workingRoot = await Directory('${top.path}/onedrive').create();
      final support = await Directory('${top.path}/support').create();
      final account = await signedInAccount();
      accountKey = account.session.accountKey!;
      nb = Notebook(
        PageStore(await Directory('${top.path}/pages').create()),
        buildModules(),
        saveDelay: Duration.zero,
        bindersFile: File('${top.path}/app/binders.json'),
        readOnlyRoots: [workingRoot.path],
        watchFiles: false,
        folderCheckInterval: Duration.zero,
      );
      await nb.load();
      sync = OneDriveSync.create(
        notebook: nb,
        microsoft: account,
        workingRoot: workingRoot,
        support: support,
        graphOrigin: fake.origin,
      );
      await sync.start();
      expect(nb.pageTitleOf(_pageId), isNull);
      await sync.choose(ChosenRoot(driveId: FakeGraph.driveId, itemId: rootId, path: 'Noted'));
      // The first round runs on its own; the page arrives in the tree.
      await until(() => nb.pageTitleOf(_pageId) != null && !sync.checking, 'the first sync');
    });
    expect(nb.pageTitleOf(_pageId), 'From OneDrive');
    expect(sync.statusLine, startsWith('Up to date'));
    final working = oneDriveWorkingCopy(workingRoot, accountKey, rootId);
    expect(File('${working.path}/$_pageId.canvas').existsSync(), isTrue);
    expect(nb.isPullOnlyPage(_pageId), isTrue);

    // Open the page on screen.
    await t.pumpWidget(MaterialApp(home: Home(notebook: nb)));
    await t.pump();
    await t.runAsync(() => nb.open(_pageId));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 300));
      await t.runAsync(() => realIoPause(50));
    }
    await t.pumpAndSettle();
    expect(find.text('first version', findRichText: true), findsOneWidget);

    // A remote edit: the next round writes it, tells the notebook, and the
    // editor shows it.
    await t.runAsync(() async {
      fake.replaceFile('Noted/$_pageId.canvas', utf8.encode(_pageWith('second version')));
      await sync.checkNow();
      await until(() => !sync.checking, 'the second round');
    });
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 300));
      await t.runAsync(() => realIoPause(50));
    }
    await t.pumpAndSettle();
    expect(File('${working.path}/$_pageId.canvas').readAsStringSync(), contains('second version'));
    expect(find.text('second version', findRichText: true), findsOneWidget);
    expect(find.text('first version', findRichText: true), findsNothing);
    expect(nb.current!.readOnly, isTrue);

    await t.pumpWidget(const SizedBox());
    sync.dispose();
    await t.runAsync(() async {
      nb.dispose();
      await fake.close();
      await top.delete(recursive: true);
    });
  });
}
