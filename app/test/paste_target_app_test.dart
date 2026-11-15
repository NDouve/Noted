// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A paste at a point keeps its target (R-1): a page opened while the clipboard
// is being read gets nothing, and a paste that completes is the same after
// the page is saved and loaded again.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/settle_saves.dart';
import 'support/shell_world.dart';

void main() {
  testWidgets('a clipboard read that completes after another page opened adds nothing to either page', (t) async {
    final w = await ShellWorld.open(t);
    final a = w.nb.current!;
    final gate = Completer<List<IncomingFile>>();
    FileClipboard.read = () => gate.future;
    addTearDown(() => FileClipboard.read = () async => const []);
    final before = a.page.nodes.length;
    final paste = w.canvas(t).pasteFilesAt(const Offset(300, 300));
    await w.openPage(t, w.second);
    final b = w.nb.current!;
    expect(identical(a, b), isFalse);
    gate.complete([IncomingFile('notes.pdf', Uint8List.fromList(const [1, 2, 3]))]);
    await t.runAsync(() => paste);
    await w.settle(t);
    expect(a.page.nodes.length, before);
    expect(b.page.nodes, isEmpty);
    await w.close(t);
  });

  testWidgets('a paste that completes survives save and load: the nodes are equal and the file is stored', (t) async {
    final w = await ShellWorld.open(t);
    final a = w.nb.current!;
    FileClipboard.read = () async => [IncomingFile('notes.pdf', Uint8List.fromList(const [1, 2, 3]))];
    addTearDown(() => FileClipboard.read = () async => const []);
    await t.runAsync(() => w.canvas(t).pasteFilesAt(const Offset(300, 300)));
    await w.settle(t);
    final boxes = a.page.nodes.whereType<BoxRecord>().toList();
    expect(boxes, hasLength(1));
    expect(boxes.single.bounds.x, closeTo(300, 1));
    await settleSaves(t, w.nb);
    await t.runAsync(() => w.nb.flush());

    late Notebook again;
    await t.runAsync(() async {
      again = Notebook(
        PageStore(Directory('${w.dir.path}/pages')),
        buildModules(),
        saveDelay: Duration.zero,
      );
      await again.load();
      await again.open(w.first);
    });
    final reloaded = again.current!;
    expect([for (final n in reloaded.page.nodes) n.id], [for (final n in a.page.nodes) n.id]);
    for (final n in a.page.nodes.whereType<BoxRecord>()) {
      final r = reloaded.page.node(n.id)! as BoxRecord;
      expect(r.bounds, n.bounds);
      expect(r.data.toString(), n.data.toString());
      final live = reloaded.modules.codecs.resolve(r);
      if (live is LiveBox) {
        for (final name in live.codec.folderFiles(live.data)) {
          expect(again.attachments!.exists(name), isTrue, reason: name);
        }
      }
    }
    // The other page has no box that refers to the first page's folder.
    await t.runAsync(() => again.open(w.second));
    expect(again.current!.page.nodes.whereType<BoxRecord>(), isEmpty);
    await t.runAsync(() async => again.dispose());
    await w.close(t);
  });

  testWidgets('three files, the page switched after the first box: A keeps that box, B none, and both reload as they were', (t) async {
    final w = await ShellWorld.open(t);
    final a = w.nb.current!;
    final gate = _GatedStore(w.nb.attachments!);
    Widget canvas(PageCanvasState? old) => MaterialApp(
      home: Scaffold(
        body: PageCanvas(
          key: const ValueKey('canvas'),
          controller: w.nb.current!,
          tools: w.nb.tools,
          attachments: identical(w.nb.current, a) ? gate : _GatedStore(w.nb.attachments!),
        ),
      ),
    );
    await t.pumpWidget(canvas(null));
    await t.pump();
    FileClipboard.read = () async => [
      IncomingFile('a.pdf', Uint8List.fromList(const [1])),
      IncomingFile('bb.pdf', Uint8List.fromList(const [2, 2])),
      IncomingFile('ccc.pdf', Uint8List.fromList(const [3, 3, 3])),
    ];
    addTearDown(() => FileClipboard.read = () async => const []);
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(done(), isTrue);
    }

    final state = t.state<PageCanvasState>(find.byType(PageCanvas));
    final paste = state.pasteFilesAt(const Offset(300, 300));
    await until(() => gate.waiting.isNotEmpty);
    await t.runAsync(() async => gate.waiting[0].complete());
    await until(() => gate.waiting.length == 2);
    await until(() => a.page.nodes.whereType<BoxRecord>().length == 1);
    // Page B opens while the second file is being stored.
    await t.runAsync(() => w.nb.open(w.second));
    await t.pumpWidget(canvas(state));
    await t.pump();
    await t.runAsync(() async => gate.waiting[1].complete());
    await t.runAsync(() => paste);
    await t.pump();
    expect(gate.waiting, hasLength(2), reason: 'the third file was never stored');
    expect(a.page.nodes.whereType<BoxRecord>(), hasLength(1));
    expect(w.nb.current!.page.nodes.whereType<BoxRecord>(), isEmpty);

    await t.pumpWidget(const SizedBox());
    await settleSaves(t, w.nb);
    await t.runAsync(() => w.nb.flush());
    late Notebook again;
    await t.runAsync(() async {
      again = Notebook(
        PageStore(Directory('${w.dir.path}/pages')),
        buildModules(),
        saveDelay: Duration.zero,
      );
      await again.load();
      await again.open(w.first);
    });
    final reloaded = again.current!;
    expect([for (final n in reloaded.page.nodes) n.id], [for (final n in a.page.nodes) n.id]);
    for (final n in a.page.nodes.whereType<BoxRecord>()) {
      final r = reloaded.page.node(n.id)! as BoxRecord;
      expect(r.data.toString(), n.data.toString());
      final live = reloaded.modules.codecs.resolve(r);
      expect(live, isA<LiveBox>());
      if (live is LiveBox) {
        for (final name in live.codec.folderFiles(live.data)) {
          expect(again.attachments!.exists(name), isTrue, reason: name);
        }
      }
    }
    await t.runAsync(() => again.open(w.second));
    expect(again.current!.page.nodes.whereType<BoxRecord>(), isEmpty);
    await t.runAsync(() async => again.dispose());
    await w.close(t);
  });
}

/// Delegates to a page's store; every `put` waits until the test lets it go.
class _GatedStore implements AttachmentStore {
  _GatedStore(this.inner);

  final AttachmentStore inner;
  final List<Completer<void>> waiting = [];

  @override
  Future<StoredAttachment> put(Uint8List bytes, {required String extension, AttachmentStorage? storage}) async {
    final c = Completer<void>();
    waiting.add(c);
    await c.future;
    return inner.put(bytes, extension: extension, storage: storage);
  }

  @override
  AttachmentStorage get storage => inner.storage;
  @override
  Future<Uint8List?> read(String fileName) => inner.read(fileName);
  @override
  bool exists(String fileName) => inner.exists(fileName);
  @override
  Listenable get changes => inner.changes;
  @override
  Directory get cacheDirectory => inner.cacheDirectory;
  @override
  void notify(String message) => inner.notify(message);
  @override
  Future<void> open(String name, {String? fileName, Uint8List? bytes}) =>
      inner.open(name, fileName: fileName, bytes: bytes);
  @override
  Future<List<IncomingFile>> pick({required bool imagesOnly}) => inner.pick(imagesOnly: imagesOnly);
}
