// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// WebDAV in the app's shell: About and the settings menu offered with a WebDAV
// controller and no Microsoft account, the section after the reveal when there
// is one, the whole app's tree, the guard's question in Home, and what starts
// when Noted owns its data.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/about_dialog.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/microsoft_account.dart';
import 'package:noted/src/settings_menu.dart';
import 'package:noted/src/webdav_sync.dart';
import 'package:noted_sync/noted_sync.dart' show GuardQuestion;

import 'support/onedrive_world.dart';
import 'support/real_io.dart';
import 'support/webdav_world.dart';

void main() {
  late WebDavWorld w;

  Future<void> build(WidgetTester t, {bool saveConnection = false}) async {
    await t.runAsync(() async {
      w = await WebDavWorld.create(saveConnection: saveConnection);
      if (!saveConnection) await w.sync.start();
    });
  }

  Future<void> finish(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 100));
      await t.runAsync(() => realIoPause(30));
    }
    w.sync.dispose();
    await t.runAsync(() async {
      w.nb.dispose();
      await w.top.delete(recursive: true);
    });
  }

  Widget scoped(Widget home) => MaterialApp(
    builder: (context, child) => WebDavScope(sync: w.sync, child: child!),
    home: home,
  );

  testWidgets(
    'About with a WebDAV controller and no Microsoft account shows the section at once',
    (t) async {
      await build(t);
      await t.pumpWidget(
        scoped(const Scaffold(body: AboutNotedDialog(microsoft: null))),
      );
      expect(find.byKey(const ValueKey('dav-section')), findsOneWidget);
      expect(find.byKey(const ValueKey('ms-section')), findsNothing);
      await finish(t);
    },
  );

  testWidgets(
    'with a Microsoft account the WebDAV section waits for the same reveal',
    (t) async {
      await build(t);
      final account = await signedInAccount();
      addTearDown(account.dispose);
      await t.pumpWidget(
        scoped(Scaffold(body: AboutNotedDialog(microsoft: account))),
      );
      expect(find.byKey(const ValueKey('dav-section')), findsNothing);
      for (var i = 0; i < aboutTapsToReveal; i++) {
        await t.tap(find.byKey(const ValueKey('about-line')));
      }
      await t.pump();
      expect(find.byKey(const ValueKey('dav-section')), findsOneWidget);
      expect(find.byKey(const ValueKey('ms-section')), findsOneWidget);
      await finish(t);
    },
  );

  testWidgets(
    'the settings menu offers About with a WebDAV controller alone, and not with neither',
    (t) async {
      await build(t);
      final settings = AppSettings(null);
      await t.pumpWidget(
        scoped(Scaffold(body: SettingsMenu(settings: settings))),
      );
      await t.tap(find.byKey(const ValueKey('settings-menu')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-about')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('settings-about')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('dav-section')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('about-close')));
      await t.pumpAndSettle();

      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SettingsMenu(settings: settings)),
        ),
      );
      await t.tap(find.byKey(const ValueKey('settings-menu')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-about')), findsNothing);
      await finish(t);
    },
  );

  testWidgets(
    'NotedApp gives the whole tree the controller: Home, its settings menu and About reach the section',
    (t) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await build(t);
      await t.pumpWidget(
        NotedApp(notebook: w.nb, settings: AppSettings(null), webdav: w.sync),
      );
      await t.pump();
      await t.runAsync(() => realIoPause(50));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('settings-menu')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('settings-about')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('dav-section')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('about-close')));
      await t.pumpAndSettle();
      await finish(t);
    },
  );

  testWidgets(
    'Home asks a WebDAV guard question in WebDAV\'s words and answers to that pull',
    (t) async {
      await build(t, saveConnection: true);
      final q = GuardQuestion(['Work/a.canvas']);
      w.runner.guardQuestion = q;
      await t.runAsync(() => w.sync.start());
      await t.pumpWidget(scoped(Home(notebook: w.nb)));
      await t.runAsync(() => realIoPause(50));
      await t.pumpAndSettle();
      expect(find.text('WebDAV says 1 page was removed.'), findsOneWidget);
      expect(find.text('OneDrive says 1 page was removed.'), findsNothing);
      await t.tap(find.byKey(const ValueKey('onedrive-guard-keep')));
      await t.pumpAndSettle();
      expect(w.runner.answers, [(q, false)]);
      await finish(t);
    },
  );

  group('what starts once Noted owns its data', () {
    late Directory dir;
    late File file;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('noted_owned');
      file = File('${dir.path}/settings.json')..writeAsStringSync('{}');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      dir.deleteSync(recursive: true);
    });

    test('the keychain step runs with no Microsoft account at all', () async {
      var deletes = 0;
      final cleaner = KeychainCleaner(
        AppSettings(file),
        delete: () async => deletes++,
      );
      startOwned(
        cleaner: cleaner,
        microsoft: null,
        settings: AppSettings(file),
      );
      expect(await cleaner.cleanKeychainOnce(), isTrue);
      expect(deletes, 1);
      expect(AppSettings(file).keychainCleaned, isTrue);
    });

    test(
      'with Microsoft its start waits for that same step: one delete',
      () async {
        var deletes = 0;
        final cleaner = KeychainCleaner(
          AppSettings(file),
          delete: () async => deletes++,
        );
        final account = await signedInAccount();
        addTearDown(account.dispose);
        startOwned(
          cleaner: cleaner,
          microsoft: account,
          settings: AppSettings(file),
        );
        expect(await cleaner.cleanKeychainOnce(), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(deletes, 1);
      },
    );
  });
}
