// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The attachment copy helpers delete only what they can verify (0124, 0130):
// the rollback of a copy, the removal of a copied source and the sweep of
// what a crashed delete left aside.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/attachment_copy.dart';
import 'package:noted_core/noted_core.dart' show storedReadObserver;
import 'support/notebook_folder.dart';
import 'package:noted_canvas/noted_canvas.dart' show AttachmentState;
import 'package:noted_core/noted_core.dart' show StorageBusy, contentHash;
import 'package:noted_core/src/storage/dataless.dart' show debugDatalessPaths, debugMarkDataless;
import 'support/io_trace.dart' show IoTrace, TracingIoOverrides;

void main() {
  late Directory root;
  late Directory from;
  late Directory to;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_attcopy');
    from = await Directory('${root.path}/from').create();
    to = Directory('${root.path}/to');
  });

  tearDown(() async {
    await deleteTestFolder(root);
  });

  File f(Directory d, String name) => File('${d.path}/$name');

  test('R-1: the rollback of a copy keeps a file that changed after it was published', () async {
    f(from, 'x.txt').writeAsStringSync('one');
    f(from, 'y.txt').writeAsStringSync('two');
    final r = AttachmentCopy();
    await copyAttachmentTree(from, to, r);
    expect(r.created, hasLength(3), reason: 'the folder and two files');

    f(to, 'x.txt').writeAsStringSync('changed by a sync client');

    expect(await removeCreated(r), isFalse, reason: 'something was kept');
    expect(f(to, 'x.txt').readAsStringSync(), 'changed by a sync client');
    expect(
      f(to, 'y.txt').existsSync(),
      isFalse,
      reason: 'the unchanged copy goes',
    );
    expect(
      to.existsSync(),
      isTrue,
      reason: 'the folder still holds the kept file',
    );
    expect(to.listSync().where((e) => e.path.contains('.cas-')), isEmpty);
  });

  test(
    'the rollback of an unchanged copy removes every file and folder it made',
    () async {
      f(from, 'x.txt').writeAsStringSync('one');
      final r = AttachmentCopy();
      await copyAttachmentTree(from, to, r);
      expect(await removeCreated(r), isTrue);
      expect(to.existsSync(), isFalse);
    },
  );

  test(
    'R-1: an original set aside by a crashed delete is swept back, and copied',
    () async {
      // What deleteFileIfMatches leaves when the process stops after the move aside.
      f(from, 'x.txt.4242-1a-2b.cas-old').writeAsStringSync('one');

      final r = AttachmentCopy();
      await copyAttachmentTree(from, to, r);

      expect(
        f(from, 'x.txt').readAsStringSync(),
        'one',
        reason: 'put back where it was',
      );
      expect(
        f(to, 'x.txt').readAsStringSync(),
        'one',
        reason: 'and copied with the rest',
      );
      expect(
        from.listSync().where((e) => e.path.endsWith('.cas-old')),
        isEmpty,
      );
      expect(r.keptAside, isEmpty);
    },
  );

  test(
    'a swept-back original never replaces a file that is there now',
    () async {
      f(from, 'x.txt.4242-1a-2b.cas-old').writeAsStringSync('old');
      f(from, 'x.txt').writeAsStringSync('newer');

      final r = AttachmentCopy();
      await sweepAttachmentLeftovers(from, r);
      expect(
        r.keptAside.single,
        contains('-recovered-'),
        reason: 'reported, not silent',
      );

      expect(f(from, 'x.txt').readAsStringSync(), 'newer');
      final kept = from.listSync().whereType<File>().where(
        (e) => e.path.contains('-recovered-'),
      );
      expect(kept.map((e) => e.readAsStringSync()), [
        'old',
      ], reason: 'kept as a copy, not deleted');
    },
  );

  test('10: a hash-named target that fails its hash is kept as .damaged-<hex> and the good copy takes its name (what templates use)', () async {
    final good = List<int>.generate(40, (i) => i);
    final hash = contentHash(good);
    final name = '$hash.png';
    f(from, name).writeAsBytesSync(good);
    to.createSync();
    final old = List<int>.filled(40, 9);
    f(to, name).writeAsBytesSync(old);
    final r = AttachmentCopy();
    await copyAttachmentTree(from, to, r);
    final aside = damagedCopyName(name, contentHash(old));
    expect(f(to, name).readAsBytesSync(), good);
    expect(f(to, aside).readAsBytesSync(), old);
    expect(r.damagedKept, hasLength(1));
    expect(r.damagedKept.single.aside, aside);
    expect(r.damagedKept.single.name, name);
    expect(r.damagedKept.single.incomplete, isFalse);
    expect(r.differing, isEmpty);
    expect(r.stillChanging, isEmpty);
    expect(r.verified, hasLength(1));
  });

  test('a shorter target is recorded as incomplete', () async {
    final good = List<int>.generate(40, (i) => i);
    final name = contentHash(good);
    f(from, name).writeAsBytesSync(good);
    to.createSync();
    f(to, name).writeAsBytesSync([1, 2]);
    final r = AttachmentCopy();
    await copyAttachmentTree(from, to, r);
    expect(r.damagedKept.single.incomplete, isTrue);
    expect(f(to, name).readAsBytesSync(), good);
    expect(f(to, damagedCopyName(name, contentHash([1, 2]))).readAsBytesSync(), [1, 2]);
  });

  // --- t2a: nothing is read, copied or written in a not-downloaded file's place -

  group('a file that is not downloaded (t2a)', () {
    late _Opens trace;
    final good = List<int>.generate(40, (i) => i);
    final name = '${contentHash(good)}.bin';

    setUp(() {
      trace = _Opens();
      storedReadObserver = null;
    });
    tearDown(() => debugDatalessPaths = null);

    // Runs [body] with every file operation recorded.
    Future<T> traced<T>(Future<T> Function() body) =>
        IOOverrides.runWithIOOverrides(body, TracingIoOverrides(trace));

    void expectNoOpen(String path) {
      final key = path.replaceAll(r'\', '/').toLowerCase();
      expect(
        trace.opens.where((o) => o.toLowerCase().endsWith(key)),
        isEmpty,
        reason: 'nothing opened or read $path: ${trace.opens}',
      );
    }

    test('checkAttachmentFile answers syncing with notDownloaded, before any stat or open', () async {
      f(from, name).writeAsBytesSync(good);
      debugMarkDataless(f(from, name).path);
      final c = await traced(() => checkAttachmentFile(f(from, name), contentHash(good), good.length));
      expect(c.state, AttachmentState.syncing);
      expect(c.notDownloaded, isTrue);
      expect(trace.ops.where((o) => o.endsWith(name)), isEmpty, reason: 'not even a stat: ${trace.ops}');
    });

    test('checkAttachmentFile: a stub with no file is not downloaded', () async {
      f(from, '.$name.icloud').writeAsStringSync('');
      final c = await checkAttachmentFile(f(from, name), contentHash(good), good.length);
      expect(c.notDownloaded, isTrue);
      expect(c.state, AttachmentState.syncing);
    });

    test('copyAttachmentFile: a source that is not downloaded is not read, and nothing is made', () async {
      f(from, name).writeAsBytesSync(good);
      debugMarkDataless(f(from, name).path);
      to.createSync();
      final r = AttachmentCopy();
      await traced(() => copyAttachmentFile(f(from, name), f(to, name).path, name, r));
      expect(_n(r.notDownloaded), _n([f(from, name).path]));
      expect(r.created, isEmpty);
      expect(to.listSync(), isEmpty, reason: 'not even a temporary file stays');
      expectNoOpen(f(from, name).path);
    });

    test('copyAttachmentFile: a target that is not downloaded is not read and not set aside', () async {
      f(from, name).writeAsBytesSync(good);
      to.createSync();
      f(to, name).writeAsBytesSync(good.sublist(0, 5));
      debugMarkDataless(f(to, name).path);
      final r = AttachmentCopy();
      await traced(() => copyAttachmentFile(f(from, name), f(to, name).path, name, r));
      expect(_n(r.notDownloaded), _n([f(to, name).path]));
      expect(r.damagedKept, isEmpty);
      expect(r.verified, isEmpty);
      expect(to.listSync().map((e) => e.path.split(RegExp(r'[\\/]')).last), [name]);
      expectNoOpen(f(to, name).path);
    });

    test('copyAttachmentFile: only a stub at the target counts as taken, and is not downloaded', () async {
      f(from, name).writeAsBytesSync(good);
      to.createSync();
      f(to, '.$name.icloud').writeAsStringSync('');
      final r = AttachmentCopy();
      await copyAttachmentFile(f(from, name), f(to, name).path, name, r);
      expect(_n(r.notDownloaded), _n([f(to, name).path]));
      expect(f(to, name).existsSync(), isFalse);
    });

    test('_settleExisting: a source that is not downloaded is not hashed', () async {
      // A different file is at the target, so the settle would hash the source.
      f(from, name).writeAsBytesSync(good);
      to.createSync();
      f(to, name).writeAsBytesSync([1, 2, 3]);
      debugMarkDataless(f(from, name).path);
      final r = AttachmentCopy();
      await traced(() => copyAttachmentFile(f(from, name), f(to, name).path, name, r));
      expect(_n(r.notDownloaded), contains(_n([f(from, name).path]).single));
      expect(r.damagedKept, isEmpty);
      expect(f(to, name).readAsBytesSync(), [1, 2, 3], reason: 'the target was not touched');
      expectNoOpen(f(from, name).path);
    });

    test('attachmentNameToTake: an unfinished write that is not downloaded is not hashed, and is listed', () async {
      final tmp = f(from, '$name.tmp');
      f(from, '$name.tmp').writeAsBytesSync(good);
      debugMarkDataless(tmp.path);
      final r = AttachmentCopy();
      final taken = await traced(() => attachmentNameToTake(tmp, '$name.tmp', r));
      expect(taken, isNull);
      expect(_n(r.notDownloaded), _n([tmp.path]));
      expectNoOpen(tmp.path);
    });

    test('sweepAttachmentLeftovers: a leftover that is not downloaded is not hashed or put back', () async {
      final left = f(from, '$name.1700000000000000-1.tmp');
      left.writeAsBytesSync(good);
      debugMarkDataless(left.path);
      final r = AttachmentCopy();
      await traced(() => sweepAttachmentLeftovers(from, r));
      expect(_n(r.notDownloaded), _n([left.path]));
      expect(left.existsSync(), isTrue);
      expect(f(from, name).existsSync(), isFalse, reason: 'not put back');
      expectNoOpen(left.path);
    });

    test('sweepAttachmentLeftovers: the target of a leftover that is not downloaded is not compared', () async {
      final left = f(from, '$name.1700000000000000-1.tmp');
      left.writeAsBytesSync(good);
      f(from, name).writeAsBytesSync(good);
      debugMarkDataless(f(from, name).path);
      final r = AttachmentCopy();
      await traced(() => sweepAttachmentLeftovers(from, r));
      expect(_n(r.notDownloaded), _n([f(from, name).path]));
      expect(left.existsSync(), isTrue, reason: 'the leftover is not deleted as a duplicate');
      expectNoOpen(f(from, name).path);
    });

    test('copyAttachmentTree: a stub is asked for, never copied as a file', () async {
      f(from, name).writeAsBytesSync(good);
      f(from, '.other.bin.icloud').writeAsStringSync('');
      final r = AttachmentCopy();
      await copyAttachmentTree(from, to, r);
      expect(_n(r.notDownloaded), _n(['${from.path}${Platform.pathSeparator}other.bin']));
      expect(to.listSync().map((e) => e.path.split(RegExp(r'[\\/]')).last), [name]);
    });

    test('keepGoodCopy: a kept copy that is not downloaded is not used, and no second one is written', () async {
      final bytes = Uint8List.fromList(good);
      to.createSync();
      final kept = f(to, '$name.kept-1');
      kept.writeAsBytesSync(good);
      debugMarkDataless(kept.path);
      await expectLater(
        keepGoodCopy(to, name, bytes),
        throwsA(isA<StorageBusy>().having((e) => _n(e.paths), 'paths', _n([kept.path]))),
      );
      expect(to.listSync().length, 1);
    });

    test('restoreKeptCopy: a kept copy that is not downloaded is not used', () async {
      to.createSync();
      final kept = f(to, '$name.kept-1');
      kept.writeAsBytesSync(good);
      debugMarkDataless(kept.path);
      final held = <String>[];
      expect(await restoreKeptCopy(to, name, contentHash(good), good.length, notDownloaded: held), isFalse);
      expect(_n(held), _n([kept.path]));
      expect(f(to, name).existsSync(), isFalse);
    });
  });
}

// Records the operations that open or read a file.
class _Opens extends IoTrace {
  final List<String> ops = [];

  List<String> get opens => [
    for (final o in ops)
      if (o.startsWith('open') || o.startsWith('read')) o,
  ];

  @override
  int begin(String op, String path, {String? to}) {
    ops.add('$op ${path.replaceAll(r'\', '/')}');
    return super.begin(op, path, to: to);
  }
}

List<String> _n(Iterable<String> paths) => [for (final p in paths) p.replaceAll(r'\', '/')];
