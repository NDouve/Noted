// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Attachments are re-hashed where they are trusted: reading for display,
// embedding, opening, and decoding embedded data (0098, 0131).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'fake_store.dart';

void main() {
  late FakeStore store;
  final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7 fake content'));
  // The same bytes with one changed: full size, wrong hash.
  final damagedPdf = Uint8List.fromList(pdf)..[3] ^= 0xff;
  // A valid picture that is not the one the hash names: it decodes, so
  // without a check its display copy would be cached under the wrong hash.
  final damagedPng = Uint8List.fromList([...redPng, 0]);

  AttachmentRef folderRef(Uint8List bytes, {String ext = 'pdf'}) {
    final hash = contentHash(bytes);
    return AttachmentRef(
      name: 'Plan.$ext',
      size: bytes.length,
      hash: hash,
      file: '$hash.$ext',
    );
  }

  Map<String, Object?> embeddedJson(Uint8List data) => {
    'name': 'Plan.pdf',
    'size': pdf.length,
    'hash': contentHash(pdf),
    'data': base64Encode(data),
  };

  setUp(() => store = FakeStore());

  group('embedded data', () {
    test(
      'base64 that does not match its hash is not used, and is kept as it is',
      () {
        final ref = AttachmentRef.fromJson(embeddedJson(damagedPdf))!;
        expect(ref.bytes, isNull);
        expect(ref.isEmbedded, isFalse);
        expect(ref.isDamaged, isTrue);
        expect(
          attachmentMissing(ref, store),
          isFalse,
          reason: 'damaged, not syncing',
        );
        expect(
          ref.toJson()['data'],
          base64Encode(damagedPdf),
          reason: 'the page keeps it',
        );
      },
    );

    test(
      'with a folder file, the damaged data is ignored and the file is used',
      () {
        final hash = contentHash(pdf);
        final ref = AttachmentRef.fromJson({
          ...embeddedJson(damagedPdf),
          'file': '$hash.pdf',
        })!;
        expect(ref.bytes, isNull);
        expect(ref.file, '$hash.pdf');
        expect(ref.isDamaged, isFalse);
      },
    );

    test('matching base64 is used', () {
      expect(AttachmentRef.fromJson(embeddedJson(pdf))!.bytes, pdf);
    });

    test(
      'reading a damaged embedded ref tells the user and gives no bytes',
      () async {
        final ref = AttachmentRef.fromJson(embeddedJson(damagedPdf))!;
        final r = await readAttachment(ref, store);
        expect(r.state, AttachmentState.damaged);
        expect(r.bytes, isNull);
        expect(store.notices.single, contains('Plan.pdf'));
        expect(store.notices.single, contains('damaged'));
      },
    );
  });

  group('readAttachment', () {
    test(
      'a damaged folder file at full size is damaged and not returned',
      () async {
        final ref = folderRef(pdf);
        store.arrive(ref.file!, damagedPdf);
        final r = await readAttachment(ref, store);
        expect(r.state, AttachmentState.damaged);
        expect(r.bytes, isNull);
        expect(store.notices.single, contains('damaged'));
      },
    );

    test(
      'a file shorter than the recorded size is still syncing, not damaged',
      () async {
        final ref = folderRef(pdf);
        store.arrive(ref.file!, Uint8List.sublistView(pdf, 0, 5));
        final r = await readAttachment(ref, store);
        expect(r.state, AttachmentState.syncing);
        expect(r.bytes, isNull);
        expect(store.notices, isEmpty);
      },
    );

    test('a missing file is syncing and a good file is read', () async {
      final ref = folderRef(pdf);
      expect((await readAttachment(ref, store)).state, AttachmentState.syncing);
      store.arrive(ref.file!, pdf);
      final r = await readAttachment(ref, store);
      expect(r.state, AttachmentState.ok);
      expect(r.bytes, pdf);
    });
  });

  test('the display copy is not cached from a damaged original', () async {
    // The box recorded redPng; the folder file is a different picture of at
    // least that size.
    final ref = folderRef(redPng, ext: 'png');
    store.arrive(ref.file!, damagedPng);
    final r = await loadDisplayCopyChecked(ref, store);
    expect(r.state, AttachmentState.damaged);
    expect(r.bytes, isNull);
    expect(
      displayCopyFile(store.cacheDirectory, ref.hash).existsSync(),
      isFalse,
    );
  });

  group('embedding', () {
    test('a damaged folder file is not embedded', () async {
      final ref = folderRef(pdf);
      store.arrive(ref.file!, damagedPdf);
      final out = await convertAttachment(
        ref,
        AttachmentStorage.embedded,
        store,
        [],
      );
      expect(out, isNull);
      expect(store.notices.single, contains('damaged'));
    });

    test('a file still arriving is not embedded', () async {
      final ref = folderRef(pdf);
      store.arrive(ref.file!, Uint8List.sublistView(pdf, 0, 4));
      final out = await convertAttachment(
        ref,
        AttachmentStorage.embedded,
        store,
        [],
      );
      expect(out, isNull);
      expect(store.notices, isEmpty);
    });

    test('a box that holds damaged embedded data is not converted, so the data is not dropped', () async {
      final hash = contentHash(pdf);
      final ref = AttachmentRef.fromJson({
        ...embeddedJson(damagedPdf),
        'file': '$hash.pdf',
      })!;
      store.arrive('$hash.pdf', pdf);
      final out = await convertAttachment(
        ref,
        AttachmentStorage.embedded,
        store,
        [],
      );
      expect(out, isNull);
      expect(store.notices.single, contains('not embedded'));
    });

    test('a good folder file is embedded', () async {
      final ref = folderRef(pdf);
      store.arrive(ref.file!, pdf);
      final out = await convertAttachment(
        ref,
        AttachmentStorage.embedded,
        store,
        [],
      );
      expect(out!.bytes, pdf);
    });
  });

  group('opening', () {
    Future<void> pump(WidgetTester t, AttachmentRef ref) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      const codec = FileCodec();
      final data = FileData(ref: ref);
      final box = BoxRecord.create(
        id: 'f',
        typeId: codec.typeId,
        dataVersion: codec.dataVersion,
        bounds: const Bounds(40, 40, 280, 64),
        data: RawJson.encode(codec.encode(data)),
        snapshotText: codec.snapshotText(data),
        rev: 'r',
      ).withFixedHeight(true);
      final modules = ModuleRegistry()
        ..register(const ImageModule())
        ..register(const FileModule(), isDefault: true);
      final page = NotedPage.create(
        PageMeta.create(id: 'p', title: '', order: 0),
      ).insertNode(box);
      await t.pumpWidget(
        MaterialApp(
          theme: notedThemeData(Brightness.light),
          home: Scaffold(
            body: PageCanvas(
              controller: CanvasController(page, modules),
              attachments: store,
            ),
          ),
        ),
      );
      await t.pump();
    }

    Future<void> doubleTap(WidgetTester t) async {
      final box = find.byKey(const ValueKey('file-box'));
      await t.tap(box);
      await t.pump(const Duration(milliseconds: 50));
      await t.tap(box);
      await t.pump(const Duration(milliseconds: 400));
    }

    testWidgets('a damaged file is not opened', (t) async {
      final ref = folderRef(pdf);
      store.arrive(ref.file!, damagedPdf);
      await pump(t, ref);
      await doubleTap(t);
      expect(store.opened, isEmpty);
      expect(store.notices.single, contains('damaged'));
    });

    testWidgets('a file still arriving is not opened', (t) async {
      final ref = folderRef(pdf);
      store.arrive(ref.file!, Uint8List.sublistView(pdf, 0, 3));
      await pump(t, ref);
      await doubleTap(t);
      expect(store.opened, isEmpty);
    });

    testWidgets('a good file is opened', (t) async {
      final ref = folderRef(pdf);
      store.arrive(ref.file!, pdf);
      await pump(t, ref);
      await doubleTap(t);
      expect(store.opened.single.$2, ref.file);
    });
  });

  group('page format', () {
    test(
      'a page with damaged embedded data is saved byte for byte as it was read',
      () {
        const codec = ImageCodec();
        final json = {
          'image': embeddedJson(damagedPdf),
          'width': 4,
          'height': 4,
          'alt': '',
        };
        final data = codec.decode(json, 1);
        // Decoding then encoding gives the same JSON, damaged data included.
        expect(jsonEncode(codec.encode(data)), jsonEncode(json));
        final box = BoxRecord.create(
          id: 'i',
          typeId: codec.typeId,
          dataVersion: codec.dataVersion,
          bounds: const Bounds(0, 0, 100, 100),
          data: RawJson.encode(json),
          snapshotText: codec.snapshotText(data),
          rev: 'r',
        );
        final page = NotedPage.create(
          PageMeta.create(id: 'p', title: '', order: 0),
        ).insertNode(box);
        final text = writePage(page);
        expect(writePage(readPage(text)), text);
      },
    );
  });
}
