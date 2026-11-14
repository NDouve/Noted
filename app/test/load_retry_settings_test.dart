// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

// A Retry of a load that failed after the binder list was settled: the lists
// are rebuilt, so nothing may be written from them and no AI write may run
// until that load succeeds.
// A store whose new-page writes fail while [failWrite] is set.
class _ReadStore extends PageStore {
  _ReadStore(super.directory);

  bool failWrite = false;

  @override
  Future<bool> saveNewText(NotedPage page, String text, {Future<void> Function()? beforePublish}) async {
    if (failWrite) throw const FileSystemException('late failure');
    return super.saveNewText(page, text, beforePublish: beforePublish);
  }
}

void main() {
  late Directory dir;
  late File listFile;
  late String binderPath;

  Notebook make([PageStore? store]) => Notebook(
    store ?? PageStore(Directory('${dir.path}/pages')..createSync()),
    buildModules(),
    saveDelay: Duration.zero,
    bindersFile: listFile,
    settingsRetryFirst: const Duration(hours: 1),
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('noted_retry_settings');
    listFile = File('${dir.path}/binders.json');
    binderPath = (await Directory('${dir.path}/b1').create()).path;
    final first = make();
    await first.load();
    await first.addBinder(Directory(binderPath).path);
    await first.flush();
    first.dispose();
    expect(listFile.readAsStringSync(), contains('b1'));
  });

  tearDown(() => dir.delete(recursive: true));

  // A second launch whose first load fails when it makes the first page of an empty
  // notebook: after the list is settled and the folder timer has started.
  Future<Notebook> failedLaunch() async {
    for (final e in Directory('${dir.path}/pages').listSync()) {
      if (e is File) e.deleteSync();
    }
    final store = _ReadStore(Directory('${dir.path}/pages'))..failWrite = true;
    final nb = make(store);
    addTearDown(nb.dispose);
    await nb.loadChecked();
    expect(nb.loadError, isNotNull);
    // Held until a load succeeds, though the list had been settled.
    expect(nb.settingsHoldForTest, 'pending');
    store.failWrite = false;
    return nb;
  }

  test('a settings save during the Retry reload writes nothing', () async {
    final nb = await failedLaunch();
    final before = listFile.readAsStringSync();
    String? during;
    nb.binderHook = (point, path) async {
      if (point != 'load-open') return;
      // The lists are empty here.
      await nb.saveSettingsForTest();
      during = listFile.readAsStringSync();
    };
    await nb.loadChecked();
    expect(nb.loadError, isNull);
    expect(during, before, reason: 'binders.json was rewritten from half-empty lists');
    expect(listFile.readAsStringSync(), before);
    expect(listFile.readAsStringSync(), contains('b1'));
  });

  test('an AI write waits for the Retry reload, then goes ahead', () async {
    final nb = await failedLaunch();
    final inside = Completer<void>();
    final release = Completer<void>();
    nb.binderHook = (point, path) async {
      if (point != 'load-open') return;
      inside.complete();
      await release.future;
    };
    final retry = nb.loadChecked();
    await inside.future;
    // The lists are being rebuilt: not loaded, though the failed load had ended.
    expect(await nb.aiWaitLoaded(const Duration(milliseconds: 100)), isFalse);
    release.complete();
    await retry;
    expect(nb.loadError, isNull);
    expect(await nb.aiWaitLoaded(const Duration(milliseconds: 100)), isTrue);
  });
}
