// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('noted_store'));
  tearDown(() async => dir.delete(recursive: true));

  test('saves, scans, overwrites and loads pages', () async {
    final store = PageStore(dir);
    final page = Page.create(PageMeta.create(id: 'p1', title: 'One', order: 0));
    await store.save(page);
    // A second save replaces the existing file.
    await store.save(page.withMeta(page.meta.withTitle('Renamed')));

    final fresh = PageStore(dir);
    final entries = await fresh.scan();
    expect(entries.single, isA<ReadablePage>());
    expect((entries.single as ReadablePage).meta.title, 'Renamed');
    expect((await fresh.load('p1')).meta.title, 'Renamed');
    expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
  });

  test('reports unreadable files without touching them', () async {
    final bad = File('${dir.path}/broken.canvas')..writeAsStringSync('{oops');
    final entries = await PageStore(dir).scan();
    expect(entries.single, isA<UnreadablePage>());
    expect(bad.readAsStringSync(), '{oops');
  });

  test('deletes pages', () async {
    final store = PageStore(dir);
    await store.save(Page.create(PageMeta.create(id: 'p1', title: '', order: 0)));
    await store.delete('p1');
    expect(await store.scan(), isEmpty);
  });
}
