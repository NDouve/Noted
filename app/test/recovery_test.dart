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
    expect(nb.readOnlyReason, contains('not a page this version can read'));

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

    test('a failed copy after the page landed keeps the entry; a restart lands the files and retires it', () async {
      final x = await keptFile();
      File('${extra.path}/$x.assets').writeAsStringSync('in the way'); // the copy can't make the folder
      final again = make();
      await again.load();
      expect(readPage(pageFile(extra, x).readAsStringSync()).nodes, hasLength(1), reason: 'the page landed');
      expect(entries(), hasLength(1), reason: 'the entry is the retry');
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

    test('stopped between the page landing and the files landing, over and over: still retried', () async {
      final x = await keptFile();
      File('${extra.path}/$x.assets').writeAsStringSync('in the way');
      for (var i = 0; i < 2; i++) {
        final nb = make();
        await nb.load();
        quit(nb);
        expect(entries(), hasLength(1));
        expect(Directory('${rec.path}/$x.assets').existsSync(), isTrue);
      }
      File('${extra.path}/$x.assets').deleteSync();
      final last = make();
      await last.load();
      expect(Directory('${extra.path}/$x.assets').existsSync(), isTrue);
      expect(entries(), isEmpty);
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
      expect(nb.recoveryDamaged.single.reason, contains('injected read failure'));

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
