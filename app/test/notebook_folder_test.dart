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

void main() {
  late Directory root;
  late Notebook nb;

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
