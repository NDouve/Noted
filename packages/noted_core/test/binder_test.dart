// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

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
    final made = await store.create(
      Binder.create(title: 'Work', color: binderPalette[1], created: DateTime.utc(2026, 1, 2)),
    );
    expect(made.id, hasLength(16));
    final read = (await store.read() as BinderFound).binder;
    expect(read.title, 'Work');
    expect(read.owner, '');
    expect(read.color, binderPalette[1]);
    expect(read.created, DateTime.utc(2026, 1, 2).millisecondsSinceEpoch);

    await store.save(read.withTitle('Home').withOwner('me').withDescription('d'));
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
    final b = (await store.read() as BinderFound).binder;
    await store.save(b.withTitle('New'));
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
      () => store.create(Binder.create(title: 'x', color: binderPalette.first)),
      throwsA(isA<FileSystemException>()),
    );
    expect(f.readAsStringSync(), '{"format":1}');
  });
}
