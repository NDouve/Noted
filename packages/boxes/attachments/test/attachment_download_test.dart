// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A folder file that is only a cloud placeholder: the boxes say so, offer Retry,
// and a plain store keeps "Still syncing" (Box API 0.17).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'fake_store.dart';

/// A [FakeStore] that says where the download of each file stands.
class _DownloadStore extends FakeStore implements DownloadingAttachmentStore {
  final Map<String, AttachmentDownload> state = {};
  final Map<String, String> errors = {};
  final List<String> retried = [];
  Object? putThrows;

  @override
  AttachmentDownload download(String fileName) => state[fileName] ?? AttachmentDownload.onDevice;

  @override
  String? downloadError(String fileName) => errors[fileName];

  @override
  void retryDownload(String fileName) {
    retried.add(fileName);
    state[fileName] = AttachmentDownload.downloading;
    errors.remove(fileName);
    notifyListeners();
  }

  @override
  bool exists(String fileName) => true; // the placeholder is there

  @override
  Future<StoredAttachment> put(Uint8List bytes, {required String extension, AttachmentStorage? storage}) {
    final e = putThrows;
    if (e != null) throw e;
    return super.put(bytes, extension: extension, storage: storage);
  }
}

BoxRecord _box(BoxCodec<Object?> codec, String id, Object? data, Bounds at) => BoxRecord.create(
  id: id,
  typeId: codec.typeId,
  dataVersion: codec.dataVersion,
  bounds: at,
  data: RawJson.encode(codec.encode(data)),
  snapshotText: codec.snapshotText(data),
  rev: 'r',
).withFixedHeight(true);

void main() {
  final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7 fake'));
  final hash = contentHash(pdf);
  final fileName = '$hash.pdf';
  final ref = AttachmentRef(name: 'Plan.pdf', size: pdf.length, hash: hash, file: fileName);
  final png = redPng;
  final pngHash = contentHash(png);
  final pngName = '$pngHash.png';
  final imageRef = AttachmentRef(name: 'red.png', size: png.length, hash: pngHash, file: pngName);

  late CanvasController c;

  Future<void> show(WidgetTester t, FakeStore store, {bool image = false}) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final modules = ModuleRegistry()
      ..register(const ImageModule())
      ..register(const FileModule(), isDefault: true);
    final node = image
        ? _box(const ImageCodec(), 'b', ImageData(ref: imageRef, width: 4, height: 4), const Bounds(40, 40, 240, 200))
        : _box(const FileCodec(), 'b', FileData(ref: ref), const Bounds(40, 40, 300, 64));
    final page = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)).insertNode(node);
    c = CanvasController(page, modules);
    await t.pumpWidget(
      MaterialApp(
        theme: notedThemeData(Brightness.light),
        home: Scaffold(body: PageCanvas(controller: c, attachments: store)),
      ),
    );
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pump();
  }

  group('the file box', () {
    testWidgets('a file that is downloading says so, offers Retry, and a double-click says it will open', (t) async {
      final s = _DownloadStore()..state[fileName] = AttachmentDownload.downloading;
      await show(t, s);
      expect(find.text('Downloading…'), findsOneWidget);
      expect(find.byKey(const ValueKey('still-downloading')), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Still syncing'), findsNothing);
      // A double-click is not silent.
      final box = find.byKey(const ValueKey('file-box'));
      await t.tap(box);
      await t.pump(const Duration(milliseconds: 50));
      await t.tap(box);
      await t.pump(const Duration(milliseconds: 400));
      expect(s.opened, isEmpty);
      expect(s.notices, ["This file is still downloading. Open it again once it's here."]);
      // Retry asks again.
      await t.tap(find.byKey(const ValueKey('download-retry')));
      await t.pump(const Duration(milliseconds: 400)); // the box's double-click window
      expect(s.retried, [fileName]);
    });

    testWidgets("a refused download says \"Can't download\", with the message, and Retry", (t) async {
      final s = _DownloadStore()
        ..state[fileName] = AttachmentDownload.failed
        ..errors[fileName] = 'The cloud says no';
      await show(t, s);
      expect(find.text("Can't download"), findsOneWidget);
      expect(find.byKey(const ValueKey('download-failed')), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is Tooltip && w.message == 'The cloud says no'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('when the file is on the device the size shows, with no Retry', (t) async {
      final s = _DownloadStore();
      await show(t, s);
      expect(find.text(formatByteSize(pdf.length)), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Downloading…'), findsNothing);
    });

    testWidgets('a plain store keeps "Still syncing", with no Retry', (t) async {
      await show(t, FakeStore());
      expect(find.byKey(const ValueKey('still-syncing')), findsOneWidget);
      expect(find.text('Still syncing'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });
  });

  group('the image box', () {
    testWidgets('a file that is downloading shows "Downloading…" and Retry', (t) async {
      final s = _DownloadStore()..state[pngName] = AttachmentDownload.downloading;
      await show(t, s, image: true);
      expect(find.text('Downloading…'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Still syncing'), findsNothing);
      await t.tap(find.byKey(const ValueKey('download-retry')));
      await t.pump();
      expect(s.retried, [pngName]);
    });

    testWidgets('a refused download shows "Can\'t download" with the message as its tooltip', (t) async {
      final s = _DownloadStore()
        ..state[pngName] = AttachmentDownload.failed
        ..errors[pngName] = 'The cloud says no';
      await show(t, s, image: true);
      expect(find.text("Can't download"), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is Tooltip && w.message == 'The cloud says no'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('it follows the store: Retry, then the file arrives and the picture shows', (t) async {
      final s = _DownloadStore()..state[pngName] = AttachmentDownload.failed;
      await show(t, s, image: true);
      s.retryDownload(pngName);
      await t.pump();
      expect(find.text('Downloading…'), findsOneWidget);
      s.state.remove(pngName);
      s.arrive(pngName, png);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.pump();
      expect(find.text('Downloading…'), findsNothing);
    });

    testWidgets('a plain store keeps "Still syncing"', (t) async {
      await show(t, FakeStore(), image: true);
      expect(find.text('Still syncing'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });
  });

  group('a paste', () {
    testWidgets('over a file that is downloading says so and makes no box', (t) async {
      final s = _DownloadStore()..putThrows = StorageBusy(StorageBusyReason.dataless, ['x']);
      await show(t, s);
      final canvas = t.state<PageCanvasState>(find.byType(PageCanvas));
      final before = c.page.nodes.length;
      await t.runAsync(() => canvas.insertFiles([IncomingFile('Other.pdf', Uint8List.fromList(utf8.encode('%PDF other')))]));
      await t.pump();
      expect(s.notices, ['This file is still downloading. Try again in a moment.']);
      expect(c.page.nodes.length, before, reason: 'no box');
    });

    testWidgets('a refusal that is not about a download is the folder message', (t) async {
      final s = _DownloadStore()..putThrows = const FileSystemException('full');
      await show(t, s);
      final canvas = t.state<PageCanvasState>(find.byType(PageCanvas));
      await t.runAsync(() => canvas.insertFiles([IncomingFile('Other.pdf', Uint8List.fromList(utf8.encode('%PDF other')))]));
      await t.pump();
      expect(s.notices.single, contains('could not be added'));
    });
  });
}
