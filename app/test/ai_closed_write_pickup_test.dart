// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

// A write the MCP server made to a page file while Noted was not running (it
// splices one box record into the file) reaches a Noted that starts, or is
// already watching, through the same file watching as any outside change
// (decision 0020): an open page merges it per box, and a box with unsaved
// local edits becomes a conflict instead of losing either side.

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

void main() {
  late Directory dir;
  late Notebook nb;
  late PageStore store;
  late ModuleRegistry modules;

  Future<void> start({bool watch = true}) async {
    dir = await Directory.systemTemp.createTemp('noted_closed_write');
    modules = buildModules();
    nb = Notebook(
      PageStore(dir),
      modules,
      saveDelay: const Duration(hours: 1), // saves happen on flush()
      watchFiles: watch,
      watchDebounce: const Duration(milliseconds: 50),
    );
    store = PageStore(dir);
    await nb.load();
    await store.scan();
    // Give the OS watcher a moment to start.
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  tearDown(() async {
    nb.dispose();
    await dir.delete(recursive: true);
  });

  Future<void> until(bool Function() ok) async {
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('the watcher did not report the change in time');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  // The box [id] of the page file [pageId] gets [text], the way the MCP
  // server writes it: one record spliced into the file, the rest untouched.
  void closedWrite(String pageId, String id, String text) {
    final codec = modules.codecs.codecFor('noted.note')!;
    final file = File(store.pathFor(pageId));
    final spliced = spliceBoxContent(
      file.readAsStringSync(),
      id,
      data: RawJson.encode(codec.encode(codec.decode(doc(text), 1))),
      dataVersion: 1,
      snapshotText: text,
      newRev: 'closed-write-rev',
    );
    expect(spliced, isNotNull);
    file.writeAsStringSync(spliced!);
  }

  Future<BoxRecord> noteBox(NotedPage page, String text) async {
    final c = nb.current!;
    final box = c.createBoxAt(const Bounds(10, 10, 0, 0));
    c.commit(box.id, modules.codecs.codecFor('noted.note')!.decode(doc(text), 1));
    await nb.flush();
    return c.page.node(box.id)! as BoxRecord;
  }

  test('a page that is not open shows the closed-app write when it is opened', () async {
    await start();
    final first = nb.currentId!;
    final box = await noteBox(nb.current!.page, 'one');
    final other = await nb.createPage();
    expect(nb.currentId, other);

    closedWrite(first, box.id, 'written while Noted was closed');
    // The watcher looks at the file; opening the page then shows the content.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await nb.open(first);
    expect((nb.current!.page.node(box.id)! as BoxRecord).snapshotText, 'written while Noted was closed');
    expect(nb.hasConflict(first), isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('an open page takes the write to a box nobody edited', () async {
    await start();
    final id = nb.currentId!;
    final box = await noteBox(nb.current!.page, 'one');
    closedWrite(id, box.id, 'by the AI');
    await until(() => (nb.current!.page.node(box.id)! as BoxRecord).snapshotText == 'by the AI');
    expect(nb.current!.conflictedBoxes, isEmpty);
    expect(nb.hasConflict(id), isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a box with unsaved local edits becomes a conflict; the other boxes are untouched', () async {
    await start();
    final id = nb.currentId!;
    final c = nb.current!;
    final box = await noteBox(c.page, 'base');
    final bystander = await noteBox(c.page, 'bystander');
    final codec = modules.codecs.codecFor('noted.note')!;

    c.commit(box.id, codec.decode(doc('mine, unsaved'), 1)); // not saved yet
    closedWrite(id, box.id, 'by the AI');
    await until(() => nb.hasConflict(id));

    final now = c.page.node(box.id)! as BoxRecord;
    expect(now.isConflicted, isTrue);
    expect(now.snapshotText, 'mine, unsaved');
    expect(now.conflicts.single.node?.text, contains('by the AI'));
    expect((c.page.node(bystander.id)! as BoxRecord).snapshotText, 'bystander');

    // The conflict is saved with the page, and resolving it clears it.
    await nb.flush();
    final saved = (await store.load(id)).node(box.id)! as BoxRecord;
    expect(saved.isConflicted, isTrue);
    c.resolveKeepMine(box.id);
    expect(nb.hasConflict(id), isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
