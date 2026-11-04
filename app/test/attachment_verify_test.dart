// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A damaged attachment is never trusted and never overwritten or deleted: the
// store keeps it aside as `<name>.damaged-<12 hex>` and tells the user (0098,
// 0131).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/attachment_copy.dart';
import 'package:noted/src/page_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory root;
  late Directory pages;
  late List<String> notices;
  late List<File> opened;
  late PageAttachments store;

  final good = Uint8List.fromList(List.generate(300, (i) => i % 251));
  final bad = Uint8List.fromList(good)..[10] ^= 0xff;
  final hash = contentHash(good);
  final badHash = contentHash(bad);
  final name = '$hash.bin';

  File asset(String n) => File('${pages.path}/p.assets/$n');
  String damagedName(String n, String h) => '$n.damaged-${h.substring(0, 12)}';

  setUp(() {
    root = Directory.systemTemp.createTempSync('noted_verify');
    pages = Directory('${root.path}/pages')..createSync();
    notices = [];
    opened = [];
    store = PageAttachments(
      pageFolder: pages,
      pageId: 'p',
      storage: () => AttachmentStorage.folder,
      cacheDirectory: Directory('${root.path}/cache'),
      onNotice: notices.add,
      opener: (f) async => opened.add(f),
      watch: false,
    );
    addTearDown(() {
      store.dispose();
      root.deleteSync(recursive: true);
    });
  });

  void plant(Uint8List bytes) {
    Directory('${pages.path}/p.assets').createSync(recursive: true);
    asset(name).writeAsBytesSync(bytes);
  }

  group('writing over an existing file', () {
    test('a damaged file under the target name is kept aside and the good copy is written', () async {
      plant(bad);
      final s = await store.put(good, extension: 'bin');
      expect(s.fileName, name);
      expect(asset(name).readAsBytesSync(), good);
      expect(asset(damagedName(name, badHash)).readAsBytesSync(), bad);
      expect(notices.single, contains(damagedName(name, badHash)));
    });

    test('a shorter file is still syncing: left alone, nothing set aside', () async {
      plant(Uint8List.sublistView(good, 0, 50));
      await store.put(good, extension: 'bin');
      expect(asset(name).lengthSync(), 50);
      expect(Directory('${pages.path}/p.assets').listSync().length, 1);
      expect(notices, isEmpty);
    });

    test('a good file is left alone', () async {
      plant(good);
      await store.put(good, extension: 'bin');
      expect(asset(name).readAsBytesSync(), good);
      expect(Directory('${pages.path}/p.assets').listSync().length, 1);
      expect(notices, isEmpty);
    });

    test('the same damaged bytes met twice keep one damaged copy', () async {
      plant(bad);
      await store.put(good, extension: 'bin');
      asset(name).deleteSync();
      plant(bad);
      await store.put(good, extension: 'bin');
      final names = Directory('${pages.path}/p.assets').listSync().map((e) => e.path.split(RegExp(r'[\\/]')).last).toSet();
      expect(names, {name, damagedName(name, badHash)});
      expect(asset(name).readAsBytesSync(), good);
    });
  });

  group('reading and opening a folder file', () {
    test('a damaged file is kept aside, not returned, and the user is told', () async {
      plant(bad);
      final r = await store.readVerified(name, size: good.length);
      expect(r.state, AttachmentState.damaged);
      expect(r.bytes, isNull);
      expect(asset(name).existsSync(), isFalse);
      expect(asset(damagedName(name, badHash)).readAsBytesSync(), bad);
      expect(notices.single, contains(damagedName(name, badHash)));
    });

    test('a file shorter than the recorded size is still syncing and stays', () async {
      plant(Uint8List.sublistView(good, 0, 50));
      final r = await store.readVerified(name, size: good.length);
      expect(r.state, AttachmentState.syncing);
      expect(asset(name).lengthSync(), 50);
      expect(notices, isEmpty);
    });

    test('a good file is read; a missing one is syncing', () async {
      expect((await store.readVerified(name, size: good.length)).state, AttachmentState.syncing);
      plant(good);
      final r = await store.readVerified(name, size: good.length);
      expect(r.state, AttachmentState.ok);
      expect(r.bytes, good);
    });

    test('verify finds a damaged file without keeping bytes', () async {
      plant(bad);
      expect(await store.verify(name, size: good.length), AttachmentState.damaged);
      expect(asset(damagedName(name, badHash)).existsSync(), isTrue);
    });

    test('a temporary copy of an embedded file left damaged is rewritten before opening', () async {
      await store.open('Report.pdf', bytes: good);
      final copy = opened.single;
      copy.writeAsBytesSync(bad);
      await store.open('Report.pdf', bytes: good);
      expect(opened.last.readAsBytesSync(), good);
    });
  });

  group('older readers ignore a kept damaged copy', () {
    test('it is not an attachment name, not a leftover, and not promoted', () async {
      plant(good);
      final dn = damagedName(name, badHash);
      File('${pages.path}/p.assets/$dn').writeAsBytesSync(bad);
      expect(isDamagedCopyName(dn), isTrue);
      expect(isDamagedCopyName(name), isFalse);
      expect(attachmentNameHash(dn), isNull);

      // The sweep leaves it where it is and reports nothing.
      final r = AttachmentCopy();
      await sweepAttachmentLeftovers(Directory('${pages.path}/p.assets'), r);
      expect(r.keptAside, isEmpty);
      expect(File('${pages.path}/p.assets/$dn').readAsBytesSync(), bad);
      expect(asset(name).readAsBytesSync(), good);

      // A copy of the folder carries it along as it is: both stay, and the
      // damaged one is never renamed to a hash name.
      final to = Directory('${root.path}/copy');
      final c = AttachmentCopy();
      await copyAttachmentTree(Directory('${pages.path}/p.assets'), to, c);
      expect(File('${to.path}/$dn').readAsBytesSync(), bad);
      expect(File('${to.path}/$name').readAsBytesSync(), good);
      expect(c.differing, isEmpty);
      expect(to.listSync().length, 2);
    });
  });
}
