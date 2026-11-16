// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The WebDAV section of About: the form, its refusals, the folder picker with
// WebDAV's words, the connected state and Disconnect.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/webdav_section.dart';
import 'package:noted/src/webdav_sync.dart';
import 'package:noted_sync/noted_sync.dart' show SyncIssue;

import '../../packages/noted_sync/test/fake_webdav.dart';
import 'support/webdav_world.dart';

void main() {
  setUpAll(() => HttpOverrides.global = null);

  late WebDavWorld w;

  Future<void> build(
    WidgetTester t, {
    bool server = false,
    bool saveConnection = false,
  }) async {
    await t.runAsync(() async {
      w = await WebDavWorld.create(
        server: server,
        saveConnection: saveConnection,
      );
      await w.sync.start();
    });
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: WebDavSection(sync: w.sync)),
        ),
      ),
    );
  }

  void sTest(String name, Future<void> Function(WidgetTester t) body) {
    testWidgets(name, (t) async {
      try {
        await body(t);
      } finally {
        await t.pumpWidget(const SizedBox());
        w.sync.dispose();
        await t.runAsync(() async {
          w.nb.dispose();
          try {
            await w.fake?.close();
          } on Object {
            // A request cut off by the close is not what the test is about.
          }
          await w.top.delete(recursive: true);
        });
      }
    });
  }

  // Real time for the server and the files, the test clock for the frames.
  Future<void> until(WidgetTester t, bool Function() done, String what) async {
    for (var i = 0; i < 100; i++) {
      await t.pump();
      if (done()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    fail('timed out waiting for $what');
  }

  Future<void> fill(WidgetTester t, {String? password}) async {
    await t.enterText(
      find.byKey(const ValueKey('dav-address')),
      w.fake!.urlOf('').toString(),
    );
    await t.enterText(find.byKey(const ValueKey('dav-user')), FakeWebDav.user);
    await t.enterText(
      find.byKey(const ValueKey('dav-password')),
      password ?? w.fake!.password,
    );
  }

  sTest(
    'with no connection the form is offered, and the password is hidden as typed',
    (t) async {
      await build(t);
      expect(find.text('WebDAV folder'), findsOneWidget);
      expect(find.byKey(const ValueKey('dav-address')), findsOneWidget);
      expect(find.byKey(const ValueKey('dav-user')), findsOneWidget);
      expect(find.byKey(const ValueKey('dav-connect')), findsOneWidget);
      expect(find.byKey(const ValueKey('dav-check-now')), findsNothing);
      expect(find.byKey(const ValueKey('dav-disconnect')), findsNothing);
      final field = t.widget<TextField>(
        find.byKey(const ValueKey('dav-password')),
      );
      expect(field.obscureText, isTrue);
    },
  );

  sTest('a refusal is shown under the form and nothing is saved', (t) async {
    await build(t, server: true);
    await fill(t, password: 'wrong');
    await t.tap(find.byKey(const ValueKey('dav-connect')));
    await until(
      t,
      () => find.byKey(const ValueKey('dav-error')).evaluate().isNotEmpty,
      'the refusal',
    );
    expect(
      t.widget<Text>(find.byKey(const ValueKey('dav-error'))).data,
      'WebDAV refused the user name or password.',
    );
    expect(
      find.byKey(const ValueKey('dav-connect')),
      findsOneWidget,
      reason: 'the form stays',
    );
    expect(w.store.inner.values, isEmpty);
  });

  sTest(
    'connect opens the folder picker in WebDAV\'s words; choosing a folder connects',
    (t) async {
      await build(t, server: true);
      await t.runAsync(() async => w.fake!.addFile('Noted/a.canvas', [1, 2]));
      await fill(t);
      await t.tap(find.byKey(const ValueKey('dav-connect')));
      await until(
        t,
        () => find.byKey(const ValueKey('picker-title')).evaluate().isNotEmpty,
        'the picker',
      );
      expect(
        t.widget<Text>(find.byKey(const ValueKey('picker-title'))).data,
        'WebDAV',
      );
      expect(
        find.textContaining("The top level of WebDAV can't be chosen"),
        findsOneWidget,
      );
      await until(
        t,
        () => find
            .byKey(const ValueKey('picker-folder-Noted'))
            .evaluate()
            .isNotEmpty,
        'the folders',
      );
      await t.tap(find.byKey(const ValueKey('picker-folder-Noted')));
      await until(
        t,
        () =>
            t
                .widget<FilledButton>(find.byKey(const ValueKey('picker-use')))
                .onPressed !=
            null,
        'the folder hint',
      );
      await t.tap(find.byKey(const ValueKey('picker-use')));
      await until(
        t,
        () => find.byKey(const ValueKey('dav-path')).evaluate().isNotEmpty,
        'the connection',
      );
      expect(
        t.widget<Text>(find.byKey(const ValueKey('dav-path'))).data,
        'Noted',
      );
      expect(find.byKey(const ValueKey('dav-status')), findsOneWidget);
      expect(find.byKey(const ValueKey('dav-check-now')), findsOneWidget);
      expect(find.byKey(const ValueKey('dav-disconnect')), findsOneWidget);
      expect(find.byKey(const ValueKey('dav-connect')), findsNothing);
      expect(
        find.text('app-password'),
        findsNothing,
        reason: 'the password is never shown again',
      );
    },
  );

  sTest(
    'connected: the folder, its status, Check now and Disconnect; Disconnect brings the form back',
    (t) async {
      await build(t, saveConnection: true);
      await t.pump();
      expect(
        t.widget<Text>(find.byKey(const ValueKey('dav-path'))).data,
        'Noted',
      );
      expect(find.byKey(const ValueKey('dav-status')), findsOneWidget);
      expect(find.byKey(const ValueKey('dav-address')), findsNothing);
      final rounds = w.runner.rounds;
      await t.tap(find.byKey(const ValueKey('dav-check-now')));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump();
      expect(w.runner.rounds, rounds + 1);

      await t.tap(find.byKey(const ValueKey('dav-disconnect')));
      await until(
        t,
        () => find.byKey(const ValueKey('dav-connect')).evaluate().isNotEmpty,
        'the form',
      );
      expect(find.byKey(const ValueKey('dav-path')), findsNothing);
      expect(w.store.inner.values, isEmpty);
    },
  );

  sTest('what the pull left alone is counted and listed', (t) async {
    await build(t, saveConnection: true);
    w.runner.issues = [
      const SyncIssue('a/b.canvas', 'A different file is already here'),
    ];
    w.runner.changed();
    await t.pump();
    expect(find.text('1 issue'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('dav-issues')));
    await t.pumpAndSettle();
    expect(find.text('WebDAV issues'), findsOneWidget);
    expect(find.text('a/b.canvas'), findsOneWidget);
    expect(find.text('A different file is already here'), findsOneWidget);
  });

  testWidgets(
    'an unexpected failure while connecting is shown in plain words and the form is usable again',
    (t) async {
      await t.runAsync(() async {
        w = await WebDavWorld.create();
        await w.sync.start();
      });
      final failing = _FailingSync(w);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: WebDavSection(sync: failing)),
          ),
        ),
      );
      await t.enterText(
        find.byKey(const ValueKey('dav-address')),
        'https://dav.example.test/',
      );
      await t.enterText(find.byKey(const ValueKey('dav-user')), 'alice');
      await t.enterText(find.byKey(const ValueKey('dav-password')), 'x');
      await t.tap(find.byKey(const ValueKey('dav-connect')));
      await until(
        t,
        () => find.byKey(const ValueKey('dav-error')).evaluate().isNotEmpty,
        'the error',
      );
      expect(
        t.widget<Text>(find.byKey(const ValueKey('dav-error'))).data,
        "WebDAV couldn't be used.",
      );
      expect(
        t
            .widget<FilledButton>(find.byKey(const ValueKey('dav-connect')))
            .onPressed,
        isNotNull,
      );
      await t.pumpWidget(const SizedBox());
      failing.dispose();
      await t.runAsync(() async {
        w.nb.dispose();
        await w.top.delete(recursive: true);
      });
    },
  );
}

// A controller whose first checks throw something no one planned for.
class _FailingSync extends WebDavSync {
  _FailingSync(WebDavWorld w)
    : super(
        notebook: w.nb,
        workingRoot: w.workingRoot,
        support: w.support,
        store: w.store,
        keychainReady: () async => true,
        clientFactory: loopbackClient,
        runnerFactory: ({
          required workingCopy,
          required stateDir,
          required connection,
          required password,
        }) => w.runner,
      );

  @override
  Future<WebDavLogin> checkLogin({
    required String address,
    required String user,
    required String password,
  }) => throw StateError('unplanned');
}
