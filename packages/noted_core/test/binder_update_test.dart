// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// BinderStore.update, create and sweepLeftovers (R-2): a change is reapplied
// to the file as it is on disk, compared and replaced through the 0131
// primitives, and nothing is deleted without comparing.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

class _CountingStore extends BinderStore {
  _CountingStore(super.directory, {super.tries});

  int temps = 0;

  @override
  File newTempFile() {
    temps++;
    return super.newTempFile();
  }
}

void main() {
  late Directory dir;
  late BinderStore store;
  late Binder original;

  File binderFile() => File('${dir.path}/$binderFileName');
  String text() => binderFile().readAsStringSync();
  List<String> names() =>
      [for (final e in dir.listSync()) e.path.split(RegExp(r'[\\/]')).last]
        ..sort();
  List<String> tmps() => names().where((n) => n.endsWith('.tmp')).toList();

  BinderDelta title(String t, {String? id, List<BinderTemp>? temps}) =>
      BinderDelta(
        binderId: id ?? original.id,
        kind: BinderDeltaKind.cover,
        apply: (b) => b.withTitle(t),
        temps: temps,
      );

  BinderDelta ai(AiAccess? base, AiAccess? request) => BinderDelta(
    binderId: original.id,
    kind: BinderDeltaKind.setting,
    apply: (b) => b.withAiAccess(request),
    field: BinderAiField(base: base, request: request),
  );

  // What another device does: replaces the file with a different one.
  void other({String owner = 'Them', String? aiValue}) {
    var b = Binder.parse(text()).withOwner(owner);
    if (aiValue != null) b = b.withAiAccess(AiAccess.parse(aiValue));
    binderFile().writeAsStringSync(
      b.write().replaceFirst('{', '{"x-future":{"k":1},'),
    );
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('noted_binder_update');
    store = BinderStore(dir, retryDelay: Duration.zero);
    original = Binder.create(
      id: 'aa11',
      title: 'Work',
      color: binderPalette.first,
    );
    expect(await store.create(original), BinderCreated.created);
  });
  tearDown(() async => dir.delete(recursive: true));

  test('1. an unseen replacement survives', () async {
    other();
    final r = await store.update(title('New'));
    expect(r, isA<BinderUpdated>());
    expect(text(), contains('"x-future":{"k":1}'));
    expect(text(), contains('"owner":"Them"'));
    expect(text(), contains('"title":"New"'));
    expect(tmps(), isEmpty);
  });

  group('2. a file that changes during the replace', () {
    test(
      'a replacement at beforeMoveAside: retried, both changes kept',
      () async {
        var once = true;
        final r = await store.update(
          title('New'),
          beforeMoveAside: () {
            if (!once) return;
            once = false;
            other();
          },
        );
        expect(r, isA<BinderUpdated>());
        expect(text(), contains('"owner":"Them"'));
        expect(text(), contains('"title":"New"'));
        expect(names().where((n) => n.contains('.cas-')), isEmpty);
      },
    );

    test('a file at beforePublish: supersededKept, then the change lands on it', () async {
      var once = true;
      final r = await store.update(
        title('New'),
        beforePublish: () {
          if (!once) return;
          once = false;
          // The binder file is set aside now; another device publishes its own.
          binderFile().writeAsStringSync(
            original
                .withOwner('Them')
                .write()
                .replaceFirst('{', '{"x-future":{"k":1},'),
          );
        },
      );
      expect(r, isA<BinderUpdated>());
      expect(text(), contains('"owner":"Them"'));
      expect(text(), contains('"title":"New"'));
      // The set-aside version is kept as a conflict copy and listed.
      expect((r as BinderUpdated).kept, hasLength(1));
      expect(File(r.kept.single).existsSync(), isTrue);
      expect(File(r.kept.single).readAsStringSync(), original.write());
    });

    test('five changes in a row: keepsChanging', () async {
      var n = 0;
      final r = await store.update(
        title('New'),
        beforeMoveAside: () => other(owner: 'Them ${n++}'),
      );
      expect(r, isA<BinderRefused>());
      expect((r as BinderRefused).kind, BinderRefusal.keepsChanging);
      expect(n, 5);
      expect(text(), contains('"owner":"Them 4"'));
      expect(text(), isNot(contains('"title":"New"')));
    });
  });

  group('3. what is refused is left byte for byte', () {
    Future<void> refused(List<int> bytes, BinderRefusal kind) async {
      binderFile().writeAsBytesSync(bytes);
      final d = title('New');
      final r = await store.update(d);
      expect(r, isA<BinderRefused>());
      expect((r as BinderRefused).kind, kind);
      expect(binderFile().readAsBytesSync(), bytes);
      expect(names(), [binderFileName]);
      expect(d.temps, isEmpty);
    }

    test(
      'newer format',
      () => refused(
        utf8.encode('{"format":2,"binderId":"aa11"}'),
        BinderRefusal.unreadable,
      ),
    );
    test(
      'invalid JSON',
      () => refused(utf8.encode('{oops'), BinderRefusal.unreadable),
    );
    test('invalid UTF-8', () async {
      final bytes = [...utf8.encode(original.write()), 0xC3, 0x28];
      await refused(bytes, BinderRefusal.unreadable);
    });
    test(
      'no id',
      () => refused(
        utf8.encode('{"format":1,"title":"x"}'),
        BinderRefusal.unreadable,
      ),
    );
    test('another binder', () async {
      await refused(
        utf8.encode(
          Binder.create(
            id: 'bb22',
            title: 'Other',
            color: binderPalette.first,
          ).write(),
        ),
        BinderRefusal.otherBinder,
      );
    });
  });

  test('4. the file deleted at beforeMoveAside: gone, the temp kept', () async {
    final d = title('New');
    final r = await store.update(d, beforeMoveAside: binderFile().deleteSync);
    expect((r as BinderRefused).kind, BinderRefusal.gone);
    expect(tmps(), hasLength(1));
    expect(d.temps.single.path, endsWith(tmps().single));
    expect(binderFile().existsSync(), isFalse);
  });

  group('5. temps are removed only against the same binder file', () {
    // A first try that finds the file changed leaves its temp; the second
    // lands. The first try's temp is what T removes.
    Future<BinderDelta> landedWithTemp() async {
      var once = true;
      final d = title('New');
      await store.update(
        d,
        beforeMoveAside: () {
          if (!once) return;
          once = false;
          other();
        },
      );
      expect(tmps(), hasLength(1));
      expect(d.temps, hasLength(1));
      return d;
    }

    test('removed while the same binder is present', () async {
      final d = await landedWithTemp();
      expect(await store.removeTemps(d), isEmpty);
      expect(tmps(), isEmpty);
      expect(d.temps, isEmpty);
    });

    test('the file deleted before g: the temp is kept', () async {
      final d = await landedWithTemp();
      binderFile().deleteSync();
      expect(await store.removeTemps(d), hasLength(1));
      expect(tmps(), hasLength(1));
      expect(d.temps, hasLength(1));
    });

    test('another binder file: the temp is kept', () async {
      final d = await landedWithTemp();
      binderFile().writeAsStringSync(
        Binder.create(
          id: 'bb22',
          title: 'Other',
          color: binderPalette.first,
        ).write(),
      );
      expect(await store.removeTemps(d), hasLength(1));
      expect(tmps(), hasLength(1));
    });

    test(
      'a temp replaced before its delete: the replacement is kept',
      () async {
        final d = await landedWithTemp();
        File(d.temps.single.path).writeAsStringSync('someone else wrote this');
        expect(await store.removeTemps(d), hasLength(1));
        expect(
          File(d.temps.single.path).readAsStringSync(),
          'someone else wrote this',
        );
      },
    );

    test('a null binder id compares with the id given at delete time, else the temp id', () async {
      final d = await landedWithTemp();
      d.binderId = null;
      binderFile().writeAsStringSync(
        Binder.create(
          id: 'bb22',
          title: 'Other',
          color: binderPalette.first,
        ).write(),
      );
      expect(await store.removeTemps(d, currentId: () => 'bb22'), isEmpty);
      expect(tmps(), isEmpty);
    });
  });

  test(
    '5b. try 1 changed, then damaged or foreign: try 1\'s temp is kept',
    () async {
      for (final replacement in [
        '{oops',
        Binder.create(
          id: 'bb22',
          title: 'Other',
          color: binderPalette.first,
        ).write(),
      ]) {
        var once = true;
        final d = title('New');
        final r = await store.update(
          d,
          beforeMoveAside: () {
            if (!once) return;
            once = false;
            binderFile().writeAsStringSync(replacement);
          },
        );
        expect(r, isA<BinderRefused>());
        expect(d.temps, hasLength(1));
        expect(File(d.temps.single.path).existsSync(), isTrue);
        expect(binderFile().readAsStringSync(), replacement);
        for (final f in dir.listSync().whereType<File>().where(
          (f) => f.path.endsWith('.tmp'),
        )) {
          f.deleteSync();
        }
        binderFile().writeAsStringSync(original.write());
      }
    },
  );

  group('6. leftovers', () {
    String aside(String target, String suffix) =>
        '${dir.path}/$target.4242-ab12-cd34$suffix';

    test('a foreign-pid .cas-old with no file is restored', () async {
      final bytes = original.write();
      File(aside(binderFileName, asideSuffix)).writeAsStringSync(bytes);
      binderFile().deleteSync();
      final before = await store.sweepLeftovers(restore: false);
      expect(before.hasBinderAside, isTrue);
      expect(binderFile().existsSync(), isFalse);
      final s = await store.sweepLeftovers(restore: true);
      expect(s.restored, hasLength(1));
      expect(text(), bytes);
      expect(names(), [binderFileName]);
    });

    test('.cas-verified with the file present becomes a conflict copy; nothing is deleted', () async {
      final older = original.withTitle('Older').write();
      File(aside(binderFileName, verifiedSuffix)).writeAsStringSync(older);
      final s = await store.sweepLeftovers(restore: true);
      expect(text(), original.write());
      final conflict = names().where((n) => n.contains('-conflict-')).toList();
      expect(conflict, hasLength(1));
      expect(File('${dir.path}/${conflict.single}').readAsStringSync(), older);
      expect(s.copies.map((c) => c.name), contains(conflict.single));
    });

    test('a temp aside goes back; the sweep removes no name', () async {
      final temp = '${dir.path}/$binderFileName.1-2.tmp';
      File(aside('$binderFileName.1-2.tmp', asideSuffix))
          .writeAsStringSync('half');
      File('${dir.path}/noted-binder.json.tmp').writeAsStringSync('legacy');
      File('${dir.path}/$binderFileName.9-9.tmp').writeAsStringSync('old temp');
      File('${dir.path}/other.txt').writeAsStringSync('x');
      final before = names();
      final s = await store.sweepLeftovers(restore: true);
      expect(File(temp).readAsStringSync(), 'half');
      expect(
        s.copies.map((c) => c.name),
        containsAll([
          'noted-binder.json.tmp',
          '$binderFileName.9-9.tmp',
          '$binderFileName.1-2.tmp',
        ]),
      );
      expect(s.hasBinderAside, isFalse);
      // Every name still there, except the aside that moved back.
      expect(names().length, before.length);
      expect(names(), isNot(contains('other.txt.removed')));
    });

    test('only the binder file\'s own asides count as one', () {
      expect(
        isBinderFileAsideName('noted-binder.json.4242-ab12-cd34.cas-old'),
        isTrue,
      );
      expect(
        isBinderFileAsideName('noted-binder.json.4242-ab12-cd34.cas-verified'),
        isTrue,
      );
      expect(
        isBinderFileAsideName(
          'noted-binder.json.1-2.tmp.4242-ab12-cd34.cas-old',
        ),
        isFalse,
      );
      expect(
        isBinderFileAsideName(
          'noted-binder-conflict-ab12.json.4242-ab12-cd34.cas-old',
        ),
        isFalse,
      );
      expect(isBinderFileAsideName('noted-binder.json'), isFalse);
      expect(isBinderFileAsideName('noted-binder.json.tmp'), isFalse);
    });

    test('a missing file with an aside is inUse, not gone', () async {
      File(aside(binderFileName, asideSuffix))
          .writeAsStringSync(original.write());
      binderFile().deleteSync();
      final r = await store.update(title('New'));
      expect((r as BinderRefused).kind, BinderRefusal.inUse);
    });
  });

  group('7. create', () {
    test('a race: the file appears before the publish -> exists', () async {
      binderFile().deleteSync();
      final mine = Binder.create(
        id: 'cc33',
        title: 'Mine',
        color: binderPalette.first,
      );
      final theirs = Binder.create(
        id: 'dd44',
        title: 'Theirs',
        color: binderPalette.first,
      );
      final r = await store.create(
        mine,
        beforePublish: () => binderFile().writeAsStringSync(theirs.write()),
      );
      expect(r, BinderCreated.exists);
      expect(text(), theirs.write());
      expect(names(), [binderFileName]);
    });

    test(
      '7b. the file holds another binder: create\'s own temp is deleted',
      () async {
        final r = await store.create(
          Binder.create(id: 'cc33', title: 'Mine', color: binderPalette.first),
        );
        expect(r, BinderCreated.exists);
        expect(text(), original.write());
        expect(names(), [binderFileName]);
      },
    );
  });

  group('8. the stricter value on disk is kept', () {
    test('AI access: base Open, Guarded on disk at beforeMoveAside, Privileged requested', () async {
      binderFile().writeAsStringSync(
        original.withAiAccess(AiAccess.open).write(),
      );
      var once = true;
      final r = await store.update(
        ai(AiAccess.open, AiAccess.privileged),
        beforeMoveAside: () {
          if (!once) return;
          once = false;
          binderFile().writeAsStringSync(
            original.withAiAccess(AiAccess.guarded).write(),
          );
        },
      );
      expect(r, isA<BinderUpdated>());
      expect(Binder.parse(text()).aiAccess, AiAccess.guarded);
    });

    test(
      'AI access: a looser value on disk is replaced by the request',
      () async {
        binderFile().writeAsStringSync(
          original.withAiAccess(AiAccess.guarded).write(),
        );
        await store.update(ai(AiAccess.guarded, AiAccess.open));
        expect(Binder.parse(text()).aiAccess, AiAccess.open);
      },
    );

    test('AI access: null on disk is Guarded', () async {
      final r = await store.update(ai(AiAccess.open, AiAccess.privileged));
      expect(Binder.parse(text()).aiAccess, isNull);
      expect((r as BinderUpdated).wrote, isFalse);
    });

    test(
      'a box type: false on disk is kept against a request of true',
      () async {
        final d = BinderDelta(
          binderId: original.id,
          kind: BinderDeltaKind.setting,
          apply: (b) => b.withBoxType('drawing', true),
          field: const BinderBoxTypeField('drawing', base: true, request: true),
        );
        binderFile().writeAsStringSync(
          original.withBoxType('drawing', false).write(),
        );
        await store.update(d);
        expect(Binder.parse(text()).boxTypeChoice('drawing'), isFalse);
      },
    );

    test('a box type: no stricter value, the request is written', () async {
      final d = BinderDelta(
        binderId: original.id,
        kind: BinderDeltaKind.setting,
        apply: (b) => b.withBoxType('drawing', false),
        field: const BinderBoxTypeField('drawing', base: null, request: false),
      );
      await store.update(d);
      expect(Binder.parse(text()).boxTypeChoice('drawing'), isFalse);
    });
  });

  group('8b. read-only and reused temps', () {
    test('a read-only file is refused with no temp written', () async {
      if (Platform.isWindows) {
        Process.runSync('attrib', ['+R', binderFile().path]);
      } else {
        Process.runSync('chmod', ['444', binderFile().path]);
      }
      addTearDown(() {
        if (Platform.isWindows) {
          Process.runSync('attrib', ['-R', binderFile().path]);
        } else {
          Process.runSync('chmod', ['644', binderFile().path]);
        }
      });
      final d = title('New');
      final r = await store.update(d);
      expect((r as BinderRefused).kind, BinderRefusal.readOnly);
      expect(tmps(), isEmpty);
      expect(d.temps, isEmpty);
    });

    test('a retry with equal bytes reuses the temp', () async {
      final counting = _CountingStore(dir, tries: 1);
      final d = title('New');
      final r1 = await counting.update(
        d,
        beforePublish: () =>
            throw FileSystemException('busy', binderFile().path),
      );
      expect((r1 as BinderRefused).kind, BinderRefusal.inUse);
      expect(counting.temps, 1);
      expect(d.temps, hasLength(1));
      final r2 = await counting.update(d);
      expect(r2, isA<BinderUpdated>());
      expect(counting.temps, 1);
      expect(d.temps, isEmpty);
      expect(tmps(), isEmpty);
      expect(text(), contains('"title":"New"'));
    });

    test('a temp write that throws: a complete temp is kept for reuse, a partial one deleted', () async {
      final failing = _FailingWrite(dir, partial: false);
      final d = title('New');
      final r = await failing.update(d);
      expect((r as BinderRefused).kind, BinderRefusal.cantWrite);
      expect(d.temps, hasLength(1));
      expect(tmps(), hasLength(1));

      final dir2 = await Directory.systemTemp.createTemp(
        'noted_binder_update2',
      );
      addTearDown(() => dir2.delete(recursive: true));
      final s2 = BinderStore(dir2);
      await s2.create(original);
      final partial = _FailingWrite(dir2, partial: true);
      final d2 = title('New');
      final r2 = await partial.update(d2);
      expect((r2 as BinderRefused).kind, BinderRefusal.cantWrite);
      expect(d2.temps, isEmpty);
      expect(dir2.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
    });
  });


    test('a temp replaced by someone else after the failed write is kept, not deleted', () async {
      final unrelated = Binder.create(id: 'zz99', title: 'Unrelated', color: binderPalette.first).write();
      final store2 = _ReplacingWrite(dir, unrelated);
      final d = title('New');
      final r = await store2.update(d);
      expect((r as BinderRefused).kind, BinderRefusal.cantWrite);
      expect(r.kept, hasLength(1));
      expect(File(r.kept.single).readAsStringSync(), unrelated);
      expect(d.temps, isEmpty);
    });


  test('a change that alters nothing writes nothing', () async {
    final r = await store.update(title('Work'));
    expect((r as BinderUpdated).wrote, isFalse);
    expect(names(), [binderFileName]);
  });
}

class _FailingWrite extends BinderStore {
  _FailingWrite(super.directory, {required this.partial});

  final bool partial;

  @override
  Future<void> writeTemp(File temp, List<int> bytes) async {
    await temp.writeAsBytes(
      partial ? bytes.sublist(0, bytes.length ~/ 2) : bytes,
      flush: true,
    );
    throw FileSystemException('disk full', temp.path);
  }
}

class _ReplacingWrite extends BinderStore {
  _ReplacingWrite(super.directory, this.replacement);

  final String replacement;

  // Writes part of the file, then another writer replaces it, then the write fails.
  @override
  Future<void> writeTemp(File temp, List<int> bytes) async {
    await temp.writeAsBytes(bytes.sublist(0, bytes.length ~/ 2), flush: true);
    await temp.writeAsString(replacement, flush: true);
    throw FileSystemException('disk full', temp.path);
  }
}
