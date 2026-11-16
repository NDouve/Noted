// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The WebDAV pull end to end (run 2026-11-15-02, task 4): the real controller,
// engine, driver and client against the noted_sync tests' fake WebDAV server,
// on a notebook with no folder watching and a read-only root, as on an iPad.
// Connecting through the form's three steps brings a page into the tree; a
// remote edit reaches the open page; a refused password pauses the pull.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/onedrive_sync.dart' show ChosenRoot;
import 'package:noted/src/webdav_sync.dart';
import 'package:noted_auth/noted_auth.dart';
import 'package:noted_core/noted_core.dart';

import '../../packages/noted_sync/test/fake_webdav.dart';
import 'support/real_io.dart';
import 'support/webdav_world.dart' show loopbackClient;

const String _pageId = 'cccc000000000002';

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
    createBox(codec, const Bounds(10, 10, 300, 40)).withId('bremote0000002'),
    codec,
    codec.decode(_doc(text), 1),
  );
  final page = NotedPage.create(
    PageMeta.create(id: _pageId, title: 'From WebDAV', order: 1),
  ).insertNode(box);
  return writePage(page);
}

void main() {
  // The widget test binding refuses every real request; this test makes them.
  setUpAll(() => HttpOverrides.global = null);

  testWidgets(
    'connecting brings a page in, a remote edit reaches the open page, a refused password pauses',
    (t) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);

      late FakeWebDav fake;
      late Directory top;
      late Directory workingRoot;
      late Notebook nb;
      late WebDavSync sync;
      late MemoryTokenStore store;

      Future<void> until(bool Function() done, String what) async {
        for (var i = 0; i < 200; i++) {
          if (done()) return;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        fail('timed out waiting for $what');
      }

      await t.runAsync(() async {
        fake = await FakeWebDav.start();
        fake.addFile(
          'Noted/$_pageId.canvas',
          utf8.encode(_pageWith('first version')),
        );
        top = await Directory.systemTemp.createTemp('noted_webdav_e2e');
        workingRoot = await Directory('${top.path}/webdav').create();
        final support = await Directory('${top.path}/support').create();
        store = MemoryTokenStore();
        nb = Notebook(
          PageStore(await Directory('${top.path}/pages').create()),
          buildModules(),
          saveDelay: Duration.zero,
          bindersFile: File('${top.path}/app/binders.json'),
          readOnlyRoots: [workingRoot.path],
          readOnlyRootNames: {workingRoot.path: 'WebDAV'},
          watchFiles: false,
          folderCheckInterval: Duration.zero,
        );
        await nb.load();
        sync = WebDavSync.create(
          notebook: nb,
          workingRoot: workingRoot,
          support: support,
          keychainReady: () async => true,
          store: store,
          clientFactory: loopbackClient,
        );
        await sync.start();
        expect(nb.pageTitleOf(_pageId), isNull);

        // The form: check the server, pick the folder, connect.
        final login = await sync.checkLogin(
          address: fake.urlOf('').toString(),
          user: FakeWebDav.user,
          password: fake.password,
        );
        final folders = await login.source.listFolders();
        expect(folders.map((f) => f.name), ['Noted']);
        final error = await sync.connect(
          login,
          ChosenRoot(
            driveId: webDavPickerDriveId,
            itemId: folders.single.id,
            path: 'Noted',
          ),
        );
        login.close();
        expect(error, isNull);
        // The first round runs on its own; the page arrives in the tree.
        await until(
          () => nb.pageTitleOf(_pageId) != null && !sync.checking,
          'the first sync',
        );
      });
      expect(nb.pageTitleOf(_pageId), 'From WebDAV');
      expect(sync.statusLine, startsWith('Up to date'));
      final working = sync.workingCopy!;
      expect(File('${working.path}/$_pageId.canvas').existsSync(), isTrue);
      expect(nb.isPullOnlyPage(_pageId), isTrue);
      expect(store.values.values, [
        fake.password,
      ], reason: 'the password is in the store only');
      expect(
        Directory('${top.path}/support')
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => f.readAsStringSync())
            .where((s) => s.contains(fake.password)),
        isEmpty,
        reason: 'and in no file of the state folder',
      );

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
        fake.replaceFile(
          'Noted/$_pageId.canvas',
          utf8.encode(_pageWith('second version')),
        );
        await sync.checkNow();
        await until(() => !sync.checking, 'the second round');
      });
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 300));
        await t.runAsync(() => realIoPause(50));
      }
      await t.pumpAndSettle();
      expect(
        File('${working.path}/$_pageId.canvas').readAsStringSync(),
        contains('second version'),
      );
      expect(find.text('second version', findRichText: true), findsOneWidget);
      expect(find.text('first version', findRichText: true), findsNothing);
      expect(nb.current!.readOnly, isTrue);

      // The server stops accepting the password: the pull pauses, the page stays.
      await t.runAsync(() async {
        fake.password = 'changed';
        await sync.checkNow();
        await until(() => !sync.checking, 'the refused round');
      });
      expect(
        sync.statusLine,
        startsWith('Paused: WebDAV refused the password'),
      );
      expect(
        File('${working.path}/$_pageId.canvas').readAsStringSync(),
        contains('second version'),
      );
      // The refused password is not sent again: no request follows on Check now.
      final sent = fake.requests.length;
      await t.runAsync(() async {
        await sync.checkNow();
        await realIoPause(100);
      });
      expect(fake.requests.length, sent);
      expect(nb.pageTitleOf(_pageId), 'From WebDAV');

      await t.pumpWidget(const SizedBox());
      sync.dispose();
      await t.runAsync(() async {
        nb.dispose();
        await fake.close();
        await top.delete(recursive: true);
      });
    },
  );
}
