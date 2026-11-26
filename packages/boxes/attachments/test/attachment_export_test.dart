// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The image and file boxes' export (Box API 0.18): the original file, and an
// image as PNG.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'fake_store.dart';

// A GIF of two frames of one pixel: the first red, the second blue.
final Uint8List _gif = Uint8List.fromList([
  ...'GIF89a'.codeUnits, 1, 0, 1, 0, 0x80, 0, 0, 255, 255, 255, 0, 0, 0, //
  0x21, 0xF9, 4, 0, 10, 0, 0, 0, //
  0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0x80, 255, 0, 0, 0, 0, 0, 2, 2, 0x44, 1, 0,
  0x21, 0xF9, 4, 0, 10, 0, 0, 0, //
  0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0x80, 0, 0, 255, 0, 0, 0, 2, 2, 0x44, 1, 0,
  0x3B,
]);

class _Source implements ExportImageSource {
  _Source(this.width, this.height);
  @override
  final int width;
  @override
  final int height;
  int decodes = 0;
  @override
  Future<ui.Codec> instantiateCodec({int? targetWidth, int? targetHeight}) async {
    decodes++;
    throw StateError('decoded');
  }

  @override
  void dispose() {}
}

AttachmentRef embedded(String name, Uint8List bytes) =>
    AttachmentRef(name: name, size: bytes.length, hash: contentHash(bytes), bytes: bytes);

AttachmentRef inFolder(String name, Uint8List bytes, {String? file}) => AttachmentRef(
  name: name,
  size: bytes.length,
  hash: contentHash(bytes),
  file: file ?? '${contentHash(bytes)}.${normalizedExtension(name)}',
);

ExportContext contextOf(AttachmentStore? store) => ExportContext(attachments: store, size: const ui.Size(100, 100));

void main() {
  const image = ImageModule();
  const file = FileModule();

  ImageData imageData(AttachmentRef ref) => ImageData(ref: ref, width: 4, height: 4);

  test('an image lists original and png, a file lists original, an empty box nothing', () {
    expect([for (final f in image.exportFormats(imageData(embedded('a.png', redPng))))  f.id], ['original', 'png']);
    expect([for (final f in file.exportFormats(FileData(ref: embedded('a.txt', Uint8List(1)))))  f.id], ['original']);
    expect(image.exportFormats(null), isEmpty);
    expect(file.exportFormats(null), isEmpty);
  });

  group('original', () {
    test('an embedded file keeps its display name and bytes', () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final f = await file.export(FileData(ref: embedded('Plan.pdf', bytes)), ExportFormat.original, contextOf(null));
      expect(f!.name, 'Plan.pdf');
      expect(f.bytes, bytes);
    });

    test('a folder file is read through the store', () async {
      final bytes = Uint8List.fromList([9, 8, 7]);
      final store = PageFolderFakeStore();
      final ref = inFolder('Notes.txt', bytes);
      store.folder[ref.file!] = bytes;
      final f = await file.export(FileData(ref: ref), ExportFormat.original, contextOf(store));
      expect(f!.bytes, bytes);
      expect(f.name, 'Notes.txt');
    });

    test('an absent file, a short one and a damaged one give nothing', () async {
      final bytes = Uint8List.fromList([9, 8, 7, 6]);
      final ref = inFolder('Notes.txt', bytes);
      final store = PageFolderFakeStore();
      expect(await file.export(FileData(ref: ref), ExportFormat.original, contextOf(store)), isNull, reason: 'absent');
      store.folder[ref.file!] = bytes.sublist(0, 2);
      expect(await file.export(FileData(ref: ref), ExportFormat.original, contextOf(store)), isNull, reason: 'short');
      store.folder[ref.file!] = Uint8List.fromList([0, 0, 0, 0]);
      expect(await file.export(FileData(ref: ref), ExportFormat.original, contextOf(store)), isNull, reason: 'damaged');
    });

    test('a name that is not an attachment name never reaches the store', () async {
      final store = PageFolderFakeStore()..folder['../secret.txt'] = Uint8List.fromList([1]);
      final ref = AttachmentRef(name: 'x.txt', size: 1, hash: contentHash(Uint8List.fromList([1])), file: '../secret.txt');
      expect(attachmentNameInvalid(ref), isTrue);
      expect(await file.export(FileData(ref: ref), ExportFormat.original, contextOf(store)), isNull);
    });

    test('an image\'s original is the stored file', () async {
      final f = await image.export(imageData(embedded('red.png', redPng)), ExportFormat.original, contextOf(null));
      expect(f!.bytes, redPng);
      expect(f.name, 'red.png');
    });
  });

  group('PNG', () {
    tearDown(() => exportImageOpener = null);

    test('a PNG original is passed through unchanged, never decoded', () async {
      final source = _Source(4, 4);
      exportImageOpener = (_) async => source;
      final f = await image.export(imageData(embedded('red.png', redPng)), ExportFormat.png, contextOf(null));
      expect(f!.bytes, same(redPng));
      expect(source.decodes, 0);
    });

    testWidgets('a GIF gives a PNG of its first frame', (t) async {
      await t.runAsync(() async {
        final f = await image.export(imageData(embedded('a.gif', _gif)), ExportFormat.png, contextOf(null));
        expect(isPngBytes(f!.bytes), isTrue);
        final codec = await ui.instantiateImageCodec(f.bytes);
        final frame = await codec.getNextFrame();
        final px = (await frame.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
        expect((frame.image.width, frame.image.height), (1, 1));
        expect(px.buffer.asUint8List().sublist(0, 4), [255, 0, 0, 255]);
        frame.image.dispose();
      });
    });

    test('an image over the cap is decoded at its target size, never at full size', () async {
      final source = _Source(8000, 6000);
      exportImageOpener = (_) async => source;
      // A decode that fails gives nothing (the box says so), not a crash.
      final f = await image.export(imageData(embedded('big.gif', _gif)), ExportFormat.png, contextOf(null));
      expect(f, isNull);
      expect(source.decodes, 1);
    });

    test('an image over 100 MP is refused with the host\'s message and not decoded', () async {
      final source = _Source(12000, 10000);
      exportImageOpener = (_) async => source;
      await expectLater(
        image.export(imageData(embedded('huge.gif', _gif)), ExportFormat.png, contextOf(null)),
        throwsA(
          isA<ExportRefused>().having(
            (e) => e.message,
            'message',
            'huge.gif is too large to convert. Export the original instead.',
          ),
        ),
      );
      expect(source.decodes, 0);
      // The original is still there, unchanged.
      final f = await image.export(imageData(embedded('huge.gif', _gif)), ExportFormat.original, contextOf(null));
      expect(f!.bytes, _gif);
    });

    test('a file that doesn\'t decode gives nothing', () async {
      final junk = Uint8List.fromList([1, 2, 3]);
      final f = await image.export(imageData(embedded('x.gif', junk)), ExportFormat.png, contextOf(null));
      expect(f, isNull);
    });
  });
}
