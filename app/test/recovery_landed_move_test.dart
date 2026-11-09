// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// R-1 (run-diff-5): landed text belongs to one generation. A generation that
// combines entries never inherits it (decision 0156: a move merges again).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted_canvas/noted_canvas.dart';
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

void main() {
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

  Notebook make({PageStore Function(Directory)? storeFactory}) {
    final nb = Notebook(
      PageStore(pages),
      buildModules(),
      storeFactory: storeFactory ?? PageStore.new,
      saveDelay: const Duration(hours: 1),
      bindersFile: File('${root.path}/app/binders.json'),
      recoveryDirectory: rec,
      folderCheckInterval: Duration.zero,
    );
    opened.add(nb);
    return nb;
  }

  File pageFile(Directory d, String id) => File('${d.path}/$id.canvas');
  List<String> entryFiles() =>
      rec.existsSync() ? [for (final f in rec.listSync()) f.path].where((p) => p.endsWith('.entry')).toList() : const [];
  NotedPage disk(Directory d, String id) => readPage(pageFile(d, id).readAsStringSync());
  List<String> ids(NotedPage p) => [for (final n in p.nodes) n.id];

  // Page P in A with [boxes] boxes saved (the base); returns its id, base text
  // and a box X that is not on it. The notebook that made it is closed.
  Future<({String id, String baseText, BoxRecord x})> makePage({int boxes = 1}) async {
    final nb = make();
    await nb.load();
    final id = await nb.createPage(folderPath: a.path);
    final other = await nb.createPage(folderPath: a.path);
    await nb.flush();
    await nb.open(other);
    nb.current!.createBoxAt(const Bounds(300, 300, 0, 0));
    await nb.flush();
    await nb.open(id);
    for (var i = 0; i < boxes; i++) {
      nb.current!.createBoxAt(Bounds(40.0 + 150 * i, 40, 0, 0));
    }
    await nb.flush();
    final text = pageFile(a, id).readAsStringSync();
    final box = disk(a, other).nodes.whereType<BoxRecord>().single;
    nb.dispose();
    opened.remove(nb);
    // The helper page "other" is no longer wanted: the folder holds only P.
    pageFile(a, other).deleteSync();
    return (id: id, baseText: text, x: box);
  }

  // The entry of P in A (a retitle and a moved first box) lands on the next
  // load, and its settle read fails after the publish, so landed text is kept.
  // Returns the notebook, still failing reads.
  Future<(Notebook, void Function(bool))> landedUnsettled(String id, String baseText) async {
    final base = readPage(baseText);
    final box = base.nodes.first as BoxRecord;
    final m = base.replaceNode(box.withBounds(const Bounds(200, 200, 30, 30)));
    final mine = m.withMeta(m.meta.withTitle('Mine'));
    await RecoveryStore(rec).write(folder: a.path, page: mine, baseText: baseText, time: DateTime.now());
    var failing = false;
    final nb = make(storeFactory: (d) => d.path == a.path ? _FlakyReadStore(d, () => failing) : PageStore(d));
    nb.syncHook = (point, path) async {
      if (point == 'recover-published') failing = true;
    };
    await nb.load();
    expect(entryFiles(), isNotEmpty, reason: 'landed, not settled: the entry stays');
    expect(nb.landedTextCount, 1);
    return (nb, (v) => failing = v);
  }

  // An entry of P in B that the page was edited with while B was offline: the
  // base text with box [x] added.
  Future<void> targetEntry(String id, String baseText, BoxRecord x) async {
    final withX = readPage(baseText).insertNode(x);
    await RecoveryStore(rec).write(folder: b.path, page: withX, baseText: baseText, time: DateTime.now());
  }

  group('R-1 landed text is not handed to a combined generation', () {
    // 1: back != out. B already holds a page, so the move changes P's order.
    test('a move into a folder holding an entry merges again; the extra box lands', () async {
      final p = await makePage();
      final (nb, failing) = await landedUnsettled(p.id, p.baseText);
      await nb.createPage(folderPath: b.path);
      await nb.flush();
      await targetEntry(p.id, p.baseText, p.x);
      await nb.refreshRecoveryIndexForTest();
      failing(false);
      expect(await nb.moveToFolder(p.id, b.path), isTrue);

      await nb.recoverNowForTest();
      expect(pageFile(b, p.id).existsSync(), isTrue);
      expect(ids(disk(b, p.id)), contains(p.x.id), reason: 'the target entry\'s box is in the file');
      expect(entryFiles(), isEmpty, reason: 'retired only after the file held every box');
      expect(nb.landedTextCount, 0);
      expect(disk(b, p.id).meta.title, 'Mine');
    });

    // 2: back == out. B is empty, so the placement bytes do not change.
    test('the same with a top-level page whose placement does not change', () async {
      final p = await makePage();
      final (nb, failing) = await landedUnsettled(p.id, p.baseText);
      await targetEntry(p.id, p.baseText, p.x);
      await nb.refreshRecoveryIndexForTest();
      failing(false);
      expect(await nb.moveToFolder(p.id, b.path), isTrue);

      await nb.recoverNowForTest();
      expect(ids(disk(b, p.id)), contains(p.x.id));
      expect(entryFiles(), isEmpty);
      expect(nb.landedTextCount, 0);
    });
  });
}
