// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The page's attachment store joins a box's `file` value onto the assets
// folder only if it is a name the app writes (0098). Anything else is a
// missing file: not read, hashed, opened or set aside, wherever it points.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/page_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory root;
  late Directory pages;
  late Directory recovery;
  late PageAttachments store;
  late List<File> opened;
  late File sentinel;
  final secret = Uint8List.fromList(List.generate(40, (i) => i));
  final hash = contentHash(secret);

  // Everything under [root], to show nothing was copied, moved or set aside.
  List<String> listing() =>
      root.listSync(recursive: true, followLinks: false).map((e) => e.path).toList()..sort();

  setUp(() {
    root = Directory.systemTemp.createTempSync('noted_names');
    pages = Directory('${root.path}/pages')..createSync();
    recovery = Directory('${root.path}/recovery')..createSync();
    Directory('${pages.path}/p.assets').createSync();
    Directory('${recovery.path}/p.assets').createSync();
    sentinel = File('${pages.path}/secret.txt')..writeAsBytesSync(secret);
    File('${recovery.path}/secret.txt').writeAsBytesSync(secret);
    opened = [];
    store = PageAttachments(
      pageFolder: pages,
      pageId: 'p',
      storage: () => AttachmentStorage.folder,
      cacheDirectory: Directory('${root.path}/cache'),
      recoveryDirectory: recovery,
      opener: (f) async => opened.add(f),
      watch: false,
    );
    addTearDown(() {
      store.dispose();
      root.deleteSync(recursive: true);
    });
  });

  // Names that would reach `secret.txt` (one folder above the assets folder),
  // or are otherwise not attachment names.
  List<String> bad() => [
    '',
    '../secret.txt',
    '..\\secret.txt',
    '../../pages/secret.txt',
    sentinel.path,
    sentinel.absolute.path.replaceAll('/', '\\'),
    'C:secret.txt',
    '\\\\server\\share\\secret.txt',
    '/etc/hostname',
    '$hash.PDF',
    '$hash.abcdefghijk',
    '${hash.toUpperCase()}.pdf',
    '${hash.substring(1)}.pdf',
    '${hash}0',
    '$hash.',
    'secret.txt',
  ];

  test('every bad name is missing and nothing is touched', () async {
    final before = listing();
    final stamp = sentinel.statSync().modified;
    for (final n in bad()) {
      expect(store.exists(n), isFalse, reason: 'exists "$n"');
      expect(await store.read(n), isNull, reason: 'read "$n"');
      for (final v in [await store.readVerified(n, size: 1), await store.verify(n, size: 1)]) {
        expect(v.state, AttachmentState.syncing, reason: 'verify "$n"');
        expect(v.bytes, isNull, reason: 'verify "$n"');
      }
      await store.open('Plan', fileName: n);
    }
    expect(opened, isEmpty);
    expect(listing(), before, reason: 'nothing created, copied, moved or set aside');
    expect(sentinel.readAsBytesSync(), secret);
    expect(sentinel.statSync().modified, stamp);
  });

  test('a good name is still found in the folder and in the recovery folder', () async {
    final name = '$hash.bin';
    File('${pages.path}/p.assets/$name').writeAsBytesSync(secret);
    expect(store.exists(name), isTrue);
    expect(await store.read(name), secret);
    expect((await store.readVerified(name, size: secret.length)).state, AttachmentState.ok);
    await store.open('Plan', fileName: name);
    expect(opened.single.path, endsWith(name));

    final other = '${contentHash(Uint8List(3))}.bin';
    File('${recovery.path}/p.assets/$other').writeAsBytesSync(Uint8List(3));
    expect(await store.read(other), Uint8List(3));
  });

  test('a bare hash name (no extension) is accepted', () async {
    // A bare 64-hex name is accepted by the rule (no extension).
    File('${pages.path}/p.assets/$hash').writeAsBytesSync(secret);
    expect(await store.read(hash), secret);
  });
}
