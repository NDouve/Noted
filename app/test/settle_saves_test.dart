// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'support/settle_saves.dart';

void main() {
  late Directory root;
  late PageStore store;
  late Notebook nb;
  late String id;

  // A notebook with the real autosave delay, with one edit made inside the
  // test's fake-time zone so its autosave timer lives there.
  Future<void> startAndEdit(WidgetTester t) async {
    await t.runAsync(() async {
      root = await Directory.systemTemp.createTemp('noted_settle_saves');
      store = PageStore(await Directory('${root.path}/pages').create());
      nb = Notebook(store, buildModules(), bindersFile: File('${root.path}/binders.json'));
      await nb.load();
      id = nb.currentId!;
    });
    nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
    expect(nb.unsavedDescription, isNotNull);
  }

  Future<void> cleanUp(WidgetTester t) => t.runAsync(() async {
    nb.dispose();
    await root.delete(recursive: true);
  });

  Future<int> boxesOnDisk(WidgetTester t) async =>
      (await t.runAsync(() async => (await store.load(id)).nodes.length))!;

  testWidgets('settleSaves lands an autosave scheduled in the fake zone', (t) async {
    await startAndEdit(t);
    expect(await boxesOnDisk(t), 0);

    await settleSaves(t, nb);

    expect(nb.unsavedDescription, isNull);
    expect(await boxesOnDisk(t), 1);
    await cleanUp(t);
  });

  testWidgets('the old teardown, flush() from runAsync, waits forever on such a save', (t) async {
    await startAndEdit(t);
    // The autosave timer fires in the fake zone, so the save starts there.
    await t.pump(nb.saveDelay + const Duration(milliseconds: 1));

    final timedOut = await t.runAsync(
      () => nb.flush().then((_) => false).timeout(const Duration(seconds: 2), onTimeout: () => true),
    );
    expect(timedOut, isTrue);

    // The helper finishes the same save.
    await settleSaves(t, nb);
    expect(await boxesOnDisk(t), 1);
    await cleanUp(t);
  });

  testWidgets('settleSaves lands a binder cover edit started in the fake zone', (t) async {
    late String path;
    await t.runAsync(() async {
      root = await Directory.systemTemp.createTemp('noted_settle_saves');
      store = PageStore(await Directory('${root.path}/pages').create());
      nb = Notebook(store, buildModules(), bindersFile: File('${root.path}/binders.json'));
      await nb.load();
      final folder = await Directory('${root.path}/Work').create();
      path = (await nb.addBinder(folder.path)).path;
    });
    unawaited(nb.updateBinder(path, title: 'Renamed'));
    expect(nb.unsavedDescription, contains('binder cover edit'));

    await settleSaves(t, nb);

    expect(nb.unsavedDescription, isNull);
    final found = await t.runAsync(() => BinderStore(Directory(path)).read());
    expect((found as BinderFound).binder.title, 'Renamed');
    await cleanUp(t);
  });

  testWidgets('settleSaves fails and names the page of a save that never finishes', (t) async {
    final stuck = Completer<void>();
    late _StuckStore stuckStore;
    await t.runAsync(() async {
      root = await Directory.systemTemp.createTemp('noted_settle_saves');
      stuckStore = _StuckStore(await Directory('${root.path}/pages').create());
      store = stuckStore;
      nb = Notebook(store, buildModules(), bindersFile: File('${root.path}/binders.json'));
      await nb.load();
      id = nb.currentId!;
    });
    stuckStore.hold = stuck.future;
    nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));

    String? message;
    try {
      await settleSaves(t, nb, limit: const Duration(milliseconds: 300));
    } on TestFailure catch (e) {
      message = e.message;
    }
    expect(message, contains('save of page $id'));
    expect(message, contains('started and not finished'));

    stuck.complete();
    stuckStore.hold = null;
    await settleSaves(t, nb);
    await cleanUp(t);
  });
}

// A store whose saves wait for [hold], to model a save that never finishes.
class _StuckStore extends PageStore {
  _StuckStore(super.directory);

  Future<void>? hold;

  @override
  Future<void> save(NotedPage page) async {
    await hold;
    await super.save(page);
  }
}
