// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// An open page shown from its own conflict-copy-named file (it was opened
// while `<id>.canvas` was away) when the original comes back: a save never
// merges inside its own job, and the merge runs from outside the chain (t8,
// design 2026-11-26-01 revision 4.1).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/save_trouble.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/src/storage/dataless.dart'
    show debugMarkDataless, debugUnmarkDataless, debugDatalessPaths;

import 'support/busy_retry.dart';
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

// A store whose replaces of the page's own file fail while [fail] is set.
class FailingStore extends PageStore {
  FailingStore(super.directory);

  bool fail = false;

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
    void Function(FileStamp?)? onPublishStamp,
  }) async {
    if (fail) {
      throw FileSystemException(
        'write failed',
        pathFor(page.id),
        const OSError('Access is denied', 5),
      );
    }
    return super.saveIfUnchanged(
      page,
      expectedText,
      onPublishStamp: onPublishStamp,
    );
  }
}

void main() {
  const id = 'p1';
  const within = Duration(seconds: 5);
  final sep = Platform.pathSeparator;
  late Directory dir;
  late Directory recDir;
  late ModuleRegistry modules;
  late Notebook nb;
  late PageStore st;
  late BoxRecord baseBox;

  String originalPath() => '${dir.path}$sep$id.canvas';
  String copyPath() => '${dir.path}$sep$id-NOTED-MCP-0123456789abcdef.canvas';

  BoxRecord noteBox(String text, {Bounds at = const Bounds(10, 10, 200, 40)}) {
    final codec = modules.codecs.codecFor('noted.note')!;
    return commitBox(createBox(codec, at), codec, codec.decode(doc(text), 1));
  }

  NotedPage read(String path) => readPage(File(path).readAsStringSync());

  Set<String> ids(NotedPage p) => p.nodes.map((n) => n.id).toSet();

  Notebook make(
    PageStore store, {
    Duration leaveSaveLimit = const Duration(seconds: 5),
  }) => Notebook(
    store,
    modules,
    saveDelay: const Duration(hours: 1),
    recoveryDirectory: recDir,
    copyRetireAfter: const Duration(hours: 1),
    leaveSaveLimit: leaveSaveLimit,
  );

  // The page exists only as its copy-named file, and is open from it.
  Future<void> start({
    PageStore Function(Directory)? store,
    Duration leaveSaveLimit = const Duration(seconds: 5),
  }) async {
    dir = await Directory.systemTemp.createTemp('noted_own_copy');
    recDir = Directory('${dir.path}-rec');
    modules = buildModules();
    baseBox = noteBox('base');
    final page = NotedPage.create(
      PageMeta.create(id: id, title: 'Page', order: 0),
    ).insertNode(baseBox);
    File(copyPath()).writeAsStringSync(writePage(page));
    st = (store ?? PageStore.new)(dir);
    nb = make(st, leaveSaveLimit: leaveSaveLimit);
    await nb.load();
    if (nb.currentId != id) await nb.open(id);
    expect(nb.pageFileForTest(id), copyPath());
  }

  tearDown(() async {
    nb.dispose();
    await deleteTestFolder(dir);
    if (recDir.existsSync()) {
      await busyRetry(() => recDir.delete(recursive: true));
    }
  });

  // The original comes back holding box A, which only it has.
  BoxRecord originalArrives() {
    final a = noteBox(
      'only in the original',
      at: const Bounds(400, 10, 200, 40),
    );
    File(originalPath())
        .writeAsStringSync(writePage(read(copyPath()).insertNode(a)));
    return a;
  }

  // Edit E is typed on the open page.
  BoxRecord type(String text, {Bounds at = const Bounds(10, 300, 0, 0)}) {
    final c = nb.current!;
    final e = c.createBoxAt(at);
    c.commit(e.id, modules.codecs.codecFor('noted.note')!.decode(doc(text), 1));
    return c.page.node(e.id)! as BoxRecord;
  }

  Future<List<String>> entries() async => [
    for (final e in (await nb.recoveryStoreForTest!.list()).entries) e.page.id,
  ];

  // The merge has landed: A and [also] on screen and in the original, which
  // is the page's file, and the copy is gone after a recovery keep.
  Future<void> expectMerged(
    BoxRecord a, [
    List<BoxRecord> also = const [],
  ]) async {
    final want = {baseBox.id, a.id, for (final b in also) b.id};
    expect(ids(nb.current!.page), containsAll(want));
    await nb.flush();
    expect(ids(read(originalPath())), containsAll(want));
    expect(nb.pageFileForTest(id), originalPath());
    expect(File(copyPath()).existsSync(), isFalse);
    expect(
      await entries(),
      contains(id),
      reason: 'the copy was kept in recovery first',
    );
    expect(nb.unreadable, isEmpty);
    expect(nb.trouble.isTrouble, isFalse);
  }

  // Nothing merged: the page still saves to the copy, which holds it.
  void expectNotMerged(BoxRecord a) {
    expect(nb.pageFileForTest(id), copyPath());
    expect(File(copyPath()).existsSync(), isTrue);
    expect(nb.current!.page.node(a.id), isNull);
  }

  group('the live case', () {
    test('a save lands on the copy within 5 s, and the merge lands after it from outside the job', () async {
      await start();
      final a = originalArrives();
      final originalText = File(originalPath()).readAsStringSync();
      final e = type('E');
      final r = await nb.saveOpenPageForTest().timeout(within);
      expect(r.end, SaveEnd.landed);
      final copyText = File(copyPath()).readAsStringSync();
      expect(
        readPage(copyText).node(e.id),
        isNotNull,
        reason: 'the save wrote the file it opened from',
      );
      expect(nb.knownTextForTest(copyPath()), copyText);
      expect(nb.checkQueueIdleForTest, isTrue);
      expect(nb.unreadable, isEmpty);
      expect(
        File(originalPath()).readAsStringSync(),
        originalText,
        reason: 'nothing merged inside the save',
      );
      expectNotMerged(a);

      await nb.checkFile(originalPath()).timeout(within);
      await expectMerged(a, [e]);
    });

    test('the copy\'s own event merges the original (the self-merge regression: A appears)', () async {
      await start();
      final a = originalArrives();
      final e = type('E');
      await nb.checkFile(copyPath()).timeout(within);
      await expectMerged(a, [e]);
    });

    test('the folder tick merges the original', () async {
      await start();
      final a = originalArrives();
      final e = type('E');
      await nb.folderTickForTest().timeout(within);
      await expectMerged(a, [e]);
    });
  });

  test('B1: the screen\'s geometry and header win over the original at equal revisions', () async {
    await start();
    final a = originalArrives();
    final c = nb.current!;
    const moved = Bounds(50, 500, 200, 40);
    c.requestBounds(baseBox.id, moved);
    c.updateMeta(c.page.meta.withTitle('Renamed'));
    await nb.checkFile(copyPath()).timeout(within);
    await expectMerged(a);
    expect((c.page.node(baseBox.id)! as BoxRecord).bounds, moved);
    expect(c.page.meta.title, 'Renamed');
    final disk = read(originalPath());
    expect((disk.node(baseBox.id)! as BoxRecord).bounds, moved);
    expect(disk.meta.title, 'Renamed');
  });

  test('B2: the original listed first (save trouble), then the next save lands with _known intact and the merge lands later', () async {
    late FailingStore failing;
    await start(store: (d) => failing = FailingStore(d));
    final e = type('E');
    failing.fail = true;
    final failed = await nb.saveOpenPageForTest().timeout(within);
    expect(failed.end, isNot(SaveEnd.landed));
    expect(nb.trouble.isTrouble, isTrue);
    final a = originalArrives();
    // The original's check: the merge can't run now, so it is listed as before.
    await nb.checkFile(originalPath()).timeout(within);
    expect(nb.unreadable.map((u) => u.path), contains(originalPath()));
    expectNotMerged(a);
    failing.fail = false;
    final r = await nb.saveOpenPageForTest().timeout(within);
    expect(
      r.end,
      SaveEnd.landed,
      reason: 'the save meets its own file, not a duplicate',
    );
    final copyText = File(copyPath()).readAsStringSync();
    expect(readPage(copyText).node(e.id), isNotNull);
    expect(nb.knownTextForTest(copyPath()), copyText);
    expect(nb.trouble.isTrouble, isFalse);
    await nb.folderTickForTest().timeout(within);
    await expectMerged(a, [e]);
  });

  test('B3: a failure after the publish and before the re-point changes nothing of the page\'s file, and loses nothing', () async {
    await start();
    final a = originalArrives();
    final e = type('E');
    await nb.flush();
    final copyText = File(copyPath()).readAsStringSync();
    nb.syncHook = (point, _) async {
      if (point == 'own-copy-published') {
        throw const FileSystemException('injected');
      }
    };
    await nb.checkFile(copyPath()).timeout(within);
    expect(nb.pageFileForTest(id), copyPath());
    expect(st.pathFor(id), copyPath(), reason: 'PageStore._paths is unchanged');
    expect(nb.knownTextForTest(copyPath()), copyText);
    expect(nb.knownTextForTest(originalPath()), isNull);
    expect(File(copyPath()).readAsStringSync(), copyText);
    expect(
      ids(read(originalPath())),
      containsAll({baseBox.id, a.id, e.id}),
      reason: 'the publish landed',
    );
    expect(nb.current!.page.node(a.id), isNull);
    nb.syncHook = null;
    await nb.folderTickForTest().timeout(within);
    await expectMerged(a, [e]);
  });

  test('Codex R-1: an original that holds another page by then is neither written, deleted nor adopted, also after a restart', () async {
    await start();
    originalArrives();
    final e = type('E');
    await nb.flush();
    final copyText = File(copyPath()).readAsStringSync();
    final other = NotedPage.create(
      PageMeta.create(id: 'other', title: 'Other', order: 1),
    ).insertNode(noteBox('other'));
    nb.syncHook = (point, path) async {
      if (point == 'own-copy-original') {
        File(path).writeAsStringSync(writePage(other));
      }
    };
    final screen = writePage(nb.current!.page);
    await nb.checkFile(copyPath()).timeout(within);
    nb.syncHook = null;
    expect(File(originalPath()).readAsStringSync(), writePage(other));
    expect(File(copyPath()).readAsStringSync(), copyText);
    expect(nb.pageFileForTest(id), copyPath());
    expect(writePage(nb.current!.page), screen);
    expect(await entries(), isEmpty);
    // After a restart both are pages of their own, and the copy still holds this one.
    nb.dispose();
    nb = make(PageStore(dir));
    await nb.load();
    expect(nb.tree[id], isNotNull);
    expect(nb.tree['other'], isNotNull);
    expect(nb.pageFileForTest(id), copyPath());
    expect(read(copyPath()).node(e.id), isNotNull);
  });

  test(
    'N4: a Discard between the snapshot and the publish publishes nothing',
    () async {
      await start();
      final a = originalArrives();
      type('E');
      final originalText = File(originalPath()).readAsStringSync();
      nb.syncHook = (point, _) async {
        if (point == 'own-copy-merged') nb.raiseFloorForTest();
      };
      await nb.checkFile(copyPath()).timeout(within);
      nb.syncHook = null;
      expect(File(originalPath()).readAsStringSync(), originalText);
      expectNotMerged(a);
    },
  );

  group('seams', () {
    test('an edit typed between the read-back and the re-point is kept and saved into the original', () async {
      await start();
      final a = originalArrives();
      final e = type('E');
      BoxRecord? late;
      nb.syncHook = (point, _) async {
        if (point == 'own-copy-published') {
          late = type('typed late', at: const Bounds(10, 600, 0, 0));
        }
      };
      await nb.checkFile(copyPath()).timeout(within);
      nb.syncHook = null;
      expect(late, isNotNull);
      await expectMerged(a, [e, late!]);
    });

    test('the original replaced before the publish: refused, merged again, nothing lost', () async {
      await start();
      final a = originalArrives();
      final e = type('E');
      final b = noteBox(
        'written meanwhile',
        at: const Bounds(400, 300, 200, 40),
      );
      var rounds = 0;
      nb.syncHook = (point, path) async {
        if (point == 'own-copy-merged' && rounds++ == 0) {
          File(path).writeAsStringSync(writePage(read(path).insertNode(b)));
        }
      };
      await nb.checkFile(copyPath()).timeout(within);
      nb.syncHook = null;
      expect(rounds, 2);
      await expectMerged(a, [e, b]);
    });

    test('the page left at that seam: nothing is re-pointed, and the copy merges closed later', () async {
      await start(leaveSaveLimit: const Duration(milliseconds: 300));
      final a = originalArrives();
      final e = type('E');
      await nb.flush();
      final next = await nb.createPage();
      await nb.open(id);
      Future<void>? leaving;
      nb.syncHook = (point, _) async {
        if (point != 'own-copy-published' || leaving != null) return;
        // Left from outside the job, which it waits for up to its limit.
        leaving = Zone.root.run(() => nb.open(next));
        final end = DateTime.now().add(within);
        while (nb.currentId == id && DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      };
      await nb.checkFile(copyPath()).timeout(const Duration(seconds: 10));
      nb.syncHook = null;
      await leaving;
      expect(nb.currentId, next);
      expect(
        File(copyPath()).existsSync(),
        isTrue,
        reason: 'nothing was retired',
      );
      await nb.checkFile(copyPath()).timeout(within);
      expect(File(copyPath()).existsSync(), isFalse);
      expect(ids(read(originalPath())), containsAll({baseBox.id, a.id, e.id}));
      // The closed merge wrote nothing (the original held it all), so the page
      // is still listed from the copy: it moves to the original once both
      // files are looked at again.
      await nb.filesChanged([originalPath(), copyPath()]);
      expect(nb.pageFileForTest(id), originalPath());
      await nb.open(id);
      expect(ids(nb.current!.page), containsAll({baseBox.id, a.id, e.id}));
    });

    test(
      'the original not downloaded: not now, then its download event merges it',
      () async {
        await start();
        addTearDown(() => debugDatalessPaths = null);
        final asked = <String>[];
        nb.askDownload = (p) async {
          asked.add(p);
          return null;
        };
        final a = originalArrives();
        final e = type('E');
        debugMarkDataless(originalPath());
        await nb.checkFile(copyPath()).timeout(within);
        expectNotMerged(a);
        expect(asked, contains(originalPath()));
        debugUnmarkDataless(originalPath());
        await nb.filesChanged([originalPath()]).timeout(within);
        await expectMerged(a, [e]);
      },
    );

    test('the copy changed by another writer: not now, then merged', () async {
      await start();
      final a = originalArrives();
      final c = noteBox(
        'written into the copy',
        at: const Bounds(400, 600, 200, 40),
      );
      // Another writer adds C to the copy, and A to the original's base too.
      File(copyPath())
          .writeAsStringSync(writePage(read(copyPath()).insertNode(c)));
      await nb.checkFile(copyPath()).timeout(within);
      expectNotMerged(a);
      expect(
        nb.current!.page.node(c.id),
        isNotNull,
        reason: 'the page took in the change first',
      );
      await nb.folderTickForTest().timeout(within);
      await expectMerged(a, [c]);
    });

    test('a merge that drops something writes nothing, and is not tried again until a file changes', () async {
      await start();
      final a = originalArrives();
      final originalText = File(originalPath()).readAsStringSync();
      nb.conflictMergeHook = (p) => p.removeNode(a.id);
      await nb.checkFile(copyPath()).timeout(within);
      nb.conflictMergeHook = null;
      expect(File(originalPath()).readAsStringSync(), originalText);
      expectNotMerged(a);
      await nb.folderTickForTest().timeout(within);
      expectNotMerged(a);
      // The page's next save changes the copy's text: tried again.
      final e = type('E');
      await nb.flush();
      await nb.folderTickForTest().timeout(within);
      await expectMerged(a, [e]);
    });
  });
}
