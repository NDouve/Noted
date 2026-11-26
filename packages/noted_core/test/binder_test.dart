// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/src/storage/dataless.dart' show debugDatalessAbi, debugDatalessPaths, debugMarkDataless, debugResetDataless;

void main() {
  late Directory dir;
  late BinderStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('noted_binder');
    store = BinderStore(dir);
  });
  tearDown(() async => dir.delete(recursive: true));

  test('creates, reads and edits a binder file', () async {
    expect(await store.read(), isA<BinderMissing>());
    final made = Binder.create(
      title: 'Work',
      color: binderPalette[1],
      created: DateTime.utc(2026, 1, 2),
    );
    expect(await store.create(made), BinderCreated.created);
    expect(made.id, hasLength(16));
    final read = (await store.read() as BinderFound).binder;
    expect(read.title, 'Work');
    expect(read.owner, '');
    expect(read.color, binderPalette[1]);
    expect(read.created, DateTime.utc(2026, 1, 2).millisecondsSinceEpoch);

    final r = await store.update(
      BinderDelta(
        binderId: read.id,
        kind: BinderDeltaKind.cover,
        apply: (b) => b.withTitle('Home').withOwner('me').withDescription('d'),
      ),
    );
    expect(r, isA<BinderUpdated>());
    final again = (await store.read() as BinderFound).binder;
    expect([again.title, again.owner, again.description], ['Home', 'me', 'd']);
    expect(again.id, read.id);
    expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
  });

  test('unknown fields round-trip byte for byte', () async {
    File('${dir.path}/$binderFileName').writeAsStringSync(
      '{"format":1,"binderId":"abc","x-future":{"a": [1, 2,  3],"b":"\\u00e9"},'
      '"title":"T","description":"","owner":"","color":"#FF3F51B5","created":5,"z":1.50}',
    );
    await store.update(
      BinderDelta(binderId: 'abc', kind: BinderDeltaKind.cover, apply: (x) => x.withTitle('New')),
    );
    final text = File('${dir.path}/$binderFileName').readAsStringSync();
    expect(text, contains('"x-future":{"a": [1, 2,  3],"b":"\\u00e9"}'));
    expect(text, contains('"z":1.50'));
    expect(text, contains('"title":"New"'));
    expect(text.indexOf('x-future'), lessThan(text.indexOf('"title"')));
  });

  test('a newer format is refused and left untouched', () async {
    final f = File('${dir.path}/$binderFileName')
      ..writeAsStringSync('{"format":2,"binderId":"abc","title":"T"}');
    final r = await store.read();
    expect(r, isA<BinderUnreadable>());
    expect((r as BinderUnreadable).reason, contains('newer'));
    expect(
      () => Binder.parse(f.readAsStringSync()),
      throwsA(isA<UnsupportedBinderFormatException>()),
    );
    expect(f.readAsStringSync(), '{"format":2,"binderId":"abc","title":"T"}');
  });

  test('unreadable files are reported, never overwritten', () async {
    final f = File('${dir.path}/$binderFileName')..writeAsStringSync('{oops');
    expect(await store.read(), isA<BinderUnreadable>());
    f.writeAsStringSync('{"format":1}');
    expect(await store.read(), isA<BinderUnreadable>());
    expect(
      await store.create(Binder.create(title: 'x', color: binderPalette.first)),
      BinderCreated.exists,
    );
    expect(f.readAsStringSync(), '{"format":1}');
  });

  group('files that are not downloaded', () {
    tearDown(() {
      debugDatalessAbi = null;
      debugResetDataless();
      debugDatalessPaths = null;
    });

    test('a stub-only binder file is present: unreadable while downloading, never missing, never created over', () async {
      File('${dir.path}/.noted-binder.json.icloud').writeAsStringSync('');
      final r = await store.read();
      expect(r, isA<BinderUnreadable>());
      expect((r as BinderUnreadable).reason, stillDownloading);
      expect(await store.create(Binder.create(title: 'x', color: binderPalette.first)), BinderCreated.exists);
      expect(dir.listSync().length, 1);
    });

    test('a binder file whose stub stands alone is still downloading, never gone', () async {
      final made = Binder.create(title: 'x', color: binderPalette.first);
      await store.create(made);
      File('${dir.path}/noted-binder.json').renameSync('${dir.path}/.noted-binder.json.icloud');
      final r = await store.update(
        BinderDelta(binderId: made.id, kind: BinderDeltaKind.cover, apply: (x) => x.withTitle('New')),
      );
      expect(r, isA<BinderRefused>());
      expect((r as BinderRefused).kind, BinderRefusal.inUse);
      expect(r.reason, contains('still downloading'));
    });

    test('a present dataless binder file (the seam) is unreadable while downloading, and an update is busy', () async {
      final made = Binder.create(title: 'x', color: binderPalette.first);
      await store.create(made);
      debugMarkDataless(store.file.path);
      final r = await store.read();
      expect((r as BinderUnreadable).reason, stillDownloading);
      expect(store.fileHoldsBinderSync(made.id), isFalse);
      final u = await store.update(
        BinderDelta(binderId: made.id, kind: BinderDeltaKind.cover, apply: (x) => x.withTitle('New')),
      );
      expect((u as BinderRefused).kind, BinderRefusal.inUse);
      expect(u.reason, contains('still downloading'));
    });

    test('a binder file that is not UTF-8 is unreadable, not a crash', () async {
      store.file.writeAsBytesSync([0x7b, 0xff, 0xfe, 0x7d]);
      expect(await store.read(), isA<BinderUnreadable>());
    });

    test('a dataless binder file is not read', () async {
      await store.create(Binder.create(title: 'x', color: binderPalette.first));
      debugDatalessAbi = Abi.macosX64; // no lstat$INODE64 off Apple: every existing file fails closed
      debugResetDataless();
      expect(await store.read(), isA<BinderUnreadable>());
      expect(store.fileHoldsBinderSync('anything'), isFalse);
    }, skip: (Platform.isMacOS || Platform.isIOS) ? 'a real lstat exists: nothing fails closed' : null);
  });
}
