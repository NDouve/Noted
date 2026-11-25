// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// How `main.dart` wires the WebDAV pull (run 2026-11-15-02, task 4): the
// read-only root beside OneDrive's and each one's own message, the one lock,
// plain http refused in the app's own client, the order of the start, and the
// keychain clean-up as one step that everything holding a secret waits for.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/cloud_sync.dart';
import 'package:noted/src/device_storage.dart';
import 'package:noted/src/microsoft_account.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/webdav_sync.dart';
import 'package:noted_auth/noted_auth.dart';
import 'package:noted_core/noted_core.dart' show PageStore;
import 'package:noted_sync/noted_sync.dart';

import 'support/onedrive_world.dart';
import 'support/webdav_world.dart';
import 'support/notebook_folder.dart';

class _LogSync extends WebDavSync {
  _LogSync(this.log, Notebook nb)
    : super(
        notebook: nb,
        workingRoot: Directory.systemTemp,
        support: Directory.systemTemp,
        store: MemoryTokenStore(),
        keychainReady: () async => true,
        clientFactory: loopbackClient,
        runnerFactory: ({
          required workingCopy,
          required stateDir,
          required connection,
          required password,
        }) => FakeRunner(),
      );

  final List<String> log;

  @override
  Future<void> start() {
    log.add('webdav.start');
    return Future<void>.value();
  }
}

class _LogNotebook extends SpyNotebook {
  _LogNotebook(this.order, super.store, super.modules);

  final List<String> order;

  @override
  Future<void> load() async {
    order.add('load');
    await super.load();
    order.add('loaded');
  }
}

