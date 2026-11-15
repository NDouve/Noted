// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A paste or drop keeps its target (controller, page, store, point) from its
// start and checks it before every file it stores and every box it adds: a page
// opened meanwhile gets nothing.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'context_menu_world.dart';

const _stopNotice = 'The paste stopped; nothing was added to another page.';
void main() {
  late World w;
  late CanvasController other;

  Future<void> setUp(WidgetTester t, List<IncomingFile> clipboard) async {
    w = World(t)..disableAnimations = true;
    await w.pump(withStore: true);
    fileGate.wait = true;
    other = CanvasController(tpage(const [], id: 'q'), w.modules);
    addTearDown(other.dispose);
    FileClipboard.read = () async => clipboard;
    addTearDown(() => FileClipboard.read = () async => const []);
  }

  IncomingFile file(String name) => IncomingFile(name, Uint8List.fromList([name.length]));

  int boxes(CanvasController c) => c.page.nodes.whereType<BoxRecord>().where((b) => b.typeId == 'test.file').length;

  testWidgets('one file, another page opened before creation completes: no box on either, the file kept, the user told', (t) async {
    await setUp(t, [file('a.txt')]);
    final done = w.state.pasteFilesAt(const Offset(900, 600));
    await t.pump();
    expect(fileGate.waiting, hasLength(1));
    await w.rebuild(controller: other);
    fileGate.waiting.single.complete();
    await done;
    await t.pump();
    expect(boxes(w.c), 0);
    expect(boxes(other), 0);
    expect(w.store!.stored, hasLength(1));
    expect(w.store!.notices, [_stopNotice]);
  });

  testWidgets('three files, the switch after the first box: only that box, on the original page; the third is never stored', (t) async {
    await setUp(t, [file('a.txt'), file('bb.txt'), file('ccc.txt')]);
    final done = w.state.pasteFilesAt(const Offset(900, 600));
    await t.pump();
    fileGate.waiting[0].complete();
    await t.pump();
    await t.pump();
    expect(boxes(w.c), 1);
    expect(fileGate.waiting, hasLength(2));
    await w.rebuild(controller: other);
    fileGate.waiting[1].complete();
    await done;
    await t.pump();
    expect(boxes(w.c), 1);
    expect(boxes(other), 0);
    // The second file was stored in the original page's folder, unreferenced.
    expect(w.store!.stored, hasLength(2));
    expect(fileGate.created, ['a.txt', 'bb.txt']);
    expect(fileGate.waiting, hasLength(2));
    expect(w.store!.notices, [_stopNotice]);
  });

  testWidgets('the page turned read-only mid-paste stops the same way', (t) async {
    await setUp(t, [file('a.txt'), file('bb.txt')]);
    final done = w.state.pasteFilesAt(const Offset(900, 600));
    await t.pump();
    await w.rebuild(readOnly: true);
    fileGate.waiting.single.complete();
    await done;
    await t.pump();
    expect(boxes(w.c), 0);
    expect(w.store!.stored, hasLength(1));
    expect(w.store!.notices, [_stopNotice]);
  });

  testWidgets('the store replaced mid-paste stops the same way', (t) async {
    await setUp(t, [file('a.txt')]);
    final first = w.store!;
    final done = w.state.pasteFilesAt(const Offset(900, 600));
    await t.pump();
    w.store = TStore();
    await w.rebuild();
    fileGate.waiting.single.complete();
    await done;
    await t.pump();
    expect(boxes(w.c), 0);
    expect(first.stored, hasLength(1));
    expect(first.notices, [_stopNotice]);
    expect(w.store!.stored, isEmpty);
  });

  testWidgets('a toolbar insert or a drop takes the same checks', (t) async {
    await setUp(t, const []);
    var done = w.state.insertFiles([file('a.txt')]);
    await t.pump();
    await w.rebuild(controller: other);
    fileGate.waiting.single.complete();
    await done;
    await t.pump();
    expect(boxes(w.c), 0);
    expect(boxes(other), 0);

    fileGate.waiting.clear();
    await w.rebuild(controller: w.c);
    await t.pump();
    done = w.state.dropFiles([file('d.txt')], const Offset(500, 500));
    await t.pump();
    await w.rebuild(controller: other);
    fileGate.waiting.single.complete();
    await done;
    await t.pump();
    expect(boxes(w.c), 0);
    expect(boxes(other), 0);
  });

  testWidgets('without a change, every file goes in, stacked from the point, and the last is selected', (t) async {
    await setUp(t, [file('a.txt'), file('bb.txt')]);
    fileGate.wait = false;
    expect(await w.state.pasteFilesAt(const Offset(900, 600)), isTrue);
    await t.pump();
    expect(boxes(w.c), 2);
    expect(w.store!.notices, isEmpty);
    final ids = [for (final n in w.c.page.nodes.whereType<BoxRecord>().where((b) => b.typeId == 'test.file')) n.bounds.y];
    expect(ids[1], greaterThan(ids[0]));
    expect(w.c.selectedId, w.c.page.nodes.last.id);
  });
}
