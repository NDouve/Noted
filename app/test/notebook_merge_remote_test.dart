// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
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

/// A store with hooks at the points a sync client could change a file.
class HookStore extends PageStore {
  HookStore(super.directory);

  /// Runs after each `readText` (the text has been read; the file may change).
  Future<void> Function(String id)? afterRead;

  /// Runs inside `saveIfUnchanged`, just before the file is moved aside.
  void Function()? beforeMoveAside;

  int writes = 0;
  Completer<void>? stallSaveNew;

  @override
  Future<String> readText(String pageId) async {
    final t = await super.readText(pageId);
    await afterRead?.call(pageId);
    return t;
  }

  @override
  Future<ReplaceResult> saveIfUnchanged(
    NotedPage page,
    String? expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    void Function()? beforePublish,
    void Function()? beforeRestore,
  }) {
    final hook = this.beforeMoveAside;
    this.beforeMoveAside = null;
    return super.saveIfUnchanged(
      page,
      expectedText,
      beforeMoveAside: hook,
      afterRead: afterRead,
      beforePublish: beforePublish,
      beforeRestore: beforeRestore,
    ).then((r) {
      if (r.replaced) writes++;
      return r;
    });
  }

  @override
  Future<bool> saveNew(NotedPage page, {Future<void> Function()? beforePublish}) async {
    final s = stallSaveNew;
    if (s != null) await s.future;
    return super.saveNew(page, beforePublish: beforePublish);
  }
}

