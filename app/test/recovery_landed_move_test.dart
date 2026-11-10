// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// R-1 (run-diff-5): landed text belongs to one generation. A generation that
// combines entries never inherits it (decision 0156: a move merges again).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted_core/noted_core.dart';

/// A store whose reads throw while [fail] says so.
class _FlakyReadStore extends PageStore {
  _FlakyReadStore(super.directory, this.fail);

  final bool Function() fail;

  @override
  Future<String> readText(String pageId) {
    if (fail()) throw const FileSystemException('injected read failure');
    return super.readText(pageId);
  }
}

/// A store that refuses to make new page files while [refuse] says so.
class _NoNewStore extends PageStore {
  _NoNewStore(super.directory, this.refuse);

  final bool Function() refuse;

  @override
  Future<bool> saveNewText(
    NotedPage page,
    String text, {
    Future<void> Function()? beforePublish,
  }) {
    if (refuse()) throw const FileSystemException('injected write failure');
    return super.saveNewText(page, text, beforePublish: beforePublish);
  }
}

/// A file whose readAsString throws once when [fail] says so; the rest is the
/// real file.
class _EntryReadFails implements File {
  _EntryReadFails(this._f, this.fail);

  final File _f;
  final bool Function() fail;

  @override
  Future<String> readAsString({Encoding encoding = utf8}) {
    if (fail()) throw const FileSystemException('injected read failure');
    return _f.readAsString(encoding: encoding);
  }

  @override
  String get path => _f.path;

  @override
  File get absolute => _f.absolute;

  @override
  Future<bool> exists() => _f.exists();

  @override
  Future<Uint8List> readAsBytes() => _f.readAsBytes();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _f.delete(recursive: recursive);

  @override
  Future<File> rename(String newPath) => _f.rename(newPath);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  var failNew = false;
  late Directory root;
  late Directory pages;
  late Directory a; // the folder the page starts in
  late Directory b; // the folder it moves to
  late Directory rec;
  late List<Notebook> opened;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_landed_move');
    pages = await Directory('${root.path}/pages').create();
    a = await Directory('${root.path}/A').create();
    b = await Directory('${root.path}/B').create();
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

