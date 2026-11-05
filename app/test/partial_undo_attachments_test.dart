// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'support/busy_retry.dart';

/// A store that can pretend a newer file is in the page's place, and that its
/// folder cannot be written to (so a restored page can't be put beside it).
class _FlakyStore extends PageStore {
  _FlakyStore(super.directory, this.unwritable);

  final Directory unwritable;
  bool armed = false;
  bool broken = false;

  @override
  Directory get directory => broken ? unwritable : super.directory;

  @override
  Future<bool> saveNew(NotedPage page, {Future<void> Function()? beforePublish}) async =>
      armed ? _fail() : super.saveNew(page, beforePublish: beforePublish);

  // The page can not be written, and from now on the folder can not be
  // written to either (so no copy can be put beside the file).
  Future<bool> _fail() async {
    broken = true;
    return false;
  }
}

void main() {
  late Directory root;
  late Directory pages;
  late Directory app;
  late _FlakyStore store;
  late Notebook nb;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_partial_undo');
    pages = await Directory('${root.path}/pages').create();
    app = await Directory('${root.path}/app').create();
    // A folder under a file can't be created or written.
    await File('${root.path}/blocker').writeAsString('x');
    store = _FlakyStore(pages, Directory('${root.path}/blocker/folder'));
    nb = Notebook(
      store,
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${app.path}/binders.json'),
    );
    await nb.load();
  });

  tearDown(() async {
    await nb.flush();
    nb.dispose();
    await busyRetry(() => root.delete(recursive: true));
  });

  /// Deletes a page that has an attachment, then puts a different file under
  /// the same name where the attachment belongs, and makes Undo only partly
  /// work. Returns the delete and the set-aside copy of the attachment.
  Future<(DeletedPages, File)> partlyUndone() async {
    final id = await nb.createPage();
    final assets = await Directory('${pages.path}/${assetsFolderName(id)}').create();
    await File('${assets.path}/x.bin').writeAsBytes([1, 2, 3]);
    final deleted = await nb.delete(id);
    final saved = File('${app.path}/deleted-attachments')
        .parent
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('x.bin'));
    // A different file with that name is in the way now.
    final live = await Directory('${pages.path}/${assetsFolderName(id)}').create();
    await File('${live.path}/x.bin').writeAsBytes([9, 9, 9]);
    store.armed = true;
    await expectLater(nb.undoDelete(deleted), throwsA(isA<NotebookException>()));
    store.armed = false;
    store.broken = false;
    return (deleted, saved);
  }

  test('after a partial Undo the delete stays pending and the attachments Undo told about are kept', () async {
    final (deleted, saved) = await partlyUndone();
    expect(nb.isPendingDelete(deleted), isTrue, reason: 'Undo can be tried again');
    expect(saved.existsSync(), isTrue);

    await nb.discardPendingDelete(); // the bar timed out, or the app is closing
    expect(nb.isPendingDelete(deleted), isFalse);
    expect(saved.existsSync(), isTrue, reason: 'the folder the message points to is not removed');
    expect(saved.readAsBytesSync(), [1, 2, 3]);
  });

  test('discardDeleted after a partial Undo also leaves those attachments', () async {
    final (deleted, saved) = await partlyUndone();
    nb.discardDeleted(deleted);
    await realIoWait();
    expect(saved.existsSync(), isTrue);
  });

  test('a delete without a partial Undo is still removed completely', () async {
    final id = await nb.createPage();
    final assets = await Directory('${pages.path}/${assetsFolderName(id)}').create();
    await File('${assets.path}/x.bin').writeAsBytes([1]);
    await nb.delete(id);
    final trash = Directory('${app.path}/deleted-attachments');
    expect(trash.listSync(recursive: true).whereType<File>(), isNotEmpty);
    await nb.discardPendingDelete();
    expect(trash.listSync(recursive: true).whereType<File>(), isEmpty);
  });
}

Future<void> realIoWait() => Future<void>.delayed(const Duration(milliseconds: 200));
