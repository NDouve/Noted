// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// How `main.dart` wires the OneDrive pull (sync stage 3): the read-only root,
// the one lock the notebook and the engine share, the order of the start, and
// nothing at all on desktop or without a client id. The notebook here is built
// the way a device builds it, by `buildAppNotebook` under the iOS override.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/device_storage.dart';
import 'package:noted/src/microsoft_account.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/onedrive_sync.dart';
import 'package:noted_core/noted_core.dart' show PageStore;

import 'support/onedrive_world.dart';

class _LogSync extends OneDriveSync {
  _LogSync(this.log, Notebook nb, MicrosoftAccount account)
    : super(
        microsoft: account,
        notebook: nb,
        workingRoot: Directory.systemTemp,
        support: Directory.systemTemp,
        folders: FakeFolders(),
        runnerFactory: ({required workingCopy, required stateDir, required driveId, required rootItemId}) =>
            FakeRunner(),
      );

  final List<String> log;

  @override
  Future<void> start() {
    log.add('sync.start');
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
  late Directory top;
  late Directory documents;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    top = await Directory.systemTemp.createTemp('noted_wiring');
    documents = await Directory('${top.path}/documents').create();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    resetDeviceStorage();
    await top.delete(recursive: true);
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
    pagesDirectory: Directory('${top.path}/documents/Noted/pages')..createSync(recursive: true),
    bindersFile: File('${top.path}/support/Noted/binders.json'),
  );

  test('on a device the OneDrive folder is a read-only root and nothing else is', () async {
    await asDevice();
    final nb = build();
    addTearDown(nb.dispose);
    final root = deviceOneDriveRoot()!;
    expect(root.path, '${documents.path}${Platform.pathSeparator}Noted${Platform.pathSeparator}onedrive');
    expect(nb.isPullOnlyLocation(root.path), isTrue);
    expect(nb.isPullOnlyLocation('${root.path}${Platform.pathSeparator}acct${Platform.pathSeparator}rootid'), isTrue);
    expect(nb.isPullOnlyLocation('${documents.path}${Platform.pathSeparator}Noted${Platform.pathSeparator}pages'), isFalse);
    expect(nb.watchFiles, isFalse);
  });

  test('on desktop nothing is read-only and there is no OneDrive pull', () async {
    final nb = build();
    addTearDown(nb.dispose);
    expect(nb.isPullOnlyLocation('${top.path}/documents/Noted/onedrive/x'), isFalse);
    final account = await signedInAccount();
    addTearDown(account.dispose);
    expect(buildOneDriveSync(nb, account), isNull);
  });

  test('a build without a client id has no pull even on a device', () async {
    await asDevice();
    final nb = build();
    addTearDown(nb.dispose);
    expect(buildOneDriveSync(nb, null), isNull);
  });

  test('the engine uses the notebook\'s own lock', () async {
    await asDevice();
    final nb = build();
    addTearDown(nb.dispose);
    final account = await signedInAccount();
    addTearDown(account.dispose);
    final sync = buildOneDriveSync(nb, account)!;
    addTearDown(sync.dispose);
    expect(sync.workingRoot.path, deviceOneDriveRoot()!.path);
    final runner = sync.runnerFactory(
      workingCopy: Directory('${top.path}/wc'),
      stateDir: Directory('${top.path}/state'),
      driveId: 'd',
      rootItemId: 'r',
    );
    addTearDown(runner.dispose);
    expect((runner as EngineRunner).engine.locks, same(nb.folderLocks));
  });

  test('the pull starts after the notebook has loaded, and only when there is one', () async {
    await asDevice();
    final order = <String>[];
    final account = await signedInAccount();
    addTearDown(account.dispose);
    final nb = _LogNotebook(
      order,
      PageStore(Directory('${top.path}/pages')..createSync()),
      buildModules(),
    );
    addTearDown(nb.dispose);
    final sync = _LogSync(order, nb, account);
    addTearDown(sync.dispose);
    Widget? shown;
    await openWhenOwned(nb, top, show: (w) => shown = w, sync: sync);
    expect(shown, isA<NotedApp>());
    expect((shown! as NotedApp).sync, same(sync));
    expect(order, ['load', 'loaded', 'sync.start']);

    // No controller: it loads and starts nothing.
    order.clear();
    final nb2 = _LogNotebook(order, PageStore(Directory('${top.path}/pages2')..createSync()), buildModules());
    addTearDown(nb2.dispose);
    await openWhenOwned(nb2, top, show: (_) {});
    expect(order, ['load', 'loaded']);
  });

  test('the release Android manifest declares INTERNET', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android.permission.INTERNET'));
  });
}
