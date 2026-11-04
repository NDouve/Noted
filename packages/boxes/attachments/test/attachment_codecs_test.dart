// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'fake_store.dart';

void main() {
  final bytes = Uint8List.fromList(utf8.encode('hello file'));
  final hash = contentHash(bytes);

  group('codecs', () {
    test('an image stores its ref, size and alt text; the snapshot is [image: alt]', () {
      const codec = ImageCodec();
      final data = ImageData(
        ref: AttachmentRef(
          name: 'cat.png',
          size: 10,
          hash: hash,
          file: '$hash.png',
        ),
        width: 640,
        height: 480,
        alt: 'A cat',
      );
      final json = jsonDecode(jsonEncode(codec.encode(data)));
      expect(json, {
        'image': {
          'name': 'cat.png',
          'size': 10,
          'hash': hash,
          'file': '$hash.png',
        },
        'width': 640,
        'height': 480,
        'alt': 'A cat',
      });
      final back = codec.decode(json, 1)!;
      expect(back.ref, data.ref);
      expect((back.width, back.height, back.alt), (640, 480, 'A cat'));
      expect(codec.snapshotText(back), '[image: A cat]');
      expect(codec.snapshotText(back.copyWith(alt: '')), '[image: ]');
    });

    test('a file box\'s snapshot is [file: name]', () {
      const codec = FileCodec();
      final data = FileData(
        ref: AttachmentRef(
          name: 'Plan.pdf',
          size: 3,
          hash: hash,
          file: '$hash.pdf',
        ),
      );
      expect(codec.snapshotText(data), '[file: Plan.pdf]');
      expect(
        codec.decode(jsonDecode(jsonEncode(codec.encode(data))), 1)!.ref,
        data.ref,
      );
    });

    test('both kinds are read whatever the setting: folder file and embedded bytes', () {
      final inFolder = AttachmentRef.fromJson({
        'name': 'a.txt',
        'size': 10,
        'hash': hash,
        'file': '$hash.txt',
      })!;
      final embedded = AttachmentRef.fromJson({
        'name': 'a.txt',
        'size': 10,
        'hash': hash,
        'data': base64Encode(bytes),
      })!;
      expect(inFolder.isEmbedded, isFalse);
      expect(inFolder.file, '$hash.txt');
      expect(embedded.isEmbedded, isTrue);
      expect(embedded.bytes, bytes);
      expect(
        AttachmentRef.fromJson({'name': 'x', 'hash': hash}),
        isNull,
        reason: 'neither',
      );
      final undecodable = AttachmentRef.fromJson({
        'name': 'x',
        'hash': hash,
        'data': '%%%',
      })!;
      expect(undecodable.isDamaged, isTrue, reason: 'kept, not dropped');
      expect(undecodable.toJson()['data'], '%%%');
    });

    test('fields of a newer version are kept', () {
      const codec = ImageCodec();
      final json = {
        'image': {
          'name': 'a.png',
          'size': 1,
          'hash': hash,
          'file': '$hash.png',
        },
        'width': 2,
        'height': 1,
        'alt': '',
        'crop': [0, 0, 1, 1],
      };
      expect(jsonEncode(codec.encode(codec.decode(json, 1))), jsonEncode(json));
    });

    test('a box whose data can\'t be read is never discarded as empty', () {
      expect(const ImageCodec().isEmpty(null), isFalse);
      expect(const FileCodec().isEmpty(null), isFalse);
    });

    test('merge: both changing the alt text differently conflicts; the same '
        'change on both sides merges', () {
      const codec = ImageCodec();
      final base = ImageData(
        ref: AttachmentRef(name: 'a.png', size: 1, hash: hash, file: 'f'),
        width: 1,
        height: 1,
      );
      final mine = base.copyWith(alt: 'mine');
      expect(
        (codec.merge(base, mine, base.copyWith(alt: 'mine')) as Merged<ImageData?>)
            .data!
            .alt,
        'mine',
      );
      expect(
        codec.merge(base, mine, base.copyWith(alt: 'theirs')),
        isA<Conflicted<ImageData?>>(),
      );
    });
  });

  group('merge: the same part changed on both sides is a conflict', () {
    AttachmentRef ref(String name) =>
        AttachmentRef(name: name, size: 1, hash: hash, file: 'f');

    test('image: both replaced the picture, or one removed its data', () {
      const codec = ImageCodec();
      final base = ImageData(ref: ref('a.png'), width: 1, height: 1);
      expect(
        codec.merge(
          base,
          base.copyWith(ref: ref('m.png')),
          base.copyWith(ref: ref('t.png')),
        ),
        isA<Conflicted<ImageData?>>(),
      );
      expect(
        codec.merge(base, null, base.copyWith(alt: 'x')),
        isA<Conflicted<ImageData?>>(),
      );
    });

    test('image: picture on one side and alt text on the other conflicts '
        '(the text would describe the wrong picture)', () {
      const codec = ImageCodec();
      final base = ImageData(ref: ref('a.png'), width: 1, height: 1);
      expect(
        codec.merge(
          base,
          base.copyWith(ref: ref('m.png')),
          base.copyWith(alt: 'text'),
        ),
        isA<Conflicted<ImageData?>>(),
      );
    });

    test('file: both replaced the file', () {
      const codec = FileCodec();
      final base = FileData(ref: ref('a.pdf'));
      expect(
        codec.merge(
          base,
          FileData(ref: ref('m.pdf')),
          FileData(ref: ref('t.pdf')),
        ),
        isA<Conflicted<FileData?>>(),
      );
    });
  });

  group('storing and converting', () {
    test(
      'folder mode writes the file under its hash; the box keeps name and hash',
      () async {
        final store = FakeStore();
        final ref = await storeIncoming(
          IncomingFile('Notes.TXT', bytes),
          store,
        );
        expect(ref.isEmbedded, isFalse);
        expect(ref.file, '$hash.txt');
        expect(ref.hash, hash);
        expect(store.folder.keys, ['$hash.txt']);
        expect(await loadAttachment(ref, store), bytes);
      },
    );

    test(
      'embedded mode keeps the bytes in the box and writes nothing',
      () async {
        final store = FakeStore(storage: AttachmentStorage.embedded);
        final ref = await storeIncoming(
          IncomingFile('Notes.txt', bytes),
          store,
        );
        expect(ref.isEmbedded, isTrue);
        expect(ref.bytes, bytes);
        expect(store.folder, isEmpty);
        expect(jsonEncode(ref.toJson()), contains(base64Encode(bytes)));
      },
    );

    test('size guard: over 5 MB goes to the folder even in embedded mode, with a notice', () async {
      final store = FakeStore(storage: AttachmentStorage.embedded);
      final big = Uint8List(embedLimitBytes + 1);
      final ref = await storeIncoming(IncomingFile('big.bin', big), store);
      expect(ref.isEmbedded, isFalse);
      expect(store.folder, hasLength(1));
      expect(store.notices, hasLength(1));
      final atLimit = await storeIncoming(
        IncomingFile('ok.bin', Uint8List(embedLimitBytes)),
        store,
      );
      expect(atLimit.isEmbedded, isTrue);
    });

    test(
      'converting both ways; over-limit files stay and are reported',
      () async {
        final store = PageFolderFakeStore();
        final small = await storeIncoming(IncomingFile('a.txt', bytes), store);
        final over = <String>[];
        final embedded = (await convertAttachment(
          small,
          AttachmentStorage.embedded,
          store,
          over,
        ))!;
        expect(embedded.isEmbedded, isTrue);
        expect(embedded.bytes, bytes);
        expect(
          await convertAttachment(
            embedded,
            AttachmentStorage.embedded,
            store,
            over,
          ),
          isNull,
          reason: 'already',
        );

        store.folder.clear();
        final back = (await convertAttachment(
          embedded,
          AttachmentStorage.folder,
          store,
          over,
        ))!;
        expect(back.file, '$hash.txt');
        expect(store.folder['$hash.txt'], bytes);

        final big = await storeIncoming(
          IncomingFile('big.bin', Uint8List(embedLimitBytes + 10)),
          store,
        );
        expect(
          await convertAttachment(big, AttachmentStorage.embedded, store, over),
          isNull,
        );
        expect(over, ['big.bin']);
        expect(over, hasLength(1));

        // A file that hasn't arrived stays as it is.
        final missing = AttachmentRef(
          name: 'm.txt',
          size: 1,
          hash: 'h',
          file: 'h.txt',
        );
        expect(
          await convertAttachment(
            missing,
            AttachmentStorage.embedded,
            store,
            over,
          ),
          isNull,
        );
        expect(attachmentMissing(missing, store), isTrue);
        expect(attachmentMissing(embedded, null), isFalse);
      },
    );

    test('converting to the folder throws when the stored file does not verify', () async {
      final embedded = AttachmentRef(name: 'a.txt', size: bytes.length, hash: hash).embedded(bytes);
      final store = PageFolderFakeStore()..corruptOnPut = true;
      await expectLater(
        convertAttachment(embedded, AttachmentStorage.folder, store, []),
        throwsA(isA<FileSystemException>()),
      );
      final failing = PageFolderFakeStore()..failPut = true;
      await expectLater(
        convertAttachment(embedded, AttachmentStorage.folder, failing, []),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a store that cannot confirm a page-folder file never converts to the folder', () async {
      final embedded = AttachmentRef(name: 'a.txt', size: bytes.length, hash: hash).embedded(bytes);
      final store = FakeStore();
      await expectLater(
        convertAttachment(embedded, AttachmentStorage.folder, store, []),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.folder, isEmpty);
    });
  });

  test('module file affinity: images to the image box, anything else to the file box', () {
    final r = ModuleRegistry()
      ..register(const ImageModule())
      ..register(const FileModule());
    for (final name in [
      'a.png',
      'b.JPG',
      'c.jpeg',
      'd.gif',
      'e.webp',
      'f.bmp',
    ]) {
      expect(
        r.moduleForFile(IncomingFile(name, bytes))?.codec.typeId,
        ImageCodec.id,
        reason: name,
      );
    }
    for (final name in ['a.pdf', 'b.svg', 'notes', 'c.tiff']) {
      expect(
        r.moduleForFile(IncomingFile(name, bytes))?.codec.typeId,
        FileCodec.id,
        reason: name,
      );
    }
  });
}