void main() {
  late Directory dir;
  late Notebook nb;
  late HookStore store;
  late PageStore other;
  late ModuleRegistry modules;
  late List<LocalChange> events;
  late StreamSubscription<LocalChange> sub;
  final sep = Platform.pathSeparator;
  final extra = <Directory>[];

  Future<void> start({bool listen = true, FolderLocks? locks}) async {
    dir = await Directory.systemTemp.createTemp('noted_merge_remote');
    modules = buildModules();
    store = HookStore(dir);
    nb = Notebook(
      store,
      modules,
      saveDelay: const Duration(hours: 1),
      folderLocks: locks,
    );
    other = PageStore(dir);
    events = [];
    await nb.load();
    await other.scan();
    if (listen) sub = nb.localChanges.listen(events.add);
  }

  tearDown(() async {
    nb.dispose();
    for (final d in extra) {
      if (d.existsSync()) await busyRetry(() => d.delete(recursive: true));
    }
    extra.clear();
    await busyRetry(() => dir.delete(recursive: true));
  });

  BoxRecord noteBox(String text, {Bounds at = const Bounds(10, 10, 200, 40)}) {
    final codec = modules.codecs.codecFor('noted.note')!;
    return commitBox(createBox(codec, at), codec, codec.decode(doc(text), 1));
  }

  BoxRecord withText(BoxRecord b, String text) {
    final codec = modules.codecs.codecFor('noted.note')!;
    return commitBox(b, codec, codec.decode(doc(text), 1));
  }

  String pathOf(String id) => '${dir.path}$sep$id.canvas';
  String textOf(String id) => File(pathOf(id)).readAsStringSync();
  NotedPage onDisk(String id) => readPage(textOf(id));
  List<int> bytes(NotedPage p) => utf8.encode(writePage(p));
  Set<String> ids(NotedPage p) => {for (final n in p.nodes) n.id};
  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 20));

  /// A closed page holding one note; the open page is another one.
  Future<(String, BoxRecord, NotedPage)> closedPage() async {
    final id = nb.currentId!;
    final box = noteBox('base');
    final base = (await other.load(id)).insertNode(box);
    await busyRetry(() => other.save(base));
    await nb.createPage(); // opens another page; [id] is closed
    await nb.checkFile(pathOf(id));
    await pump();
    events.clear();
    return (id, box, base);
  }

  Future<void> expectUntouched(String id, String before, {String? why}) async {
    expect(textOf(id), before, reason: why ?? 'the file is untouched');
    await pump();
    expect(events, isEmpty, reason: 'no event');
  }

  group('a closed page', () {
    test('is merged and saved with one event carrying the identity of the file', () async {
      await start();
      final (id, box, base) = await closedPage();
      final local = noteBox('local', at: const Bounds(300, 10, 200, 40));
      await busyRetry(() => other.save(base.insertNode(local)));
      final remote = noteBox('remote', at: const Bounds(600, 10, 200, 40));
      final r = await nb.mergeRemote(pathOf(id), bytes(base), bytes(base.insertNode(remote)));
      expect(r.outcome, RemoteMergeOutcome.merged, reason: '$r');
      expect(r.wrote, isTrue);
      expect(ids(onDisk(id)), {box.id, local.id, remote.id});
      await pump();
      expect(events, hasLength(1));
      expect(events.single.kind, LocalChangeKind.published);
      expect(events.single.path, pathOf(id));
      final onFile = await ContentIdentity.ofFile(pathOf(id));
      expect(events.single.identity, onFile);
      expect(r.identity, onFile);
    });

    test('with nothing new to merge writes nothing and reports the identity of the file', () async {
      await start();
      final (id, _, base) = await closedPage();
      final before = textOf(id);
      final r = await nb.mergeRemote(pathOf(id), bytes(base), bytes(base));
      expect(r.outcome, RemoteMergeOutcome.merged);
      expect(r.wrote, isFalse);
      expect(r.identity, await ContentIdentity.ofFile(pathOf(id)));
      await expectUntouched(id, before);
    });

    test('a file that changed between the read and the save is merged again', () async {
      await start();
      final (id, box, base) = await closedPage();
      final synced = noteBox('synced', at: const Bounds(300, 10, 200, 40));
      var first = true;
      store.afterRead = (_) async {
        if (!first) return;
        first = false;
        await busyRetry(() => other.save(base.insertNode(synced)));
      };
      final remote = noteBox('remote', at: const Bounds(600, 10, 200, 40));
      final r = await nb.mergeRemote(pathOf(id), bytes(base), bytes(base.insertNode(remote)));
      expect(r.outcome, RemoteMergeOutcome.merged);
      expect(ids(onDisk(id)), {box.id, synced.id, remote.id});
      await pump();
      expect(events, hasLength(1));
    });

    test('a file that keeps changing gives changed, leaves the file and emits nothing', () async {
      await start();
      final (id, _, base) = await closedPage();
      var n = 0;
      store.afterRead = (_) async {
        final b = noteBox('sync ${n++}', at: Bounds(300.0 + n * 10, 10, 200, 40));
        await busyRetry(() => other.save(readPage(textOf(id)).insertNode(b)));
      };
      final remote = noteBox('remote', at: const Bounds(600, 10, 200, 40));
      final r = await nb.mergeRemote(pathOf(id), bytes(base), bytes(base.insertNode(remote)));
      expect(r.outcome, RemoteMergeOutcome.changed);
      expect(onDisk(id).node(remote.id), isNull, reason: 'the remote box was not written');
      await pump();
      expect(events, isEmpty);
    });

    test('a page opened during the merge shows the merged page, keeps it after an edit, and a fresh notebook agrees', () async {
      await start();
      final (id, box, base) = await closedPage();
      final remote = noteBox('remote', at: const Bounds(600, 10, 200, 40));
      final paused = Completer<void>();
      final resume = Completer<void>();
      var first = true;
      store.afterRead = (_) async {
        if (!first) return;
        first = false;
        paused.complete();
        await resume.future;
      };
      final merge = nb.mergeRemote(pathOf(id), bytes(base), bytes(base.insertNode(remote)));
      await paused.future;
      var opened = false;
      final open = nb.open(id).then((_) => opened = true);
      await pump();
      expect(opened, isFalse, reason: 'the open waits for the merge job');
      resume.complete();
      expect((await merge).outcome, RemoteMergeOutcome.merged);
      await open;
      expect(nb.currentId, id);
      expect(ids(nb.current!.page), {box.id, remote.id}, reason: 'the editor shows the merge');
      final c = nb.current!;
      final mine = c.createBoxAt(const Bounds(10, 300, 0, 0));
      c.commit(mine.id, modules.codecs.codecFor('noted.note')!.decode(doc('after'), 1));
      await nb.flush();
      expect(ids(onDisk(id)), {box.id, remote.id, mine.id});
      final fresh = Notebook(PageStore(dir), modules, saveDelay: const Duration(hours: 1));
      try {
        await fresh.load();
        await fresh.open(id);
        expect(ids(fresh.current!.page), {box.id, remote.id, mine.id});
      } finally {
        fresh.dispose();
      }
    });

    test('a remote title, parent and AI access are in the live tree and in a fresh notebook', () async {
      await start();
      final (id, _, base) = await closedPage();
      final parent = nb.currentId!; // the other page, open
      final meta = base.meta.withTitle('Remote title').withParent(parent).withAiAccess(AiAccess.open);
      final r = await nb.mergeRemote(pathOf(id), bytes(base), bytes(base.withMeta(meta)));
      expect(r.outcome, RemoteMergeOutcome.merged, reason: '$r');
      void check(Notebook n, String when) {
        expect(n.tree[id]!.title, 'Remote title', reason: when);
        expect(n.tree.descendantsOf(parent), contains(id), reason: when);
        expect(n.ownAiAccess(id), AiAccess.open, reason: when);
      }

      check(nb, 'live');
      final fresh = Notebook(PageStore(dir), modules, saveDelay: const Duration(hours: 1));
      try {
        await fresh.load();
        check(fresh, 'fresh');
      } finally {
        fresh.dispose();
      }
    });

    test('both sides changing a box of a type the page disallows leave it conflicted, both versions byte for byte', () async {
      await start();
      final (id, box, _) = await closedPage();
      await nb.setBoxType(id, 'noted.note', false);
      await nb.flush();
      final base = onDisk(id);
      final mine = withText(box, 'local side');
      await busyRetry(() => other.save(base.replaceNode(mine)));
      final theirs = withText(box, 'remote side');
      final r = await nb.mergeRemote(pathOf(id), bytes(base), bytes(base.replaceNode(theirs)));
      expect(r.outcome, RemoteMergeOutcome.merged, reason: '$r');
      final saved = onDisk(id).node(box.id)! as BoxRecord;
      expect(saved.isConflicted, isTrue);
      expect(saved.snapshotText, 'local side');
      expect(saved.conflicts.single.node, theirs.toRaw());
      expect(nb.hasConflict(id), isTrue);
    });

    test('a box of an unregistered type passes through byte for byte', () async {
      await start();
      final (id, _, base) = await closedPage();
      const data = r'{"b":1,  "z":"café", "a":[1, 2 ,3],"n":null}';
      final odd = BoxRecord.create(
        id: '00000000000000f1',
        typeId: 'x.unregistered',
        dataVersion: 3,
        bounds: const Bounds(900, 900, 100, 50),
        data: const RawJson.trusted(data),
        snapshotText: 'snapshot',
        rev: 'opaquerev',
      );
      final r = await nb.mergeRemote(pathOf(id), bytes(base), bytes(base.insertNode(odd)));
      expect(r.outcome, RemoteMergeOutcome.merged, reason: '$r');
      expect(onDisk(id).node(odd.id)!.toRaw().text, odd.toRaw().text);
    });

    test('merging the same inputs twice: the second run documents today\'s output', () async {
      await start();
      final (id, _, base) = await closedPage();
      final remote = noteBox('remote', at: const Bounds(600, 10, 200, 40));
      final args = (bytes(base), bytes(base.insertNode(remote)));
      expect((await nb.mergeRemote(pathOf(id), args.$1, args.$2)).outcome, RemoteMergeOutcome.merged);
      final once = textOf(id);
      final r2 = await nb.mergeRemote(pathOf(id), args.$1, args.$2);
      expect(r2.outcome, RemoteMergeOutcome.merged);
      // The page still holds the remote box once; the file is whatever the
      // merge of the same remote into the merged page gives.
      expect(ids(onDisk(id)), ids(readPage(once)));
      expect(onDisk(id).nodes.where((n) => n.id == remote.id), hasLength(1));
    });

    test('a move in progress is not failed by a landing merge: changed, and the move completes', () async {
      await start();
      final folder = await Directory.systemTemp.createTemp('noted_merge_remote_mv');
      extra.add(folder);
      late HookStore dest;
      nb.dispose();
      nb = Notebook(
        store = HookStore(dir),
        modules,
        saveDelay: const Duration(hours: 1),
        storeFactory: (d) => d.path == dir.path ? PageStore(d) : (dest = HookStore(d)),
      );
      await nb.load();
      final section = await nb.addBinder(folder.path);
      final id = nb.currentId!;
      await nb.createPage();
      await nb.flush();
      final base = readPage(textOf(id));
      final stall = Completer<void>();
      dest.stallSaveNew = stall;
      final move = nb.moveToLocation(id, binderPath: section.path);
      await pump();
      final before = textOf(id);
      final r = await nb.mergeRemote(pathOf(id), bytes(base), bytes(base.insertNode(noteBox('remote'))));
      expect(r.outcome, RemoteMergeOutcome.changed, reason: '$r');
      expect(textOf(id), before);
      stall.complete();
      expect(await move, isTrue, reason: 'the move is not failed by the merge');
    });
  });

  group('the open page', () {
    test('keeps unsaved edits plus the remote change, saves both, and it is not an undo step', () async {
      await start();
      final id = nb.currentId!;
      final base = await other.load(id);
      final c = nb.current!;
      final mine = c.createBoxAt(const Bounds(10, 10, 0, 0));
      c.commit(mine.id, modules.codecs.codecFor('noted.note')!.decode(doc('mine'), 1));
      events.clear();
      final remote = noteBox('remote', at: const Bounds(600, 10, 200, 40));
      final before = c.canUndo;
      final r = await nb.mergeRemote(pathOf(id), bytes(base), bytes(base.insertNode(remote)));
      expect(r.outcome, RemoteMergeOutcome.merged, reason: '$r');
      expect(nb.current, same(c));
      expect(ids(c.page), {mine.id, remote.id});
      expect(ids(onDisk(id)), {mine.id, remote.id});
      expect(r.identity, await ContentIdentity.ofFile(pathOf(id)));
      expect(before, isTrue);
      // One undo takes back the local edit; the remote box stays.
      c.undo();
      expect(c.page.node(remote.id), isNotNull);
      expect(c.page.node(mine.id), isNull);
    });

    test('a disk change during the save is merged too', () async {
      await start();
      final id = nb.currentId!;
      final base = await other.load(id);
      final c = nb.current!;
      final mine = c.createBoxAt(const Bounds(10, 10, 0, 0));
      c.commit(mine.id, modules.codecs.codecFor('noted.note')!.decode(doc('mine'), 1));
      await nb.flush();
      final synced = noteBox('synced', at: const Bounds(300, 10, 200, 40));
      store.beforeMoveAside = () => File(pathOf(id)).writeAsStringSync(writePage(readPage(textOf(id)).insertNode(synced)));
      final remote = noteBox('remote', at: const Bounds(600, 10, 200, 40));
      final r = await nb.mergeRemote(pathOf(id), bytes(base), bytes(base.insertNode(remote)));
      expect(r.outcome, RemoteMergeOutcome.merged, reason: '$r');
      expect(ids(onDisk(id)), {mine.id, synced.id, remote.id});
      expect(ids(nb.current!.page), {mine.id, synced.id, remote.id});
      expect(r.identity, await ContentIdentity.ofFile(pathOf(id)));
    });

    test('a merge that equals the page still saves and returns an identity, with no listener', () async {
      await start(listen: false);
      final id = nb.currentId!;
      final base = await other.load(id);
      final r = await nb.mergeRemote(pathOf(id), bytes(base), bytes(base));
      expect(r.outcome, RemoteMergeOutcome.merged, reason: '$r');
      expect(r.identity, await ContentIdentity.ofFile(pathOf(id)));
    });
  });

  group('refusals write nothing', () {
    Future<void> refused(String path, List<int> base, List<int> remote, String id, {String? why}) async {
      final before = textOf(id);
      final r = await nb.mergeRemote(path, base, remote);
      expect(r.outcome, RemoteMergeOutcome.refused, reason: why ?? '$r');
      await expectUntouched(id, before);
    }

    test('a path that is not the page\'s file (a same-id duplicate)', () async {
      await start();
      final (id, _, base) = await closedPage();
      final dup = '${dir.path}${sep}dup.canvas';
      File(dup).writeAsStringSync(writePage(base));
      await refused(dup, bytes(base), bytes(base), id);
      expect(File(dup).readAsStringSync(), writePage(base));
    });

    test('an unreadable remote, a newer format and another id', () async {
      await start();
      final (id, _, base) = await closedPage();
      await refused(pathOf(id), bytes(base), utf8.encode('not a page'), id);
      final newer = writePage(base).replaceFirst(RegExp(r'"format":\s*\d+'), '"format":999');
      await refused(pathOf(id), bytes(base), utf8.encode(newer), id);
      final otherPage = NotedPage.create(PageMeta.create(id: 'other${id.substring(5)}', title: 'O', order: 3));
      await refused(pathOf(id), bytes(base), bytes(otherPage), id);
      await refused(pathOf(id), utf8.encode('garbage'), bytes(base), id);
    });

    test('a read-only location', () async {
      await start();
      final folder = await Directory.systemTemp.createTemp('noted_merge_remote_ro');
      extra.add(folder);
      final section = await nb.addBinder(folder.path);
      final id = await nb.createPage(binderPath: section.path);
      await nb.flush();
      final path = '${folder.path}$sep$id.canvas';
      final base = readPage(File(path).readAsStringSync());
      await nb.createPage(); // the binder page is closed
      File('${folder.path}${sep}noted-binder.json').writeAsStringSync('damaged');
      await nb.checkBinderFile('${folder.path}${sep}noted-binder.json');
      final before = File(path).readAsStringSync();
      final r = await nb.mergeRemote(
        path,
        bytes(base),
        bytes(base.insertNode(noteBox('remote'))),
      );
      expect(r.outcome, RemoteMergeOutcome.refused, reason: '$r');
      expect(File(path).readAsStringSync(), before);
    });

    test('a blocked open page: refused, the editor and the file are unchanged', () async {
      await start();
      final id = nb.currentId!;
      final base = await other.load(id);
      File(pathOf(id)).writeAsStringSync('not a page');
      await nb.checkFile(pathOf(id));
      final shown = writePage(nb.current!.page);
      final before = textOf(id);
      final r = await nb.mergeRemote(pathOf(id), bytes(base), bytes(base.insertNode(noteBox('remote'))));
      expect(r.outcome, RemoteMergeOutcome.refused, reason: '$r');
      expect(writePage(nb.current!.page), shown);
      expect(textOf(id), before);
    });

    test('a page that was moved and ended in both places: the copy that is not the page\'s is refused', () async {
      await start();
      final folder = await Directory.systemTemp.createTemp('noted_merge_remote_both');
      extra.add(folder);
      late FlakyDelete source;
      late FlakyDelete dest;
      nb.dispose();
      nb = Notebook(
        source = FlakyDelete(dir),
        modules,
        saveDelay: const Duration(hours: 1),
        storeFactory: (d) => d.path == dir.path ? PageStore(d) : (dest = FlakyDelete(d)),
      );
      await nb.load();
      final section = await nb.addBinder(folder.path);
      final id = nb.currentId!;
      await nb.createPage();
      await nb.flush();
      final base = readPage(textOf(id));
      source.failDelete = true;
      dest.failDelete = true;
      try {
        await nb.moveToLocation(id, binderPath: section.path);
      } on NotebookException {
        // Partly moved, as the test wants.
      }
      final inSource = File(pathOf(id)).existsSync();
      final inBinder = File('${folder.path}$sep$id.canvas').existsSync();
      if (!(inSource && inBinder)) {
        markTestSkipped('the move did not end in both places here');
        return;
      }
      final here = nb.binderOfPage(id) == section.path ? pathOf(id) : '${folder.path}$sep$id.canvas';
      final before = File(here).readAsStringSync();
      final r = await nb.mergeRemote(here, bytes(base), bytes(base.insertNode(noteBox('remote'))));
      expect(r.outcome, RemoteMergeOutcome.refused, reason: '$r');
      expect(File(here).readAsStringSync(), before);
    });

    test('a scan queued ahead that moves the page\'s file: refused inside the job, no write', () async {
      await start();
      final (id, _, base) = await closedPage();
      final before = textOf(id);
      final gate = Completer<void>();
      final held = nb.folderLocks.run(dir, () => gate.future);
      final dupPath = '${dir.path}${sep}dup-file.canvas';
      File(dupPath).writeAsStringSync(before);
      final merge = nb.mergeRemote(pathOf(id), bytes(base), bytes(base.insertNode(noteBox('remote'))));
      // The merge has read the page and waits for the lock; a scan re-adopts
      // another file of the same id ahead of its write.
      await pump();
      await pump();
      store.adopt(id, dupPath);
      gate.complete();
      await held;
      final r = await merge;
      expect(r.outcome, RemoteMergeOutcome.refused, reason: '$r');
      expect(textOf(id), before);
      expect(File(dupPath).readAsStringSync(), before);
    });
  });

  group('the lock', () {
    test('mergeRemote inside a FolderLocks job on its folder fails the debug assert', () async {
      await start();
      final (id, _, base) = await closedPage();
      Object? thrown;
      await nb.folderLocks.run(dir, () async {
        try {
          await nb.mergeRemote(pathOf(id), bytes(base), bytes(base));
        } on Object catch (e) {
          thrown = e;
        }
      });
      expect(thrown, isA<AssertionError>());
    });

    test('a shared FolderLocks held open makes a save, a scan and a delete wait', () async {
      final shared = FolderLocks();
      await start(locks: shared);
      expect(nb.folderLocks, same(shared));
      final (id, _, base) = await closedPage();
      final victim = await nb.createPage();
      await nb.flush();
      await nb.createPage(); // the victim is closed
      final gate = Completer<void>();
      final held = shared.run(dir, () => gate.future);
      var scanned = false;
      final scan = nb.scanLocationForTest('').then((_) => scanned = true);
      var merged = false;
      final merge = nb
          .mergeRemote(pathOf(id), bytes(base), bytes(base.insertNode(noteBox('remote'))))
          .then((r) {
            merged = true;
          });
      var deleted = false;
      final delete = nb.delete(victim).then((_) => deleted = true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(scanned, isFalse);
      expect(merged, isFalse);
      expect(deleted, isFalse);
      gate.complete();
      await held;
      await Future.wait<Object?>([scan, merge, delete]);
      expect(FolderLocks.keyOf(dir), FolderLocks.keyOf(Directory('${dir.path}$sep')));
    });
  });
}

/// A store whose delete can be made to fail.
class FlakyDelete extends PageStore {
  FlakyDelete(super.directory);

  bool failDelete = false;

  @override
  Future<DeleteResult> deleteIfUnchanged(
    String pageId,
    String expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    Future<void> Function()? beforeDelete,
    void Function()? beforeRestore,
  }) async {
    if (failDelete) throw const FileSystemException('delete failed');
    return super.deleteIfUnchanged(pageId, expectedText);
  }
}
