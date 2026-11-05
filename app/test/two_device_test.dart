// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Two notebooks on one shared folder, with real watchers: what one makes the
// other finds (the two-PC symptom of 0050). Each has its own binders.json,
// settings and recovery folder; the shared folder is both the default page
// folder and the default binder folder. Every wait is a condition wait with a
// time limit, never a fixed delay (the folder interval is 200 ms, so the
// backstop pass, every 10th tick, absorbs a late watcher event on any OS).
//
// Determinism: a notebook is flushed and idle before the step where the other
// scans or adds, and pages written into a binder while it is being added are
// written by the test with exclusive creates, never by a notebook's replace,
// so the scan of the adding notebook never meets a set-aside file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/busy_retry.dart';

void main() {
  late Directory base;
  late Directory shared;
  late List<Notebook> opened;
  late ModuleRegistry modules;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('noted_two_device');
    shared = await Directory('${base.path}/shared').create();
    modules = buildModules();
    opened = [];
  });

  tearDown(() async {
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    await busyRetry(() => base.delete(recursive: true));
  });

  Notebook make(String name) {
    final nb = Notebook(
      PageStore(shared),
      modules,
      saveDelay: Duration.zero,
      bindersFile: File('${base.path}/$name/binders.json'),
      recoveryDirectory: Directory('${base.path}/$name/rec'),
      settings: AppSettings(null)..defaultBinderFolder = shared.path,
      watchFiles: true,
      watchDebounce: const Duration(milliseconds: 50),
      folderCheckInterval: const Duration(milliseconds: 200),
      discoveryDebounce: const Duration(milliseconds: 100),
    );
    opened.add(nb);
    return nb;
  }

  // Waits until [condition] holds, polling; fails with [what] after [limit].
  Future<void> until(bool Function() condition, String what, {Duration limit = const Duration(seconds: 30)}) async {
    final end = DateTime.now().add(limit);
    while (!condition()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for: $what');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  BinderSection? listed(Notebook nb, String title) {
    for (final b in nb.binders) {
      if (b.available && b.title == title) return b;
    }
    return null;
  }

  Future<(Notebook, Notebook)> twoOf() async {
    final a = make('a');
    await a.load();
    await a.flush();
    final b = make('b');
    await b.load();
    await b.discoveryIdle;
    return (a, b);
  }

  const timeout = Timeout(Duration(minutes: 2));

  test('1: a standalone page made on A shows on B', () async {
    final (a, b) = await twoOf();
    final id = await a.createPage();
    await a.rename(id, 'From A');
    await a.flush();
    await until(() => b.pageTitleOf(id) == 'From A', 'B lists the page');
  }, timeout: timeout);

  test('2: a binder made on A is listed on B without Open binder', () async {
    final (a, b) = await twoOf();
    await a.createBinder(name: 'Shared binder');
    await a.flush();
    await until(() => listed(b, 'Shared binder') != null, 'B lists the binder');
    expect(b.binders, hasLength(1));
    expect(listed(b, 'Shared binder')!.binder!.id, listed(a, 'Shared binder')!.binder!.id);
  }, timeout: timeout);

  test('3: pages written into a binder while B adds it are all listed on B, without a restart', () async {
    final (a, b) = await twoOf();
    final made = await a.createBinder(name: 'Trickle');
    await a.flush();
    final store = PageStore(Directory(made.path));
    const count = 12;
    final ids = [for (var i = 0; i < count; i++) 'c${i.toString().padLeft(15, '0')}'];
    // Written with exclusive creates, a few at a time, while B looks.
    for (final id in ids) {
      expect(await store.saveNew(NotedPage.create(PageMeta.create(id: id, title: 'Page $id', order: 0))), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    await until(() => listed(b, 'Trickle') != null, 'B lists the binder');
    await until(() => ids.every((id) => b.pageTitleOf(id) != null), 'B lists every page of the binder');
  }, timeout: timeout);

  test('4: a page B adds to A\'s binder shows on A', () async {
    final (a, b) = await twoOf();
    await a.createBinder(name: 'Together');
    await a.flush();
    await until(() => listed(b, 'Together') != null, 'B lists the binder');
    final id = await b.createPage(binderPath: listed(b, 'Together')!.path);
    await b.rename(id, 'From B');
    await b.flush();
    await until(() => a.pageTitleOf(id) == 'From B', 'A lists the page');
  }, timeout: timeout);

  test('5: a binder B removed stays removed on B after a restart; A still lists it with its pages', () async {
    final (a, b) = await twoOf();
    final made = await a.createBinder(name: 'Keep on A');
    final pageId = await a.createPage(binderPath: made.path);
    await a.flush();
    await until(() => listed(b, 'Keep on A') != null, 'B lists the binder');
    await until(() => b.pageTitleOf(pageId) != null, 'B lists its page');
    await b.removeBinder(listed(b, 'Keep on A')!.path);
    await b.flush();
    // B is rebuilt over the same files.
    await b.discoveryIdle;
    b.dispose();
    opened.remove(b);
    final b2 = make('b');
    await b2.load();
    await b2.discoveryIdle;
    expect(listed(b2, 'Keep on A'), isNull);
    // Control: a binder A makes afterwards is found by the rebuilt B, so the
    // watchers and the passes are running while the removed one stays out.
    await a.createBinder(name: 'Later');
    await a.flush();
    await until(() => listed(b2, 'Later') != null, 'the rebuilt B lists a later binder');
    await b2.discoverBinders();
    expect(listed(b2, 'Keep on A'), isNull);
    expect(b2.pageTitleOf(pageId), isNull);
    expect(listed(a, 'Keep on A'), isNotNull);
    expect(a.pageTitleOf(pageId), isNotNull);
  }, timeout: timeout);
}