void main() {
  setUpAll(() => HttpOverrides.global = null);

  late Directory top;
  late Directory documents;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    top = await Directory.systemTemp.createTemp('noted_wiring_dav');
    documents = await Directory('${top.path}/documents').create();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    resetDeviceStorage();
    await deleteTestFolder(top);
  });

  Future<void> asDevice() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await initDeviceStorage(
      documents: () async => documents,
      cache: () async => Directory('${top.path}/cache').create(),
      support: () async => Directory('${top.path}/support').create(),
    );
  }

  Notebook build() => buildAppNotebook(
    pagesDirectory: Directory('${top.path}/documents/Noted/pages')
      ..createSync(recursive: true),
    bindersFile: File('${top.path}/support/Noted/binders.json'),
  );

  final sep = Platform.pathSeparator;

  group('the read-only roots', () {
    test('on a device the WebDAV folder is a read-only root beside OneDrive\'s, each with its own message', () async {
      await asDevice();
      final nb = build();
      addTearDown(nb.dispose);
      final dav = deviceWebDavRoot()!;
      final od = deviceOneDriveRoot()!;
      expect(dav.path, '${documents.path}${sep}Noted${sep}webdav');
      expect(deviceCloudRoot('webdav')!.path, dav.path);
      for (final root in [dav, od]) {
        expect(nb.isPullOnlyLocation(root.path), isTrue);
        expect(
          nb.isPullOnlyLocation('${root.path}${sep}acct${sep}rootid'),
          isTrue,
        );
      }
      expect(
        nb.pullOnlyMessageFor('${dav.path}${sep}acct${sep}rootid'),
        'This WebDAV folder is read-only on this device for now.',
      );
      expect(
        nb.pullOnlyMessageFor('${od.path}${sep}acct${sep}rootid'),
        'This OneDrive folder is read-only on this device for now.',
      );
      expect(
        Notebook.pullOnlyMessage,
        'This OneDrive folder is read-only on this device for now.',
      );
      expect(
        nb.isPullOnlyLocation('${documents.path}${sep}Noted${sep}pages'),
        isFalse,
      );
    });

    test('a binder or folder named webdav directly under Noted falls inside the root and is pull-only (N13)', () async {
      await asDevice();
      final nb = build();
      addTearDown(nb.dispose);
      expect(
        nb.isPullOnlyLocation('${documents.path}${sep}Noted${sep}webdav'),
        isTrue,
      );
      expect(
        nb.isPullOnlyLocation(
          '${documents.path}${sep}Noted${sep}webdav${sep}My binder',
        ),
        isTrue,
      );
      // Renaming it lifts that.
      expect(
        nb.isPullOnlyLocation('${documents.path}${sep}Noted${sep}webdav2'),
        isFalse,
      );
      expect(
        nb.isPullOnlyLocation('${documents.path}${sep}Noted${sep}Work'),
        isFalse,
      );
    });

    test(
      'on desktop nothing is read-only and there is no WebDAV pull',
      () async {
        final nb = build();
        addTearDown(nb.dispose);
        expect(
          nb.isPullOnlyLocation('${top.path}/documents/Noted/webdav/x'),
          isFalse,
        );
        expect(deviceWebDavRoot(), isNull);
        expect(
          buildWebDavSync(
            nb,
            KeychainCleaner(AppSettings(null), delete: () async {}),
          ),
          isNull,
        );
      },
    );
  });

  group('the controller of a device', () {
    test(
      'uses the notebook\'s own lock, and a driver of the saved id kind',
      () async {
        await asDevice();
        final nb = build();
        addTearDown(nb.dispose);
        final sync = buildWebDavSync(
          nb,
          KeychainCleaner(AppSettings(null), delete: () async {}),
        )!;
        addTearDown(sync.dispose);
        expect(sync.workingRoot.path, deviceWebDavRoot()!.path);
        final conn = WebDavConnection(
          url: 'https://dav.example.test/dav/Notes/',
          user: 'alice',
          idKind: DavIdKind.fileId,
          rootId: '0042',
          path: 'Notes',
        );
        final runner = sync.runnerFactory(
          workingCopy: Directory('${top.path}/wc'),
          stateDir: Directory('${top.path}/state'),
          connection: conn,
          password: 'secret',
        );
        addTearDown(runner.dispose);
        final engine = (runner as EngineRunner).engine;
        expect(engine.locks, same(nb.folderLocks));
        expect(engine.driver, isA<WebDavDriver>());
        expect((engine.driver as WebDavDriver).idKind, DavIdKind.fileId);
        expect(engine.driver.rootId, '0042');
        expect(engine.driver.provider, 'webdav');
      },
    );

    test(
      'the app\'s own client never uses plain http, not even to the loopback',
      () async {
        await asDevice();
        final nb = build();
        addTearDown(nb.dispose);
        final sync = buildWebDavSync(
          nb,
          KeychainCleaner(AppSettings(null), delete: () async {}),
        )!;
        addTearDown(sync.dispose);
        for (final address in [
          'http://127.0.0.1:9/dav/',
          'http://localhost/dav/',
          'http://dav.example.test/dav/',
        ]) {
          await expectLater(
            sync.checkLogin(address: address, user: 'alice', password: 'x'),
            throwsA(
              isA<WebDavLoginException>().having(
                (e) => e.message,
                'message',
                'WebDAV needs an https address.',
              ),
            ),
            reason: address,
          );
        }
      },
    );

    test('the pull starts after the notebook has loaded, and only when there is one', () async {
      await asDevice();
      final order = <String>[];
      final nb = _LogNotebook(
        order,
        PageStore(Directory('${top.path}/pages')..createSync()),
        buildModules(),
      );
      addTearDown(nb.dispose);
      final sync = _LogSync(order, nb);
      addTearDown(sync.dispose);
      Widget? shown;
      await openWhenOwned(nb, top, show: (w) => shown = w, webdav: sync);
      expect(shown, isA<NotedApp>());
      expect((shown! as NotedApp).webdav, same(sync));
      expect(order, ['load', 'loaded', 'webdav.start']);

      order.clear();
      final nb2 = _LogNotebook(
        order,
        PageStore(Directory('${top.path}/pages2')..createSync()),
        buildModules(),
      );
      addTearDown(nb2.dispose);
      await openWhenOwned(nb2, top, show: (_) {});
      expect(order, ['load', 'loaded']);
    });
  });

  group('the keychain step', () {
    late Directory dir;
    late File file;
    late List<String> log;
    late int deletes;
    late Completer<void>? gate;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('noted_keychain_dav');
      file = File('${dir.path}/settings.json')..writeAsStringSync('{}');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      log = [];
      deletes = 0;
      gate = null;
    });

    tearDown(() => deleteTestFolder(dir));

    // A widget test on iOS: the platform is put back before the framework checks it.
    void iosWidgets(String name, Future<void> Function(WidgetTester t) body) {
      testWidgets(name, (t) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          await body(t);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    KeychainCleaner cleaner({
      AppSettings? settings,
      Future<void> Function()? delete,
    }) => KeychainCleaner(
      settings ?? AppSettings(file),
      delete:
          delete ??
          () async {
            log.add('delete');
            deletes++;
            await gate?.future;
          },
    );

    MicrosoftAccount account(MemoryTokenStore store) {
      const config = AuthConfig(clientId: 'test-client');
      return MicrosoftAccount(
        config: config,
        session: AuthSession(tokens: TestTokens(config), store: store),
        flow: (_) async =>
            const AuthGrant(code: 'c', codeVerifier: 'v', redirectUri: 'r'),
      );
    }

    // A WebDAV controller whose secret store logs into [log], on the step [c].
    Future<WebDavWorld> dav(WidgetTester t, KeychainCleaner c) async {
      final w = await WebDavWorld.create(saveConnection: true);
      w.keychain = c.cleanKeychainOnce;
      // Its own log is the shared one, so the order across both is visible.
      w.log.clear();
      return w;
    }

    iosWidgets(
      'runs before any WebDAV secret is read, with no Microsoft account at all',
      (t) async {
        final c = cleaner();
        late WebDavWorld w;
        await t.runAsync(() async {
          w = await dav(t, c);
          await w.sync.start();
        });
        // The step's own delete ran before the controller's first read.
        expect(deletes, 1);
        expect(w.log, ['keychain', 'store.read']);
        expect(AppSettings(file).keychainCleaned, isTrue);
        expect(w.built.length, 1);
        w.sync.dispose();
        await t.runAsync(() async {
          w.nb.dispose();
          await deleteTestFolder(w.top);
        });
      },
    );

    iosWidgets('and before any is written, when connecting', (t) async {
      final c = cleaner();
      late WebDavWorld w;
      await t.runAsync(() async {
        w = await WebDavWorld.create(server: true);
        w.keychain = c.cleanKeychainOnce;
        final login = await w.sync.checkLogin(
          address: w.fake!.urlOf('').toString(),
          user: 'alice',
          password: w.fake!.password,
        );
        expect(
          deletes,
          1,
          reason: 'the clean-up is done before the server is even asked',
        );
        expect(w.log, isNot(contains('store.write')));
        login.close();
      });
      w.sync.dispose();
      await t.runAsync(() async {
        w.nb.dispose();
        await w.fake!.close();
        await deleteTestFolder(w.top);
      });
    });

    test('a success is kept for the launch, a running call is shared, and a false result is cleared', () async {
      gate = Completer<void>();
      final c = cleaner();
      final a = c.cleanKeychainOnce();
      final b = c.cleanKeychainOnce();
      gate!.complete();
      expect(await a, isTrue);
      expect(await b, isTrue);
      expect(deletes, 1, reason: 'one running call, shared');
      file.deleteSync(); // even the flag going does not make it run again
      expect(await c.cleanKeychainOnce(), isTrue);
      expect(deletes, 1, reason: 'success kept');

      // A false result is cleared: the next call runs again.
      file.writeAsStringSync('{}');
      var fail = true;
      var runs = 0;
      final d = cleaner(
        delete: () async {
          runs++;
          if (fail) throw StateError('keychain');
        },
      );
      expect(await d.cleanKeychainOnce(), isFalse);
      expect(await d.cleanKeychainOnce(), isFalse);
      expect(runs, 2);
      fail = false;
      expect(await d.cleanKeychainOnce(), isTrue);
      expect(runs, 3);
    });

    test(
      'a delete that worked is not repeated when only the flag failed to save',
      () async {
        File('${dir.path}/blocker').writeAsStringSync('x');
        final c = cleaner(
          settings: AppSettings(File('${dir.path}/blocker/settings.json')),
        );
        expect(await c.cleanKeychainOnce(), isFalse);
        expect(await c.cleanKeychainOnce(), isFalse);
        expect(deletes, 1);
      },
    );

    iosWidgets(
      'WebDAV proceeds when the step returns true although settings.json can not be read',
      (t) async {
        file.writeAsStringSync('{ not json');
        final settings = AppSettings(file);
        expect(settings.canRememberNotes, isFalse);
        final c = cleaner(settings: settings);
        late WebDavWorld w;
        await t.runAsync(() async {
          w = await dav(t, c);
          await w.sync.start();
        });
        expect(await c.cleanKeychainOnce(), isTrue);
        expect(
          deletes,
          0,
          reason: 'nothing is deleted from a settings file that is not trusted',
        );
        expect(
          settings.keychainCleaned,
          isFalse,
          reason: 'and the flag is not set',
        );
        expect(w.log, ['keychain', 'store.read']);
        expect(w.built.length, 1);
        w.sync.dispose();
        await t.runAsync(() async {
          w.nb.dispose();
          await deleteTestFolder(w.top);
        });
      },
    );

    iosWidgets(
      'a false result blocks Microsoft and WebDAV both, until a retry succeeds',
      (t) async {
        var fail = true;
        final c = cleaner(
          delete: () async {
            log.add('delete');
            deletes++;
            if (fail) throw StateError('keychain');
          },
        );
        final store = MemoryTokenStore();
        final ms = account(store);
        addTearDown(ms.dispose);
        late WebDavWorld w;
        await t.runAsync(() async {
          w = await WebDavWorld.create(saveConnection: true);
          w.keychain = c.cleanKeychainOnce;
          await ms.start(settings: AppSettings(file), cleaner: c);
          await w.sync.start();
        });
        expect(ms.state, AuthState.signedOut);
        expect(w.log, ['keychain'], reason: 'no WebDAV secret is read');
        expect(w.built, isEmpty);
        await t.runAsync(ms.signIn);
        expect(ms.error, "Noted couldn't prepare sign-in. Try again.");
        expect(store.values, isEmpty, reason: 'no Microsoft secret is written');

        // The next Microsoft sign-in runs the step again, and WebDAV's Check now
        // finds it done: one delete that worked, none repeated.
        fail = false;
        await t.runAsync(ms.signIn);
        expect(ms.error, isNull);
        expect(ms.state, AuthState.signedIn);
        await t.runAsync(() => w.sync.checkNow());
        await t.pump();
        expect(w.built.length, 1);
        expect(w.log, ['keychain', 'keychain', 'store.read']);
        expect(log.where((e) => e == 'delete').length, greaterThanOrEqualTo(2));
        expect(AppSettings(file).keychainCleaned, isTrue);
        w.sync.dispose();
        await t.runAsync(() async {
          w.nb.dispose();
          await deleteTestFolder(w.top);
        });
      },
    );

    iosWidgets('Microsoft and WebDAV start together on one clean-up', (
      t,
    ) async {
      final c = cleaner();
      final ms = account(MemoryTokenStore());
      addTearDown(ms.dispose);
      late WebDavWorld w;
      late Future<void> msStart;
      late Future<void> davStart;
      await t.runAsync(() async {
        gate =
            Completer<void>(); // made in the real zone: it is completed there
        w = await dav(t, c);
        // What onOwned does: start the step, then Microsoft; WebDAV starts with the notebook.
        unawaited(c.cleanKeychainOnce());
        msStart = ms.start(settings: AppSettings(file), cleaner: c);
        davStart = w.sync.start();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(w.log, ['keychain'], reason: 'WebDAV waits for the step');
        gate!.complete();
        await Future.wait([msStart, davStart]);
      });
      expect(deletes, 1);
      expect(w.log, ['keychain', 'store.read']);
      w.sync.dispose();
      await t.runAsync(() async {
        w.nb.dispose();
        await deleteTestFolder(w.top);
      });
    });
  });
}
