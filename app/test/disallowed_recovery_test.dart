// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Run 2026-11-14-02, task 3. Recovery replay, the recovery preview and keeping
// as a closed writer merge a box of a type disallowed under any version's
// header as a switched-off module's box: never decoded, this device's version
// kept, the other recorded in its conflicts (0111, 0155).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted/src/save_trouble.dart' show KeepKind;
import 'package:noted_core/noted_core.dart';

import 'support/spy_modules.dart';
import 'support/notebook_folder.dart';
import 'support/trouble_world.dart' show FailStore;

void main() {
  late Directory root;
  late Directory pages;
  late Directory rec;
  late List<Notebook> opened;
  late FailStore store;

  const boxId = 'd000000000000001';
  final s0 = spyStroke('s0', 30, t0: 1);
  final s1 = spyStroke('s1', 60, t0: 2);
  final s2 = spyStroke('s2', 90, t0: 3);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_disallowed_recovery');
    pages = await Directory('${root.path}/pages').create();
    rec = Directory('${root.path}/rec');
    opened = [];
  });

  tearDown(() async {
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    await deleteTestFolder(root);
  });

  Notebook make({PageStore? pageStore}) {
    final nb = Notebook(
      pageStore ?? PageStore(pages),
      spyModules(),
      saveDelay: const Duration(hours: 1),
      bindersFile: File('${root.path}/app/binders.json'),
      recoveryDirectory: rec,
      folderCheckInterval: Duration.zero,
    );
    opened.add(nb);
    return nb;
  }

  BoxRecord boxOf(NotedPage p) => p.node(boxId)! as BoxRecord;
  File pageFile(String id) => File('${pages.path}/$id.canvas');
  NotedPage disk(String id) => readPage(pageFile(id).readAsStringSync());

  /// A page holding one drawing box (the base, saved), then the file changed
  /// since: the box has [s2] added. Returns the id and the base text.
  Future<(String, String)> world() async {
    final nb = make();
    await nb.load();
    final id = nb.currentId!;
    nb.current!.insertBox(spyDrawingBox(boxId, [s0]));
    await nb.flush();
    final baseText = pageFile(id).readAsStringSync();
    nb.dispose();
    opened.remove(nb);
    final base = readPage(baseText);
    pageFile(id).writeAsStringSync(writePage(base.replaceNode(withStrokes(boxOf(base), [s0, s2]))));
    return (id, baseText);
  }

  /// An entry of the page: mine has [s1] added to the base, and its header
  /// disallows the drawing type, which the file and this device's page allow.
  Future<NotedPage> entry(String id, String baseText) async {
    final base = readPage(baseText);
    final mine = base.replaceNode(withStrokes(boxOf(base), [s0, s1]));
    final page = mine.withMeta(mine.meta.withBoxType(spyDrawing, false));
    await RecoveryStore(rec).write(folder: pages.path, page: page, baseText: baseText, time: DateTime.now());
    return page;
  }

  void expectKeptMine(NotedPage page, BoxRecord mine, BoxRecord theirs) {
    final b = boxOf(page);
    expect(b.isConflicted, isTrue);
    expect(b.data!.text, mine.data!.text);
    expect(b.dataVersion, mine.dataVersion);
    expect(b.snapshotText, mine.snapshotText);
    expect(b.rev, mine.rev);
    expect(b.conflicts.single.node!.text, theirs.toRaw().text);
    expect(page.meta.boxTypeChoice(spyDrawing), isFalse, reason: 'the merged header disallows the type');
  }

  // The recorded other version's time differs between two merges of the same
  // inputs; everything else must match.
  String withoutAt(NotedPage p) => writePage(p).replaceAll(RegExp(r'"at":\d+'), '"at":0');

  test('4 recovery replay with a base: a drawing both sides changed is conflicted, never decoded, and the preview shows the same', () async {
    final (id, baseText) = await world();
    final entryPage = await entry(id, baseText);
    final theirs = boxOf(disk(id));
    // The same inputs, shown while the replay can't publish: the preview.
    store = FailStore(pages)..failWith = const FileSystemException('injected write failure');
    final shown = make(pageStore: store);
    SpyCalls.reset();
    await shown.load();
    await shown.open(id);
    expect(shown.current!.readOnly, isTrue, reason: 'the page is a preview');
    final preview = shown.current!.page;
    expectKeptMine(preview, boxOf(entryPage), theirs);
    expect(SpyCalls.total(spyDrawing), 0, reason: 'the preview decoded nothing');
    expect(shown.current!.disallowedTypes, contains(spyDrawing), reason: 'the preview controller holds the set');
    expect(pageFile(id).readAsStringSync(), isNot(contains('"conflicts"')), reason: 'nothing was written');
    shown.dispose();
    opened.remove(shown);

    // The replay that can publish.
    final nb = make();
    SpyCalls.reset();
    await nb.load();
    await nb.flush();
    final written = disk(id);
    expectKeptMine(written, boxOf(entryPage), theirs);
    expect(SpyCalls.total(spyDrawing), 0, reason: 'the replay decoded nothing');
    expect(withoutAt(preview), withoutAt(written), reason: 'the preview equals the written page');
    expect((await nb.pendingRecovery()).entries, isEmpty);
  });

  test('5 keep as a closed writer: the same inputs give the same result', () async {
    final (id, baseText) = await world();
    final base = readPage(baseText);
    final mine = base.replaceNode(withStrokes(boxOf(base), [s0, s1]));
    final entryPage = mine.withMeta(mine.meta.withBoxType(spyDrawing, false));
    final theirsPage = disk(id);
    final nb = make();
    await nb.load();
    // A closed writer kept its page (the entry), and another keeps the page the
    // file now holds, merging the entry kept for the page.
    final first = await nb.keepClosedForTest(entryPage, base, pages.path);
    expect(first.kind, KeepKind.kept, reason: first.why);
    SpyCalls.reset();
    final outcome = await nb.keepClosedForTest(theirsPage, base, pages.path);
    expect(outcome.kind, KeepKind.kept, reason: outcome.why);
    expect(SpyCalls.total(spyDrawing), 0);
    await nb.refreshRecoveryIndexForTest();
    final kept = nb.recoveryStoreForTest!.entriesFor(pages.path.replaceAll(r'\', '/'), id);
    expect(kept, hasLength(1));
    expectKeptMine(kept.single.page, boxOf(entryPage), boxOf(theirsPage));
  });
}