  PageStore plain(Directory d) => _NoNewStore(
    d,
    () => failNew && d.path.replaceAll(r'\', '/').endsWith('/B'),
  );

  Notebook make({PageStore Function(Directory)? storeFactory}) {
    final nb = Notebook(
      PageStore(pages),
      buildModules(),
      storeFactory: storeFactory ?? plain,
      saveDelay: const Duration(hours: 1),
      bindersFile: File('${root.path}/app/binders.json'),
      recoveryDirectory: rec,
      folderCheckInterval: Duration.zero,
    );
    opened.add(nb);
    return nb;
  }

  File pageFile(Directory d, String id) => File('${d.path}/$id.canvas');
  List<String> entryFiles() => rec.existsSync()
      ? [for (final f in rec.listSync()) f.path]
            .where((p) => p.endsWith('.entry'))
            .toList()
      : const [];
  NotedPage disk(Directory d, String id) =>
      readPage(pageFile(d, id).readAsStringSync());
  List<String> ids(NotedPage p) => [for (final n in p.nodes) n.id];

  // Page P in A with one box saved (the base); returns its id, base text and
  // three boxes that are not on it. The notebook that made it is closed.
  Future<({String id, String baseText, List<BoxRecord> xs, String? parent})>
  makePage({bool subpage = false}) async {
    final nb = make();
    await nb.load();
    final q = subpage ? await nb.createPage(folderPath: a.path) : null;
    final id = subpage
        ? await nb.createPage(parentId: q)
        : await nb.createPage(folderPath: a.path);
    final other = await nb.createPage(folderPath: a.path);
    await nb.flush();
    await nb.open(other);
    for (var i = 0; i < 3; i++) {
      nb.current!.createBoxAt(Bounds(300.0 + 150 * i, 300, 0, 0));
    }
    await nb.flush();
    await nb.open(id);
    nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
    await nb.flush();
    final text = pageFile(a, id).readAsStringSync();
    final xs = disk(a, other).nodes.whereType<BoxRecord>().toList();
    nb.dispose();
    opened.remove(nb);
    // The helper page is no longer wanted: the folder holds only P.
    pageFile(a, other).deleteSync();
    return (id: id, baseText: text, xs: xs, parent: q);
  }

  // The entries of P in A (a retitle and a moved first box; [more] adds
  // entries that each add one box) land on the next load, and the settle read
  // fails after the publish, so landed text is kept. Reads work again at
  // return; the landed text stays in memory.
  Future<Notebook> landedUnsettled(
    String id,
    String baseText, {
    List<BoxRecord> more = const [],
  }) async {
    final base = readPage(baseText);
    final box = base.nodes.first as BoxRecord;
    final m = base.replaceNode(box.withBounds(const Bounds(200, 200, 30, 30)));
    final mine = m.withMeta(m.meta.withTitle('Mine'));
    final store = RecoveryStore(rec);
    await store.write(
      folder: a.path,
      page: mine,
      baseText: baseText,
      time: DateTime.now(),
    );
    for (var i = 0; i < more.length; i++) {
      await store.write(
        folder: a.path,
        page: base.insertNode(more[i]),
        baseText: baseText,
        time: DateTime.now().add(Duration(seconds: i + 1)),
        freshSlot: true,
      );
    }
    var failing = false;
    final nb = make(
      storeFactory: (d) =>
          d.path == a.path ? _FlakyReadStore(d, () => failing) : plain(d),
    );
    nb.syncHook = (point, path) async {
      if (point == 'recover-published') failing = true;
    };
    await nb.load();
    nb.syncHook = null;
    failing = false;
    expect(
      entryFiles(),
      isNotEmpty,
      reason: 'landed, not settled: the entries stay',
    );
    expect(nb.landedTextCount, 1 + more.length);
    return nb;
  }

  // An entry of P under B (written after the landing, so the replay does not
  // take it for a stale key and merge it into A first): the base text with [x]
  // added.
  Future<void> targetEntry(String baseText, BoxRecord x) async {
    final withX = readPage(baseText).insertNode(x);
    await RecoveryStore(rec).write(
      folder: b.path,
      page: withX,
      baseText: baseText,
      time: DateTime.now(),
    );
  }

  group('R-1 landed text is not handed to a combined generation', () {
    // 1: back != out. B already holds a page, so the move changes P's order.
    test(
      'a move into a folder holding an entry merges again; the extra box lands',
      () async {
        final p = await makePage();
        final nb = await landedUnsettled(p.id, p.baseText);
        await nb.createPage(folderPath: b.path);
        await nb.flush();
        await targetEntry(p.baseText, p.xs[0]);
        await nb.refreshRecoveryIndexForTest();
        expect(await nb.moveToFolder(p.id, b.path), isTrue);
        final placed = disk(b, p.id).meta;
        expect(
          placed.order,
          isNot(readPage(p.baseText).meta.order),
          reason: 'the move changed the order',
        );
        await nb.recoverNowForTest();
        expect(pageFile(b, p.id).existsSync(), isTrue);
        expect(
          ids(disk(b, p.id)),
          contains(p.xs[0].id),
          reason: 'the target entry\'s box is in the file',
        );
        expect(
          entryFiles(),
          isEmpty,
          reason: 'retired only after the file held every box',
        );
        expect(nb.landedTextCount, 0);
        expect(disk(b, p.id).meta.title, 'Mine');
        // Neither entry changed the placement, so the move's stands.
        expect(disk(b, p.id).meta.parentId, placed.parentId);
        expect(disk(b, p.id).meta.order, placed.order);
      },
    );

    // 2: back == out. P is a subpage of Q, and Q is moved: P's own bytes do
    // not change (same parent, same order), so the file equals the text that
    // landed. Without step 1 the exact check fails the retry with the entry
    // kept; test 1 shows the other failure.
    test(
      'a subpage whose bytes do not change in the move: the extra box lands',
      () async {
        final p = await makePage(subpage: true);
        final nb = await landedUnsettled(p.id, p.baseText);
        await targetEntry(p.baseText, p.xs[0]);
        await nb.refreshRecoveryIndexForTest();
        expect(await nb.moveToFolder(p.parent!, b.path), isTrue);
        await nb.recoverNowForTest();
        expect(
          entryFiles(),
          isEmpty,
          reason: 'the exact check would keep the entry (back == out)',
        );
        expect(ids(disk(b, p.id)), contains(p.xs[0].id));
        expect(nb.landedTextCount, 0);
      },
    );

    // The next listing can not read the entry: its generation is out of the
    // index while the entry is still there, so the landed text must stay.
    test('a listing that can not read an entry keeps the landed text; the retry settles', () async {
      final p = await makePage();
      final nb = await landedUnsettled(p.id, p.baseText);
      var failed = false;
      await IOOverrides.runZoned(
        () => nb.recoverNowForTest(),
        createFile: (path) =>
            _EntryReadFails(Zone.root.run(() => File(path)), () {
              if (failed || !path.endsWith('.entry')) return false;
              return failed = true;
            }),
      );
      expect(failed, isTrue, reason: 'the listing tried to read the entry');
      expect(entryFiles(), isNotEmpty);
      expect(nb.landedTextCount, 1, reason: 'the entry is still there');
      var rereads = 0;
      nb.syncHook = (point, path) async {
        if (point == 'recover-reread') rereads++;
      };
      await nb.recoverNowForTest();
      expect(
        rereads,
        0,
        reason: 'settled from the landed text, not merged again',
      );
      expect(entryFiles(), isEmpty);
      expect(nb.landedTextCount, 0);
    });

    // 3: guards the exact-copy condition; passes either way.
    test('a fresh-slot move keeps the landed text: the retry settles without merging again', () async {
      final p = await makePage();
      final nb = await landedUnsettled(p.id, p.baseText);
      expect(await nb.moveToFolder(p.id, b.path), isTrue);
      var rereads = 0;
      nb.syncHook = (point, path) async {
        if (point == 'recover-reread') rereads++;
      };
      await nb.recoverNowForTest();
      expect(
        rereads,
        0,
        reason: 'settled from the landed text, not merged again',
      );
      expect(entryFiles(), isEmpty);
      expect(nb.landedTextCount, 0);
      expect(disk(b, p.id).meta.title, 'Mine');
    });

    test('two entries at the source and one at the target: every box of all three lands', () async {
      final p = await makePage();
      final nb = await landedUnsettled(p.id, p.baseText, more: [p.xs[1]]);
      await targetEntry(p.baseText, p.xs[0]);
      await nb.refreshRecoveryIndexForTest();
      expect(await nb.moveToFolder(p.id, b.path), isTrue);
      await nb.recoverNowForTest();
      final got = ids(disk(b, p.id));
      expect(got, containsAll([p.xs[0].id, p.xs[1].id]));
      expect(entryFiles(), isEmpty);
      expect(nb.landedTextCount, 0);
    });

    test('a rolled-back move leaves a combined entry at the target: it is merged back into the source', () async {
      final p = await makePage();
      final nb = await landedUnsettled(p.id, p.baseText);
      await targetEntry(p.baseText, p.xs[0]);
      await nb.refreshRecoveryIndexForTest();
      failNew = true;
      await expectLater(
        nb.moveToFolder(p.id, b.path),
        throwsA(isA<NotebookException>()),
      );
      failNew = false;
      await nb.recoverNowForTest();
      expect(pageFile(b, p.id).existsSync(), isFalse);
      expect(
        ids(disk(a, p.id)),
        contains(p.xs[0].id),
        reason: 'the target entry\'s box is in the source page',
      );
      expect(entryFiles(), isEmpty);
      await nb.recoverNowForTest(); // the next listing prunes
      expect(nb.landedTextCount, 0, reason: 'the old landed text is pruned');
    });

    test('a combining keep of a landed generation merges again; the orphan landed text is pruned', () async {
      final p = await makePage();
      final nb = await landedUnsettled(p.id, p.baseText);
      final base = readPage(p.baseText);
      final out = await nb.keepClosedForTest(
        base.insertNode(p.xs[0]),
        base,
        a.path,
      );
      expect(out.safe, isTrue);
      await nb.recoverNowForTest();
      final d = disk(a, p.id);
      expect(ids(d), contains(p.xs[0].id));
      expect(d.meta.title, 'Mine');
      expect(entryFiles(), isEmpty);
      expect(nb.landedTextCount, 0);
    });
  });
}
