// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_store.dart';
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

/// A store that can be told to fail, to test that a copy is kept then.
class FlakyStore extends PageStore {
  FlakyStore(super.directory);

  bool dropSaves = false;
  bool failReads = false;

  @override
  Future<void> save(NotedPage page) async {
    if (!dropSaves) await super.save(page);
  }

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
  }) async {
    if (dropSaves) return const ReplaceResult(ReplaceOutcome.replaced); // says so, keeps nothing
    return super.saveIfUnchanged(page, expectedText, onPublishStamp: onPublishStamp);
  }

  @override
  Future<String> readText(String pageId) async {
    if (failReads) throw const FileSystemException('read failed');
    return super.readText(pageId);
  }
}

void main() {
  late Directory dir;
  late Notebook nb;
  late PageStore other;
  late ModuleRegistry modules;
  final sep = Platform.pathSeparator;

  // A merged copy is kept in recovery until a re-check: [recovery] false runs
  // without a recovery folder (a copy is then never deleted). The re-check is
  // due [copyRetireAfter] after the merge, by [clock] (advanced by tests).
  late Directory recDir;
  var clock = DateTime(2026, 11, 16, 12);
  Notebook makeNotebook(PageStore st, {bool recovery = true, bool watch = false}) {
    clock = DateTime(2026, 11, 16, 12);
    return Notebook(
      st,
      modules,
      saveDelay: const Duration(hours: 1),
      watchFiles: watch,
      watchDebounce: const Duration(milliseconds: 50),
      recoveryDirectory: recovery ? recDir : null,
      copyRetireAfter: const Duration(hours: 1),
    )..now = () => clock;
  }

  Future<void> start({bool watch = false, bool recovery = true, PageStore Function(Directory)? make}) async {
    dir = await Directory.systemTemp.createTemp('noted_copies');
    recDir = Directory('${dir.path}-rec');
    modules = buildModules();
    nb = makeNotebook((make ?? PageStore.new)(dir), recovery: recovery, watch: watch);
    other = PageStore(dir);
    await nb.load();
    await other.scan();
  }

  tearDown(() async {
    nb.dispose();
    await busyRetry(() => dir.delete(recursive: true));
    if (recDir.existsSync()) await busyRetry(() => recDir.delete(recursive: true));
  });

  // Makes every consumed copy's re-check due and runs a replay pass.
  Future<void> recheck() async {
    clock = clock.add(const Duration(hours: 2));
    await nb.recoverNowForTest();
  }

  Future<List<RecoveryEntry>> entries() async => (await nb.recoveryStoreForTest!.list()).entries;

  BoxRecord noteBox(String text, {Bounds at = const Bounds(10, 10, 200, 40)}) {
    final codec = modules.codecs.codecFor('noted.note')!;
    return commitBox(createBox(codec, at), codec, codec.decode(doc(text), 1));
  }

  BoxRecord withText(BoxRecord b, String text) {
    final codec = modules.codecs.codecFor('noted.note')!;
    return commitBox(b, codec, codec.decode(doc(text), 1));
  }

  String pathOf(String id) => '${dir.path}$sep$id.canvas';

  String copyPath(String id, String suffix) => '${dir.path}$sep$id-$suffix.canvas';

  Future<void> saveAsOther(NotedPage page) => busyRetry(() => other.save(page));

  Future<void> writeCopy(String path, NotedPage page) =>
      busyRetry(() => File(path).writeAsString(writePage(page)));

  NotedPage onDisk(String id) => readPage(File(pathOf(id)).readAsStringSync());

  /// A closed page [id] holding one note, and the open page is another one.
  Future<(String, BoxRecord)> closedPageWithBox() async {
    final id = nb.currentId!;
    final box = noteBox('base');
    await saveAsOther((await other.load(id)).insertNode(box));
    await nb.createPage(); // opens another page; [id] is closed
    await nb.checkFile(pathOf(id));
    return (id, box);
  }

  test('a copy with a computer name is merged into a closed page and deleted', () async {
    await start();
    final (id, box) = await closedPageWithBox();
    final disk = await other.load(id);
    final added = noteBox('from the other machine', at: const Bounds(400, 10, 200, 40));
    final copy = disk.insertNode(added).replaceNode(withText(box, 'edited there'));
    final path = copyPath(id, 'DESKTOP-4QK2N8L');
    await writeCopy(path, copy);

    await nb.checkFile(path);

    expect(File(path).existsSync(), isFalse);
    final merged = onDisk(id);
    expect(merged.nodes.map((n) => n.id).toSet(), {box.id, added.id});
    expect((merged.node(box.id)! as BoxRecord).snapshotText, 'edited there');
    expect(nb.unreadable, isEmpty);
    expect(nb.tree[id], isNotNull);
  });

  test('a copy with a hyphenated name and a number', () async {
    await start();
    final (id, box) = await closedPageWithBox();
    final added = noteBox('two');
    final path = copyPath(id, 'LAPTOP-ABC-1');
    await writeCopy(path, (await other.load(id)).insertNode(added));
    await nb.checkFile(path);
    expect(File(path).existsSync(), isFalse);
    expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, added.id});
  });

  test('a computer name made of digits, and a name that is a plain word', () async {
    await start();
    final (id, _) = await closedPageWithBox();
    for (final name in ['20481024', 'MyPC']) {
      final added = noteBox('from $name');
      final path = copyPath(id, name);
      await writeCopy(path, (await other.load(id)).insertNode(added));
      await nb.checkFile(path);
      expect(File(path).existsSync(), isFalse, reason: name);
      expect(onDisk(id).node(added.id), isNotNull, reason: name);
    }
  });

  test('a hyphenated file with another page id is a page, not a copy', () async {
    await start();
    final (id, _) = await closedPageWithBox();
    final before = File(pathOf(id)).readAsStringSync();
    final path = copyPath(id, 'notes');
    await writeCopy(
      path,
      NotedPage.create(PageMeta.create(id: 'different', title: 'Different', order: 7)),
    );
    await nb.checkFile(path);
    expect(File(path).existsSync(), isTrue);
    expect(nb.tree['different']!.title, 'Different');
    expect(File(pathOf(id)).readAsStringSync(), before);
  });

  test('a hyphenated duplicate without an original is still cannot-open', () async {
    await start();
    final (id, _) = await closedPageWithBox();
    final path = '${dir.path}${sep}zzzz-PC.canvas'; // no zzzz.canvas
    await writeCopy(path, await other.load(id));
    await nb.checkFile(path);
    expect(File(path).existsSync(), isTrue);
    expect(nb.unreadable.map((u) => u.path), [path]);
    expect(nb.unreadable.single.reason, contains('duplicate'));
  });

  test('the open page keeps an unsaved local edit when a copy is merged', () async {
    await start();
    final id = nb.currentId!;
    final c = nb.current!;
    final mine = c.createBoxAt(const Bounds(10, 10, 0, 0));
    c.commit(mine.id, modules.codecs.codecFor('noted.note')!.decode(doc('mine'), 1));
    await nb.flush();

    final added = noteBox('theirs', at: const Bounds(400, 10, 200, 40));
    final path = copyPath(id, 'DESKTOP-4QK2N8L');
    await writeCopy(path, (await other.load(id)).insertNode(added));
    final local = c.createBoxAt(const Bounds(10, 300, 0, 0)); // not saved yet
    c.commit(local.id, modules.codecs.codecFor('noted.note')!.decode(doc('local'), 1));

    await nb.checkFile(path);

    expect(nb.current, same(c));
    expect(c.page.nodes.map((n) => n.id).toSet(), {mine.id, added.id, local.id});
    expect(File(path).existsSync(), isFalse);
    expect(onDisk(id).nodes.map((n) => n.id).toSet(), {mine.id, added.id, local.id});
  });

  test('a copy that edited the same box differently leaves a conflict', () async {
    await start();
    final (id, box) = await closedPageWithBox();
    final disk = await other.load(id);
    final mineEdit = withText(box, 'original side');
    final theirEdit = withText(box, 'copy side');
    await saveAsOther(disk.replaceNode(mineEdit));
    await nb.checkFile(pathOf(id));
    final path = copyPath(id, 'DESKTOP-4QK2N8L');
    await writeCopy(path, disk.replaceNode(theirEdit));

    await nb.checkFile(path);

    expect(File(path).existsSync(), isFalse);
    final saved = onDisk(id).node(box.id)! as BoxRecord;
    expect(saved.snapshotText, 'original side');
    expect(saved.conflicts.single.node, theirEdit.toRaw());
    expect(nb.hasConflict(id), isTrue);
  });

  test('an identical copy is deleted and the page file is not rewritten', () async {
    await start();
    final (id, _) = await closedPageWithBox();
    final before = File(pathOf(id)).readAsStringSync();
    final stamp = File(pathOf(id)).lastModifiedSync();
    final path = copyPath(id, 'DESKTOP-4QK2N8L');
    await File(path).writeAsString(before);
    await nb.checkFile(path);
    expect(File(path).existsSync(), isFalse);
    expect(File(pathOf(id)).readAsStringSync(), before);
    expect(File(pathOf(id)).lastModifiedSync(), stamp);
  });

  test('a copy found at startup is merged on load', () async {
    dir = await Directory.systemTemp.createTemp('noted_copies');
    recDir = Directory('${dir.path}-rec');
    modules = buildModules();
    other = PageStore(dir);
    final page = NotedPage.create(PageMeta.create(id: 'aaaa1111', title: 'A', order: 0));
    await saveAsOther(page);
    final added = noteBox('new');
    final path = copyPath('aaaa1111', 'DESKTOP-4QK2N8L');
    await writeCopy(path, page.insertNode(added));
    nb = makeNotebook(PageStore(dir));
    await nb.load();
    expect(File(path).existsSync(), isFalse);
    expect(nb.unreadable, isEmpty);
    expect(onDisk('aaaa1111').node(added.id), isNotNull);
    expect(nb.currentId, 'aaaa1111');
    expect(nb.current!.page.node(added.id), isNotNull);
  });

  test('a store that does not keep the write: the copy stays and is listed', () async {
    late FlakyStore store;
    await start(make: (d) => store = FlakyStore(d));
    final (id, _) = await closedPageWithBox();
    final before = File(pathOf(id)).readAsStringSync();
    final added = noteBox('lost?');
    final path = copyPath(id, 'DESKTOP-4QK2N8L');
    await writeCopy(path, (await other.load(id)).insertNode(added));
    store.dropSaves = true;
    await nb.checkFile(path);
    expect(File(path).existsSync(), isTrue);
    expect(File(pathOf(id)).readAsStringSync(), before);
    expect(nb.unreadable.map((u) => u.path), [path]);
  });

  test('a read-back that fails keeps the copy; a later try merges it', () async {
    late FlakyStore store;
    await start(make: (d) => store = FlakyStore(d));
    final (id, box) = await closedPageWithBox();
    final added = noteBox('kept');
    final path = copyPath(id, 'DESKTOP-4QK2N8L');
    await writeCopy(path, (await other.load(id)).insertNode(added));
    store.failReads = true;
    await nb.checkFile(path);
    expect(File(path).existsSync(), isTrue);
    expect(nb.unreadable.map((u) => u.path), [path]);

    store.failReads = false;
    await nb.checkFile(path);
    expect(File(path).existsSync(), isFalse);
    expect(nb.unreadable, isEmpty);
    expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, added.id});
  });

  // Run 2026-11-16-01 (R-1): a merged copy is deleted only once it is kept in
  // recovery, and the entry goes only once a later read holds it.
  test('without a recovery folder a merged copy is never deleted: it stays listed', () async {
    await start(recovery: false);
    final (id, _) = await closedPageWithBox();
    final path = copyPath(id, 'DESKTOP-4QK2N8L');
    await writeCopy(path, (await other.load(id)).insertNode(noteBox('extra', at: const Bounds(400, 10, 200, 40))));
    await nb.checkFile(path);
    expect(File(path).existsSync(), isTrue);
    expect(nb.unreadable.map((u) => u.path), [path]);
    expect(nb.unreadable.single.reason, contains('could not be kept in recovery'));
  });

  test('an identical copy is kept in recovery; the first re-check retires it and the page file is untouched', () async {
    await start();
    final (id, _) = await closedPageWithBox();
    final before = File(pathOf(id)).readAsStringSync();
    final stamp = File(pathOf(id)).lastModifiedSync();
    final path = copyPath(id, 'DESKTOP-4QK2N8L');
    await File(path).writeAsString(before);
    await nb.checkFile(path);
    expect(File(path).existsSync(), isFalse);
    expect((await entries()).single.pageId, id);
    expect((await nb.pendingRecovery()).entries, isEmpty, reason: 'not an edit waiting');
    await nb.recoverNowForTest();
    expect(await entries(), hasLength(1), reason: 'not due yet');
    await recheck();
    expect(await entries(), isEmpty);
    expect(File(pathOf(id)).readAsStringSync(), before);
    expect(File(pathOf(id)).lastModifiedSync(), stamp);
  });

  test('a watcher merges a copy that appears while running', () async {
    await start(watch: true);
    final (id, box) = await closedPageWithBox();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final added = noteBox('via watcher');
    final path = copyPath(id, 'DESKTOP-4QK2N8L');
    await writeCopy(path, (await other.load(id)).insertNode(added));

    final end = DateTime.now().add(const Duration(seconds: 20));
    while (File(path).existsSync()) {
      if (DateTime.now().isAfter(end)) fail('the copy was not merged in time');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, added.id});
    expect(nb.unreadable, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  group('the merge of a closed page runs as one chain job (run 2026-11-06-04)', () {
    test('a page opened during the merge shows the merged page, and an edit keeps the copy', () async {
      await start();
      final (id, box) = await closedPageWithBox();
      final added = noteBox('from the copy', at: const Bounds(400, 10, 200, 40));
      final path = copyPath(id, 'DESKTOP-4QK2N8L');
      await writeCopy(path, (await other.load(id)).insertNode(added));
      final paused = Completer<void>();
      final resume = Completer<void>();
      nb.syncHook = (point, _) async {
        if (point != 'original-read') return;
        paused.complete();
        await resume.future;
      };
      final check = nb.checkFile(path);
      await paused.future;
      var opened = false;
      final open = nb.open(id).then((_) => opened = true);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(opened, isFalse, reason: 'the open waits for the merge');
      resume.complete();
      await check;
      await open;
      nb.syncHook = null;

      expect(nb.currentId, id);
      expect(nb.current!.page.node(added.id), isNotNull, reason: 'the editor shows the merge');
      final c = nb.current!;
      final mine = c.createBoxAt(const Bounds(10, 300, 0, 0));
      c.commit(mine.id, modules.codecs.codecFor('noted.note')!.decode(doc('after'), 1));
      await nb.flush();
      expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, added.id, mine.id});
      expect(File(path).existsSync(), isFalse);
    });

    test('a page opened ahead of the queued job takes the merge in the editor (in-job re-check)', () async {
      await start();
      final (id, box) = await closedPageWithBox();
      final added = noteBox('from the copy', at: const Bounds(400, 10, 200, 40));
      final path = copyPath(id, 'DESKTOP-4QK2N8L');
      await writeCopy(path, (await other.load(id)).insertNode(added));
      // The page is opened after the check decided "closed" and before its job
      // is queued; the job must see it open.
      nb.syncHook = (point, _) async {
        if (point == 'conflict-copy-closed') await nb.open(id);
      };
      await nb.checkFile(path);
      nb.syncHook = null;
      expect(nb.currentId, id);
      expect(nb.current!.page.nodes.map((n) => n.id).toSet(), {box.id, added.id});
      expect(File(path).existsSync(), isFalse);
      await nb.flush();
      expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, added.id});
    });

    test('a page opened before the job runs takes the merge in the editor', () async {
      await start();
      final (id, box) = await closedPageWithBox();
      final added = noteBox('from the copy', at: const Bounds(400, 10, 200, 40));
      final path = copyPath(id, 'DESKTOP-4QK2N8L');
      await writeCopy(path, (await other.load(id)).insertNode(added));
      // The check starts, then the page is opened before the merge runs.
      final check = nb.checkFile(path);
      await nb.open(id);
      await check;
      expect(nb.current!.page.id, id);
      expect(nb.current!.page.nodes.map((n) => n.id).toSet(), {box.id, added.id});
      expect(File(path).existsSync(), isFalse);
      await nb.flush();
      expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, added.id});
    });

    test('a check started by a timer made inside a chain job still queues on the chain', () async {
      await start();
      final (id, box) = await closedPageWithBox();
      final a = noteBox('copy one', at: const Bounds(400, 10, 200, 40));
      final b = noteBox('copy two', at: const Bounds(400, 100, 200, 40));
      final path1 = copyPath(id, 'DESKTOP-1');
      final path2 = copyPath(id, 'DESKTOP-2');
      final base = await other.load(id);
      await writeCopy(path1, base.insertNode(a));
      await writeCopy(path2, base.insertNode(b));
      final paused = Completer<void>();
      final resume = Completer<void>();
      Future<void>? second;
      var calls = 0;
      nb.syncHook = (point, _) async {
        if (point != 'original-read') return;
        if (++calls == 1) {
          // Inside the first merge's chain job: a timer that starts the next
          // check after the job has ended.
          Timer(const Duration(milliseconds: 30), () => second = nb.checkFile(path2));
          return;
        }
        paused.complete();
        await resume.future;
      };
      await nb.checkFile(path1);
      await paused.future;
      expect(second, isNotNull);
      var opened = false;
      final open = nb.open(id).then((_) => opened = true);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(opened, isFalse, reason: 'the second merge holds the chain: it was queued, not run inline');
      resume.complete();
      await second;
      await open;
      nb.syncHook = null;
      expect(nb.current!.page.nodes.map((n) => n.id).toSet(), {box.id, a.id, b.id});
      expect(File(path1).existsSync() || File(path2).existsSync(), isFalse);
    });

    test('a check that runs inside a chain job and meets a copy of a closed page completes', () async {
      await start();
      final (id, box) = await closedPageWithBox();
      final added = noteBox('from the copy', at: const Bounds(400, 10, 200, 40));
      final path = copyPath(id, 'DESKTOP-4QK2N8L');
      await writeCopy(path, (await other.load(id)).insertNode(added));
      // As a save's own check runs: inside a job of the chain, which can't
      // queue the merge on the chain and wait for it.
      await nb.checkFileInChainForTest(path).timeout(const Duration(seconds: 20));
      expect(File(path).existsSync(), isFalse);
      expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, added.id});
    });
  });

  group('provider names (design 2026-11-15-01 section 5)', () {
    String named(String id, String suffix) => '${dir.path}$sep$id$suffix.canvas';

    test('Drive, Finder and Nextcloud names are merged into the original and deleted', () async {
      await start();
      final (id, _) = await closedPageWithBox();
      for (final suffix in [' (1)', ' 2', ' (conflicted copy 2018-04-10 093612)']) {
        final added = noteBox('from $suffix');
        final path = named(id, suffix);
        await writeCopy(path, (await other.load(id)).insertNode(added));
        await nb.checkFile(path);
        expect(File(path).existsSync(), isFalse, reason: suffix);
        expect(onDisk(id).node(added.id), isNotNull, reason: suffix);
      }
      expect(nb.unreadable, isEmpty);
    });

    test('a chain with a missing middle file is merged into the original', () async {
      await start();
      final (id, box) = await closedPageWithBox();
      final added = noteBox('chain');
      final path = named(id, '-DESKTOP-4QK2N8L (1)'); // no <id>-DESKTOP-4QK2N8L.canvas
      await writeCopy(path, (await other.load(id)).insertNode(added));
      await nb.checkFile(path);
      expect(File(path).existsSync(), isFalse);
      expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, added.id});
    });

    test('opening <id> 2.canvas from a file association merges it as a copy', () async {
      await start();
      final (id, box) = await closedPageWithBox();
      final added = noteBox('opened as a file');
      final path = named(id, ' 2');
      await writeCopy(path, (await other.load(id)).insertNode(added));
      await nb.adoptUnlistedPageFile(path, id);
      await nb.checkFile(path);
      expect(File(path).existsSync(), isFalse);
      expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, added.id});
      expect(nb.unreadable, isEmpty);
    });

    // Run 2026-11-16-01: a copy found at startup goes through the same keep and
    // re-check (R-1), and the same-id merge takes the stricter AI access.
    Future<void> restart() async {
      nb.dispose();
      nb = makeNotebook(PageStore(dir));
      await nb.load();
      await nb.createPage(); // the merged page is closed (an open one waits)
    }

    test('an <id> 2.canvas merged after a restart, then the old original put back: the re-check restores it', () async {
      await start();
      final (id, box) = await closedPageWithBox();
      final before = File(pathOf(id)).readAsStringSync();
      final added = noteBox('from the second file', at: const Bounds(400, 10, 200, 40));
      final path = named(id, ' 2');
      await writeCopy(path, (await other.load(id)).insertNode(added));
      await restart();
      expect(File(path).existsSync(), isFalse);
      expect(onDisk(id).node(added.id), isNotNull);
      expect((await entries()).single.page.node(added.id), isNotNull, reason: 'kept until the re-check');
      await busyRetry(() => File(pathOf(id)).writeAsString(before)); // sync puts the old file back
      await recheck();
      expect(onDisk(id).nodes.map((n) => n.id).toSet(), {box.id, added.id});
      expect(await entries(), hasLength(1), reason: 'merged again: re-checked once more');
      await recheck();
      expect(await entries(), isEmpty);
      expect(onDisk(id).node(added.id), isNotNull);
    });

    test('a Guarded <id> 2.canvas merged into an Open original after a restart: the page is Guarded', () async {
      await start();
      final (id, _) = await closedPageWithBox();
      final open = await other.load(id);
      await saveAsOther(open.withMeta(open.meta.withAiAccess(AiAccess.open)));
      final path = named(id, ' 2');
      await writeCopy(path, open.withMeta(open.meta.withAiAccess(AiAccess.guarded)));
      await restart();
      expect(File(path).existsSync(), isFalse);
      expect(onDisk(id).meta.rawAiAccess, RawJson.encode('guarded'));
      expect(nb.ownAiAccess(id), AiAccess.guarded);
    });

    // A chosen <id> 2.canvas (id has no <id>.canvas when it is chosen), then
    // <id>.canvas comes back: <id> 2 (1).canvas is a copy of the chosen file.
    Future<(String, BoxRecord, String)> withChosenSecond() async {
      final (id, box) = await closedPageWithBox();
      final text = File(pathOf(id)).readAsStringSync();
      final chosen = named(id, ' 2');
      final dupe = '${dir.path}${sep}dupe.canvas';
      File(pathOf(id)).renameSync(dupe);
      await nb.checkFile(pathOf(id));
      await nb.checkFile(dupe);
      await busyRetry(() => File(chosen).writeAsString(text));
      await nb.checkFile(chosen);
      await nb.adoptUnlistedPageFile(chosen, id);
      await busyRetry(() => File(pathOf(id)).writeAsString(text));
      await nb.checkFile(pathOf(id));
      return (id, box, chosen);
    }

    test('a copy of a chosen <id> 2.canvas merges into it, not into <id>.canvas', () async {
      await start();
      final (id, box, chosen) = await withChosenSecond();
      final plain = File(pathOf(id)).readAsStringSync();
      final added = noteBox('into the chosen file');
      final path = named(id, ' 2 (1)');
      await writeCopy(path, (await other.load(id)).insertNode(added));
      await nb.checkFile(path);
      expect(File(path).existsSync(), isFalse);
      expect(readPage(File(chosen).readAsStringSync()).nodes.map((n) => n.id).toSet(), {box.id, added.id});
      expect(File(pathOf(id)).readAsStringSync(), plain);
    });

    test('the watcher merges it into the chosen file too', () async {
      await start(watch: true);
      final (id, box, chosen) = await withChosenSecond();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final plain = File(pathOf(id)).readAsStringSync();
      final added = noteBox('via watcher');
      final path = named(id, ' 2 (1)');
      await writeCopy(path, (await other.load(id)).insertNode(added));
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (File(path).existsSync()) {
        if (DateTime.now().isAfter(end)) fail('the copy was not merged in time');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(readPage(File(chosen).readAsStringSync()).nodes.map((n) => n.id).toSet(), {box.id, added.id});
      expect(File(pathOf(id)).readAsStringSync(), plain);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('older ownCloud names are merged into the original and deleted', () async {
      await start();
      final (id, _) = await closedPageWithBox();
      final added = noteBox('owncloud');
      final path = named(id, '_conflict-20180410-093612');
      await writeCopy(path, (await other.load(id)).insertNode(added));
      await nb.checkFile(path);
      expect(File(path).existsSync(), isFalse);
      expect(onDisk(id).node(added.id), isNotNull);
    });

    test('saving a chosen <id> 2.canvas while <id>.canvas exists neither merges nor lists it', () async {
      await start();
      final (id, _, chosen) = await withChosenSecond();
      final plain = File(pathOf(id)).readAsStringSync();
      await nb.open(id);
      final c = nb.current!;
      final mine = c.createBoxAt(const Bounds(10, 10, 0, 0));
      c.commit(mine.id, modules.codecs.codecFor('noted.note')!.decode(doc('edit of the chosen page'), 1));
      await nb.flush();
      await nb.checkFile(chosen);
      expect(File(chosen).existsSync(), isTrue);
      expect(readPage(File(chosen).readAsStringSync()).node(mine.id), isNotNull);
      expect(File(pathOf(id)).readAsStringSync(), plain);
      expect(nb.unreadable.where((u) => u.path == chosen), isEmpty);
      expect(nb.tree[id], isNotNull);
    });

    test('a copy-shaped duplicate with no original is promoted when the chosen file goes', () async {
      await start();
      final (id, _) = await closedPageWithBox();
      final text = File(pathOf(id)).readAsStringSync();
      final second = named(id, ' (1)'); // no <id>.canvas next to it
      final chosen = named(id, ' 2');
      File(pathOf(id)).renameSync(second);
      await nb.checkFile(pathOf(id));
      await nb.checkFile(second);
      await busyRetry(() => File(chosen).writeAsString(text));
      await nb.checkFile(chosen);
      await nb.adoptUnlistedPageFile(chosen, id);
      expect(nb.unreadable.map((u) => u.path), contains(second));
      File(chosen).deleteSync();
      await nb.checkFile(chosen);
      await nb.checkFolders();
      expect(nb.tree[id], isNotNull);
      expect(File(second).existsSync(), isTrue);
      expect(nb.unreadable.where((u) => u.path == second), isEmpty);
    });
  });
}