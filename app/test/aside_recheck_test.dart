// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The aside re-check seen from the notebook (run 2026-11-15-01, task 1): a sync
// client that follows items by id writes another device's version into the
// aside a save, a move or a delete has set aside. Nothing is lost.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/src/storage/dataless.dart' show debugDatalessPaths, debugMarkDataless, debugUnmarkDataless;

import 'support/busy_retry.dart';
import 'support/page_save.dart';
import 'support/notebook_folder.dart';

Map<String, Object?> doc(String text) => {
  'document': {
    'type': 'page',
    'children': [
      {
        'type': 'paragraph',
        'data': {
          'delta': [
            {'insert': text},
          ],
        },
      },
    ],
  },
};

/// A store whose next replace or delete runs a seam in the aside's re-check.
class SwapStore extends PageStore {
  SwapStore(super.directory);

  /// Run once, in the next compare-and-swap replace or compare-and-delete.
  Future<void> Function(String path)? beforeAsideDeleteOnce;
  Future<void> Function(String path)? beforeFinalCheckOnce;

  @override
  Future<ReplaceResult> saveIfUnchanged(
    NotedPage page,
    String? expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    void Function()? beforePublish,
    void Function()? beforeRestore, void Function(FileStamp?)? onPublishStamp,
    Future<void> Function(String path)? beforeAsideDelete,
    Future<void> Function(String path)? beforeFinalCheck,
    Future<void> Function(String path)? afterFinalRead,
  }) {
    final a = beforeAsideDeleteOnce;
    final f = beforeFinalCheckOnce;
    beforeAsideDeleteOnce = null;
    beforeFinalCheckOnce = null;
    return super.saveIfUnchanged(
      page,
      expectedText,
      beforeMoveAside: beforeMoveAside,
      afterRead: afterRead,
      beforePublish: beforePublish,
      beforeRestore: beforeRestore,
      onPublishStamp: onPublishStamp,
      beforeAsideDelete: a ?? beforeAsideDelete,
      beforeFinalCheck: f ?? beforeFinalCheck,
      afterFinalRead: afterFinalRead,
    );
  }

  @override
  Future<DeleteResult> deleteIfUnchanged(
    String pageId,
    String expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    Future<void> Function()? beforeDelete,
    void Function()? beforeRestore, void Function(FileStamp?)? onPublishStamp,
    Future<void> Function(String path)? beforeAsideDelete,
    Future<void> Function(String path)? beforeFinalCheck,
    Future<void> Function(String path)? afterFinalRead,
  }) {
    final a = beforeAsideDeleteOnce;
    final f = beforeFinalCheckOnce;
    beforeAsideDeleteOnce = null;
    beforeFinalCheckOnce = null;
    return super.deleteIfUnchanged(
      pageId,
      expectedText,
      beforeMoveAside: beforeMoveAside,
      afterRead: afterRead,
      beforeDelete: beforeDelete,
      beforeRestore: beforeRestore,
      beforeAsideDelete: a ?? beforeAsideDelete,
      beforeFinalCheck: f ?? beforeFinalCheck,
      afterFinalRead: afterFinalRead,
    );
  }
}

