// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

/// Stands in for the image box: takes .png files, keeps nothing.
final class _Images extends BoxModule<String> {
  @override
  BoxCodec<String> get codec => const _ImageCodec();
  @override
  int fileAffinity(IncomingFile file) => file.extension == 'png' ? 10 : 0;
  @override
  Future<(String, Size)?> createFromFile(IncomingFile file, AttachmentStore store) async =>
      (file.name, const Size(80, 60));
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) => Text(box.data);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) => Text(box.data);
}

final class _ImageCodec extends BoxCodec<String> {
  const _ImageCodec();
  @override
  String get typeId => 'test.image';
  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.fixed;
  @override
  String create() => '';
  @override
  String decode(Object? json, int storedVersion) => json is String ? json : '';
  @override
  Object? encode(String data) => data;
  @override
  String snapshotText(String data) => data;
  @override
  bool isEmpty(String data) => false;
  @override
  AiExposure aiExposure(String data) => AiText(data);
  @override
  MergeResult<String> merge(String base, String mine, String theirs) => Merged(mine);
}

class _Store extends ChangeNotifier implements AttachmentStore {
  @override
  AttachmentStorage get storage => AttachmentStorage.folder;
  @override
  Listenable get changes => this;
  @override
  Directory get cacheDirectory => Directory.systemTemp;
  @override
  Future<StoredAttachment> put(Uint8List bytes, {required String extension, AttachmentStorage? storage}) async =>
      StoredAttachment(hash: contentHash(bytes), fileName: attachmentFileName(contentHash(bytes), extension));
  @override
  Future<Uint8List?> read(String fileName) async => null;
  @override
  bool exists(String fileName) => false;
  @override
  void notify(String message) {}
  @override
  Future<void> open(String name, {String? fileName, Uint8List? bytes}) async {}
  @override
  Future<List<IncomingFile>> pick({required bool imagesOnly}) async => const [];
}

void main() {
  late CanvasController c;

  tearDown(() {
    FileClipboard.read = () async => const [];
    AppFlowyClipboard.mockSetData(null);
  });

  Future<void> frames(WidgetTester t, [int n = 6]) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<EditorState> newNote(WidgetTester t, String text) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final modules = ModuleRegistry()
      ..register(const NoteModule(), alwaysOn: true, isDefault: true)
      ..register(_Images());
    c = CanvasController(NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)), modules);
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: noteLocalizationsDelegates,
        home: Scaffold(body: PageCanvas(controller: c, attachments: _Store())),
      ),
    );
    await t.pump();
    final canvas = t.state<PageCanvasState>(find.byType(PageCanvas));
    await t.tapAt(canvas.view!.toScreen(const Offset(100, 100)) + const Offset(0, CommandToolbar.height));
    await frames(t);
    final editor = t.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;
    await editor.insertTextAtCurrentSelection(text);
    await t.pump();
    return editor;
  }

  Future<void> ctrlV(WidgetTester t) async {
    await t.runAsync(() async {
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyV);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await frames(t, 4);
  }

  String text(EditorState e) => e.document.root.children.first.delta!.toPlainText();

  testWidgets('an image on the clipboard becomes a box beside the note, not inline', (t) async {
    FileClipboard.read = () async => [IncomingFile('Pasted image.png', Uint8List.fromList([1, 2, 3]))];
    final editor = await newNote(t, 'caption');
    final note = c.editingId!;
    await ctrlV(t);
    final image = c.page.nodes.whereType<BoxRecord>().singleWhere((b) => b.typeId == 'test.image');
    final n = c.page.node(note)!.bounds!;
    expect(image.bounds.x, greaterThan(n.x + n.width));
    expect(image.bounds.y, n.y, reason: 'top-aligned with the note');
    expect(text(editor), 'caption', reason: 'nothing pasted inline');
  });

  testWidgets('text on the clipboard is pasted into the note as before', (t) async {
    AppFlowyClipboard.mockSetData(const AppFlowyClipboardData(text: ' pasted'));
    final editor = await newNote(t, 'caption');
    await ctrlV(t);
    expect(text(editor), 'caption pasted');
    expect(c.page.nodes.whereType<BoxRecord>().where((b) => b.typeId == 'test.image'), isEmpty);
  });

  testWidgets('a non-image file on the clipboard is pasted as text, not as a box', (t) async {
    FileClipboard.read = () async => [IncomingFile('notes.pdf', Uint8List.fromList([1]))];
    AppFlowyClipboard.mockSetData(const AppFlowyClipboardData(text: '!'));
    final editor = await newNote(t, 'caption');
    await ctrlV(t);
    expect(text(editor), 'caption!');
  });
}
