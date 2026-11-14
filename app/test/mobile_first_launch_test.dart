// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/device_storage.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_lock.dart';
import 'package:noted/src/recovery_store.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('noted_first');
    resetDeviceStorage();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    resetDeviceStorage();
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // The recovery lock is held for the life of the process.
    }
  });

  // As on a device: the app's three folders exist and are empty.
  Future<Notebook> freshInstall(TargetPlatform platform) async {
    debugDefaultTargetPlatformOverride = platform;
    final docs = await Directory('${root.path}/docs').create();
    final cache = await Directory('${root.path}/cache').create();
    final support = await Directory('${root.path}/support').create();
    await initDeviceStorage(documents: () async => docs, cache: () async => cache, support: () async => support);
    final lock = RecoveryLock.besides(defaultRecoveryDirectory(defaultBindersFile()));
    expect(lock.acquireSync(), RecoveryLockResult.acquired);
    final nb = buildAppNotebook(recoveryLock: lock);
    addTearDown(nb.dispose);
    return nb;
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('a fresh $platform install opens a page', () async {
      final nb = await freshInstall(platform);
      await nb.load().timeout(const Duration(seconds: 20));
      expect(nb.currentId, isNotNull);
    });
  }

  testWidgets('a fresh android launch through openWhenOwned shows a page', timeout: const Timeout(Duration(seconds: 60)), (t) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final nb = (await t.runAsync(() => freshInstall(TargetPlatform.android)))!;
    Widget? shown;
    await t.runAsync(() => openWhenOwned(nb, root, show: (w) => shown = w).timeout(const Duration(seconds: 15)));
    await t.pumpWidget(shown!);
    await t.pump(const Duration(seconds: 1));
    expect(nb.currentId, isNotNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
