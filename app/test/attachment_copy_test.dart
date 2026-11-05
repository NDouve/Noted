// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The attachment copy helpers delete only what they can verify (0124, 0130):
// the rollback of a copy, the removal of a copied source and the sweep of
// what a crashed delete left aside.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/attachment_copy.dart';
import 'package:noted_core/noted_core.dart' show contentHash;

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
    await root.delete(recursive: true);
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
    'a source that is replaced while it is set aside is never deleted',
    () async {
      f(from, 'x.txt').writeAsStringSync('one');
      final r = AttachmentCopy();
      await copyAttachmentTree(from, to, r);
      attachmentAfterAsideHook = (source) =>
          source.writeAsStringSync('arrived');
      addTearDown(() => attachmentAfterAsideHook = null);

      await removeVerifiedSources(r, from);

      expect(f(from, 'x.txt').readAsStringSync(), 'arrived');
      expect(from.listSync().where((e) => e.path.contains('.cas-')), isEmpty);
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
}
