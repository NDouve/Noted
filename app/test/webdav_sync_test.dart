// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The WebDAV controller (run 2026-11-15-02, task 4): the connection's keys and
// file, the first checks, connecting, what it saves and where, the start and
// the keychain step, polling and disconnecting. Time is the test clock; the
// files and the fake WebDAV server are real, so the world is built inside
// `runAsync`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/device_storage.dart';
import 'package:noted/src/onedrive_sync.dart' show ChosenRoot;
import 'package:noted/src/webdav_sync.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_sync/noted_sync.dart';

import '../../packages/noted_sync/test/fake_webdav.dart';
import 'support/webdav_world.dart';

WebDavConnection _conn({
  String url = 'https://dav.example.test/dav/Notes/',
  String user = 'alice',
  DavIdKind kind = DavIdKind.path,
  String rootId = '/',
  String path = 'Notes',
}) => WebDavConnection(
  url: url,
  user: user,
  idKind: kind,
  rootId: rootId,
  path: path,
);

void main() {
  setUpAll(() => HttpOverrides.global = null);

  group('the connection', () {
    test('an address has one form: scheme and host in lower case, no default port, no query', () {
      const one = 'https://dav.example.test/dav/Notes/';
      for (final spelling in [
        'HTTPS://DAV.example.test/dav/Notes',
        'https://dav.example.test:443/dav//Notes/',
        'https://dav.example.test/dav/Notes/?x=1#top',
      ]) {
        expect(normalizeWebDavUrl(Uri.parse(spelling)), one, reason: spelling);
      }
      expect(
        normalizeWebDavUrl(Uri.parse('https://dav.example.test')),
        'https://dav.example.test/',
      );
      expect(
        normalizeWebDavUrl(Uri.parse('https://dav.example.test:8443/a b/')),
        'https://dav.example.test:8443/a%20b/',
      );
    });

    test('the keys are SHA-256: the account from origin and user, the folder from its address', () {
      final a = _conn();
      expect(a.accountKey, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(a.rootKey, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(
        _conn(path: 'Other name').accountKey,
        a.accountKey,
        reason: 'the shown path is not a key',
      );
      expect(_conn(user: 'bob').accountKey, isNot(a.accountKey));
      expect(_conn(user: 'bob').rootKey, a.rootKey);
      expect(
        _conn(url: 'https://dav.example.test/dav/Other/').rootKey,
        isNot(a.rootKey),
      );
      expect(
        _conn(url: 'https://dav.example.test/dav/Other/').accountKey,
        a.accountKey,
        reason: 'same server and user',
      );
      expect(
        _conn(url: 'https://other.example.test/dav/Notes/').accountKey,
        isNot(a.accountKey),
      );
      expect(a.passwordKey, 'webdav.password.${a.accountKey}');
    });

    test('connection.json holds the address, user, id kind, root id and path, never a password', () {
      final c = _conn(kind: DavIdKind.fileId, rootId: '00000007ocfake');
      final json = jsonEncode(c.toJson());
      expect(jsonDecode(json), {
        'url': 'https://dav.example.test/dav/Notes/',
        'user': 'alice',
        'idKind': 'fileid',
        'rootId': '00000007ocfake',
        'path': 'Notes',
      });
      final back = WebDavConnection.fromJson(jsonDecode(json))!;
      expect(back.url, c.url);
      expect(back.idKind, DavIdKind.fileId);
      expect(back.rootId, '00000007ocfake');
    });

    test('what is not a connection is refused', () {
      final good = _conn().toJson();
      expect(WebDavConnection.fromJson(good), isNotNull);
      expect(WebDavConnection.fromJson('x'), isNull);
      for (final bad in [
        {...good, 'user': ''},
        {...good, 'idKind': 'guess'},
        {...good, 'rootId': ''},
        {
          ...good,
          'url': 'https://dav.example.test/dav/Notes',
        }, // not in its one form
        {...good, 'url': 'not an address'},
        {...good}..remove('path'),
      ]) {
        expect(WebDavConnection.fromJson(bad), isNull, reason: '$bad');
      }
    });

    test('the working copy and the state folder are below their roots, by the two keys', () {
      final c = _conn();
      final wc = webDavWorkingCopy(
        Directory('/d/Noted/webdav'),
        c.accountKey,
        c.rootKey,
      );
      expect(
        wc.path.replaceAll(r'\', '/'),
        '/d/Noted/webdav/${c.accountKey}/${c.rootKey}',
      );
      final st = webDavStateDir(Directory('/s/Noted'), c.accountKey, c.rootKey);
      expect(
        st.path.replaceAll(r'\', '/'),
        '/s/Noted/webdav/${c.accountKey}/${c.rootKey}',
      );
      expect(
        webDavConnectionFile(st).path.replaceAll(r'\', '/'),
        endsWith('/${c.rootKey}/connection.json'),
      );
    });
  });

  group('with a world', () {
    late WebDavWorld w;

    Future<void> build(
      WidgetTester t, {
      bool server = false,
      bool saveConnection = false,
      String? connectionText,
      String? password = 'app-password',
      bool pageInFolder = false,
    }) async {
      await t.runAsync(() async {
        w = await WebDavWorld.create(
          server: server,
          saveConnection: saveConnection,
          connectionText: connectionText,
          password: password,
          pageInFolder: pageInFolder,
        );
      });
    }

    void sTest(String name, Future<void> Function(WidgetTester t) body) {
      testWidgets(name, (t) async {
        try {
          await body(t);
        } finally {
          w.sync.dispose();
          await t.runAsync(() async {
            w.nb.dispose();
            await w.fake?.close();
            await w.top.delete(recursive: true);
          });
        }
      });
    }

    Future<void> start(WidgetTester t) async {
      await t.runAsync(() => w.sync.start());
      await t.pump();
    }

    Future<void> settle(WidgetTester t) async {
      await t.pump();
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump();
    }

    Future<void> foregroundAgain(WidgetTester t) async {
      w.sync.didChangeAppLifecycleState(AppLifecycleState.paused);
      w.sync.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settle(t);
    }

    String address() => w.fake!.urlOf('').toString();

    // The form's three steps against the fake server: check, pick the first
    // folder, connect. Returns what connect says.
    Future<String?> connectToFirstFolder(
      WidgetTester t, {
      String? password,
    }) async {
      final r = await t.runAsync(() async {
        final login = await w.sync.checkLogin(
          address: address(),
          user: FakeWebDav.user,
          password: password ?? w.fake!.password,
        );
        try {
          final folders = await login.source.listFolders();
          return await w.sync.connect(
            login,
            ChosenRoot(
              driveId: webDavPickerDriveId,
              itemId: folders.first.id,
              path: folders.first.name!,
            ),
          );
        } finally {
          login.close();
        }
      });
      await t.pump();
      return r;
    }

    Future<WebDavLoginException?> loginFails(
      WidgetTester t, {
      String? address,
      String user = FakeWebDav.user,
      String password = 'app-password',
    }) async {
      return await t.runAsync<WebDavLoginException?>(() async {
        try {
          final login = await w.sync.checkLogin(
            address: address ?? w.fake!.urlOf('').toString(),
            user: user,
            password: password,
          );
          login.close();
          return null;
        } on WebDavLoginException catch (e) {
          return e;
        }
      });
    }

    group('the first checks', () {
      sTest(
        'a server that accepts the password gives a browser of its folders',
        (t) async {
          await build(t, server: true);
          await t.runAsync(() async {
            w.fake!.addFile('Noted/$webDavPageId.canvas', utf8.encode('{}'));
            w.fake!.addFolder('Other/Deep');
            final login = await w.sync.checkLogin(
              address: address(),
              user: FakeWebDav.user,
              password: 'app-password',
            );
            try {
              final top = await login.source.listFolders();
              expect(top.map((f) => f.name), ['Noted', 'Other']);
              expect(
                top.every(
                  (f) => f.driveId == webDavPickerDriveId && f.isFolder,
                ),
                isTrue,
              );
              final hint = await login.source.folderHint('Noted');
              expect(hint.canvasCount, 1);
              expect(hint.holdsBinderFile, isFalse);
              expect(
                (await login.source.listFolders(parentItemId: 'Other'))
                    .map((f) => f.name),
                ['Deep'],
              );
            } finally {
              login.close();
            }
          });
          expect(
            w.log.where((e) => e == 'store.write'),
            isEmpty,
            reason: 'nothing is saved by the checks',
          );
          expect(w.keychainCalls, 1);
        },
      );

      sTest('a wrong password is said in plain words and nothing is saved', (
        t,
      ) async {
        await build(t, server: true);
        final e = await loginFails(t, password: 'wrong');
        expect(e!.message, 'WebDAV refused the user name or password.');
        expect(w.store.inner.values, isEmpty);
      });

      sTest('a server that is not WebDAV is refused', (t) async {
        await build(t, server: true);
        w.fake!.omitDavHeader = true;
        expect(
          (await loginFails(t))!.message,
          'This address is not a WebDAV server.',
        );
      });

      sTest(
        'plain http is refused, and so is an address with a user name in it',
        (t) async {
          await build(t);
          expect(
            (await loginFails(
              t,
              address: 'http://dav.example.test/dav/',
            ))!.message,
            'WebDAV needs an https address.',
          );
          expect(
            (await loginFails(
              t,
              address: 'https://alice:secret@dav.example.test/dav/',
            ))!.message,
            'The address must not hold a user name.',
          );
        },
      );

      sTest('an empty address, user or password is asked for', (t) async {
        await build(t);
        expect(
          (await loginFails(t, address: ' '))!.message,
          startsWith('Enter the server address'),
        );
        expect(
          (await loginFails(t, address: 'dav.example.test/dav'))!.message,
          startsWith('Enter the server address'),
        );
        expect(
          (await loginFails(
            t,
            address: 'https://dav.example.test/',
            user: ' ',
          ))!.message,
          'Enter the user name.',
        );
        expect(
          (await loginFails(
            t,
            address: 'https://dav.example.test/',
            password: '',
          ))!.message,
          'Enter the app password.',
        );
        expect(
          w.keychainCalls,
          0,
          reason: 'the form is checked before anything else',
        );
      });

      sTest('the address must be a folder', (t) async {
        await build(t, server: true);
        await t.runAsync(() async => w.fake!.addFile('note.txt', [1]));
        expect(
          (await loginFails(
            t,
            address: w.fake!.urlOf('note.txt').toString(),
          ))?.message,
          isNotNull,
        );
      });

      sTest(
        'a keychain step that is not done refuses the connect before the server is asked',
        (t) async {
          await build(t, server: true);
          w.keychain = () async => false;
          final e = await loginFails(t);
          expect(
            e!.message,
            "Noted couldn't prepare the secure storage. Try again.",
          );
          expect(w.fake!.requests, isEmpty);
          // The next connect runs the step again.
          w.keychain = () async => true;
          expect(await loginFails(t), isNull);
          expect(w.keychainCalls, 2);
        },
      );
    });

    group('connecting', () {
      sTest(
        'saves the password, then connection.json without it, adds the folder and pulls',
        (t) async {
          await build(t, server: true);
          await t.runAsync(
            () async => w.fake!.addFile(
              'Noted/$webDavPageId.canvas',
              utf8.encode('{}'),
            ),
          );
          await start(t);
          expect(w.sync.canConnect, isTrue);
          final conn = _conn(
            url: normalizeWebDavUrl(w.fake!.urlOf('Noted')),
            path: 'Noted',
          );
          final file = webDavConnectionFile(
            webDavStateDir(w.support, conn.accountKey, conn.rootKey),
          );
          var fileThere = true;
          w.store.onWrite = () => fileThere = file.existsSync();

          expect(await connectToFirstFolder(t), isNull);

          expect(fileThere, isFalse, reason: 'the password goes first');
          expect(w.store.inner.values, {conn.passwordKey: 'app-password'});
          final text = file.readAsStringSync();
          expect(text, isNot(contains('app-password')));
          final saved = WebDavConnection.fromJson(jsonDecode(text))!;
          expect(saved.url, conn.url);
          expect(saved.user, 'alice');
          expect(saved.idKind, DavIdKind.path);
          expect(saved.rootId, '/');
          expect(saved.path, 'Noted');
          expect(File('${file.path}.tmp').existsSync(), isFalse);
          expect(w.sync.connection!.path, 'Noted');
          expect(w.sync.canConnect, isFalse);
          expect(
            w.sync.workingCopy!.path,
            webDavWorkingCopy(
              w.workingRoot,
              conn.accountKey,
              conn.rootKey,
            ).path,
          );
          expect(w.nb.standaloneFolders.length, 1);
          expect(w.built.single.url, conn.url);
          expect(w.builtPasswords.single, 'app-password');
          expect(w.runner.rounds, 1);
          expect(w.sync.statusLine, startsWith('Up to date'));
        },
      );

      sTest(
        'a server that reports no file versions is refused, and nothing is saved',
        (t) async {
          await build(t, server: true);
          await t.runAsync(
            () async => w.fake!.addFile('Noted/a.canvas', utf8.encode('{}')),
          );
          w.fake!.omitEtags = true;
          await start(t);
          expect(
            await connectToFirstFolder(t),
            "This server doesn't report file versions.",
          );
          expect(w.store.inner.values, isEmpty);
          expect(Directory('${w.support.path}/webdav').existsSync(), isFalse);
          expect(w.built, isEmpty);
          expect(w.nb.standaloneFolders, isEmpty);
          expect(w.sync.canConnect, isTrue, reason: 'the form stays');
        },
      );

      sTest('a folder that cannot be saved to leaves no password behind', (
        t,
      ) async {
        await build(t, server: true);
        await start(t);
        // The state folder's parent is a file: nothing can be made there.
        File('${w.support.path}/webdav').writeAsStringSync('x');
        expect(
          await connectToFirstFolder(t),
          "The connection couldn't be saved on this device.",
        );
        expect(w.store.inner.values, isEmpty);
        expect(w.sync.connection, isNull);
        expect(w.built, isEmpty);
      });

      sTest('the keychain step is awaited again before the secret is written', (
        t,
      ) async {
        await build(t, server: true);
        await start(t);
        var calls = 0;
        w.keychain = () async =>
            ++calls != 2; // the check passes, the write does not
        expect(
          await connectToFirstFolder(t),
          "Noted couldn't prepare the secure storage. Try again.",
        );
        expect(w.store.inner.values, isEmpty);
        expect(w.log, isNot(contains('store.write')));
      });

      sTest('a second connection is refused while one exists', (t) async {
        await build(t, server: true);
        await start(t);
        expect(await connectToFirstFolder(t), isNull);
        expect(await connectToFirstFolder(t), 'WebDAV is connected already.');
        expect(w.built.length, 1);
      });

      sTest(
        'with oc:fileid ids the connection keeps that kind and the folder id',
        (t) async {
          await build(t, server: true);
          w.fake!.ids = FakeDavIds.ocFileId;
          await t.runAsync(
            () async => w.fake!.addFile('Noted/a.canvas', utf8.encode('{}')),
          );
          await start(t);
          expect(await connectToFirstFolder(t), isNull);
          expect(w.sync.connection!.idKind, DavIdKind.fileId);
          expect(w.sync.connection!.rootId, w.fake!.idOf('Noted'));
        },
      );
    });

    group('start', () {
      sTest(
        'a saved connection is restored after the keychain step: the folder is listed and polled',
        (t) async {
          await build(t, saveConnection: true, pageInFolder: true);
          await start(t);
          expect(
            w.log.indexOf('keychain'),
            lessThan(w.log.indexOf('store.read')),
          );
          expect(w.built.single.url, webDavNoServerUrl);
          expect(w.builtPasswords.single, 'app-password');
          expect(w.nb.pageTitleOf(webDavPageId), 'From WebDAV');
          expect(w.nb.isPullOnlyPage(webDavPageId), isTrue);
          expect(
            w.nb.pullOnlyMessageFor(w.workingCopy.path),
            'This WebDAV folder is read-only on this device for now.',
          );
          expect(w.runner.rounds, 1, reason: 'a launch polls');
          await t.runAsync(() => w.sync.start());
          expect(w.runner.rounds, 1, reason: 'start is idempotent');
        },
      );

      sTest('no connection: nothing starts and the form is offered', (t) async {
        await build(t);
        await start(t);
        expect(w.sync.connection, isNull);
        expect(w.sync.canConnect, isTrue);
        expect(w.runner.rounds, 0);
        expect(w.log, isEmpty, reason: 'no secret is touched');
        expect(w.nb.standaloneFolders, isEmpty);
      });

      sTest('a missing password pauses with a way out', (t) async {
        await build(t, saveConnection: true, password: null);
        await start(t);
        expect(w.built, isEmpty);
        expect(w.sync.statusLine, contains('password is missing'));
        expect(w.runner.rounds, 0);
        expect(w.sync.canConnect, isFalse);
      });

      sTest(
        'a connection file that cannot be read pauses and is never overwritten',
        (t) async {
          await build(t, saveConnection: true, connectionText: '{ not json');
          await start(t);
          expect(w.sync.connectionUnreadable, isTrue);
          expect(w.sync.canConnect, isFalse);
          expect(w.sync.statusLine, contains("can't be read"));
          expect(w.built, isEmpty);
          expect(w.log, isNot(contains('store.read')));
          expect(
            webDavConnectionFile(w.stateDir).readAsStringSync(),
            '{ not json',
          );
        },
      );

      sTest(
        'a connection file in the wrong folder is not ours: paused, left alone',
        (t) async {
          await build(t, saveConnection: true);
          final f = webDavConnectionFile(w.stateDir);
          final moved = File(
            '${w.support.path}/webdav/${w.saved!.accountKey}/not-the-root-key/connection.json',
          );
          await t.runAsync(() async {
            await moved.parent.create(recursive: true);
            await f.rename(moved.path);
          });
          await start(t);
          expect(w.sync.connectionUnreadable, isTrue);
          expect(moved.existsSync(), isTrue);
          expect(w.built, isEmpty);
        },
      );

      sTest(
        'a keychain step that is not done blocks the read, and Check now retries it',
        (t) async {
          await build(t, saveConnection: true);
          w.keychain = () async => false;
          await start(t);
          expect(w.log, ['keychain'], reason: 'the password is not read');
          expect(w.sync.statusLine, "Paused: the secure storage isn't ready");
          expect(w.runner.rounds, 0);
          w.keychain = () async => true;
          await t.runAsync(() => w.sync.checkNow());
          await settle(t);
          expect(w.log, ['keychain', 'keychain', 'store.read']);
          expect(w.built.length, 1);
          expect(w.runner.rounds, 1);
        },
      );

      sTest('a keychain step that throws counts as not done', (t) async {
        await build(t, saveConnection: true);
        w.keychain = () async => throw StateError('keychain');
        await start(t);
        expect(w.log, ['keychain']);
        expect(w.sync.hasProblem, isTrue);
      });

      sTest('the folder is not made again once its journal exists', (t) async {
        await build(t, saveConnection: true);
        await t.runAsync(() async {
          final j = syncJournalFile(w.stateDir);
          await j.parent.create(recursive: true);
          await j.writeAsString('{}');
        });
        await start(t);
        expect(
          w.sync.statusLine,
          'Paused: the WebDAV folder is missing on this device',
        );
        expect(w.workingCopy.existsSync(), isFalse);
        expect(w.built, isEmpty);
      });
    });

    group('polling', () {
      sTest('5 min with no WebDAV page open', (t) async {
        await build(t, saveConnection: true);
        await start(t);
        await foregroundAgain(t);
        final base = w.runner.rounds;
        await t.pump(const Duration(minutes: 4, seconds: 59));
        expect(w.runner.rounds, base);
        await t.pump(const Duration(seconds: 1));
        expect(w.runner.rounds, base + 1);
      });

      sTest('10 s with a page of the WebDAV folder open', (t) async {
        await build(t, saveConnection: true, pageInFolder: true);
        await start(t);
        await t.runAsync(() => w.nb.open(webDavPageId));
        await foregroundAgain(t);
        final base = w.runner.rounds;
        await t.pump(const Duration(seconds: 9));
        expect(w.runner.rounds, base);
        await t.pump(const Duration(seconds: 1));
        expect(w.runner.rounds, base + 1);
        await t.pump(const Duration(seconds: 10));
        expect(w.runner.rounds, base + 2);
      });

      sTest('a page of another provider\'s folder does not speed this one up', (
        t,
      ) async {
        await build(t, saveConnection: true);
        final other = Directory('${w.top.path}/onedrive/acct/root');
        await start(t);
        await t.runAsync(() async {
          await other.create(recursive: true);
          final page = NotedPage.create(
            PageMeta.create(
              id: 'eeee000000000001',
              title: 'Elsewhere',
              order: 1,
            ),
          );
          await File('${other.path}/eeee000000000001.canvas')
              .writeAsString(writePage(page));
          await w.nb.addStandaloneFolder(other.path);
          await w.nb.open('eeee000000000001');
        });
        expect(w.nb.isPullOnlyPage('eeee000000000001'), isTrue);
        await foregroundAgain(t);
        final base = w.runner.rounds;
        await t.pump(const Duration(seconds: 30));
        expect(w.runner.rounds, base, reason: 'still the 5 minute tick');
      });

      sTest('timers stop in the background', (t) async {
        await build(t, saveConnection: true, pageInFolder: true);
        await start(t);
        await t.runAsync(() => w.nb.open(webDavPageId));
        await foregroundAgain(t);
        w.sync.didChangeAppLifecycleState(AppLifecycleState.paused);
        final base = w.runner.rounds;
        await t.pump(const Duration(hours: 1));
        expect(w.runner.rounds, base);
      });

      sTest(
        'what a round changed is told to the notebook, then the folder check and discovery',
        (t) async {
          await build(t, saveConnection: true, pageInFolder: true);
          await start(t);
          w.nb.log.clear();
          final path = '${w.workingCopy.path}/$webDavPageId.canvas';
          w.runner.next = () => RoundResult()..changedPaths.add(path);
          await w.sync.checkNow();
          expect(w.nb.changedPaths.last, [path]);
          expect(w.nb.log, ['filesChanged', 'checkFolders', 'discoverBinders']);
        },
      );

      sTest('the guard\'s answer goes to the pull that asked', (t) async {
        await build(t, saveConnection: true);
        final q = GuardQuestion(['a.canvas']);
        w.runner.guardQuestion = q;
        await start(t);
        expect(w.sync.guardQuestion, q);
        final source = w.sync.guardSource;
        expect(source, isNotNull);
        expect(
          await t.runAsync(
            () => w.sync.answerGuard(q, remove: false, source: source),
          ),
          isTrue,
        );
        expect(w.runner.answers, [(q, false)]);
        expect(
          await t.runAsync(
            () => w.sync.answerGuard(q, remove: false, source: Object()),
          ),
          isFalse,
        );
      });
    });

    group('disconnecting', () {
      sTest(
        'forgets the password and the connection file, keeps the folder and the journal, and stops polling',
        (t) async {
          await build(t, saveConnection: true, pageInFolder: true);
          await start(t);
          final journal = syncJournalFile(w.stateDir);
          await t.runAsync(() async {
            await journal.parent.create(recursive: true);
            await journal.writeAsString('{}');
          });
          await t.runAsync(() => w.sync.disconnect());
          expect(w.store.inner.values, isEmpty);
          expect(webDavConnectionFile(w.stateDir).existsSync(), isFalse);
          expect(w.workingCopy.existsSync(), isTrue);
          expect(
            File('${w.workingCopy.path}/$webDavPageId.canvas').existsSync(),
            isTrue,
          );
          expect(journal.existsSync(), isTrue);
          expect(w.sync.connection, isNull);
          expect(w.sync.canConnect, isTrue);
          final base = w.runner.rounds;
          await t.pump(const Duration(hours: 1));
          expect(w.runner.rounds, base);
        },
      );

      sTest('connecting again to the same folder uses the same working copy', (
        t,
      ) async {
        await build(t, server: true);
        await start(t);
        expect(await connectToFirstFolder(t), isNull);
        final first = w.sync.workingCopy!.path;
        await t.runAsync(() => w.sync.disconnect());
        expect(await connectToFirstFolder(t), isNull);
        expect(w.sync.workingCopy!.path, first);
        expect(w.built.length, 2);
      });
    });
  });
}
