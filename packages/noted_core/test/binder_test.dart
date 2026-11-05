// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

import 'support/cached_save_binder_store.dart';

void main() {
  late Directory dir;
  late BinderStore store;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('noted_binder');
    store = BinderStore(dir, retryDelay: Duration.zero);
    file = File('${dir.path}/$binderFileName');
  });
  tearDown(() async {
    for (final f in dir.listSync()) {
      if (f is File) _readOnly(f.path, on: false);
    }
    await dir.delete(recursive: true);
  });

  Future<Binder> made({String title = 'Work', String? id}) async {
    final b = Binder.create(
      id: id,
      title: title,
      color: binderPalette[1],
      created: DateTime.utc(2026, 1, 2),
    );
    expect(await store.create(b), BinderCreated.created);
    return b;
  }

  List<String> leftovers() => dir
      .listSync()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n != binderFileName)
      .toList();

  test('creates, reads and edits a binder file', () async {
    expect(await store.read(), isA<BinderMissing>());
    final b = await made();
    expect(b.id, hasLength(16));
    final read = (await store.read() as BinderFound).binder;
    expect(read.title, 'Work');
    expect(read.owner, '');
    expect(read.color, binderPalette[1]);
    expect(read.created, DateTime.utc(2026, 1, 2).millisecondsSinceEpoch);

    final r = await store.update(
      (d) => d.withTitle('Home').withOwner('me').withDescription('d'),
      binderId: read.id,
    );
    expect(r, isA<BinderUpdated>());
    final again = (await store.read() as BinderFound).binder;
    expect([again.title, again.owner, again.description], ['Home', 'me', 'd']);
    expect(again.id, read.id);
    expect(leftovers(), isEmpty);
  });

  test('unknown fields round-trip byte for byte', () async {
    file.writeAsStringSync(
      '{"format":1,"binderId":"abc","x-future":{"a": [1, 2,  3],"b":"\\u00e9"},'
      '"title":"T","description":"","owner":"","color":"#FF3F51B5","created":5,"z":1.50}',
    );
    await store.update((d) => d.withTitle('New'), binderId: 'abc');
    final text = file.readAsStringSync();
    expect(text, contains('"x-future":{"a": [1, 2,  3],"b":"\\u00e9"}'));
    expect(text, contains('"z":1.50'));
    expect(text, contains('"title":"New"'));
    expect(text.indexOf('x-future'), lessThan(text.indexOf('"title"')));
  });

  test('a change that alters nothing writes nothing', () async {
    final b = await made();
    final before = file.lastModifiedSync();
    final r = await store.update((d) => d.withTitle('Work'), binderId: b.id);
    expect((r as BinderUpdated).wrote, isFalse);
    expect(file.lastModifiedSync(), before);
    expect(leftovers(), isEmpty);
  });

  group('1. an unseen replacement', () {
    const other =
        '{"format":1,"binderId":"abc","title":"Theirs","description":"","owner":"o",'
        '"color":"#FF2563EB","x-future":{"k": 1}}';

    test('both its fields and the change survive', () async {
      file.writeAsStringSync('{"format":1,"binderId":"abc","title":"Mine"}');
      expect(await store.read(), isA<BinderFound>()); // the cache a caller holds
      file.writeAsStringSync(other);
      final r = await store.update((d) => d.withDescription('mine'), binderId: 'abc');
      expect(r, isA<BinderUpdated>());
      final text = file.readAsStringSync();
      expect(text, contains('"title":"Theirs"'));
      expect(text, contains('"owner":"o"'));
      expect(text, contains('"x-future":{"k": 1}'));
      expect(text, contains('"description":"mine"'));
    });

    test('the cached save loses them (what R-2 was)', () async {
      file.writeAsStringSync('{"format":1,"binderId":"abc","title":"Mine"}');
      final cached = CachedSaveBinderStore(dir, {});
      expect(await cached.read(), isA<BinderFound>());
      file.writeAsStringSync(other);
      await cached.update((d) => d.withDescription('mine'), binderId: 'abc');
      final text = file.readAsStringSync();
      expect(text, isNot(contains('x-future')));
      expect(text, isNot(contains('Theirs')));
    });
  });

  group('2. a replacement during the write', () {
    test('before the compare: reapplied, both changes kept', () async {
      file.writeAsStringSync('{"format":1,"binderId":"abc","title":"T"}');
      var n = 0;
      final r = await store.update(
        (d) => d.withDescription('mine'),
        binderId: 'abc',
        beforeCompare: () {
          if (n++ == 0) {
            file.writeAsStringSync('{"format":1,"binderId":"abc","title":"T","owner":"them"}');
          }
        },
      );
      expect(r, isA<BinderUpdated>());
      expect(n, 2);
      final text = file.readAsStringSync();
      expect(text, contains('"owner":"them"'));
      expect(text, contains('"description":"mine"'));
      expect(leftovers(), isEmpty);
    });

    test('inside the window: overwritten (the accepted window)', () async {
      file.writeAsStringSync('{"format":1,"binderId":"abc","title":"T"}');
      var n = 0;
      await store.update(
        (d) => d.withDescription('mine'),
        binderId: 'abc',
        beforeRename: () {
          if (n++ == 0) {
            file.writeAsStringSync('{"format":1,"binderId":"abc","title":"T","owner":"them"}');
          }
        },
      );
      expect(file.readAsStringSync(), isNot(contains('them')));
      expect(file.readAsStringSync(), contains('"description":"mine"'));
    });

    test('five replacements: keepsChanging, the last one kept, no temp', () async {
      file.writeAsStringSync('{"format":1,"binderId":"abc","title":"T"}');
      var n = 0;
      final r = await store.update(
        (d) => d.withDescription('mine'),
        binderId: 'abc',
        beforeCompare: () => file.writeAsStringSync(
          '{"format":1,"binderId":"abc","title":"T","owner":"v${n++}"}',
        ),
      );
      expect(r, isA<BinderRefused>());
      expect((r as BinderRefused).kind, BinderRefusal.keepsChanging);
      expect(r.reason, 'The binder file keeps changing');
      expect(n, 5);
      expect(file.readAsStringSync(), contains('"owner":"v4"'));
      expect(leftovers(), isEmpty);
    });
  });

  group('3. a file that must not be written', () {
    Future<void> refused(
      List<int> bytes,
      BinderRefusal kind, {
      String id = 'abc',
    }) async {
      file.writeAsBytesSync(bytes);
      final r = await store.update((d) => d.withTitle('x'), binderId: id);
      expect((r as BinderRefused).kind, kind);
      expect(file.readAsBytesSync(), bytes);
      expect(leftovers(), isEmpty);
    }

    test('a newer format', () => refused(utf8.encode('{"format":2,"binderId":"abc"}'), BinderRefusal.unreadable));
    test('invalid JSON', () => refused(utf8.encode('{oops'), BinderRefusal.unreadable));
    test('invalid UTF-8', () => refused(
      [...utf8.encode('{"format":1,"binderId":"abc","title":"'), 0xff, 0xfe, ...utf8.encode('"}')],
      BinderRefusal.unreadable,
    ));
    test('no binderId', () => refused(utf8.encode('{"format":1}'), BinderRefusal.unreadable));
    test('a different binderId', () => refused(
      utf8.encode('{"format":1,"binderId":"zzz"}'),
      BinderRefusal.otherBinder,
    ));

    test('no file: gone', () async {
      final r = await store.update((d) => d, binderId: 'abc');
      expect((r as BinderRefused).kind, BinderRefusal.gone);
      expect(file.existsSync(), isFalse);
    });

    test('the cached save overwrites a damaged file (what R-2 was)', () async {
      final b = await made(id: 'abc');
      final cached = CachedSaveBinderStore(dir, {});
      expect(await cached.read(), isA<BinderFound>());
      file.writeAsStringSync('{oops');
      await cached.update((d) => d.withTitle('x'), binderId: b.id);
      expect(file.readAsStringSync(), isNot('{oops'));
    });

    test('read: invalid UTF-8 is unreadable, not missing', () async {
      file.writeAsBytesSync([0x7b, 0xff, 0x7d]);
      expect(await store.read(), isA<BinderUnreadable>());
    });
  });

  group('4. crash leftovers', () {
    final old = DateTime.now().subtract(const Duration(hours: 1));

    File temp(String name, String text, {DateTime? at}) {
      final f = File('${dir.path}/$name')..writeAsStringSync(text);
      f.setLastModifiedSync(at ?? old);
      return f;
    }

    const body = '{"format":1,"binderId":"abc","title":"T"}\n';

    test('a stale temp equal to the file is deleted', () async {
      file.writeAsStringSync(body);
      final t = temp('$binderFileName.1-1.tmp', body);
      expect(await sweepBinderTemps(dir), isEmpty);
      expect(t.existsSync(), isFalse);
    });

    test('a temp equal to the file is kept if the file goes away during the sweep', () async {
      file.writeAsStringSync(body);
      final t = temp('$binderFileName.1-8.tmp', body);
      final kept = await sweepBinderTemps(dir, beforeDelete: file.deleteSync);
      expect(t.existsSync(), isTrue, reason: 'it may be the last copy');
      expect(kept.map((k) => File(k.path).uri.pathSegments.last), ['$binderFileName.1-8.tmp']);
      expect(kept.single.complete, isTrue);
    });

    test('a temp is kept if the file changed during the sweep', () async {
      file.writeAsStringSync(body);
      final t = temp('$binderFileName.1-9.tmp', body);
      final kept = await sweepBinderTemps(
        dir,
        beforeDelete: () => file.writeAsStringSync(body.replaceFirst('"T"', '"U"')),
      );
      expect(t.existsSync(), isTrue);
      expect(kept, hasLength(1));
    });

    test('a stale different temp is kept and returned, never promoted', () async {
      file.writeAsStringSync(body);
      final t = temp('$binderFileName.1-2.tmp', body.replaceFirst('"T"', '"U"'));
      final kept = await sweepBinderTemps(dir);
      expect(kept.map((k) => File(k.path).uri.pathSegments.last), ['$binderFileName.1-2.tmp']);
      expect(kept.single.complete, isTrue);
      expect(t.existsSync(), isTrue);
      expect(file.readAsStringSync(), body);
    });

    test('an incomplete temp is not complete', () async {
      file.writeAsStringSync(body);
      temp('$binderFileName.1-3.tmp', '{"format":1,"binder');
      expect((await sweepBinderTemps(dir)).single.complete, isFalse);
    });

    test('a young temp is skipped; the old fixed name is handled', () async {
      file.writeAsStringSync(body);
      final young = temp('$binderFileName.1-4.tmp', 'x', at: DateTime.now());
      final fixed = temp('$binderFileName.tmp', body);
      final waits = <Duration>[];
      expect(await sweepBinderTemps(dir, onYoung: waits.add), isEmpty);
      expect(waits, hasLength(1));
      expect(waits.single, greaterThan(const Duration(minutes: 9)), reason: 'time until it is old enough');
      expect(young.existsSync(), isTrue);
      expect(fixed.existsSync(), isFalse);
    });

    test('other files are not looked at', () async {
      file.writeAsStringSync(body);
      final other = temp('notes.json.1-1.tmp', 'x');
      final aside = temp('other.json.1-1-1$asideSuffix', 'x');
      await sweepBinderTemps(dir);
      expect(other.existsSync(), isTrue);
      expect(aside.existsSync(), isTrue);
    });

    test("a temp's aside is put back, then handled as a temp", () async {
      file.writeAsStringSync(body);
      // Name format of an aside: <target>.<pid>-<r>-<r>.cas-old
      final aside = File('${dir.path}/$binderFileName.1-5.tmp.77-1-1$asideSuffix')
        ..writeAsStringSync(body.replaceFirst('"T"', '"V"'));
      aside.setLastModifiedSync(old);
      final kept = await sweepBinderTemps(dir);
      expect(aside.existsSync(), isFalse);
      expect(kept.map((k) => File(k.path).uri.pathSegments.last), ['$binderFileName.1-5.tmp']);
    });

    test('a complete temp can be put back only when no file is there', () async {
      final t = temp('$binderFileName.1-6.tmp', body);
      final kept = (await sweepBinderTemps(dir)).single;
      file.writeAsStringSync('other');
      expect(await putBackBinderTemp(dir, kept.path, kept.bytes), isFalse);
      expect(file.readAsStringSync(), 'other');
      file.deleteSync();
      expect(await putBackBinderTemp(dir, kept.path, kept.bytes), isTrue);
      expect(file.readAsStringSync(), body);
      expect(t.existsSync(), isFalse);
    });

    test('an update sweeps stale equal temps first', () async {
      file.writeAsStringSync(body);
      final t = temp('$binderFileName.1-7.tmp', body);
      await store.update((d) => d.withTitle('N'), binderId: 'abc');
      expect(t.existsSync(), isFalse);
    });
  });

  group('5. the write', () {
    test('replaces a real existing file', () async {
      final b = await made();
      await store.update((d) => d.withTitle('A'), binderId: b.id);
      await store.update((d) => d.withTitle('B'), binderId: b.id);
      expect((await store.read() as BinderFound).binder.title, 'B');
      expect(leftovers(), isEmpty);
    });

    test('a temp that cannot be written: cantWrite, nothing left', () async {
      final b = await made();
      final failing = _FailingTempStore(dir);
      final r = await failing.update((d) => d.withTitle('A'), binderId: b.id);
      expect((r as BinderRefused).kind, BinderRefusal.cantWrite);
      expect(leftovers(), isEmpty);
      expect((await store.read() as BinderFound).binder.title, 'Work');
    });

    test('a read-only target: readOnly, at once, no temp left', () async {
      final b = await made();
      _readOnly(file.path, on: true);
      var calls = 0;
      final r = await store.update(
        (d) => d.withTitle('A'),
        binderId: b.id,
        beforeCompare: () => calls++,
      );
      expect((r as BinderRefused).kind, BinderRefusal.readOnly);
      expect(r.reason, 'The binder file is read-only');
      expect(calls, 1);
      _readOnly(file.path, on: false);
      expect(leftovers(), isEmpty);
      expect((await store.read() as BinderFound).binder.title, 'Work');
    });

    test('an open handle makes the rename fail and retry; closing it lets it land', () async {
      final b = await made();
      final handle = file.openSync();
      var n = 0;
      final r = await store.update(
        (d) => d.withTitle('A'),
        binderId: b.id,
        beforeCompare: () {
          if (++n == 3) handle.closeSync();
        },
      );
      expect(r, isA<BinderUpdated>());
      expect(n, 3);
      expect(leftovers(), isEmpty);
    }, skip: !Platform.isWindows);

    test('a handle kept open: inUse, no temp left', () async {
      final b = await made();
      final handle = file.openSync();
      try {
        final r = await store.update((d) => d.withTitle('A'), binderId: b.id);
        expect((r as BinderRefused).kind, BinderRefusal.inUse);
        expect(r.reason, startsWith('The binder file is in use by another program'));
        expect(leftovers(), isEmpty);
      } finally {
        handle.closeSync();
      }
      expect((await store.read() as BinderFound).binder.title, 'Work');
    }, skip: !Platform.isWindows);
  });

  group('6. create', () {
    test('an existing file gives exists and stays byte-identical', () async {
      file.writeAsStringSync('{oops');
      final r = await store.create(Binder.create(title: 'x', color: binderPalette.first));
      expect(r, BinderCreated.exists);
      expect(file.readAsStringSync(), '{oops');
      expect(leftovers(), isEmpty);
    });

    test('a file created between the check and the publish is kept', () async {
      final r = await store.create(
        Binder.create(title: 'x', color: binderPalette.first),
        beforePublish: () => file.writeAsStringSync('theirs'),
      );
      expect(r, BinderCreated.exists);
      expect(file.readAsStringSync(), 'theirs');
      expect(leftovers(), isEmpty);
    });
  });
}

class _FailingTempStore extends BinderStore {
  _FailingTempStore(super.directory);

  @override
  File newTempFile() => File('${directory.path}/no-such-folder/x.tmp');
}

void _readOnly(String path, {required bool on}) {
  if (Platform.isWindows) {
    Process.runSync('attrib', [on ? '+R' : '-R', path]);
  } else {
    Process.runSync('chmod', [on ? '444' : '644', path]);
  }
}
