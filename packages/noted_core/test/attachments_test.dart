// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

PageMeta _meta(String id, {String? parentId}) => PageMeta.create(id: id, title: id, order: 0, parentId: parentId);

void main() {
  group('the setting in a page header', () {
    test('absent means the page follows its parent; the default is folder', () {
      final m = _meta('p');
      expect(m.attachmentStorage, isNull);
      expect(m.rawAttachmentStorage, isNull);
      expect(effectiveAttachmentStorage([m]), AttachmentStorage.folder);
    });

    test('set, saved in the header and read back', () {
      final m = _meta('p').withAttachmentStorage(AttachmentStorage.embedded);
      expect(m.attachmentStorage, AttachmentStorage.embedded);
      final page = NotedPage.create(m);
      final back = readPage(writePage(page));
      expect(back.meta.attachmentStorage, AttachmentStorage.embedded);
      expect(writePage(page), contains('"attachments":"embedded"'));
      // Clearing removes the key, so the header is as before.
      final cleared = m.withAttachmentStorage(null);
      expect(cleared.rawAttachmentStorage, isNull);
      expect(writePage(NotedPage.create(cleared)), writePage(NotedPage.create(_meta('p'))));
    });

    test('an unknown value is kept as written and read as "follow the parent"', () {
      final text = writePage(NotedPage.create(_meta('p'))).replaceFirst('"pageId"', '"attachments":"cloud","pageId"');
      final page = readPage(text);
      expect(page.meta.attachmentStorage, isNull);
      expect(page.meta.rawAttachmentStorage!.text, '"cloud"');
      expect(writePage(page), text, reason: 'kept byte for byte');
      // Choosing the same as before changes nothing; choosing a value
      // replaces it.
      expect(identical(page.meta.withAttachmentStorage(null).fields, page.meta.fields), isFalse);
      expect(page.meta.withAttachmentStorage(AttachmentStorage.folder).attachmentStorage, AttachmentStorage.folder);
    });
  });

  group('inheritance (0027)', () {
    final embedded = _meta('a').withAttachmentStorage(AttachmentStorage.embedded);
    final folder = _meta('b').withAttachmentStorage(AttachmentStorage.folder);
    final plain = _meta('c');

    test('the nearest own choice wins: page, parents, binder, folder', () {
      expect(effectiveAttachmentStorage([plain, embedded]), AttachmentStorage.embedded);
      expect(effectiveAttachmentStorage([folder, embedded]), AttachmentStorage.folder);
      expect(effectiveAttachmentStorage([plain, plain]), AttachmentStorage.folder);
      final binder = Binder.create(title: 'B', color: binderPalette.first).withAttachmentStorage(AttachmentStorage.embedded);
      expect(effectiveAttachmentStorage([plain], binder: binder), AttachmentStorage.embedded);
      expect(effectiveAttachmentStorage([folder], binder: binder), AttachmentStorage.folder);
    });

    test('a binder keeps the setting in its file; unknown values read as none', () {
      final b = Binder.create(title: 'B', color: binderPalette.first);
      expect(b.attachmentStorage, isNull);
      final set = Binder.parse(b.withAttachmentStorage(AttachmentStorage.embedded).write());
      expect(set.attachmentStorage, AttachmentStorage.embedded);
      final odd = Binder.parse(b.write().replaceFirst('"title"', '"attachments":7,"title"'));
      expect(odd.attachmentStorage, isNull);
      expect(odd.write(), contains('"attachments":7'));
    });
  });

  group('names and sizes', () {
    test('a file is named by its SHA-256 and lowercase extension', () {
      final bytes = Uint8List.fromList(utf8.encode('abc'));
      final hash = contentHash(bytes);
      expect(hash, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(attachmentFileName(hash, 'JPG'), '$hash.jpg');
      expect(attachmentFileName(hash, ''), hash);
      expect(normalizedExtension('Photo.JPG'), 'jpg');
      expect(normalizedExtension('README'), '');
      expect(normalizedExtension('x.tar.gz'), 'gz');
      expect(normalizedExtension('weird.p\$g'), '');
      expect(assetsFolderName('0123'), '0123.assets');
    });

    test('the embed limit is 5 MB', () {
      expect(embedLimitBytes, 5 * 1024 * 1024);
      expect(canEmbed(Uint8List(embedLimitBytes)), isTrue);
      expect(canEmbed(Uint8List(embedLimitBytes + 1)), isFalse);
    });

    test('sizes read as B, KB and MB', () {
      expect(formatByteSize(512), '512 B');
      expect(formatByteSize(14 * 1024), '14 KB');
      expect(formatByteSize((3.2 * 1024 * 1024).round()), '3.2 MB');
      expect(formatByteSize(42 * 1024 * 1024), '42 MB');
    });
  });
}
