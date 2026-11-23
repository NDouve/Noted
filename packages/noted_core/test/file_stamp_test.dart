// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/src/storage/file_stamp.dart' show lstatSymbolFor;

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('noted_stamp'));
  tearDown(() async => dir.delete(recursive: true));

  final sep = Platform.pathSeparator;
  String p(String n) => '${dir.path}$sep$n';

  NotedPage page(String id, {String title = ''}) =>
      NotedPage.create(PageMeta.create(id: id, title: title, order: 0));

  group('fileStamp', () {
    test('a file has a stamp, and two reads of it are equal', () {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
      final a = fileStamp(p('a.bin'));
      expect(a, isNotNull);
      expect(a!.size, 3);
      expect(fileStamp(p('a.bin')), a);
      expect(fileStamp(p('a.bin')).hashCode, a.hashCode);
    });

    test('a folder has a stamp', () {
      expect(fileStamp(dir.path), isNotNull);
    });

    test('is equal across a rename (same folder and another)', () {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
      final before = fileStamp(p('a.bin'));
      File(p('a.bin')).renameSync(p('b.bin'));
      expect(fileStamp(p('b.bin')), before);
      Directory(p('sub')).createSync();
      File(p('b.bin')).renameSync(p('sub${sep}c.bin'));
      expect(fileStamp(p('sub${sep}c.bin')), before);
    });

    test('differs after an append', () {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
      final before = fileStamp(p('a.bin'));
      File(p('a.bin')).writeAsBytesSync([4], mode: FileMode.append);
      expect(fileStamp(p('a.bin')), isNot(before));
    });

    test('differs after a replace by a file of the same size', () {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
      final before = fileStamp(p('a.bin'));
      File(p('a.bin')).deleteSync();
      File(p('a.bin'))
        ..writeAsBytesSync([4, 5, 6])
        ..setLastModifiedSync(DateTime.now().add(const Duration(seconds: 7)));
      expect(fileStamp(p('a.bin')), isNot(before));
    });

    test('differs when only the modification time changes', () {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
      final before = fileStamp(p('a.bin'));
      File(p('a.bin'))
          .setLastModifiedSync(DateTime.now().add(const Duration(seconds: 11)));
      expect(fileStamp(p('a.bin')), isNot(before));
    });

    test('is null for a missing file', () {
      expect(fileStamp(p('nope')), isNull);
    });

    test('is null, not a throw, on an error from the platform call', () {
      File(p('a.bin')).writeAsBytesSync([1]);
      expect(fileStamp(p('a.bin$sep${'child'}')), isNull);
      expect(fileStamp(p('bad\u0000name')), isNull);
    });
  });

  group('lstatSymbolFor', () {
    test(r'macOS x86-64 reads the 64-bit-inode lstat; the other Apple ABIs and Linux the plain one', () {
      expect(lstatSymbolFor(Abi.macosX64), r'lstat$INODE64');
      for (final abi in [
        Abi.macosArm64,
        Abi.iosArm64,
        Abi.iosX64,
        Abi.linuxX64,
        Abi.linuxArm64,
        Abi.linuxRiscv64,
        Abi.androidX64,
        Abi.androidArm64,
      ]) {
        expect(lstatSymbolFor(abi), 'lstat', reason: '$abi');
      }
    });

    test(
      'an ABI the stat layouts do not cover has no symbol (a null stamp)',
      () {
        expect(lstatSymbolFor(Abi.linuxArm), isNull);
        expect(lstatSymbolFor(Abi.linuxIA32), isNull);
        expect(lstatSymbolFor(Abi.windowsX64), isNull);
      },
    );
  });

  group('ContentIdentity.ofFileSync', () {
    test('equals ofFile, for small, empty and multi-chunk files', () async {
      for (final size in [0, 1, 65536, 65537, 200000]) {
        final f = File(p('f$size'))
          ..writeAsBytesSync(List.generate(size, (i) => i % 251));
        expect(
          ContentIdentity.ofFileSync(f.path),
          await ContentIdentity.ofFile(f.path),
          reason: '$size',
        );
        expect(
          ContentIdentity.ofFileSync(f.path),
          ContentIdentity.ofBytes(f.readAsBytesSync()),
        );
      }
    });

    test('throws for a missing file', () {
      expect(
        () => ContentIdentity.ofFileSync(p('nope')),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('PageStore.scan(stamps:)', () {
    test('stamps readable files only, and not without the flag', () async {
      final store = PageStore(dir);
      await store.save(page('p1'));
      File(p('broken.canvas')).writeAsStringSync('{oops');
      final entries = await PageStore(dir).scan(stamps: true);
      final readable = entries.whereType<ReadablePage>().single;
      expect(readable.stamp, isNotNull);
      expect(readable.stamp, fileStamp(readable.path));
      expect(entries.whereType<UnreadablePage>().single, isA<UnreadablePage>());
      expect(
        (await PageStore(dir).scan()).whereType<ReadablePage>().single.stamp,
        isNull,
      );
    });

    test('gives no stamp to a file that changed during its read', () async {
      await PageStore(dir).save(page('p1'));
      final entries = await PageStore(dir).scan(
        stamps: true,
        afterFileRead: (path) =>
            File(path).writeAsStringSync(' ', mode: FileMode.append),
      );
      expect(entries.whereType<ReadablePage>().single.stamp, isNull);
    });

    test(
      'a page file that is a link gets no stamp (the read follows it)',
      () async {
        if (Platform.isWindows) return; // links need privileges there
        final real = File(p('real.txt'))
          ..writeAsStringSync(writePage(page('p1')));
        Link(p('p1.canvas')).createSync(real.path);
        final entries = await PageStore(dir).scan(stamps: true);
        expect(entries.whereType<ReadablePage>().single.stamp, isNull);
      },
    );

    test('a conflict copy is not stamped as a page', () async {
      final text = writePage(page('p1'));
      File(p('p1.canvas')).writeAsStringSync(text);
      File(p('p1-DESKTOP-4QK2N8L.canvas')).writeAsStringSync(text);
      final entries = await PageStore(dir).scan(stamps: true);
      expect(entries.whereType<ConflictCopyPage>(), hasLength(1));
      expect(entries.whereType<ReadablePage>().single.stamp, isNotNull);
    });
  });

  group('onPublishStamp', () {
    test('saveNew reports the stamp of the published file', () async {
      final store = PageStore(dir);
      final stamps = <FileStamp?>[];
      expect(
        await store.saveNew(page('p1'), onPublishStamp: stamps.add),
        isTrue,
      );
      expect(stamps, hasLength(1));
      expect(stamps.single, isNotNull);
      expect(stamps.single, fileStamp(store.pathFor('p1')));
    });

    test('saveNewText reports it too', () async {
      final store = PageStore(dir);
      final stamps = <FileStamp?>[];
      final pg = page('p1', title: 'T');
      expect(
        await store.saveNewText(pg, writePage(pg), onPublishStamp: stamps.add),
        isTrue,
      );
      expect(stamps.single, fileStamp(store.pathFor('p1')));
    });

    test('is not called when the publish did not land', () async {
      final store = PageStore(dir);
      await store.saveNew(page('p1'));
      final before = File(store.pathFor('p1')).readAsBytesSync();
      var calls = 0;
      expect(
        await store.saveNew(
          page('p1', title: 'Other'),
          onPublishStamp: (_) => calls++,
        ),
        isFalse,
      );
      expect(calls, 0);
      expect(File(store.pathFor('p1')).readAsBytesSync(), before);
    });

    test(
      'saveIfUnchanged reports the stamp of the file it published',
      () async {
        final store = PageStore(dir);
        final first = page('p1');
        await store.save(first);
        final expected = File(store.pathFor('p1')).readAsStringSync();
        final stamps = <FileStamp?>[];
        final r = await store.saveIfUnchanged(
          page('p1', title: 'New'),
          expected,
          onPublishStamp: stamps.add,
        );
        expect(r.replaced, isTrue);
        expect(stamps, hasLength(1));
        expect(stamps.single, isNotNull);
        expect(stamps.single, fileStamp(store.pathFor('p1')));
      },
    );

    test('saveIfUnchanged does not call it when the file changed', () async {
      final store = PageStore(dir);
      await store.save(page('p1'));
      var calls = 0;
      final r = await store.saveIfUnchanged(
        page('p1', title: 'New'),
        'not what is there',
        onPublishStamp: (_) => calls++,
      );
      expect(r.replaced, isFalse);
      expect(calls, 0);
    });

    test(
      'a stamp from a publish equals the one a scan takes of the file',
      () async {
        final store = PageStore(dir);
        FileStamp? published;
        await store.saveNew(page('p1'), onPublishStamp: (s) => published = s);
        final scanned = (await PageStore(dir).scan(stamps: true))
            .whereType<ReadablePage>()
            .single;
        expect(scanned.stamp, published);
      },
    );
  });
}
