// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

/// A store whose saves lose the page's boxes: a recovery that goes through it
/// can't pass the check.
class _LossyStore extends PageStore {
  _LossyStore(super.directory);

  @override
  Future<void> save(NotedPage page) => super.save(NotedPage.create(page.meta));

  @override
  Future<ReplaceResult> saveIfUnchanged(
    NotedPage page,
    String? expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    void Function()? beforePublish,
    void Function()? beforeRestore,
  }) => super.saveIfUnchanged(NotedPage.create(page.meta), expectedText);
}

/// A store that runs [onPublish] just before a save, replace or new-file
/// publish: a file changing between the replay's read and its write.
class _RacingStore extends PageStore {
  _RacingStore(super.directory, this.onPublish);

  final void Function(int call) onPublish;
  int calls = 0;

  @override
  Future<void> save(NotedPage page) {
    onPublish(calls++);
    return super.save(page);
  }

  @override
  Future<bool> saveNew(NotedPage page, {Future<void> Function()? beforePublish}) {
    onPublish(calls++);
    return super.saveNew(page, beforePublish: beforePublish);
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
    onPublish(calls++);
    return super.saveIfUnchanged(page, expectedText);
  }
}

/// A store whose scan can land a file and report a conflict copy at its path,
/// like a sync client writing while the folder is being read again.
class _LandingStore extends PageStore {
  _LandingStore(super.directory, this.plan);

  // Shared by every store the notebook makes for the folder.
  final _Landing plan;

  @override
  Future<List<PageEntry>> scan() async {
    final entries = await super.scan();
    final p = plan.path;
    if (p == null) return entries;
    File(p).writeAsStringSync(plan.text!);
    return [...entries, ConflictCopyPage(p, plan.page!.meta, p)];
  }
}

class _Landing {
  String? path;
  String? text;
  NotedPage? page;
}

/// A store whose reads and saves can be made to fail or to lose data.
class _ToggleStore extends PageStore {
  _ToggleStore(super.directory);

  bool lossy = false;
  bool throwOnRead = false;
  bool alterRead = false;

  @override
  Future<void> save(NotedPage page) => super.save(lossy ? NotedPage.create(page.meta) : page);

  @override
  Future<String> readText(String pageId) async {
    if (throwOnRead) throw const FileSystemException('injected read failure');
    final t = await super.readText(pageId);
    return alterRead ? '$t ' : t;
  }
}

