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

import 'support/busy_retry.dart';

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
    void Function()? beforeRestore,
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
    void Function()? beforeRestore,
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
    );
    await nb.load();
  });

  tearDown(() async {
    nb.dispose();
    await busyRetry(() => root.delete(recursive: true));
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
    test('10. page move: a swapped source is kept, the move is refused and the copy rolled back '
        '(${atCheck ? 're-check' : 'aside'})', () async {
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
      if (atCheck) {
        store.beforeFinalCheckOnce = swap;
      } else {
        store.beforeAsideDeleteOnce = swap;
      }
      Object? error;
      try {
        await nb.moveToFolder(id, elsewhere.path);
      } on Object catch (e) {
        error = e;
      }
      expect(error, isNotNull, reason: 'the move is refused');
      expect(nodeIds(onDisk(id)), {
        box.id,
        extra.id,
      }, reason: 'the swapped version stays at the source');
      expect(
        elsewhere.listSync(),
        isEmpty,
        reason: 'the destination copy was rolled back',
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
}
