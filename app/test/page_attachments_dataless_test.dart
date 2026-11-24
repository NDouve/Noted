// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A file that is not downloaded (or only its `.<name>.icloud` stub) is present,
// never read and never absent: the attachment store shows it as still syncing.

import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/page_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/src/storage/dataless.dart' show debugDatalessAbi, debugResetDataless;

void main() {
  late Directory root;
  late Directory pages;
  late List<String> notices;
  late List<File> opened;
  late PageAttachments store;

  final good = Uint8List.fromList(List.generate(300, (i) => i % 251));
  final name = '${contentHash(good)}.bin';

  File asset(String n) => File('${pages.path}/p.assets/$n');

  setUp(() {
    root = Directory.systemTemp.createTempSync('noted_dataless');
    pages = Directory('${root.path}/pages')..createSync();
    Directory('${pages.path}/p.assets').createSync();
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
      debugDatalessAbi = null;
      debugResetDataless();
      store.dispose();
      root.deleteSync(recursive: true);
    });
  });

  test('a stub-only attachment exists, is still syncing, is not read and not restored', () async {
    File('${pages.path}/p.assets/.$name.icloud').writeAsStringSync('');
    expect(store.exists(name), isTrue);
    expect((await store.verify(name, size: good.length)).state, AttachmentState.syncing);
    expect((await store.readVerified(name, size: good.length)).state, AttachmentState.syncing);
    expect(await store.read(name), isNull);
    // Nothing was created, moved or set aside.
    expect(Directory('${pages.path}/p.assets').listSync().length, 1);
  });

  test('the stub is never itself an attachment', () async {
    File('${pages.path}/p.assets/.$name.icloud').writeAsStringSync('');
    expect(store.exists('.$name.icloud'), isFalse);
    expect((await store.verify('.$name.icloud', size: 1)).state, AttachmentState.syncing);
    expect(await store.read('.$name.icloud'), isNull);
  });

  test('opening a stub-only attachment opens nothing and says to try again', () async {
    File('${pages.path}/p.assets/.$name.icloud').writeAsStringSync('');
    await store.open('f.bin', fileName: name);
    expect(opened, isEmpty);
    expect(notices.single, contains('right now'));
  });

  test('a dataless attachment is not read; the file stays as it was', () async {
    asset(name).writeAsBytesSync(good);
    expect(store.exists(name), isTrue);
    debugDatalessAbi = Abi.macosArm64; // no lstat here: every existing file fails closed
    debugResetDataless();
    expect((await store.readVerified(name, size: good.length)).state, AttachmentState.syncing);
    expect(await store.read(name), isNull);
    await store.open('f.bin', fileName: name);
    expect(opened, isEmpty);
    debugDatalessAbi = null;
    expect(asset(name).readAsBytesSync(), good);
  }, skip: (Platform.isMacOS || Platform.isIOS) ? 'a real lstat exists: nothing fails closed' : null);

  test('a good attachment is still verified and read', () async {
    asset(name).writeAsBytesSync(good);
    expect((await store.readVerified(name, size: good.length)).state, AttachmentState.ok);
    expect(await store.read(name), good);
  });
}
