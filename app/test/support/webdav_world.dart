// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Shared pieces of the WebDAV app tests: a token store that logs what it is
// asked, a world (folders, notebook, controller) built on real files and the
// noted_sync tests' fake WebDAV server, and the client factory that lets a test
// reach that server over plain loopback http (the app never does).

import 'dart:convert';
import 'dart:io';

import 'package:noted/main.dart';
import 'package:noted/src/cloud_sync.dart';
import 'package:noted/src/device_storage.dart';
import 'package:noted/src/webdav_sync.dart';
import 'package:noted_auth/noted_auth.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_sync/noted_sync.dart';

import '../../../packages/noted_sync/test/fake_webdav.dart';
import 'onedrive_world.dart';

/// A [MemoryTokenStore] that logs every call, in order, into [log].
class SpyTokenStore implements TokenStore {
  SpyTokenStore(this.log);

  final List<String> log;
  final MemoryTokenStore inner = MemoryTokenStore();

  /// Called before every write.
  void Function()? onWrite;

  /// While set, a read waits for it (made in the real zone).
  Future<void>? readGate;

  @override
  Future<String?> read(String key) async {
    log.add('store.read');
    await readGate;
    return inner.read(key);
  }

  @override
  Future<void> write(String key, String value) {
    log.add('store.write');
    onWrite?.call();
    return inner.write(key, value);
  }

  @override
  Future<void> delete(String key) {
    log.add('store.delete');
    return inner.delete(key);
  }
}

/// The client of a test: loopback http is allowed here and nowhere in the app.
WebDavClient loopbackClient(Uri root, String user, String password) =>
    WebDavClient(
      root: root,
      user: user,
      password: password,
      allowLoopbackHttp: true,
    );

/// A page id used for the page that sits in the WebDAV folder.
const String webDavPageId = 'dddd000000000001';

/// The address a world with no server is connected to.
const String webDavNoServerUrl = 'https://dav.example.test/dav/Notes/';

/// Folders, a notebook and a controller on real files. Build it inside
/// `tester.runAsync` in a widget test.
class WebDavWorld {
  WebDavWorld._();

  late final Directory top;
  late final Directory workingRoot;
  late final Directory support;
  late final Directory pages;
  late final SpyNotebook nb;
  late final WebDavSync sync;
  FakeWebDav? fake;
  final List<String> log = [];
  late final SpyTokenStore store = SpyTokenStore(log);
  final FakeRunner runner = FakeRunner();

  /// What the keychain step says; counted in [keychainCalls].
  Future<bool> Function() keychain = () async => true;
  int keychainCalls = 0;

  /// While true, building a runner throws.
  bool failRunner = false;

  /// What the controller built its runners with.
  final List<WebDavConnection> built = [];
  final List<String> builtPasswords = [];

  /// The connection a test saved before the start.
  WebDavConnection? saved;

  Directory get stateDir =>
      webDavStateDir(support, saved!.accountKey, saved!.rootKey);
  Directory get workingCopy =>
      webDavWorkingCopy(workingRoot, saved!.accountKey, saved!.rootKey);

  /// [server]: start the fake WebDAV server; [saveConnection]: a connection and
  /// its password are saved before the controller starts (to [webDavNoServerUrl],
  /// or to the folder `Noted` of the server); [connectionText]: the content of
  /// `connection.json` instead; [password]: the saved password (null: none).
  static Future<WebDavWorld> create({
    bool server = false,
    bool saveConnection = false,
    String? connectionText,
    String? password = 'app-password',
    bool pageInFolder = false,
    Duration pollOpen = cloudPollOpen,
    Duration pollIdle = cloudPollIdle,
    DateTime Function()? now,
    bool realRunner = false,
  }) async {
    final w = WebDavWorld._();
    w.top = await Directory.systemTemp.createTemp('noted_webdav');
    w.workingRoot = await Directory('${w.top.path}/webdav').create();
    w.support = await Directory('${w.top.path}/support').create();
    w.pages = await Directory('${w.top.path}/pages').create();
    if (server) {
      final f = w.fake = await FakeWebDav.start();
      f.addFolder('Noted');
    }
    if (saveConnection || connectionText != null) {
      final url = server
          ? normalizeWebDavUrl(w.fake!.urlOf('Noted'))
          : webDavNoServerUrl;
      final conn = WebDavConnection(
        url: url,
        user: FakeWebDav.user,
        idKind: DavIdKind.path,
        rootId: '/',
        path: 'Noted',
      );
      w.saved = conn;
      final file = webDavConnectionFile(
        webDavStateDir(w.support, conn.accountKey, conn.rootKey),
      );
      await file.parent.create(recursive: true);
      await file.writeAsString(connectionText ?? jsonEncode(conn.toJson()));
      if (password != null) {
        await w.store.inner.write(conn.passwordKey, password);
      }
      if (pageInFolder) {
        await w.workingCopy.create(recursive: true);
        final page = NotedPage.create(
          PageMeta.create(id: webDavPageId, title: 'From WebDAV', order: 1),
        );
        await File('${w.workingCopy.path}/$webDavPageId.canvas')
            .writeAsString(writePage(page));
      }
    }
    w.nb = SpyNotebook(
      PageStore(w.pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${w.top.path}/app/binders.json'),
      readOnlyRoots: [w.workingRoot.path, '${w.top.path}/onedrive'],
      readOnlyRootNames: {w.workingRoot.path: 'WebDAV'},
      watchFiles: false,
      folderCheckInterval: Duration.zero,
    );
    await w.nb.load();
    w.sync = WebDavSync(
      notebook: w.nb,
      workingRoot: w.workingRoot,
      support: w.support,
      store: w.store,
      keychainReady: () {
        w.keychainCalls++;
        w.log.add('keychain');
        return w.keychain();
      },
      clientFactory: loopbackClient,
      now: now,
      pollOpen: pollOpen,
      pollIdle: pollIdle,
      runnerFactory:
          ({
            required workingCopy,
            required stateDir,
            required connection,
            required password,
          }) {
            if (w.failRunner) throw StateError('no runner');
            w.built.add(connection);
            w.builtPasswords.add(password);
            if (!realRunner) return w.runner;
            final client = loopbackClient(
              connection.uri,
              connection.user,
              password,
            );
            return EngineRunner(
              PullEngine(
                workingCopy: workingCopy,
                stateDir: stateDir,
                locks: w.nb.folderLocks,
                driver: WebDavDriver(
                  client: client,
                  idKind: connection.idKind,
                  rootId: connection.rootId,
                ),
              ),
            );
          },
    );
    return w;
  }

  Future<void> close() async {
    sync.dispose();
    nb.dispose();
    await fake?.close();
    await top.delete(recursive: true);
  }
}
