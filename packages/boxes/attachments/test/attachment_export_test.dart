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

// Header-only PNG bytes: the signature and an IHDR claiming [w] x [h].
Uint8List pngHeader(int w, int h) {
  final d = ByteData(33);
  const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < 8; i++) {
    d.setUint8(i, sig[i]);
  }
  d.setUint32(8, 13);
  d.setUint32(12, 0x49484452);
  d.setUint32(16, w);
  d.setUint32(20, h);
  d.setUint8(24, 8);
  d.setUint8(25, 6);
  final out = d.buffer.asUint8List();
  d.setUint32(29, _crc(out, 12, 29));
  return out;
}

// Bitwise CRC-32, independent of the module's table version.
int _crc(Uint8List b, int start, int end) {
  var c = 0xFFFFFFFF;
  for (var i = start; i < end; i++) {
    c ^= b[i];
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
  }
  return c ^ 0xFFFFFFFF;
}

// [pngHeader] with [edit] applied, the CRC then fixed unless [fixCrc] is false.
Uint8List badPng(int w, int h, void Function(ByteData d) edit, {bool fixCrc = true}) {
  final b = pngHeader(w, h);
  final d = ByteData.sublistView(b);
  edit(d);
  if (fixCrc) d.setUint32(29, _crc(b, 12, 29));
  return b;
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

    group('a PNG over the raster caps', () {
      final refusal = isA<ExportRefused>().having(
        (e) => e.message,
        'message',
        'big.png is too large to convert. Export the original instead.',
      );

      for (final (w, h, label) in [
        (8000, 6000, 'both sides and pixels'),
        (5000, 100, 'the side limit'),
        (4096, 4097, 'the pixel count and a side'),
        (4000, 4001, 'the pixel count only'),
      ]) {
        test('is decoded at the cap, not passed through: $label', () async {
          final source = _Source(w, h);
          exportImageOpener = (_) async => source;
          final png = pngHeader(w, h);
          final f = await image.export(imageData(embedded('big.png', png)), ExportFormat.png, contextOf(null));
          expect(f, isNull); // the fake's decode fails
          expect(source.decodes, 1);
        });
      }

      test('over 100 MP is refused with the limit\'s message, and not decoded', () async {
        final source = _Source(12000, 10000);
        exportImageOpener = (_) async => source;
        final png = pngHeader(12000, 10000);
        await expectLater(
          image.export(imageData(embedded('big.png', png)), ExportFormat.png, contextOf(null)),
          throwsA(refusal),
        );
        expect(source.decodes, 0);
      });

      test('Original is the unchanged bytes', () async {
        final png = pngHeader(8000, 6000);
        final f = await image.export(imageData(embedded('big.png', png)), ExportFormat.original, contextOf(null));
        expect(f!.bytes, png);
      });

      final malformed = <String, Uint8List>{
        'length field is not 13': badPng(100, 100, (d) => d.setUint32(8, 14)),
        'only 20 bytes': pngHeader(100, 100).sublist(0, 20),
        'a truncated IHDR (30 bytes)': pngHeader(100, 100).sublist(0, 30),
        'width 0': badPng(0, 100, (d) {}),
        'a bad CRC': badPng(100, 100, (d) => d.setUint32(29, 1), fixCrc: false),
        'a bad bit depth': badPng(100, 100, (d) => d.setUint8(24, 7)),
        'a colour type that doesn\'t take the depth': badPng(100, 100, (d) {
          d.setUint8(25, 3);
          d.setUint8(24, 16);
        }),
      };
      malformed.forEach((label, bytes) {
        test('never comes back as the same bytes: $label', () async {
          final source = _Source(100, 100);
          exportImageOpener = (_) async => source;
          final f = await image.export(imageData(embedded('m.png', bytes)), ExportFormat.png, contextOf(null));
          expect(f, isNull); // decoded (the fake fails), not passed through
          expect(source.decodes, isNonZero);
        });
      });

      test('at the cap exactly passes through; a malformed header does not', () async {
        final source = _Source(4096, 3906);
        exportImageOpener = (_) async => source;
        final ok = pngHeader(4096, 3906); // 15.99 MP
        final f = await image.export(imageData(embedded('a.png', ok)), ExportFormat.png, contextOf(null));
        expect(f!.bytes, same(ok));
        // IHDR type damaged: the size can't be trusted, so it is decoded.
        final bad = Uint8List.fromList(ok)..[13] = 0x58;
        final g = await image.export(imageData(embedded('a.png', bad)), ExportFormat.png, contextOf(null));
        expect(g, isNull);
        expect(source.decodes, 1);
      });
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
