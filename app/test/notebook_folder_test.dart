// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'support/notebook_folder.dart';
import 'support/onedrive_world.dart';
import 'support/real_io.dart';

void main() {
  late Directory root;
  late Notebook nb;
  final gate = Completer<void>();

  // A notebook with the real autosave delay.
  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_folder_rule');
    nb = Notebook(PageStore(await Directory('${root.path}/pages').create()), buildModules());
    await nb.load();
  });

  tearDown(() async {
    if (!nb.disposedForTest) nb.dispose();
    await deleteTestFolder(root);
  });

  test('a notebook with an unsaved change is not settled, and the check says why', () {
    nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));

    expect(
      () => expectSettled([nb], what: 'at teardown'),
      throwsA(isA<TestFailure>().having((e) => e.message, 'message', allOf(contains('at teardown'), contains('autosave')))),
    );
  });

  test('a job still running on the save chain is not settled; settling gives up and names it', () async {
    final hold = Completer<void>();
    unawaited(nb.runOnChainForTest(() => hold.future));

    await expectLater(
      settleNotebooks(notebooks: [nb], limit: const Duration(milliseconds: 300)),
      throwsA(isA<TestFailure>().having((e) => e.message, 'message', contains('save chain'))),
    );

    hold.complete();
    await settleNotebooks(notebooks: [nb]);
    expectSettled([nb]);
  });

  // Each kind of work the notebook reports, held open, makes settling give up
  // naming it; once it ends the notebook settles.
  Future<void> expectNamed(String name) => expectLater(
    settleNotebooks(notebooks: [nb], limit: const Duration(milliseconds: 300)),
    throwsA(isA<TestFailure>().having((e) => e.message, 'message', contains(name))),
  );

  test('a settings file read in flight is not settled, and is named', () async {
    final hold = Completer<void>();
    final other = Notebook(
      PageStore(Directory('${root.path}/pages')),
      buildModules(),
      bindersFile: File('${root.path}/binders.json'),
    );
    addTearDown(() async {
      if (!hold.isCompleted) hold.complete();
      await settleNotebooks(notebooks: [other]);
      other.dispose();
    });
    other.binderHook = (point, path) => point == 'settings-read' ? hold.future : Future<void>.value();
    unawaited(other.load());
    await realIoUntil(() => other.inFlightForTest?.contains('readSettingsBytes') ?? false, 'the settings read');

    await expectLater(
      settleNotebooks(notebooks: [other], limit: const Duration(milliseconds: 300)),
      throwsA(isA<TestFailure>().having((e) => e.message, 'message', contains('readSettingsBytes'))),
    );

    hold.complete();
    await settleNotebooks(notebooks: [other]);
  });

  test('an attachment file check in flight is not settled, and is named', () async {
    final check = nb.attachments!.verify('0' * 64 + '.png', size: 0);

    expect(nb.inFlightForTest, contains('attachment file checks'));
    await check;
    await settleNotebooks(notebooks: [nb]);
  });

  test('a recovery replay or landing in flight is not settled, and is named', () async {
    final run = nb.recoverNowForTest();

    expect(nb.inFlightForTest, contains('recoverPending'));
    await run;
    await settleNotebooks(notebooks: [nb]);
  });

  test('a queued file check is not settled, and is named', () async {
    final hold = Completer<void>();
    unawaited(nb.runOnChainForTest(() => hold.future));
    final check = nb.checkFile('${root.path}/pages/none.canvas');

    expect(nb.inFlightForTest, contains('check queue'));
    await expectNamed('check queue');
    hold.complete();
    await check;
    await settleNotebooks(notebooks: [nb]);
  });

  test('a pending watcher debounce timer is not settled, and is named', () async {
    final other = Notebook(
      PageStore(Directory('${root.path}/watched')..createSync()),
      buildModules(),
      watchFiles: true,
      watchDebounce: const Duration(milliseconds: 1500),
    );
    addTearDown(() async {
      await settleNotebooks(notebooks: [other]);
      other.dispose();
    });
    await other.load();
    await settleNotebooks(notebooks: [other]);
    File('${root.path}/watched/stray.canvas').writeAsStringSync('{}');
    await realIoUntil(() => other.inFlightForTest?.contains('debounce') ?? false, 'the watcher event');

    await expectLater(
      settleNotebooks(notebooks: [other], limit: const Duration(milliseconds: 300)),
      throwsA(isA<TestFailure>().having((e) => e.message, 'message', contains('debounce'))),
    );
  });

  test('a cloud sync round in flight is not settled, and is named', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final w = await OneDriveWorld.create(pageInFolder: true);
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      w.sync.dispose();
      await settleNotebooks(under: w.top);
      await w.close();
    });
    w.runner.hold = gate;
    await w.sync.start();
    unawaited(w.sync.checkNow());
    await realIoUntil(() => w.sync.inFlightForTest != null, 'the pull round');

    expect(syncsIn(w.top), contains(w.sync));
    expect(syncsIn(Directory('${w.top.path}-other')), isEmpty, reason: 'only a folder that contains it');
    await expectLater(
      settleNotebooks(under: w.top, limit: const Duration(milliseconds: 300)),
      throwsA(isA<TestFailure>().having((e) => e.message, 'message', contains('pull round'))),
    );

    gate.complete();
    await settleNotebooks(under: w.top);
  });

  test('deleteTestFolder lands the pending save first, then deletes the folder', () async {
    final id = nb.currentId!;
    nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
    final store = PageStore(Directory('${root.path}/pages'));

    // The notebook's own folder: found without being named.
    expect(notebooksIn(root), contains(nb));
    await settleNotebooks(under: root);
    expect((await store.load(id)).nodes.length, 1);
    nb.dispose();
    await deleteTestFolder(root);

    expect(root.existsSync(), isFalse);
    expect(notebooksIn(root), isEmpty, reason: 'a settled, disposed notebook is no longer watched');
  });

  test('a notebook in another folder is not waited for', () async {
    final other = await Directory.systemTemp.createTemp('noted_folder_rule_other');
    addTearDown(() async {
      if (other.existsSync()) await other.delete(recursive: true);
    });

    expect(notebooksIn(other), isEmpty);
    await deleteTestFolder(other);
    expect(other.existsSync(), isFalse);
  });
}
