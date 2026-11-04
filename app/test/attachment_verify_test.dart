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
import 'package:noted/src/home.dart';
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

    test('a shorter file is still syncing: left alone, the good bytes kept beside it', () async {
      plant(Uint8List.sublistView(good, 0, 50));
      await store.put(good, extension: 'bin');
      expect(asset(name).lengthSync(), 50);
      final kept = Directory('${pages.path}/p.assets').listSync().map((e) => e.path.split(RegExp(r'[\\/]')).last).where((n) => n.contains('.kept-')).single;
      expect(File('${pages.path}/p.assets/$kept').readAsBytesSync(), good);
      expect(notices.single, contains(kept));
    });

    test('when the damaged file cannot be set aside, the good bytes are kept beside it', () async {
      plant(bad);
      attachmentAfterSetAsideHook = (_) => throw const FileSystemException('injected');
      addTearDown(() => attachmentAfterSetAsideHook = null);
      await store.put(good, extension: 'bin');
      final names = Directory('${pages.path}/p.assets').listSync().map((e) => e.path.split(RegExp(r'[\\/]')).last).toList();
      final kept = names.where((n) => n.contains('.kept-')).single;
      expect(File('${pages.path}/p.assets/$kept').readAsBytesSync(), good);
      expect(File('${pages.path}/p.assets/${damagedName(name, badHash)}').readAsBytesSync(), bad, reason: 'it moved before the failure');
      expect(notices.single, contains('could not be set aside'));
      expect(notices.single, contains(damagedName(name, badHash)), reason: 'says where it is');
    });

    test('a folder at the target is not touched; the good bytes are kept beside it', () async {
      Directory('${pages.path}/p.assets/$name').createSync(recursive: true);
      await store.put(good, extension: 'bin');
      expect(Directory('${pages.path}/p.assets/$name').existsSync(), isTrue);
      expect(Directory('${pages.path}/p.assets').listSync().any((e) => e.path.contains('.kept-')), isTrue);
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
      expect(r.keptAs, damagedName(name, badHash));
      expect(notices, isEmpty, reason: 'the module tells the user, by the box name');
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
      final v = await store.verify(name, size: good.length);
      expect(v.state, AttachmentState.damaged);
      expect(v.keptAs, damagedName(name, badHash));
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

  test('a long attachment notice stays longer and can be closed', () {
    final long = attachmentNoticeBar('x' * 120);
    expect(long.duration, greaterThanOrEqualTo(const Duration(seconds: 15)));
    expect(long.showCloseIcon, isTrue);
    final short = attachmentNoticeBar(overLimitNotice);
    expect(short.duration, const Duration(milliseconds: 4000));
    expect(short.showCloseIcon, isFalse);
    expect(
      'A file in this page\'s folder is damaged, so it was not used. The damaged copy was kept as "x.damaged-0123456789ab" beside it.'.length,
      greaterThan(90),
    );
  });

  group('kept copies and the checks', () {
    test('a kept copy that was finished by its writer is put back when the file is missing', () async {
      plant(bad);
      final first = await store.readVerified(name, size: good.length);
      expect(first.state, AttachmentState.damaged);
      // The in-place writer that was mid-write when the file moved aside
      // finishes the job into the file it still holds open.
      asset(damagedName(name, badHash)).writeAsBytesSync(good);
      final again = await store.readVerified(name, size: good.length);
      expect(again.state, AttachmentState.ok);
      expect(again.bytes, good);
      expect(asset(name).readAsBytesSync(), good);
      expect(asset(damagedName(name, badHash)).existsSync(), isFalse);
    });

    test('a kept copy that is still damaged is not put back', () async {
      plant(bad);
      await store.readVerified(name, size: good.length);
      final again = await store.readVerified(name, size: good.length);
      expect(again.state, AttachmentState.syncing);
      expect(asset(name).existsSync(), isFalse);
    });

    test('a folder or link in place of the file is never trusted: syncing', () async {
      Directory('${pages.path}/p.assets/$name').createSync(recursive: true);
      final r = await store.readVerified(name, size: good.length);
      expect(r.state, AttachmentState.syncing);
    });

    test('a link in place of the file is never trusted, even to a good file', () async {
      final real = File('${root.path}/elsewhere.bin')..writeAsBytesSync(good);
      Directory('${pages.path}/p.assets').createSync(recursive: true);
      try {
        Link('${pages.path}/p.assets/$name').createSync(real.path);
      } on FileSystemException {
        return; // links need a privilege on some systems
      }
      final r = await store.readVerified(name, size: good.length);
      expect(r.state, AttachmentState.syncing);
      expect(r.bytes, isNull);
    });

    test('a file that changes while it is hashed is syncing, not damaged', () async {
      plant(bad);
      attachmentAfterHashHook = (f) async => f.writeAsBytesSync([...bad, 1]);
      addTearDown(() => attachmentAfterHashHook = null);
      final c = await checkAttachmentFile(asset(name), hash, good.length, keepBytes: true);
      expect(c.state, AttachmentState.syncing);
    });

    test('a file that is not what was checked when it is moved is put back, not renamed', () async {
      plant(good);
      // The check saw something else (as if the file was replaced since).
      final r = await setAsideDamaged(asset(name), ContentIdentity(good.length, badHash));
      expect(r.name, isNull);
      expect(r.leftAt, name);
      expect(asset(name).readAsBytesSync(), good);
      expect(Directory('${pages.path}/p.assets').listSync().length, 1);
    });

    test('a failure after the move says where the file is', () async {
      plant(bad);
      attachmentAfterSetAsideHook = (_) => throw const FileSystemException('injected');
      addTearDown(() => attachmentAfterSetAsideHook = null);
      final r = await setAsideDamaged(asset(name), ContentIdentity(bad.length, badHash));
      expect(r.name, isNull);
      expect(r.leftAt, damagedName(name, badHash));
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
