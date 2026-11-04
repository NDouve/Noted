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

  group('with a VerifyingAttachmentStore', () {
    late _VerifyingStore vs;
    final png = redPng;
    final pngHash = contentHash(png);
    setUp(() => vs = _VerifyingStore());

    AttachmentRef pngRef() => AttachmentRef(
      name: 'red.png',
      size: png.length,
      hash: pngHash,
      file: '$pngHash.png',
    );

    test('a file named by another hash than the box records is never read as this attachment', () async {
      // The box says hash A, its file is named for B (and holds B).
      final other = contentHash(pdf);
      final ref = AttachmentRef(
        name: 'red.png',
        size: png.length,
        hash: pngHash,
        file: '$other.png',
      );
      vs.arrive('$other.png', png);
      final r = await loadDisplayCopyChecked(ref, vs);
      expect(r.state, AttachmentState.damaged);
      expect(r.bytes, isNull);
      expect(vs.readCalls, 0);
      expect(
        displayCopyFile(vs.cacheDirectory, pngHash).existsSync(),
        isFalse,
        reason: 'nothing cached under A',
      );
      expect(vs.notices.single, contains('red.png'));
    });

    test('a hash that is not a SHA-256 never reaches a cache path', () async {
      final ref = AttachmentRef(
        name: 'x.png',
        size: 1,
        hash: '../../x',
        file: 'x.png',
      );
      final r = await loadDisplayCopyChecked(ref, vs);
      expect(r.state, AttachmentState.damaged);
      expect(vs.notices.single, contains('x.png'));
    });

    test(
      'a damaged result tells the user by the box name and where the copy went',
      () async {
        vs.arrive('$pngHash.png', png);
        vs.result = (name) => const VerifiedAttachment(
          AttachmentState.damaged,
          keptAs: 'kept.damaged-0123456789ab',
        );
        final r = await readAttachment(pngRef(), vs);
        expect(r.state, AttachmentState.damaged);
        expect(vs.notices.single, contains('red.png'));
        expect(vs.notices.single, contains('kept.damaged-0123456789ab'));
      },
    );

    test(
      'a file that could not be set aside is reported where it is',
      () async {
        vs.arrive('$pngHash.png', png);
        vs.result = (name) => const VerifiedAttachment(
          AttachmentState.damaged,
          leftAt: 'moved.damaged-0123456789ab',
        );
        await readAttachment(pngRef(), vs);
        expect(vs.notices.single, contains('could not be moved aside'));
        expect(vs.notices.single, contains('moved.damaged-0123456789ab'));
      },
    );

    test('a good file is read through the store', () async {
      vs.arrive('$pngHash.png', png);
      final r = await readAttachment(pngRef(), vs);
      expect(r.state, AttachmentState.ok);
      expect(vs.readCalls, 1);
    });

    test('a file over the embed limit is not read when embedding', () async {
      final ref = AttachmentRef(
        name: 'big.bin',
        size: embedLimitBytes + 1,
        hash: pngHash,
        file: '$pngHash.bin',
      );
      final over = <String>[];
      final out = await convertAttachment(
        ref,
        AttachmentStorage.embedded,
        vs,
        over,
      );
      expect(out, isNull);
      expect(over, ['big.bin']);
      expect(vs.readCalls, 0);
    });

    testWidgets(
      'a damaged image is checked and reported once, not on every rebuild',
      (t) async {
        t.view.physicalSize = const Size(1200, 800);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        vs.arrive('$pngHash.png', png);
        vs.result = (name) => const VerifiedAttachment(
          AttachmentState.damaged,
          keptAs: 'k.damaged-0123456789ab',
        );
        const codec = ImageCodec();
        final data = ImageData(ref: pngRef(), width: 4, height: 4);
        final box = BoxRecord.create(
          id: 'i',
          typeId: codec.typeId,
          dataVersion: codec.dataVersion,
          bounds: const Bounds(40, 40, 200, 200),
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
        final controller = CanvasController(page, modules);
        Future<void> show() async {
          await t.pumpWidget(
            MaterialApp(
              theme: notedThemeData(Brightness.light),
              home: Scaffold(
                body: PageCanvas(controller: controller, attachments: vs),
              ),
            ),
          );
          for (var i = 0; i < 3; i++) {
            await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)),
            );
            await t.pump();
          }
        }

        await show();
        expect(vs.notices.length, 1);
        // Rebuilds (hover, drag and the like) must not hash and report again.
        // Edits to the box rebuild its content.
        for (var i = 0; i < 3; i++) {
          controller.editBox('i', data.copyWith(alt: 'edit $i'));
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 80)),
          );
          await t.pump();
        }
        await t.pump(const Duration(milliseconds: 100));
        expect(vs.notices.length, 1);
        expect(vs.readCalls, 1);
      },
    );
  });

  group('what an image box says', () {
    final png = redPng;
    final pngHash = contentHash(png);
    final ref = AttachmentRef(
      name: 'red.png',
      size: png.length,
      hash: pngHash,
      file: '$pngHash.png',
    );

    Future<void> show(WidgetTester t, FakeStore s) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      const codec = ImageCodec();
      final data = ImageData(ref: ref, width: 4, height: 4);
      final box = BoxRecord.create(
        id: 'i',
        typeId: codec.typeId,
        dataVersion: codec.dataVersion,
        bounds: const Bounds(40, 40, 200, 200),
        data: RawJson.encode(codec.encode(data)),
        snapshotText: codec.snapshotText(data),
        rev: 'r',
      ).withFixedHeight(true);
      final modules = ModuleRegistry()..register(const ImageModule());
      final page = NotedPage.create(
        PageMeta.create(id: 'p', title: '', order: 0),
      ).insertNode(box);
      await t.pumpWidget(
        MaterialApp(
          theme: notedThemeData(Brightness.light),
          home: Scaffold(
            body: PageCanvas(
              controller: CanvasController(page, modules),
              attachments: s,
            ),
          ),
        ),
      );
      await settle(t);
    }

    testWidgets('a file shorter than the recorded size says "Still syncing"', (
      t,
    ) async {
      final s = FakeStore()
        ..folder[ref.file!] = Uint8List.sublistView(png, 0, 10);
      await show(t, s);
      expect(find.byKey(const ValueKey('still-syncing')), findsOneWidget);
      expect(find.text("This image can't be shown"), findsNothing);
      expect(find.text('This image is damaged'), findsNothing);
    });

    testWidgets(
      'a damaged file says so, and keeps saying so after it is set aside',
      (t) async {
        final s = _VerifyingStore()
          ..folder[ref.file!] = png
          ..result = ((_) => const VerifiedAttachment(
            AttachmentState.damaged,
            keptAs: 'k.damaged-0123456789ab',
          ));
        await show(t, s);
        expect(find.text('This image is damaged'), findsOneWidget);
        expect(find.byKey(const ValueKey('still-syncing')), findsNothing);
        // The file is gone from its name now; the folder changed.
        s.result = (_) => const VerifiedAttachment(AttachmentState.syncing);
        s.folder.remove(ref.file);
        s.arrive('other', png);
        await settle(t);
        expect(find.text('This image is damaged'), findsOneWidget);
        expect(find.byKey(const ValueKey('still-syncing')), findsNothing);
        // A good copy arriving replaces it.
        s.result = null;
        s.arrive(ref.file!, png);
        await settle(t);
        expect(find.byKey(const ValueKey('image-box-picture')), findsOneWidget);
      },
    );

    testWidgets('a good file that does not decode says it can\'t be shown', (
      t,
    ) async {
      final junk = Uint8List.fromList(List.filled(20, 7));
      final jref = AttachmentRef(
        name: 'j.png',
        size: 20,
        hash: contentHash(junk),
        file: '${contentHash(junk)}.png',
      );
      final s = FakeStore()..folder[jref.file!] = junk;
      t.view.physicalSize = const Size(1200, 800);
      addTearDown(t.view.reset);
      const codec = ImageCodec();
      final data = ImageData(ref: jref, width: 4, height: 4);
      final box = BoxRecord.create(
        id: 'i',
        typeId: codec.typeId,
        dataVersion: codec.dataVersion,
        bounds: const Bounds(40, 40, 200, 200),
        data: RawJson.encode(codec.encode(data)),
        snapshotText: codec.snapshotText(data),
        rev: 'r',
      ).withFixedHeight(true);
      final page = NotedPage.create(
        PageMeta.create(id: 'p', title: '', order: 0),
      ).insertNode(box);
      await t.pumpWidget(
        MaterialApp(
          theme: notedThemeData(Brightness.light),
          home: Scaffold(
            body: PageCanvas(
              controller: CanvasController(
                page,
                ModuleRegistry()..register(const ImageModule()),
              ),
              attachments: s,
            ),
          ),
        ),
      );
      await settle(t);
      expect(find.text("This image can't be shown"), findsOneWidget);
    });
  });

  group('page format', () {
    test('editing another field keeps damaged embedded data byte for byte', () {
      const codec = ImageCodec();
      final json = {
        'image': embeddedJson(damagedPdf),
        'width': 4,
        'height': 4,
        'alt': '',
      };
      final data = codec.decode(json, 1)!;
      final edited = codec.encode(data.copyWith(alt: 'a new alt text'))! as Map;
      final image = edited['image']! as Map;
      expect(image['data'], base64Encode(damagedPdf));
      expect(image['hash'], (json['image']! as Map)['hash']);
      expect(edited['alt'], 'a new alt text');
    });

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

/// A [FakeStore] that checks the hash in the file name, as the app's does.
class _VerifyingStore extends FakeStore implements VerifyingAttachmentStore {
  int readCalls = 0;

  /// Replaces the check when set.
  VerifiedAttachment Function(String fileName)? result;

  @override
  Future<VerifiedAttachment> readVerified(
    String fileName, {
    required int size,
  }) async {
    readCalls++;
    final r = result;
    if (r != null) return r(fileName);
    final bytes = folder[fileName];
    if (bytes == null || bytes.length < size) {
      return const VerifiedAttachment(AttachmentState.syncing);
    }
    return contentHash(bytes) == fileName.split('.').first
        ? VerifiedAttachment(AttachmentState.ok, bytes: bytes)
        : const VerifiedAttachment(AttachmentState.damaged);
  }

  @override
  Future<VerifiedAttachment> verify(
    String fileName, {
    required int size,
  }) async {
    final v = await readVerified(fileName, size: size);
    return VerifiedAttachment(v.state, keptAs: v.keptAs, leftAt: v.leftAt);
  }
}

/// Lets the image load (real time), then rebuilds.
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 25; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await t.pump();
  }
}
