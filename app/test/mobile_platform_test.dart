// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/attachment_platform.dart';
import 'package:noted/src/device_storage.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('noted_mobile');
    Directory('${root.path}/app').createSync();
    resetDeviceStorage();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    resetDeviceStorage();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File binders() => File('${root.path}/app/binders.json');

  String norm(String p) => p.replaceAll(r'\', '/');

  group('storage', () {
    test('on mobile the defaults are the app\'s folders', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final docs = await Directory('${root.path}/docs').create();
      final cache = await Directory('${root.path}/cache').create();
      final support = await Directory('${root.path}/support').create();
      await initDeviceStorage(
        documents: () async => docs,
        cache: () async => cache,
        support: () async => support,
      );

      expect(
        norm(devicePagesDirectory()!.path),
        '${norm(docs.path)}/Noted/pages',
      );
      // Settings and recovery are in the support folder, not the documents.
      expect(
        norm(defaultSettingsFile().path),
        '${norm(support.path)}/Noted/settings.json',
      );
      expect(norm(defaultCacheDirectory().path), '${norm(cache.path)}/Noted');
      expect(
        norm(defaultRecoveryDirectory(defaultBindersFile()).absolute.path),
        '${norm(support.absolute.path)}/Noted/recovery',
      );
      // Pages and binders land in the app's documents folder.
      final base = '${norm(docs.absolute.path)}/Noted';
      expect(norm(defaultPagesDirectory().absolute.path), '$base/pages');
      expect(norm(defaultBindersDirectory().absolute.path), '$base/binders');
      expect(norm(defaultBindersFile().absolute.path), '$base/binders.json');
    });

    test('desktop defaults ignore folders found earlier on a device', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final fake = await Directory('${root.path}/fake').create();
      await initDeviceStorage(
        documents: () async => fake,
        cache: () async => fake,
        support: () async => fake,
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final fakePath = norm(fake.absolute.path);
      for (final path in [
        defaultPagesDirectory().absolute.path,
        defaultBindersFile().absolute.path,
        defaultSettingsFile().absolute.path,
        defaultRecoveryDirectory(defaultBindersFile()).absolute.path,
        defaultCacheDirectory().absolute.path,
      ]) {
        expect(norm(path).startsWith(fakePath), isFalse, reason: path);
      }
    });

    testWidgets('a failed folder lookup shows the failure, not a blank app', (
      t,
    ) async {
      await t.pumpWidget(
        StorageErrorApp(error: Exception('no plugin')),
      );
      expect(find.textContaining('no plugin'), findsOneWidget);
    });

    test('iOS is mobile too', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(isMobilePlatform, isTrue);
    });

    test(
      'on desktop nothing is looked up and the defaults are unchanged',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        final before = (
          defaultSettingsFile().path,
          defaultCacheDirectory().path,
        );
        var asked = false;
        Future<Directory> ask() async {
          asked = true;
          return root;
        }

        await initDeviceStorage(documents: ask, cache: ask);
        expect(asked, isFalse);
        expect(isMobilePlatform, isFalse);
        expect(devicePagesDirectory(), isNull);
        expect(deviceCacheDirectory(), isNull);
        expect((
          defaultSettingsFile().path,
          defaultCacheDirectory().path,
        ), before);
        expect(
          norm(defaultSettingsFile().path),
          '${norm(defaultPagesDirectory().absolute.parent.path)}/settings.json',
        );
      },
    );
  });

  group('home', () {
    Future<Notebook> open(WidgetTester t) async {
      late Notebook nb;
      await t.runAsync(() async {
        nb = Notebook(
          PageStore(Directory('${root.path}/pages')..createSync()),
          buildModules(),
          saveDelay: Duration.zero,
          bindersFile: binders(),
        );
        await nb.load();
      });
      addTearDown(nb.dispose);
      return nb;
    }

    testWidgets('no drop target on mobile', (t) async {
      t.view.physicalSize = const Size(1400, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final nb = await open(t);
        await t.pumpWidget(MaterialApp(home: Home(notebook: nb)));
        await t.pump();
        await t.pump();
        expect(find.byType(DropTarget), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a drop target on desktop', (t) async {
      t.view.physicalSize = const Size(1400, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final nb = await open(t);
        await t.pumpWidget(MaterialApp(home: Home(notebook: nb)));
        await t.pump();
        await t.pump();
        expect(find.byType(DropTarget), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('notebook wiring', () {
    Notebook build() {
      final nb = buildAppNotebook(
        pagesDirectory: Directory('${root.path}/pages'),
        bindersFile: binders(),
      );
      addTearDown(nb.dispose);
      return nb;
    }

    test('on mobile: no folder watching, no AI access, no folder picker', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final nb = build();
      expect(nb.watchFiles, isFalse);
      expect(nb.aiAccess, isNull);
      expect(nb.pickFolder, isNull);
    });

    test('on desktop: all three are on', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final nb = build();
      // Its access service polls on a timer: stop it with the test.
      addTearDown(() => nb.aiAccess?.dispose());
      expect(nb.watchFiles, isTrue);
      expect(nb.aiAccess, isNotNull);
      expect(nb.pickFolder, isNotNull);
    });

    test('tests run as desktop unless one picks a platform', () {
      expect(isMobilePlatform, isFalse);
    });
  });

  group('AI services', () {
    test('not started on mobile: no lock, no link, no files', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final nb = Notebook(
        PageStore(Directory('${root.path}/pages')..createSync()),
        buildModules(),
        bindersFile: binders(),
      );
      addTearDown(nb.dispose);
      final data = await Directory('${root.path}/data').create();
      final s = await startAiServices(nb, data);
      expect(s.lock, isNull);
      expect(s.link, isNull);
      expect(data.listSync(), isEmpty);
    });

    test('started on desktop', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final nb = Notebook(
        PageStore(Directory('${root.path}/pages')..createSync()),
        buildModules(),
        bindersFile: binders(),
      );
      addTearDown(nb.dispose);
      final data = await Directory('${root.path}/data').create();
      final s = await startAiServices(nb, data);
      addTearDown(() async {
        await s.link?.dispose();
        s.lock?.dispose();
      });
      expect(s.lock, isNotNull);
      expect(s.link, isNotNull);
    });
  });
}
