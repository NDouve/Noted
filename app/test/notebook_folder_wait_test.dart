// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'support/busy_retry.dart';

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late Directory root;
  late Directory pages;
  late Notebook nb;
  late FolderLocks locks;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_folderwait');
    pages = await Directory('${root.path}${Platform.pathSeparator}pages').create();
    locks = FolderLocks();
    nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: const Duration(hours: 1),
      folderLocks: locks,
      // A short stand-in for the 3 seconds, so the test needs no fake clock.
      folderWaitNote: const Duration(milliseconds: 400),
    );
    await nb.load();
  });

  tearDown(() async {
    nb.dispose();
    await busyRetry(() => root.delete(recursive: true));
  });

  int pageFiles() => pages.listSync().where((e) => e.path.endsWith('.canvas')).length;

  test('the note shows after the wait limit, not before, and clears when the job ends', () async {
    final seen = <bool>[];
    nb.waitingForFolder.addListener(() => seen.add(nb.waitingForFolder.value));
    final gate = Completer<void>();
    final held = locks.run(pages, () => gate.future);
    final create = nb.createPage();
    await _wait(150);
    expect(nb.waitingForFolder.value, isFalse);
    await _wait(500);
    expect(nb.waitingForFolder.value, isTrue);
    gate.complete();
    await held;
    await create.timeout(const Duration(seconds: 10));
    expect(nb.waitingForFolder.value, isFalse);
    expect(seen, [true, false]);
  });

  test('a short wait shows nothing', () async {
    final seen = <bool>[];
    nb.waitingForFolder.addListener(() => seen.add(nb.waitingForFolder.value));
    final gate = Completer<void>();
    final held = locks.run(pages, () => gate.future);
    final create = nb.createPage();
    await _wait(100);
    gate.complete();
    await held;
    await create.timeout(const Duration(seconds: 10));
    await _wait(600);
    expect(seen, isEmpty);
  });

  test('two New page calls during a stall make one page', () async {
    final before = pageFiles();
    final gate = Completer<void>();
    final held = locks.run(pages, () => gate.future);
    final a = nb.createPage();
    final b = nb.createPage();
    await _wait(100);
    gate.complete();
    await held;
    final ids = await Future.wait([a, b]).timeout(const Duration(seconds: 10));
    expect(ids[0], ids[1]);
    expect(pageFiles(), before + 1);
  });

  test('a New page after the first finished makes a second page', () async {
    final before = pageFiles();
    final first = await nb.createPage();
    final second = await nb.createPage();
    expect(second, isNot(first));
    expect(pageFiles(), before + 2);
  });
}
