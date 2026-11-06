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
    final page = NotedPage.create(PageMeta.create(id: 'p1', title: 'One', order: 0));
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
    await store.save(NotedPage.create(PageMeta.create(id: 'p1', title: '', order: 0)));
    await store.delete('p1');
    expect(await store.scan(), isEmpty);
  });

  test('an adopted file stays the one kept by later scans, until it is gone', () async {
    final page = NotedPage.create(PageMeta.create(id: 'p1', title: 'One', order: 0));
    final text = writePage(page);
    final a = File('${dir.path}/a.canvas')..writeAsStringSync(text);
    final b = File('${dir.path}/b.canvas')..writeAsStringSync(text);
    final store = PageStore(dir)..adopt('p1', b.path);
    for (var i = 0; i < 2; i++) {
      final entries = await store.scan();
      expect(entries.whereType<ReadablePage>().single.path, endsWith('b.canvas'));
      expect(entries.whereType<UnreadablePage>().single.path, endsWith('a.canvas'));
      expect(store.pathFor('p1'), endsWith('b.canvas'));
    }
    b.deleteSync();
    final entries = await store.scan();
    expect(entries.whereType<ReadablePage>().single.path, endsWith('a.canvas'));
    expect(a.readAsStringSync(), text);
  });

  group('an adopted file that cannot be ranked as its page', () {
    String textOf(String id, String title) =>
        writePage(NotedPage.create(PageMeta.create(id: id, title: title, order: 0)));

    for (final locked in [false, true]) {
      test(
        locked
            ? 'one that is locked during the scan stays the page file; the other is a duplicate'
            : 'one that is truncated during the scan stays the page file; the other is a duplicate',
        () async {
          final text = textOf('p1', 'One');
          File('${dir.path}/a.canvas').writeAsStringSync(text);
          final b = File('${dir.path}/b.canvas')..writeAsStringSync(text);
          final store = PageStore(dir)..adopt('p1', b.path);
          RandomAccessFile? raf;
          if (locked) {
            raf = b.openSync(mode: FileMode.append)..lockSync(FileLock.exclusive);
          } else {
            b.writeAsStringSync(text.substring(0, text.length ~/ 2));
          }
          try {
            for (var i = 0; i < 2; i++) {
              final entries = await store.scan();
              expect(entries.whereType<ReadablePage>(), isEmpty);
              expect(store.pathFor('p1'), endsWith('b.canvas'));
              final bad = {for (final u in entries.whereType<UnreadablePage>()) u.path.split(RegExp(r'[\\/]')).last: u.reason};
              expect(bad['a.canvas'], 'duplicate page id p1');
              expect(bad.containsKey('b.canvas'), isTrue);
              expect(store.releasedAdoptions, isEmpty);
            }
          } finally {
            raf?.unlockSync();
            raf?.closeSync();
          }
          // Readable again: the chosen file is the page's.
          b.writeAsStringSync(text);
          final entries = await store.scan();
          expect(entries.whereType<ReadablePage>().single.path, endsWith('b.canvas'));
        },
        skip: locked && !Platform.isWindows ? 'byte-range locks only block reads on Windows' : null,
      );
    }

    test('one that holds another page is reported, not ranked, and keeps the adoption', () async {
      final a = File('${dir.path}/a.canvas')..writeAsStringSync(textOf('p1', 'One'));
      final b = File('${dir.path}/b.canvas')..writeAsStringSync(textOf('p2', 'Two'));
      final store = PageStore(dir)..adopt('p1', b.path);
      for (var i = 0; i < 2; i++) {
        final entries = await store.scan();
        expect(entries.whereType<ReadablePage>().map((e) => e.path.split(RegExp(r'[\\/]')).last).toSet(), {
          'a.canvas',
          'b.canvas',
        });
        expect(store.pathFor('p1'), endsWith('a.canvas'));
        expect(store.pathFor('p2'), endsWith('b.canvas'));
        expect(store.releasedAdoptions, {'p1': b.path});
      }
      // The caller decides: the store keeps the adoption until it is let go.
      store.unadopt('p1');
      await store.scan();
      expect(store.releasedAdoptions, isEmpty);
      expect(a.existsSync(), isTrue);
    });

    test('load refuses a file that holds another page', () async {
      final store = PageStore(dir);
      File('${dir.path}/p1.canvas').writeAsStringSync(textOf('p2', 'Two'));
      await expectLater(store.load('p1'), throwsA(isA<PageFormatException>()));
      File('${dir.path}/p1.canvas').writeAsStringSync(textOf('p1', 'One'));
      expect((await store.load('p1')).meta.title, 'One');
    });
  });

  test('unadopt forgets the choice', () async {
    final page = NotedPage.create(PageMeta.create(id: 'p1', title: 'One', order: 0));
    final text = writePage(page);
    File('${dir.path}/a.canvas').writeAsStringSync(text);
    File('${dir.path}/b.canvas').writeAsStringSync(text);
    final store = PageStore(dir)..adopt('p1', '${dir.path}/b.canvas');
    expect((await store.scan()).whereType<ReadablePage>().single.path, endsWith('b.canvas'));
    store.unadopt('p1');
    // Listing order decides again: only that exactly one file is kept.
    final entries = await store.scan();
    expect(entries.whereType<ReadablePage>(), hasLength(1));
    expect(entries.whereType<UnreadablePage>(), hasLength(1));
  });

  group('scan flags (binder discovery)', () {
    test('createFolder: false on a missing folder fails and creates nothing', () async {
      final missing = Directory('${dir.path}/nope');
      await expectLater(PageStore(missing).scan(createFolder: false), throwsA(isA<FileSystemException>()));
      expect(missing.existsSync(), isFalse);
      // Control: the default still creates the folder.
      expect(await PageStore(missing).scan(), isEmpty);
      expect(missing.existsSync(), isTrue);
    });

    test('sweep: false leaves set-aside files where they are', () async {
      final page = NotedPage.create(PageMeta.create(id: 'p1', title: 'One', order: 0));
      final aside = File('${dir.path}/p1.canvas.1a2b.cas-old')..writeAsStringSync(writePage(page));
      final entries = await PageStore(dir).scan(sweep: false);
      expect(aside.existsSync(), isTrue);
      expect(File('${dir.path}/p1.canvas').existsSync(), isFalse);
      expect(File(entries.whereType<UnreadablePage>().single.path).uri, aside.uri);
      // Control: the default sweep puts it back.
      await PageStore(dir).scan();
      expect(aside.existsSync(), isFalse);
      expect(File('${dir.path}/p1.canvas').existsSync(), isTrue);
    });
  });
}