void main() {
  late Directory root;
  late Directory pages;
  late Directory extra;
  late Directory away;
  late Directory rec;
  late List<Notebook> opened;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_recovery');
    pages = await Directory('${root.path}/pages').create();
    extra = await Directory('${root.path}/Elsewhere').create();
    away = Directory('${root.path}/Elsewhere-away');
    rec = Directory('${root.path}/rec');
    opened = [];
  });

  tearDown(() async {
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Notebook make({PageStore? store, PageStore Function(Directory)? storeFactory}) {
    final nb = Notebook(
      store ?? PageStore(pages),
      buildModules(),
      storeFactory: storeFactory ?? PageStore.new,
      saveDelay: const Duration(hours: 1), // saves happen only through flush
      bindersFile: File('${root.path}/app/binders.json'),
      recoveryDirectory: rec,
      folderCheckInterval: Duration.zero,
    );
    opened.add(nb);
    return nb;
  }

  // Quitting: nothing more is written.
  void quit(Notebook nb) {
    nb.dispose();
    opened.remove(nb);
  }

  File pageFile(Directory d, String id) => File('${d.path}/$id.canvas');
  List<String> recFiles() =>
      rec.existsSync() ? [for (final f in rec.listSync()) f.path] : const [];

  // A page in the extra folder, saved with no boxes, then open with one new
  // box pending (not saved). Returns the page id and the file text before.
  Future<(Notebook, String, String)> pendingEdit() async {
    final nb = make();
    await nb.load();
    final x = await nb.createPage(folderPath: extra.path);
    await nb.flush();
    await nb.open(x);
    final before = pageFile(extra, x).readAsStringSync();
    nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
    return (nb, x, before);
  }

  Future<void> vanish(Notebook nb) async {
    await extra.rename(away.path);
    await nb.checkFolders();
  }

  Future<void> restore() async {
    await away.rename(extra.path);
  }

  test('a pending edit is kept when the folder vanishes; nothing is written to the folder', () async {
    final (nb, x, before) = await pendingEdit();
    await vanish(nb);

    final listing = await nb.pendingRecovery();
    expect(listing.entries, hasLength(1));
    expect(listing.problems, isEmpty);
    final e = listing.entries.single;
    expect(e.pageId, x);
    // Exactly what a save would have written, and the base it would merge on.
    expect(e.pageText, writePage(nb.current!.page));
    expect(e.file.existsSync(), isTrue);
    expect(e.baseText, before);
    expect(e.page.nodes, hasLength(1));
    expect(extra.existsSync(), isFalse);
    expect(away.existsSync(), isTrue);
    expect(readPage(pageFile(away, x).readAsStringSync()).nodes, isEmpty);
    expect(recFiles().where((p) => p.endsWith('.tmp')), isEmpty);
  });

  test('edits while the folder is gone (read-only) create no entries', () async {
    final (nb, _, _) = await pendingEdit();
    await vanish(nb);
    final files = recFiles()..sort();
    final text = [for (final f in files) File(f).readAsStringSync()];
    expect(nb.current!.readOnly, isTrue);
    expect(() => nb.current!.createBoxAt(const Bounds(5, 5, 0, 0)), throwsStateError);
    await nb.flush();
    await nb.checkFolders();
    expect(recFiles()..sort(), files);
    expect([for (final f in files) File(f).readAsStringSync()], text);
    expect(extra.existsSync(), isFalse);
  });

  test('folder back while running: merged, verified, entry deleted', () async {
    final (nb, x, _) = await pendingEdit();
    await vanish(nb);
    expect(recFiles(), isNotEmpty);
    await restore();
    await nb.checkFolders();
    expect(readPage(pageFile(extra, x).readAsStringSync()).nodes, hasLength(1));
    expect(nb.current!.readOnly, isFalse);
    expect(nb.current!.page.nodes, hasLength(1));
    expect(recFiles(), isEmpty);
  });

  test('quit and relaunch: kept while the folder is missing, merged when it returns', () async {
    final (nb, x, _) = await pendingEdit();
    await vanish(nb);
    quit(nb);

    final again = make();
    await again.load();
    expect((await again.pendingRecovery()).entries, hasLength(1));
    expect(recFiles(), isNotEmpty);
    expect(extra.existsSync(), isFalse);

    await restore();
    await again.checkFolders();
    expect(readPage(pageFile(extra, x).readAsStringSync()).nodes, hasLength(1));
    expect(recFiles(), isEmpty);
    expect(again.tree[x], isNotNull);
  });

  test('relaunch with the folder already back: merged at launch', () async {
    final (nb, x, _) = await pendingEdit();
    await vanish(nb);
    quit(nb);
    await restore();

    final again = make();
    await again.load();
    expect(readPage(pageFile(extra, x).readAsStringSync()).nodes, hasLength(1));
    expect(recFiles(), isEmpty);
  });

  test('a change made elsewhere while away: both are kept', () async {
    final (nb, x, _) = await pendingEdit();
    await vanish(nb);
    quit(nb);
    final other = CanvasController(
      readPage(pageFile(away, x).readAsStringSync()),
      buildModules(),
    )..createBoxAt(const Bounds(300, 300, 0, 0));
    final theirs = other.page;
    pageFile(away, x).writeAsStringSync(writePage(theirs));
    other.dispose();
    await restore();

    final again = make();
    await again.load();
    final merged = readPage(pageFile(extra, x).readAsStringSync());
    expect(merged.nodes, hasLength(2));
    expect(merged.nodes.map((n) => n.id), containsAll(theirs.nodes.map((n) => n.id)));
    expect(recFiles(), isEmpty);
  });

  group('R-2 replay over a page file that changes while it runs', () {
    BoxRecord newerBox(String id) => BoxRecord.create(
      id: id,
      typeId: 'test.other',
      dataVersion: 1,
      bounds: const Bounds(300, 300, 100, 40),
      data: RawJson.encode({'n': 1}),
      snapshotText: 'newer',
      rev: 'r-$id',
    );

    // Adds box [id] to whatever the file holds now, as a newer generation, or
    // creates the file from [fallback] when it is absent.
    void landNewer(File f, String id, NotedPage fallback) {
      final cur = f.existsSync() ? readPage(f.readAsStringSync()) : fallback;
      f.writeAsStringSync(writePage(cur.insertNode(newerBox(id))));
    }

    Future<(Notebook, String, NotedPage, _RacingStore)> setUp1(
      void Function(int call, File f, NotedPage original) onPublish, {
      bool deleteFile = false,
    }) async {
      final (nb, x, _) = await pendingEdit();
      await vanish(nb);
      quit(nb);
      final original = readPage(pageFile(away, x).readAsStringSync());
      if (deleteFile) pageFile(away, x).deleteSync();
      await restore();
      final store = _RacingStore(extra, (call) => onPublish(call, pageFile(extra, x), original));
      return (
        make(storeFactory: (d) => d.path == extra.path ? store : PageStore(d)),
        x,
        original,
        store,
      );
    }

    test('a newer generation landing before the publish is merged, not overwritten', () async {
      var entryPresent = false;
      final (again, x, original, _) = await setUp1((call, f, o) {
        if (call == 0) {
          entryPresent = recFiles().isNotEmpty;
          landNewer(f, 'newgen', o);
        }
      });
      await again.load();
      expect(entryPresent, isTrue, reason: 'the entry is still there when the publish is attempted');
      final disk = readPage(pageFile(extra, x).readAsStringSync());
      expect(disk.node('newgen'), isNotNull, reason: 'the newer edits survive');
      expect(disk.nodes, hasLength(original.nodes.length + 2)); // the pending box and theirs
      expect(recFiles(), isEmpty);
    });

    test('a page absent at the read is published only if still absent', () async {
      final (again, x, original, store) = await setUp1((call, f, o) {
        if (call == 0) landNewer(f, 'newgen', o);
      }, deleteFile: true);
      await again.load();
      final disk = readPage(pageFile(extra, x).readAsStringSync());
      expect(disk.node('newgen'), isNotNull, reason: 'the file that appeared is merged, not replaced');
      expect(disk.nodes, hasLength(original.nodes.length + 2)); // the pending box and theirs
      expect(store.calls, 2);
      expect(recFiles(), isEmpty);
    });

    test('the entry stays when the file keeps changing, and nothing newer is lost', () async {
      var n = 0;
      final (again, x, _, _) = await setUp1((call, f, o) => landNewer(f, 'gen${n++}', o));
      await again.load();
      final disk = readPage(pageFile(extra, x).readAsStringSync());
      for (var i = 0; i < n; i++) {
        expect(disk.node('gen$i'), isNotNull);
      }
      expect(recFiles(), isNotEmpty, reason: 'never verified: the entry is not retired');    });
  });

  test('the page file was deleted while away: the recovered page is written', () async {
    final (nb, x, _) = await pendingEdit();
    final mine = writePage(nb.current!.page);
    await vanish(nb);
    quit(nb);
    pageFile(away, x).deleteSync();
    await restore();

    final again = make();
    await again.load();
    expect(pageFile(extra, x).readAsStringSync(), mine);
    expect(again.tree[x], isNotNull);
    expect(recFiles(), isEmpty);
  });

  test('the open page whose file was deleted while away is written again', () async {
    final (nb, x, _) = await pendingEdit();
    await vanish(nb);
    pageFile(away, x).deleteSync();
    await restore();
    await nb.checkFolders();
    expect(readPage(pageFile(extra, x).readAsStringSync()).nodes, hasLength(1));
    expect(recFiles(), isEmpty);
    expect(nb.current!.readOnly, isFalse);
  });

  for (final saved in [false, true]) {
  test('the open page whose folder returns with an unreadable file keeps merging what lands later${saved ? ' (no recovery entry)' : ''}', () async {
    final (nb, x, _) = await pendingEdit();
    if (saved) await nb.flush();
    await vanish(nb);
    if (saved) expect(recFiles(), isEmpty);
    final original = readPage(pageFile(away, x).readAsStringSync());
    pageFile(away, x).deleteSync();
    await restore();
    // A newer-format file is in its place when the folder comes back.
    final newer = writePage(original).replaceFirst(RegExp(r'"format"\s*:\s*1'), '"format":99');
    pageFile(extra, x).writeAsStringSync(newer);
    await nb.checkFolders();
    expect(pageFile(extra, x).readAsStringSync(), newer, reason: 'never written over');
    expect(nb.current!.readOnly, isTrue);
    expect(nb.readOnlyReason, allOf(contains('from a newer version of Noted'), contains('open another page')));

    // A readable version lands, with a box the other device added.
    final theirBox = BoxRecord.create(
      id: 'theirbox',
      typeId: 'test.other',
      dataVersion: 1,
      bounds: const Bounds(300, 300, 100, 40),
      data: RawJson.encode({'n': 1}),
      snapshotText: 'theirs',
      rev: 'r-theirs',
    );
    pageFile(extra, x).writeAsStringSync(writePage(original.insertNode(theirBox)));
    await nb.checkFolders();
    expect(nb.current!.readOnly, isFalse);
    expect(nb.current!.page.node('theirbox'), isNotNull);

    nb.current!.createBoxAt(const Bounds(80, 80, 0, 0));
    await nb.flush();
    final disk = readPage(pageFile(extra, x).readAsStringSync());
    expect(disk.node('theirbox'), isNotNull, reason: 'their box must survive the next save');
    expect(disk.nodes.length, 3); // the pending box, theirs, the new one
  });
  }

  test('a recovery that fails the check keeps the entry', () async {
    final nb = make();
    await nb.load();
    final a = nb.currentId!;
    nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
    final moved = Directory('${root.path}/pages-away');
    await pages.rename(moved.path);
    await nb.checkFolders();
    expect((await nb.pendingRecovery()).entries, hasLength(1));
    quit(nb);
    await moved.rename(pages.path);

    final again = make(store: _LossyStore(pages));
    await again.load();
    expect((await again.pendingRecovery()).entries.single.pageId, a);
    expect(recFiles(), isNotEmpty);
  });

  test('a damaged entry is kept and reported', () async {
    rec.createSync(recursive: true);
    File('${rec.path}/bad-1.json').writeAsStringSync('{ nope');
    File('${rec.path}/bad-1.canvas').writeAsStringSync('not a page');
    final nb = make();
    await nb.load();
    expect(nb.recoveryProblems, hasLength(1));
    expect(File('${rec.path}/bad-1.json').existsSync(), isTrue);
    expect(File('${rec.path}/bad-1.canvas').existsSync(), isTrue);
    expect((await nb.pendingRecovery()).entries, isEmpty);
  });

  test('a newer edit replaces the entry of the page', () async {
    final (nb, x, _) = await pendingEdit();
    await nb.flush(); // lands in the folder, no entry
    expect(recFiles(), isEmpty);
    nb.current!.createBoxAt(const Bounds(80, 80, 0, 0));
    await extra.rename(away.path); // vanishes before the next look
    await nb.flush();
    expect((await nb.pendingRecovery()).entries.single.page.nodes, hasLength(2));
    nb.current!.createBoxAt(const Bounds(120, 120, 0, 0)); // still looks writable
    await nb.flush();
    final e = (await nb.pendingRecovery()).entries;
    expect(e, hasLength(1));
    expect(e.single.pageId, x);
    expect(e.single.page.nodes, hasLength(3));
  });

  test('verifyRecoveredPage notices a lost edit', () {
    final base = NotedPage.create(PageMeta.create(id: 'p', title: 'p', order: 0));
    final c = CanvasController(base, buildModules())..createBoxAt(const Bounds(0, 0, 0, 0));
    final mine = c.page;
    c.dispose();
    expect(
      verifyRecoveredPage(base: base, mine: mine, theirs: base, result: mine),
      isNull,
    );
    expect(
      verifyRecoveredPage(base: base, mine: mine, theirs: base, result: base),
      isNotNull,
    );
  });

  group('an open page whose saved file is gone when its folder returns', () {
    BoxRecord theirBox() => BoxRecord.create(
      id: 'theirbox',
      typeId: 'test.other',
      dataVersion: 1,
      bounds: const Bounds(300, 300, 100, 40),
      data: RawJson.encode({'n': 1}),
      snapshotText: 'theirs',
      rev: 'r-theirs',
    );

    test('stays editable, and a file that lands later is merged, not overwritten', () async {
      final (nb, x, _) = await pendingEdit();
      await nb.flush(); // saved: no recovery entry
      await vanish(nb);
      expect(recFiles(), isEmpty);
      final original = readPage(pageFile(away, x).readAsStringSync());
      pageFile(away, x).deleteSync();
      await restore();
      await nb.checkFolders();
      expect(nb.current!.readOnly, isFalse);

      pageFile(extra, x).writeAsStringSync(writePage(original.insertNode(theirBox())));
      await nb.checkFile(pageFile(extra, x).path);
      expect(nb.current!.page.node('theirbox'), isNotNull, reason: 'merged into the open page');

      nb.current!.createBoxAt(const Bounds(80, 80, 0, 0));
      await nb.flush();
      final disk = readPage(pageFile(extra, x).readAsStringSync());
      expect(disk.node('theirbox'), isNotNull, reason: 'their box must survive the next save');
      expect(disk.nodes.length, 3);
    });

    test('a file reported before the page is resumed is merged into it', () async {
      final plan = _Landing();
      final nb = make(storeFactory: (d) => _LandingStore(d, plan));
      await nb.load();
      final x = await nb.createPage(folderPath: extra.path);
      await nb.flush();
      await nb.open(x);
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      await nb.flush();
      await vanish(nb);
      final original = readPage(pageFile(away, x).readAsStringSync());
      pageFile(away, x).deleteSync();
      await restore();
      plan
        ..path = pageFile(extra, x).path
        ..text = writePage(original.insertNode(theirBox()))
        ..page = original;
      await nb.checkFolders();
      expect(nb.current!.page.node('theirbox'), isNotNull);
      plan.path = null;
      nb.current!.createBoxAt(const Bounds(80, 80, 0, 0));
      await nb.flush();
      expect(readPage(pageFile(extra, x).readAsStringSync()).node('theirbox'), isNotNull);
    });
  });

  group('R-4 kept files land before the entry is retired', () {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);

    // A page with a pending edit and a file kept for it, the folder away and
    // the app quit. Returns the page id.
    Future<String> keptFile() async {
      final (nb, x, _) = await pendingEdit();
      await extra.rename(away.path);
      await nb.attachments!.put(bytes, extension: 'txt');
      await nb.checkFolders();
      expect(Directory('${rec.path}/$x.assets').existsSync(), isTrue);
      quit(nb);
      await restore();
      return x;
    }

    List<String> entries() => recFiles().where((p) => p.endsWith('.entry')).toList();

    test('a failed copy after the page landed retires the entry and keeps the files; a restart lands them', () async {
      final x = await keptFile();
      File('${extra.path}/$x.assets').writeAsStringSync('in the way'); // the copy can't make the folder
      final again = make();
      await again.load();
      expect(readPage(pageFile(extra, x).readAsStringSync()).nodes, hasLength(1), reason: 'the page landed');
      expect(entries(), isEmpty, reason: 'the page part is done; the kept folder is the retry');
      expect(Directory('${rec.path}/$x.assets').existsSync(), isTrue);
      expect(again.recoveryDamaged, hasLength(1));

      File('${extra.path}/$x.assets').deleteSync();
      quit(again);
      final restarted = make();
      await restarted.load();
      expect(Directory('${extra.path}/$x.assets').listSync().whereType<File>().single.readAsBytesSync(), bytes);
      expect(Directory('${rec.path}/$x.assets').existsSync(), isFalse);
      expect(entries(), isEmpty);
      expect(restarted.recoveryDamaged, isEmpty);
    });

    test('stopped after the page landed and before the files landed, over and over: still retried', () async {
      final x = await keptFile();
      File('${extra.path}/$x.assets').writeAsStringSync('in the way');
      for (var i = 0; i < 2; i++) {
        final nb = make();
        await nb.load();
        quit(nb);
        expect(entries(), isEmpty);
        expect(Directory('${rec.path}/$x.assets').existsSync(), isTrue);
      }
      File('${extra.path}/$x.assets').deleteSync();
      final last = make();
      await last.load();
      expect(Directory('${extra.path}/$x.assets').existsSync(), isTrue);
      expect(entries(), isEmpty);
    });
  });

  group('R-4 an entry is retired when its page lands; kept files land on their own', () {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    final keptName = attachmentFileName(contentHash(bytes), 'txt');
    const id = 'pg1';

    BoxRecord box(String rev, int n) => BoxRecord.create(
      id: 'abox',
      typeId: 'test.other',
      dataVersion: 1,
      bounds: const Bounds(10, 10, 100, 40),
      data: RawJson.encode({'n': n}),
      snapshotText: 's$n',
      rev: rev,
    );

    final meta = PageMeta.create(id: id, title: 'p', order: 0);
    Directory keptDir() => Directory('${rec.path}/$id.assets');
    Directory assetsOf(String page) => Directory('${pages.path}/$page.assets');
    List<String> entries() => recFiles().where((p) => p.endsWith('.entry')).toList();

    void keep({List<int>? content, String? name}) {
      keptDir().createSync(recursive: true);
      File('${keptDir().path}/${name ?? keptName}').writeAsBytesSync(content ?? bytes);
    }

    // The saved page holds box rev r1; the entry holds the same box edited
    // (rev r2) with a kept file; the target of the kept file is blocked.
    Future<void> parkedEntry() async {
      final base = NotedPage.create(meta).insertNode(box('r1', 1));
      pageFile(pages, id).writeAsStringSync(writePage(base));
      await RecoveryStore(rec).write(
        folder: pages.path,
        page: base.replaceNode(box('r2', 2)),
        baseText: writePage(base),
        time: DateTime.now(),
      );
      keep();
      File(assetsOf(id).path).writeAsStringSync('in the way');
    }

    Future<Notebook> launch() async {
      final nb = make();
      await nb.load();
      return nb;
    }

    test('the page lands and the entry is retired though the kept files can not land; they are listed', () async {
      await parkedEntry();
      final nb = await launch();
      expect((readPage(pageFile(pages, id).readAsStringSync()).node('abox') as BoxRecord).rev, 'r2');
      expect(entries(), isEmpty);
      expect(keptDir().existsSync(), isTrue);
      expect(nb.recoveryDamaged.map((d) => d.path.split(RegExp(r'[\\\\/]')).last), ['$id.assets']);
      quit(nb);
    });

    test('a re-replay can not bring back a box the user deleted since', () async {
      await parkedEntry();
      quit(await launch());
      // The user deletes the box the entry had changed; the blocker goes.
      final landed = readPage(pageFile(pages, id).readAsStringSync());
      pageFile(pages, id).writeAsStringSync(writePage(landed.removeNode('abox')));
      File(assetsOf(id).path).deleteSync();

      final again = await launch();
      expect(readPage(pageFile(pages, id).readAsStringSync()).node('abox'), isNull);
      expect(File('${assetsOf(id).path}/$keptName').readAsBytesSync(), bytes);
      expect(keptDir().existsSync(), isFalse);
      expect(again.recoveryDamaged, isEmpty);
    });

    test('a re-replay keeps the user\'s later edit, with no new conflict', () async {
      await parkedEntry();
      quit(await launch());
      final landed = readPage(pageFile(pages, id).readAsStringSync());
      pageFile(pages, id).writeAsStringSync(writePage(landed.replaceNode(box('r3', 3))));
      File(assetsOf(id).path).deleteSync();

      await launch();
      final b = readPage(pageFile(pages, id).readAsStringSync()).node('abox') as BoxRecord;
      expect(b.rev, 'r3');
      expect(b.conflicts, isEmpty);
      expect(keptDir().existsSync(), isFalse);
    });

    Future<void> pageOnly() async {
      pageFile(pages, id).writeAsStringSync(writePage(NotedPage.create(meta)));
    }

    test('a kept folder with no entry is landed on the next launch', () async {
      await pageOnly();
      keep();
      final nb = await launch();
      expect(File('${assetsOf(id).path}/$keptName').readAsBytesSync(), bytes);
      expect(keptDir().existsSync(), isFalse);
      expect(nb.recoveryDamaged, isEmpty);
    });

    test('a partial copy of the same size is replaced, and the kept folder goes only then', () async {
      await pageOnly();
      keep();
      assetsOf(id).createSync();
      File('${assetsOf(id).path}/$keptName').writeAsBytesSync([9, 9, 9, 9]);
      await launch();
      expect(File('${assetsOf(id).path}/$keptName').readAsBytesSync(), bytes);
      expect(keptDir().existsSync(), isFalse);
      expect(assetsOf(id).listSync().map((f) => f.path.split(RegExp(r'[\\/]')).last), [keptName]);
    });

    test('a partial copy of another size is replaced', () async {
      await pageOnly();
      keep();
      assetsOf(id).createSync();
      File('${assetsOf(id).path}/$keptName').writeAsBytesSync([1, 2]);
      await launch();
      expect(File('${assetsOf(id).path}/$keptName').readAsBytesSync(), bytes);
      expect(keptDir().existsSync(), isFalse);
    });

    test('a kept file that does not match its hash name is not landed and the folder stays', () async {
      await pageOnly();
      keep(content: [7, 7, 7, 7]);
      final nb = await launch();
      expect(File('${assetsOf(id).path}/$keptName').existsSync(), isFalse);
      expect(File('${keptDir().path}/$keptName').existsSync(), isTrue);
      expect(nb.recoveryDamaged.map((d) => d.path.split(RegExp(r'[\\\\/]')).last), ['$id.assets']);
    });

    test('a file whose name is not a hash is landed when identical', () async {
      await pageOnly();
      keep(name: 'note.txt');
      assetsOf(id).createSync();
      File('${assetsOf(id).path}/note.txt').writeAsBytesSync(bytes);
      await launch();
      expect(keptDir().existsSync(), isFalse);
    });

    test('a different file of the same non-hash name is never replaced: both are kept and listed', () async {
      await pageOnly();
      keep(name: 'note.txt');
      assetsOf(id).createSync();
      File('${assetsOf(id).path}/note.txt').writeAsBytesSync([4, 3, 2, 1]);
      final nb = await launch();
      expect(File('${assetsOf(id).path}/note.txt').readAsBytesSync(), [4, 3, 2, 1]);
      expect(File('${keptDir().path}/note.txt').readAsBytesSync(), bytes);
      expect(nb.recoveryProblems.single, contains('a different note.txt is already there; both are kept'));
      expect(nb.recoveryDamaged.single.reason, allOf(startsWith('The files kept for'), contains('could not be moved into place: a different note.txt')));
      expect(assetsOf(id).listSync(), hasLength(1), reason: 'no temp file left');
    });

    test('a different file that arrives at a non-hash name just before publishing is kept byte for byte', () async {
      await pageOnly();
      keep(name: 'note.txt');
      final target = '${assetsOf(id).path}/note.txt';
      // Another program creates the file after the copy was verified.
      Notebook.landBeforePublishHook = () => File(target).writeAsBytesSync([4, 3, 2, 1]);
      addTearDown(() => Notebook.landBeforePublishHook = null);
      final nb = await launch();
      expect(File(target).readAsBytesSync(), [4, 3, 2, 1]);
      expect(File('${keptDir().path}/note.txt').readAsBytesSync(), bytes);
      expect(nb.recoveryProblems.single, contains('a different note.txt is already there; both are kept'));
      expect(assetsOf(id).listSync(), hasLength(1), reason: 'no temp file left');
    });

    test('a publish that throws loses nothing: the source stays, the problem is listed, the temp goes', () async {
      await pageOnly();
      keep(name: 'note.txt');
      Notebook.landBeforePublishHook = () => throw const FileSystemException('no hard links here');
      addTearDown(() => Notebook.landBeforePublishHook = null);
      final nb = await launch();
      expect(File('${keptDir().path}/note.txt').readAsBytesSync(), bytes);
      expect(File('${assetsOf(id).path}/note.txt').existsSync(), isFalse);
      expect(nb.recoveryDamaged.single.reason, startsWith('The files kept for'));
      expect(assetsOf(id).listSync(), isEmpty, reason: 'no temp file left');
    });


    test('a failed rename onto a hash-named file that already holds the hash drops the temp and deletes nothing', () async {
      await pageOnly();
      keep();
      assetsOf(id).createSync();
      final target = '${assetsOf(id).path}/$keptName';
      // The correct file arrives after the check, then the rename fails.
      Notebook.landHashRenameHook = () {
        File(target).writeAsBytesSync(bytes);
        throw const FileSystemException('rename failed');
      };
      addTearDown(() => Notebook.landHashRenameHook = null);
      final nb = await launch();
      expect(File(target).readAsBytesSync(), bytes);
      expect(assetsOf(id).listSync(), hasLength(1), reason: 'no temp file left');
      expect(keptDir().existsSync(), isFalse, reason: 'it counted as landed');
      expect(nb.recoveryDamaged, isEmpty);
    });
    test('a complete kept temp file with no final file is landed under its hash name', () async {
      await pageOnly();
      keep(name: '$keptName.tmp');
      await launch();
      expect(File('${assetsOf(id).path}/$keptName').readAsBytesSync(), bytes);
      expect(keptDir().existsSync(), isFalse);
    });

    test('an incomplete kept temp file is not landed and keeps the folder', () async {
      await pageOnly();
      keep(name: '$keptName.tmp', content: [1, 2]);
      final nb = await launch();
      expect(File('${assetsOf(id).path}/$keptName').existsSync(), isFalse);
      expect(File('${keptDir().path}/$keptName.tmp').existsSync(), isTrue);
      expect(nb.recoveryProblems, hasLength(1));
      expect(nb.recoveryDamaged.single.reason, startsWith('The files kept for'));
    });

    test('a file that arrives while landing is not deleted, and lands on the next check', () async {
      await pageOnly();
      keep();
      final late = Uint8List.fromList([5, 6, 7]);
      final lateName = attachmentFileName(contentHash(late), 'txt');
      final nb = make();
      nb.keptLandedHook = (_) async {
        File('${keptDir().path}/$lateName').writeAsBytesSync(late);
      };
      await nb.load();
      expect(File('${keptDir().path}/$lateName').readAsBytesSync(), late);
      expect(File('${keptDir().path}/$keptName').existsSync(), isFalse, reason: 'the verified file went');
      expect(nb.recoveryProblems, hasLength(1));
      expect(nb.recoveryDamaged.single.reason, allOf(contains('were moved into place'), contains('other files stay in the kept folder')));

      nb.keptLandedHook = null;
      await nb.checkFolders();
      expect(File('${assetsOf(id).path}/$lateName').readAsBytesSync(), late);
      expect(keptDir().existsSync(), isFalse);
      expect(nb.recoveryProblems, isEmpty);
    });

    test('a stale landing temp file of a file that has landed is removed', () async {
      await pageOnly();
      keep();
      assetsOf(id).createSync();
      File('${assetsOf(id).path}/$keptName').writeAsBytesSync(bytes);
      File('${assetsOf(id).path}/$keptName.landing.tmp').writeAsBytesSync([1]);
      await launch();
      expect(assetsOf(id).listSync().map((f) => f.path.split(RegExp(r'[\\/]')).last), [keptName]);
    });

    test('a kept folder whose page is not there stays, and is listed only once nothing is away', () async {
      final (nb, x, _) = await pendingEdit();
      await vanish(nb);
      Directory('${rec.path}/ghost.assets').createSync(recursive: true);
      File('${rec.path}/ghost.assets/f').writeAsStringSync('x');
      quit(nb);

      final again = make();
      await again.load();
      expect(again.recoveryDamaged, isEmpty, reason: 'its folder may be the one that is away');
      expect(Directory('${rec.path}/ghost.assets').existsSync(), isTrue);

      await restore();
      await again.checkFolders();
      expect(Directory('${rec.path}/ghost.assets').existsSync(), isTrue);
      expect(again.recoveryDamaged.map((d) => d.path.split(RegExp(r'[\\\\/]')).last), ['ghost.assets']);
      expect(again.recoveryDamaged.single.reason, 'These kept files have no page to go with.');
      expect(again.tree[x], isNotNull);
    });

    test('the open page\'s kept files land while it stays open, and a failure is retried without a restart', () async {
      final (nb, x, _) = await pendingEdit();
      await extra.rename(away.path);
      await nb.attachments!.put(bytes, extension: 'txt');
      await nb.checkFolders();
      expect(Directory('${rec.path}/$x.assets').existsSync(), isTrue);
      await restore();
      File('${extra.path}/$x.assets').writeAsStringSync('in the way');
      await nb.checkFolders();
      expect(nb.currentId, x);
      expect(entries(), isEmpty, reason: 'the page landed');
      expect(Directory('${rec.path}/$x.assets').existsSync(), isTrue);
      expect(nb.recoveryDamaged, hasLength(1));

      File('${extra.path}/$x.assets').deleteSync();
      await nb.checkFolders(); // the open page is not reopened; the check retries
      expect(File('${extra.path}/$x.assets/$keptName').readAsBytesSync(), bytes);
      expect(Directory('${rec.path}/$x.assets').existsSync(), isFalse);
      expect(nb.recoveryDamaged, isEmpty);
      expect(nb.currentId, x);
    });
  });

  group('R-7 replay failures are listed under Can\'t open', () {
    // A page of the default folder with a pending edit, parked as an entry
    // while the folder is away.
    Future<(Notebook, _ToggleStore, Directory)> parked() async {
      final st = _ToggleStore(pages);
      final nb = make(store: st);
      await nb.load();
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      final moved = Directory('${root.path}/pages-away');
      await pages.rename(moved.path);
      await nb.checkFolders();
      expect((await nb.pendingRecovery()).entries, hasLength(1));
      return (nb, st, moved);
    }

    test('a failed check is listed', () async {
      final (nb, st, moved) = await parked();
      st.lossy = true;
      await moved.rename(pages.path);
      await nb.checkFolders();
      expect((await nb.pendingRecovery()).entries, hasLength(1));
      expect(nb.recoveryDamaged, hasLength(1));
      expect(nb.recoveryProblems, hasLength(1));
    });

    test('an exception during replay is listed, and cleared by a later successful replay', () async {
      final (nb, st, moved) = await parked();
      st.throwOnRead = true;
      await moved.rename(pages.path);
      await nb.checkFolders();
      expect((await nb.pendingRecovery()).entries, hasLength(1));
      expect(nb.recoveryDamaged, hasLength(1));
      expect(nb.recoveryDamaged.single.reason, contains('could not be saved into the page file'));
      expect(nb.recoveryDamaged.single.reason, isNot(contains('injected')));

      await pages.rename(moved.path);
      await nb.checkFolders();
      st.throwOnRead = false;
      await moved.rename(pages.path);
      await nb.checkFolders();
      expect((await nb.pendingRecovery()).entries, isEmpty);
      expect(nb.recoveryDamaged, isEmpty);
    });

    test('a read-back that differs from what was written is listed', () async {
      final nb = make();
      await nb.load();
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      final moved = Directory('${root.path}/pages-away');
      await pages.rename(moved.path);
      await nb.checkFolders();
      quit(nb);
      await moved.rename(pages.path);
      final st = _ToggleStore(pages)..alterRead = true;
      final again = make(store: st);
      await again.load();
      expect((await again.pendingRecovery()).entries, hasLength(1));
      expect(again.recoveryDamaged, hasLength(1));
    });
  });

  for (final kind in ['newer', 'damaged', 'not UTF-8']) {
    test('an entry whose saved file is $kind is kept and says so plainly', () async {
      final (nb, x, _) = await pendingEdit();
      await vanish(nb);
      quit(nb);
      await restore();
      final file = pageFile(extra, x);
      final original = file.readAsStringSync();
      switch (kind) {
        case 'newer':
          file.writeAsStringSync(original.replaceFirst(RegExp(r'"format"\s*:\s*1'), '"format":99'));
        case 'damaged':
          file.writeAsStringSync('{ not json');
        default:
          file.writeAsBytesSync([0xff, 0xfe, 0xfd]);
      }
      final again = make();
      await again.load();
      expect(recFiles().where((p) => p.endsWith('.entry')), isNotEmpty, reason: 'the entry stays');
      final reason = again.recoveryDamaged.map((d) => d.reason).join('\n');
      expect(reason, contains("Recovery can't finish: the saved file of"));
      expect(
        reason,
        contains(kind == 'newer' ? 'is from a newer version of Noted' : "isn't a valid page file"),
      );
      expect(reason, isNot(contains('could not be saved into the page file')));
      expect(reason, isNot(contains('JSON')));
    });
  }

  test('replay refuses an entry whose page is another page than the entry says', () async {
    final (nb, x, _) = await pendingEdit();
    await vanish(nb);
    quit(nb);
    await restore();
    final entry = File(recFiles().singleWhere((p) => p.endsWith('.entry')));
    final text = entry.readAsStringSync();
    entry.writeAsStringSync(text.replaceFirst('"pageId":"$x"', '"pageId":"other"'));
    final again = make();
    await again.load();
    expect(pageFile(extra, 'other').existsSync(), isFalse);
    expect(readPage(pageFile(extra, x).readAsStringSync()).nodes, isEmpty);
    expect(entry.existsSync(), isTrue);
    expect(again.recoveryDamaged, isNotEmpty);
  });
}