Future<void> until(
  bool Function() ok, {
  Duration limit = const Duration(seconds: 10),
}) async {
  final clock = Stopwatch()..start();
  while (!ok()) {
    if (clock.elapsed > limit) fail('the condition did not hold within $limit');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory root;
  late Directory dir;
  late Directory elsewhere;
  late SwapStore store;
  late Notebook nb;
  late ModuleRegistry modules;
  final sep = Platform.pathSeparator;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_asiderecheck');
    dir = await Directory('${root.path}${sep}pages').create();
    elsewhere = await Directory('${root.path}${sep}elsewhere').create();
    modules = buildModules();
    store = SwapStore(dir);
    nb = Notebook(
      store,
      modules,
      saveDelay: const Duration(hours: 1),
      watchFiles: false,
      // A merged copy is deleted only once recovery keeps it (run 2026-11-16-01).
      recoveryDirectory: Directory('${root.path}${sep}rec'),
    );
    await nb.load();
  });

  tearDown(() async {
    nb.dispose();
    await deleteTestFolder(root);
  });

  BoxRecord noteBox(String text, {Bounds at = const Bounds(10, 10, 200, 40)}) {
    final codec = modules.codecs.codecFor('noted.note')!;
    return commitBox(createBox(codec, at), codec, codec.decode(doc(text), 1));
  }

  String pathOf(String id) => '${dir.path}$sep$id.canvas';
  NotedPage onDisk(String id) => readPage(File(pathOf(id)).readAsStringSync());
  Set<String> nodeIds(NotedPage p) => p.nodes.map((n) => n.id).toSet();
  List<String> names() =>
      dir.listSync().map((f) => f.path.split(RegExp(r'[\\/]')).last).toList()
        ..sort();

  for (final atCheck in [false, true]) {
    final where = atCheck ? 'the re-check' : 'the aside';

    test(
      '9. save of the open page: another device swaps its version in at $where; '
      'checkFile merges the kept copy with no watcher',
      () async {
        final id = nb.currentId!;
        final c = nb.current!;
        final mine = c.createBoxAt(const Bounds(10, 10, 0, 0));
        c.commit(
          mine.id,
          modules.codecs.codecFor('noted.note')!.decode(doc('mine'), 1),
        );
        await nb.flush();
        final theirBox = noteBox(
          'from the other device',
          at: const Bounds(400, 10, 200, 40),
        );
        final theirs = onDisk(id).insertNode(theirBox);
        Future<void> swap(String path) async =>
            File(path).writeAsStringSync(writePage(theirs));
        if (atCheck) {
          store.beforeFinalCheckOnce = swap;
        } else {
          store.beforeAsideDeleteOnce = swap;
        }
        final second = c.createBoxAt(const Bounds(10, 300, 0, 0));
        c.commit(
          second.id,
          modules.codecs.codecFor('noted.note')!.decode(doc('also mine'), 1),
        );
        await nb.flush();
        // The kept copy is merged on the notebook's own idle, not by a watcher.
        await until(
          () =>
              nodeIds(nb.current!.page)
                  .containsAll({mine.id, second.id, theirBox.id}) &&
              names().every((n) => n == '$id.canvas'),
        );
        await nb.flush();
        expect(nodeIds(onDisk(id)), {mine.id, second.id, theirBox.id});
        expect(names(), ['$id.canvas']);
        expect(hasConflicts(onDisk(id)), isFalse);
        expect(hasConflicts(nb.current!.page), isFalse);
      },
    );
  }

  for (final atCheck in [false, true]) {
    test('10. delete the original: a source swapped by another device is kept '
        '(${atCheck ? 're-check' : 'before the delete'})', () async {
      Notebook.forceCopyMoveForTest = true; // the copy path keeps the original
      addTearDown(() => Notebook.forceCopyMoveForTest = false);
      final id = nb.currentId!;
      final box = noteBox('base');
      await busyRetry(() => PageStore(dir).save(onDisk(id).insertNode(box)));
      await nb.createPage(); // [id] is closed now
      await nb.checkFile(pathOf(id));
      final extra = noteBox(
        'from the other device',
        at: const Bounds(400, 10, 200, 40),
      );
      final theirs = onDisk(id).insertNode(extra);
      Future<void> swap(String path) async =>
          File(path).writeAsStringSync(writePage(theirs));
      nb.syncHook = (point, path) async {
        if (point == (atCheck ? 'originals-before-final-check' : 'originals-before-delete')) {
          await swap(path);
        }
      };
      OriginalsKeptException? kept;
      try {
        await nb.moveToFolder(id, elsewhere.path);
      } on OriginalsKeptException catch (e) {
        kept = e;
      }
      expect(kept, isNotNull, reason: 'the move copied and kept the original');
      expect(File('${elsewhere.path}$sep$id.canvas').existsSync(), isTrue);
      await expectLater(
        nb.deleteOriginals(kept!.move),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('was kept'))),
      );
      expect(nodeIds(onDisk(id)), {
        box.id,
        extra.id,
      }, reason: 'the swapped version stays at the source');
      expect(
        nodeIds(readPage(File('${elsewhere.path}$sep$id.canvas').readAsStringSync())),
        {box.id},
        reason: 'the copy is untouched',
      );
      expect(names().where((n) => n.contains('.cas-')), isEmpty);
    });
  }

  for (final atCheck in [false, true]) {
    test(
      '11. delete: the page is kept with the swapped box and the user is told '
      '(${atCheck ? 're-check' : 'aside'})',
      () async {
        final id = nb.currentId!;
        final box = noteBox('base');
        await busyRetry(() => PageStore(dir).save(onDisk(id).insertNode(box)));
        await nb.createPage();
        await nb.checkFile(pathOf(id));
        final extra = noteBox(
          'from the other device',
          at: const Bounds(400, 10, 200, 40),
        );
        final theirs = onDisk(id).insertNode(extra);
        Future<void> swap(String path) async =>
            File(path).writeAsStringSync(writePage(theirs));
        if (atCheck) {
          store.beforeFinalCheckOnce = swap;
        } else {
          store.beforeAsideDeleteOnce = swap;
        }
        final deleted = await nb.delete(id);
        expect(
          deleted.keptNote,
          isNotNull,
          reason: 'the user is told it changed',
        );
        expect(nodeIds(onDisk(id)), {box.id, extra.id});
        expect(names().where((n) => n.contains('.cas-')), isEmpty);
      },
    );
  }

  // 0190, R-2: the original is deleted only while the copy is read and holds the
  // page. A copy that is not downloaded is not read, so the original is kept.
  test('12. delete the original while the copy is not downloaded: the original is kept', () async {
    Notebook.forceCopyMoveForTest = true;
    addTearDown(() {
      Notebook.forceCopyMoveForTest = false;
      debugDatalessPaths = null;
    });
    final id = nb.currentId!;
    final box = noteBox('base');
    await busyRetry(() => PageStore(dir).save(onDisk(id).insertNode(box)));
    await nb.createPage();
    await nb.checkFile(pathOf(id));
    OriginalsKeptException? kept;
    try {
      await nb.moveToFolder(id, elsewhere.path);
    } on OriginalsKeptException catch (e) {
      kept = e;
    }
    expect(kept, isNotNull);
    final copy = '${elsewhere.path}$sep$id.canvas';
    debugMarkDataless(copy);
    await expectLater(
      nb.deleteOriginals(kept!.move),
      throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('was kept'))),
    );
    expect(File(pathOf(id)).existsSync(), isTrue, reason: 'the original is kept');
    debugUnmarkDataless(copy);
    await nb.deleteOriginals(kept.move);
    expect(File(pathOf(id)).existsSync(), isFalse, reason: 'deleted once the copy is read and holds the page');
  });
}
