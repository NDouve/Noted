// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

import 'package:noted_core/src/storage/coordination.dart' show folderOf, underCoordination;

import 'support/coordination_support.dart';

void main() {
  final sep = Platform.pathSeparator;
  late Directory rootA, rootB, outside;
  late RecordingCoordinator c;
  late String realA, realB;

  String a(String n) => '${rootA.path}$sep$n';
  String b(String n) => '${rootB.path}$sep$n';
  String o(String n) => '${outside.path}$sep$n';
  CoordinationIntent w(String p) => CoordinationIntent(p, CoordinationKind.write);
  CoordinationIntent m(String p) => CoordinationIntent(p, CoordinationKind.move);
  CoordinationIntent d(String p) => CoordinationIntent(p, CoordinationKind.delete);

  setUp(() async {
    final t = Directory.systemTemp;
    rootA = await t.createTemp('noted_coord_a');
    rootB = await t.createTemp('noted_coord_b');
    outside = await t.createTemp('noted_coord_o');
    c = RecordingCoordinator();
    realA = rootA.resolveSymbolicLinksSync();
    realB = rootB.resolveSymbolicLinksSync();
    registerCoordinator(realA, c);
  });
  tearDown(() async {
    unregisterCoordinator(realA);
    unregisterCoordinator(realB);
    for (final x in [rootA, rootB, outside]) {
      await x.delete(recursive: true);
    }
  });

  List<CoordinationIntent> only() {
    expect(c.calls, hasLength(1), reason: '${c.calls}');
    return c.calls.single.intents;
  }

  group('the hook, once per outermost call', () {
    test('publishExclusive: folder writes, the source as a move', () async {
      final tmp = File(a('t.tmp'))..writeAsStringSync('x');
      expect(await publishExclusive(tmp, a('f.canvas')), isTrue);
      expect(only(), [w(rootA.path), m(tmp.path)]);
    });

    test('publishExclusive from another folder names both folders', () async {
      Directory(a('sub')).createSync();
      final tmp = File(a('sub${sep}t.tmp'))..writeAsStringSync('x');
      await publishExclusive(tmp, a('f.canvas'));
      expect(only(), [w(rootA.path), w('${rootA.path}${sep}sub'), m(tmp.path)]);
    });

    test('replaceIfUnchanged: one call, even when it keeps a conflict copy', () async {
      File(a('f.canvas')).writeAsStringSync('old');
      final tmp = File(a('t.tmp'))..writeAsStringSync('new');
      final r = await replaceIfUnchanged(
        tmp,
        a('f.canvas'),
        'old'.codeUnits,
        beforePublish: () => File(a('f.canvas')).writeAsStringSync('theirs'),
      );
      expect(r.outcome, ReplaceOutcome.supersededKept);
      expect(only(), [w(rootA.path), m(a('f.canvas'))]);
    });

    test('replaceIfUnchanged with no expected bytes is one call too', () async {
      final tmp = File(a('t.tmp'))..writeAsStringSync('new');
      await replaceIfUnchanged(tmp, a('f.canvas'), null);
      expect(only(), [w(rootA.path), m(a('f.canvas'))]);
    });

    test('both deletes: a folder write and a delete of the target', () async {
      File(a('f.bin')).writeAsBytesSync([1]);
      await deleteFileIfUnchanged(a('f.bin'), [1]);
      expect(only(), [w(rootA.path), d(a('f.bin'))]);
      c.calls.clear();
      File(a('g.bin')).writeAsBytesSync([2]);
      await deleteFileIfMatches(a('g.bin'), bytes: [2]);
      expect(only(), [w(rootA.path), d(a('g.bin'))]);
    });

    test('a delete that puts the file back is still one call', () async {
      File(a('f.bin')).writeAsBytesSync([1]);
      var restored = false;
      final r = await deleteFileIfMatches(
        a('f.bin'),
        bytes: [1],
        // The file changes after the first check, so it is moved aside,
        // compared, found different and put back.
        beforeMoveAside: () => File(a('f.bin')).writeAsBytesSync([9]),
        beforeRestore: () => restored = true,
      );
      expect(r.outcome, DeleteOutcome.changed);
      expect(restored, isTrue);
      expect(File(a('f.bin')).readAsBytesSync(), [9]);
      expect(Directory(rootA.path).listSync(), hasLength(1));
      expect(c.calls, hasLength(1));
    });

    test('moveExclusive: the source and extra files as moves, the destination folder', () async {
      File(a('x.bin')).writeAsBytesSync([1]);
      expect(
        await moveExclusive(a('x.bin'), a('y.bin'), alsoMoved: [a('z.bin')]),
        MoveOutcome.moved,
      );
      expect(only(), [m(a('x.bin')), m(a('z.bin')), w(rootA.path)]);
    });

    test('sweepAsideFiles: no call without a leftover', () async {
      File(a('p.canvas')).writeAsStringSync('x');
      expect(await sweepAsideFiles(rootA), isEmpty);
      expect(c.calls, isEmpty);
    });

    test('sweepAsideFiles: a folder write and a move per leftover, one call', () async {
      File(a('p.canvas.1-2-3$asideSuffix')).writeAsStringSync('one');
      File(a('q.canvas.1-2-3$verifiedSuffix')).writeAsStringSync('two');
      File(a('r.txt.1-2-3$asideSuffix')).writeAsStringSync('not a page');
      final out = await sweepAsideFiles(rootA);
      expect(out, hasLength(2));
      final intents = only();
      expect(intents.first, w(rootA.path));
      expect(
        intents.skip(1).toSet(),
        {m(a('p.canvas.1-2-3$asideSuffix')), m(a('q.canvas.1-2-3$verifiedSuffix'))},
      );
      expect(File(a('p.canvas')).readAsStringSync(), 'one');
      expect(File(a('r.txt.1-2-3$asideSuffix')).existsSync(), isTrue);
    });

    test('sweepAsideFiles: a leftover that appears after the listing waits', () async {
      File(a('p.canvas.1-2-3$asideSuffix')).writeAsStringSync('one');
      c.beforeBody = (_) async =>
          File(a('q.canvas.4-5-6$asideSuffix')).writeAsStringSync('late');
      await sweepAsideFiles(rootA);
      expect(File(a('p.canvas')).existsSync(), isTrue);
      expect(File(a('q.canvas')).existsSync(), isFalse);
      expect(File(a('q.canvas.4-5-6$asideSuffix')).existsSync(), isTrue);
    });
  });

  group('roots and lookup', () {
    test('a call under two roots goes once, with every path', () async {
      registerCoordinator(realB, c);
      File(a('x.bin')).writeAsBytesSync([1]);
      expect(await moveExclusive(a('x.bin'), b('x.bin')), MoveOutcome.moved);
      expect(only(), [m(a('x.bin')), w(rootB.path)]);
    });

    test('a call under a root and outside goes once, with every path', () async {
      File(o('x.bin')).writeAsBytesSync([1]);
      expect(await moveExclusive(o('x.bin'), a('x.bin')), MoveOutcome.moved);
      expect(only(), [m(o('x.bin')), w(rootA.path)]);
    });

    test('a call wholly outside every root runs directly', () async {
      File(o('x.bin')).writeAsBytesSync([1]);
      expect(await moveExclusive(o('x.bin'), o('y.bin')), MoveOutcome.moved);
      expect(c.calls, isEmpty);
    });

    test('a missing parent resolves through its nearest existing ancestor', () async {
      final ran = <String>[];
      await coordinated(
        CoordinatedWrite([w(a('no${sep}such${sep}dir${sep}f'))]),
        () async => ran.add('body'),
      );
      expect(c.calls, hasLength(1));
      expect(ran, ['body']);
    });

    test('a path beside a root that shares its prefix is not under it', () async {
      final ran = await coordinated(
        CoordinatedWrite([w('${rootA.path}-other${sep}f')]),
        () async => 1,
      );
      expect(ran, 1);
      expect(c.calls, isEmpty);
    });

    test('a root registered through a link matches its real path', () async {
      if (Platform.isWindows) return; // links need privileges on Windows
      final link = '${outside.path}${sep}link';
      Link(link).createSync(rootB.path);
      registerCoordinator(link, c);
      await coordinated(CoordinatedWrite([w(b('f'))]), () async => 1);
      expect(c.calls, hasLength(1));
      c.calls.clear();
      await coordinated(CoordinatedWrite([w('$link${sep}f')]), () async => 1);
      expect(c.calls, hasLength(1));
    });

    test('nothing registered: the body runs directly', () async {
      unregisterCoordinator(realA);
      var ran = false;
      await coordinated(CoordinatedWrite([w(a('f'))]), () async => ran = true);
      expect(ran, isTrue);
      expect(c.calls, isEmpty);
    });

    test('with nothing registered, coordinated asks the file system nothing', () async {
      unregisterCoordinator(realA);
      var asked = 0;
      final r = await IOOverrides.runZoned(
        () => coordinated(CoordinatedWrite([w(a('f'))]), () async => 7),
        fseGetTypeSync: (path, follow) {
          asked++;
          return FileSystemEntityType.notFound;
        },
        getCurrentDirectory: () {
          asked++;
          return Directory(rootA.path);
        },
        createDirectory: (path) {
          asked++;
          throw StateError('no directory call expected');
        },
      );
      expect(r, 7);
      expect(asked, 0);
      expect(underCoordination([a('f')]), isFalse);
      expect(asked, 0);
    });

    test('a nested coordinated call fails the recording coordinator', () async {
      await expectLater(
        coordinated(
          CoordinatedWrite([w(a('f'))]),
          () => coordinated(CoordinatedWrite([w(a('g'))]), () async => 1),
        ),
        throwsA(isA<StorageBusy>()),
      );
    });

    test('folderOf is text-only, and keeps a drive root', () {
      if (!Platform.isWindows) {
        expect(folderOf('/a/b'), '/a');
        expect(folderOf('/a'), '/');
        expect(folderOf('a'), '.');
        return;
      }
      expect(folderOf(r'C:\a\b'), r'C:\a');
      expect(folderOf(r'C:\a'), r'C:\');
      expect(folderOf(r'C:\'), r'C:\');
      expect(folderOf('a'), '.');
    });

    test('a second, different coordinator is a StateError; the same is fine', () {
      expect(() => registerCoordinator(realB, RecordingCoordinator()), throwsStateError);
      registerCoordinator(realB, c);
      unregisterCoordinator(realA);
      unregisterCoordinator(realB);
      registerCoordinator(realB, RecordingCoordinator()); // none registered now
    });
  });

  group('refusal', () {
    test('an unavailable coordinator: StorageBusy, nothing written', () async {
      c.refuse = StorageBusy(StorageBusyReason.versionsPending, [a('f')]);
      final tmp = File(a('t.tmp'))..writeAsStringSync('x');
      await expectLater(
        publishExclusive(tmp, a('f.canvas')),
        throwsA(
          isA<StorageBusy>().having((e) => e.reason, 'reason', StorageBusyReason.versionsPending),
        ),
      );
      expect(File(a('f.canvas')).existsSync(), isFalse);
      expect(tmp.existsSync(), isTrue);
    });

    test('any error before the body starts is a coordination StorageBusy', () async {
      c.refuse = StateError('no channel');
      await expectLater(
        coordinated(CoordinatedWrite([w(a('f'))]), () async => 1),
        throwsA(
          isA<StorageBusy>().having((e) => e.reason, 'reason', StorageBusyReason.coordination),
        ),
      );
    });

    test('an error from the body is the body\'s', () async {
      await expectLater(
        coordinated(CoordinatedWrite([w(a('f'))]), () async => throw StateError('mine')),
        throwsStateError,
      );
    });

    test('replaceIfUnchanged and both deletes throw it, leaving the files', () async {
      File(a('f.canvas')).writeAsStringSync('old');
      final tmp = File(a('t.tmp'))..writeAsStringSync('new');
      c.refuse = StorageBusy(StorageBusyReason.coordination, [a('f.canvas')]);
      await expectLater(
        replaceIfUnchanged(tmp, a('f.canvas'), 'old'.codeUnits),
        throwsA(isA<StorageBusy>()),
      );
      await expectLater(deleteFileIfMatches(a('f.canvas'), bytes: 'old'.codeUnits), throwsA(isA<StorageBusy>()));
      await expectLater(deleteFileIfUnchanged(a('f.canvas'), 'old'.codeUnits), throwsA(isA<StorageBusy>()));
      expect(File(a('f.canvas')).readAsStringSync(), 'old');
      expect(Directory(rootA.path).listSync().map((e) => e.path.split(sep).last).toSet(), {'f.canvas', 't.tmp'});
    });

    test('a StorageBusy from the coordinator after the body ran is not StorageBusy', () async {
      final late = _LateRefusal();
      unregisterCoordinator(realA);
      registerCoordinator(realA, late);
      final tmp = File(a('t.tmp'))..writeAsStringSync('x');
      Object? error;
      try {
        await publishExclusive(tmp, a('f.canvas'));
      } catch (e) {
        error = e;
      }
      expect(File(a('f.canvas')).existsSync(), isTrue, reason: 'the body wrote');
      expect(error, isA<FileSystemException>());
      expect(error, isNot(isA<StorageBusy>()));
    });

    test('a StorageBusy the body itself throws stays one', () async {
      final busy = StorageBusy(StorageBusyReason.dataless, [a('f')]);
      await expectLater(
        coordinated(CoordinatedWrite([w(a('f'))]), () async => throw busy),
        throwsA(same(busy)),
      );
    });

    test('sweepAsideFiles: a coordinator failing after the body started keeps what was consumed', () async {
      final late = _LateRefusal();
      unregisterCoordinator(realA);
      registerCoordinator(realA, late);
      File(a('p.canvas.1-2-3$asideSuffix')).writeAsStringSync('one');
      final out = await sweepAsideFiles(rootA);
      expect(out, [a('p.canvas')]);
    });

    test('sweepAsideFiles: outside every root it lists once and calls no coordinator', () async {
      File(o('p.canvas.1-2-3$asideSuffix')).writeAsStringSync('one');
      File(o('q.canvas.1-2-3$asideSuffix')).writeAsStringSync('two');
      final seen = <String>[];
      final out = await sweepAsideFiles(outside, only: (n) {
        seen.add(n);
        return n == 'p.canvas';
      });
      expect(out, [o('p.canvas')]);
      expect(seen..sort(), ['p.canvas', 'q.canvas']);
      expect(c.calls, isEmpty);
      expect(File(o('q.canvas.1-2-3$asideSuffix')).existsSync(), isTrue);
    });

    test('moveExclusive: busy for every reason, nothing moved', () async {
      File(a('x.bin')).writeAsBytesSync([1]);
      for (final reason in StorageBusyReason.values) {
        c.refuse = StorageBusy(reason, [a('x.bin')]);
        expect(await moveExclusive(a('x.bin'), a('y.bin')), MoveOutcome.busy, reason: '$reason');
      }
      expect(File(a('x.bin')).existsSync(), isTrue);
      expect(File(a('y.bin')).existsSync(), isFalse);
    });

    test('sweepAsideFiles: a refusal consumes nothing and does not throw', () async {
      File(a('p.canvas.1-2-3$asideSuffix')).writeAsStringSync('one');
      c.refuse = StorageBusy(StorageBusyReason.versionsPending, [a('p.canvas.1-2-3$asideSuffix')]);
      expect(await sweepAsideFiles(rootA), isEmpty);
      expect(File(a('p.canvas.1-2-3$asideSuffix')).existsSync(), isTrue);
      expect(File(a('p.canvas')).existsSync(), isFalse);
    });

    test('a coordinator that never answers is refused after 60 s (fake clock)', () async {
      final never = _Gate();
      unregisterCoordinator(realA);
      registerCoordinator(realA, never);
      void Function()? fire;
      Duration? waited;
      final spec = ZoneSpecification(
        createTimer: (self, parent, zone, duration, f) {
          waited = duration;
          fire = f;
          return parent.createTimer(zone, const Duration(days: 365), () {});
        },
      );
      final tmp = File(a('t.tmp'))..writeAsStringSync('x');
      late Future<bool> result;
      runZoned(() => result = publishExclusive(tmp, a('f.canvas')), zoneSpecification: spec);
      expect(waited, const Duration(seconds: 60));
      expect(waited, coordinationStartTimeout);
      final expectation = expectLater(
        result,
        throwsA(isA<StorageBusy>().having((e) => e.reason, 'reason', StorageBusyReason.coordination)),
      );
      fire!();
      await expectation;
      // A late answer finds the call abandoned: the body doesn't run.
      never.open();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(File(a('f.canvas')).existsSync(), isFalse);
      expect(tmp.existsSync(), isTrue);
      expect(never.bodyThrew, isA<StorageBusy>());
    });
  });

  group('guards', () {
    final libs = <Directory>[
      for (final p in ['lib', '../noted_mcp/lib', '../noted_sync/lib', '../../app/lib'])
        if (Directory(p).existsSync()) Directory(p),
      if (Directory('../boxes').existsSync())
        for (final e in Directory('../boxes').listSync())
          if (e is Directory && Directory('${e.path}/lib').existsSync()) Directory('${e.path}/lib'),
    ];

    Map<String, String> sources() => {
      for (final dir in libs)
        for (final f in dir.listSync(recursive: true))
          if (f is File && f.path.endsWith('.dart'))
            f.path: f
                .readAsStringSync()
                .split(RegExp(r'\r?\n'))
                .where((l) => !l.trimLeft().startsWith('//'))
                .join('\n'),
    };

    test('the sources are found', () {
      final names = sources().keys.map((k) => k.replaceAll('\\', '/')).toList();
      expect(names.any((n) => n.endsWith('storage/exclusive_publish.dart')), isTrue);
      expect(names.any((n) => n.contains('noted_mcp/lib')), isTrue);
    });

    test('the uncoordinated forms are named only in the three storage files', () {
      const allowed = {'exclusive_publish.dart', 'replace_if_unchanged.dart', 'exclusive_move.dart'};
      final name = RegExp(r'\b(publishExclusiveUncoordinated|moveExclusiveUncoordinated|publishByRename)\b');
      final bad = <String>[];
      for (final e in sources().entries) {
        final file = e.key.replaceAll('\\', '/');
        if (allowed.contains(file.split('/').last)) continue;
        // The package's own library hides them from its exports.
        final text = file.endsWith('lib/noted_core.dart')
            ? e.value.replaceAll(RegExp(r'hide[^;]*;'), ';')
            : e.value;
        if (name.hasMatch(text)) bad.add(file);
      }
      expect(bad, isEmpty);
    });

    test('publishExclusiveSync is private', () {
      final bad = [
        for (final e in sources().entries)
          if (RegExp(r'(?<!_)\bpublishExclusiveSync\b').hasMatch(e.value)) e.key,
      ];
      expect(bad, isEmpty);
    });

    test('no function passed to fileWork or Isolate.run names a public primitive', () {
      final bad = <String>[];
      for (final e in sources().entries) {
        bad.addAll(primitivesInIsolateWork(e.value).map((n) => '${e.key}: $n'));
      }
      expect(bad, isEmpty);
    });

    test('the checker sees a primitive in a closure and in a named function', () {
      expect(primitivesInIsolateWork('x() => Isolate.run(() => moveExclusive(a, b));'), ['moveExclusive']);
      expect(primitivesInIsolateWork('x() => fileWork(() async { await replaceIfUnchanged(t, p, e); });'), [
        'replaceIfUnchanged',
      ]);
      expect(primitivesInIsolateWork('x() => Isolate.run(_job);\nint _job() {\n  return publishExclusive(a, b);\n}'), [
        'publishExclusive',
      ]);
      expect(primitivesInIsolateWork('x() => Isolate.run(() => moveExclusiveUncoordinated(a, b));'), isEmpty);
    });
  });
}

/// Runs the body, then fails with a StorageBusy of its own.
class _LateRefusal implements StorageCoordinator {
  @override
  Future<T> coordinate<T>(CoordinatedWrite write, Future<T> Function() body) async {
    await body();
    throw StorageBusy(StorageBusyReason.coordination, [for (final i in write.intents) i.path]);
  }
}

/// A coordinator that holds the call until [open], then offers the body.
class _Gate implements StorageCoordinator {
  final Completer<void> _open = Completer<void>();
  Object? bodyThrew;

  void open() => _open.complete();

  @override
  Future<T> coordinate<T>(CoordinatedWrite write, Future<T> Function() body) async {
    await _open.future;
    try {
      return await body();
    } catch (e) {
      bodyThrew = e;
      rethrow;
    }
  }
}

const _primitives = [
  'publishExclusive',
  'replaceIfUnchanged',
  'deleteFileIfUnchanged',
  'deleteFileIfMatches',
  'sweepAsideFiles',
  'moveExclusive',
];

/// The public primitives named by the function each `Isolate.run(` or
/// `fileWork(` call in [source] is given: the argument itself and, when it
/// names a function declared in [source], that function's body.
List<String> primitivesInIsolateWork(String source) {
  final found = <String>{};
  final starts = RegExp(r'\b(?:Isolate\.run|fileWork)\s*\(');
  final word = RegExp(r'[A-Za-z_]\w*');
  final prim = RegExp('\\b(${_primitives.join('|')})\\b');
  for (final m in starts.allMatches(source)) {
    final arg = _balanced(source, m.end - 1, '(', ')');
    found.addAll(prim.allMatches(arg).map((x) => x.group(1)!));
    for (final id in word.allMatches(arg).map((x) => x.group(0)!).toSet()) {
      final decl = RegExp('(?:^|\\n)[\\w<>?,. ]*\\b$id\\s*\\([^)]*\\)\\s*(?:async\\s*)?(\\{|=>)').firstMatch(source);
      if (decl == null) continue;
      final String body;
      if (decl.group(1) == '{') {
        body = _balanced(source, decl.end - 1, '{', '}');
      } else {
        final end = source.indexOf(';', decl.end);
        body = source.substring(decl.end, end < 0 ? source.length : end);
      }
      found.addAll(prim.allMatches(body).map((x) => x.group(1)!));
    }
  }
  return found.toList()..sort();
}

String _balanced(String s, int open, String o, String c) {
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    if (s[i] == o) depth++;
    if (s[i] == c && --depth == 0) return s.substring(open, i + 1);
  }
  return s.substring(open);
}
