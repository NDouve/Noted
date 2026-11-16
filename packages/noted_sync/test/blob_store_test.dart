// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_sync/src/journal.dart';

void main() {
  late Directory root;
  late BlobStore blobs;
  late File src;
  setUp(() {
    root = Directory.systemTemp.createTempSync('blobs');
    blobs = BlobStore(Directory('${root.path}/base'));
    src = File('${root.path}/src.canvas')..writeAsStringSync('AAA');
  });
  tearDown(() => root.deleteSync(recursive: true));

  String shaOf(String s) => ContentIdentity.ofBytes(utf8.encode(s)).sha256;

  List<String> names() => blobs.dir.existsSync()
      ? [
          for (final e in blobs.dir.listSync())
            e.path.split(RegExp(r'[\\/]')).last,
        ]
      : [];

  test('a copy that is what the name says is kept', () async {
    expect(await blobs.put(src, shaOf('AAA')), isTrue);
    expect(names(), [shaOf('AAA')]);
    expect(blobs.fileFor(shaOf('AAA')).readAsStringSync(), 'AAA');
  });

  test('a blob that is there already is left alone', () async {
    await blobs.put(src, shaOf('AAA'));
    src.writeAsStringSync('BBB');
    expect(await blobs.put(src, shaOf('AAA')), isTrue);
    expect(blobs.fileFor(shaOf('AAA')).readAsStringSync(), 'AAA');
  });

  test('a copy that is not what the name says is dropped, and no part is left', () async {
    // The source changed between hashing it and copying it.
    expect(await blobs.put(src, shaOf('BBB')), isFalse);
    expect(names(), isEmpty);
    expect(await blobs.has(shaOf('BBB')), isFalse);
  });

  test('a source that cannot be read leaves no part and throws', () async {
    await expectLater(
      blobs.put(File('${root.path}/missing'), shaOf('AAA')),
      throwsA(isA<FileSystemException>()),
    );
    expect(names(), isEmpty);
  });
}
