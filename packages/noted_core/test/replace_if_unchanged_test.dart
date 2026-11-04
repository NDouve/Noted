// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  deleteTests();
  saveNewTextTests();
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('noted_cas'));
  tearDown(() async => dir.delete(recursive: true));

  String p(String n) => '${dir.path}${Platform.pathSeparator}$n';
  List<String> names() =>
      dir.listSync().map((f) => f.path.split(RegExp(r'[\\/]')).last).toList()..sort();

  group('replaceIfUnchanged', () {
    test('equal bytes: replaced, new bytes at the target, no leftovers', () async {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7, 8]);
      final r = await replaceIfUnchanged(tmp, p('a.bin'), [1, 2, 3]);
      expect(r.outcome, ReplaceOutcome.replaced);
      expect(r.keptPath, isNull);
      expect(File(p('a.bin')).readAsBytesSync(), [7, 8]);
      expect(names(), ['a.bin']);
    });

    test('target replaced before the move-aside: changed, newer file intact', () async {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7, 8]);
      final r = await replaceIfUnchanged(
        tmp,
        p('a.bin'),
        [1, 2, 3],
        beforeMoveAside: () => File(p('a.bin')).writeAsBytesSync([9, 9, 9]),
      );
      expect(r.outcome, ReplaceOutcome.changed);
      expect(File(p('a.bin')).readAsBytesSync(), [9, 9, 9]);
      expect(tmp.readAsBytesSync(), [7, 8]);
      expect(names(), ['a.bin', 'a.tmp']);
    });

    test('a file appears after the move-aside (changed bytes): kept, newer intact', () async {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      final r = await replaceIfUnchanged(
        tmp,
        p('a.bin'),
        [1, 2, 3],
        beforeMoveAside: () => File(p('a.bin')).writeAsBytesSync([5]),
        afterRead:() => File(p('a.bin')).writeAsBytesSync([9, 9]),
      );
      expect(r.outcome, ReplaceOutcome.changedKept);
      expect(File(p('a.bin')).readAsBytesSync(), [9, 9]);
      expect(File(r.keptPath!).readAsBytesSync(), [5]);
      expect(tmp.existsSync(), isTrue);
    });

    test('a file appears after the move-aside (equal bytes): kept, newer intact', () async {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      final r = await replaceIfUnchanged(
        tmp,
        p('a.bin'),
        [1, 2, 3],
        beforePublish: () => File(p('a.bin')).writeAsBytesSync([9, 9]),
      );
      expect(r.outcome, ReplaceOutcome.supersededKept);
      expect(File(p('a.bin')).readAsBytesSync(), [9, 9]);
      expect(File(r.keptPath!).readAsBytesSync(), [1, 2, 3]);
      expect(conflictCopyOriginalNames(File(r.keptPath!).uri.pathSegments.last, extension: '.bin'), contains('a.bin'));
      expect(tmp.readAsBytesSync(), [7]);
    });

    test('different bytes: changed, original put back byte for byte', () async {
      File(p('a.bin')).writeAsBytesSync([4, 5, 6]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      final r = await replaceIfUnchanged(tmp, p('a.bin'), [1, 2, 3]);
      expect(r.outcome, ReplaceOutcome.changed);
      expect(File(p('a.bin')).readAsBytesSync(), [4, 5, 6]);
      expect(names(), ['a.bin', 'a.tmp']);
    });

    test('absent target and absence expected: published', () async {
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      final r = await replaceIfUnchanged(tmp, p('a.bin'), null);
      expect(r.outcome, ReplaceOutcome.replaced);
      expect(File(p('a.bin')).readAsBytesSync(), [7]);
      expect(names(), ['a.bin']);
    });

    test('absent target but bytes expected: changed, nothing published', () async {
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      final r = await replaceIfUnchanged(tmp, p('a.bin'), [1]);
      expect(r.outcome, ReplaceOutcome.changed);
      expect(names(), ['a.tmp']);
    });

    test('file present but absence expected: changed, file intact', () async {
      File(p('a.bin')).writeAsBytesSync([1]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      final r = await replaceIfUnchanged(tmp, p('a.bin'), null);
      expect(r.outcome, ReplaceOutcome.changed);
      expect(File(p('a.bin')).readAsBytesSync(), [1]);
    });

    test('a throw after the move-aside puts the original back', () async {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      await expectLater(
        replaceIfUnchanged(tmp, p('a.bin'), [1, 2, 3], beforePublish: () => throw StateError('x')),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(p('a.bin')).readAsBytesSync(), [1, 2, 3]);
      expect(names(), ['a.bin', 'a.tmp']);
    });
  });

  group('replaceIfUnchanged failures', () {
    test('a plain difference moves nothing aside', () async {
      File(p('a.bin')).writeAsBytesSync([4]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      var moved = false;
      final r = await replaceIfUnchanged(
        tmp,
        p('a.bin'),
        [1],
        beforeMoveAside: () => moved = true,
      );
      expect(r.outcome, ReplaceOutcome.changed);
      expect(moved, isFalse);
    });

    test('the target vanishing after the pre-read is changed', () async {
      File(p('a.bin')).writeAsBytesSync([1]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      final r = await replaceIfUnchanged(
        tmp,
        p('a.bin'),
        [1],
        beforeMoveAside: () => File(p('a.bin')).deleteSync(),
      );
      expect(r.outcome, ReplaceOutcome.changed);
      expect(names(), ['a.tmp']);
    });

    test('a file appearing before the restore is kept, not replaced', () async {
      File(p('a.bin')).writeAsBytesSync([1]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      final r = await replaceIfUnchanged(
        tmp,
        p('a.bin'),
        [1],
        beforeMoveAside: () => File(p('a.bin')).writeAsBytesSync([2]),
        beforeRestore: () => File(p('a.bin')).writeAsBytesSync([3]),
      );
      expect(r.outcome, ReplaceOutcome.changedKept);
      expect(File(p('a.bin')).readAsBytesSync(), [3]);
      expect(File(r.keptPath!).readAsBytesSync(), [2]);
    });

    test('a failed restore names the kept file, and scan puts it back', () async {
      final store = PageStore(dir);
      const page = 'p1';
      final text = writePage(
        NotedPage.create(PageMeta.create(id: page, title: 'Old', order: 0)),
      );
      File(store.pathFor(page)).writeAsStringSync(text);
      final other = writePage(
        NotedPage.create(PageMeta.create(id: page, title: 'Other', order: 0)),
      );
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      Object? error;
      try {
        await replaceIfUnchanged(
          tmp,
          store.pathFor(page),
          utf8.encode(text),
          beforeMoveAside: () => File(store.pathFor(page)).writeAsStringSync(other),
          beforeRestore: () => throw StateError('locked'),
        );
      } on FileSystemException catch (e) {
        error = e;
      }
      expect(error.toString(), contains('kept as'));
      expect(File(store.pathFor(page)).existsSync(), isFalse);
      expect(names().where((n) => n.endsWith(asideSuffix)), hasLength(1));

      final entries = await store.scan();
      expect(entries.single, isA<ReadablePage>());
      expect(File(store.pathFor(page)).readAsStringSync(), other);
      expect(names().where((n) => n.endsWith(asideSuffix)), isEmpty);
    });

    test('an open handle on the target throws and leaves it intact', () async {
      File(p('a.bin')).writeAsBytesSync([1]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      final open = File(p('a.bin')).openSync();
      try {
        await expectLater(
          replaceIfUnchanged(tmp, p('a.bin'), [1]),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        open.closeSync();
      }
      expect(File(p('a.bin')).readAsBytesSync(), [1]);
      expect(names(), ['a.bin', 'a.tmp']);
    }, skip: !Platform.isWindows);
  });

  group('sweep', () {
    NotedPage page(String title) =>
        NotedPage.create(PageMeta.create(id: 'p1', title: title, order: 0));

    test('a leftover with the target absent is restored by scan', () async {
      final store = PageStore(dir);
      final text = writePage(page('Mine'));
      File(p('p1.canvas.1234-ab-cd$asideSuffix')).writeAsStringSync(text);
      final entries = await store.scan();
      expect(entries.single, isA<ReadablePage>());
      expect(File(p('p1.canvas')).readAsStringSync(), text);
      expect(names(), ['p1.canvas']);
    });

    test('a stale verified file is published when the target is absent', () async {
      final store = PageStore(dir);
      final text = writePage(page('Mine'));
      File(p('p1.canvas.1-a-b$verifiedSuffix')).writeAsStringSync(text);
      expect((await store.scan()).single, isA<ReadablePage>());
      expect(File(p('p1.canvas')).readAsStringSync(), text);
      expect(names(), ['p1.canvas']);
    });

    test('a stale verified file is kept as a conflict copy when the target is occupied', () async {
      final store = PageStore(dir);
      final theirs = writePage(page('Theirs'));
      final old = writePage(page('Old'));
      File(p('p1.canvas')).writeAsStringSync(theirs);
      File(p('p1.canvas.1-a-b$verifiedSuffix')).writeAsStringSync(old);
      final entries = await store.scan();
      expect(entries.whereType<ReadablePage>(), hasLength(1));
      final copy = entries.whereType<ConflictCopyPage>().single;
      expect(copy.originalPath, p('p1.canvas'));
      expect(File(copy.path).readAsStringSync(), old);
      expect(File(p('p1.canvas')).readAsStringSync(), theirs);
      expect(names(), hasLength(2));
    });

    test('with extension empty, a non-page leftover is put back or kept as a copy', () async {
      File(p('x.bin.1-a-b$asideSuffix')).writeAsBytesSync([1]);
      File(p('y.bin')).writeAsBytesSync([9]);
      File(p('y.bin.1-a-b$verifiedSuffix')).writeAsBytesSync([2]);
      final out = await sweepAsideFiles(dir, extension: '');
      expect(out, hasLength(2));
      expect(File(p('x.bin')).readAsBytesSync(), [1]);
      expect(File(p('y.bin')).readAsBytesSync(), [9]);
      final copy = names().singleWhere((n) => n.startsWith('y.bin-') || n.startsWith('y-'));
      expect(File(p(copy)).readAsBytesSync(), [2]);
      expect(names(), hasLength(3));
    });

    test('a non-page leftover is left alone and listed', () async {
      final store = PageStore(dir);
      File(p('x.bin.1-a-b$asideSuffix')).writeAsBytesSync([1]);
      final entries = await store.scan();
      expect(entries.single, isA<UnreadablePage>());
      expect(names(), ['x.bin.1-a-b$asideSuffix']);
    });

    test('a leftover that cannot be moved is listed as unreadable', () async {
      final store = PageStore(dir);
      final name = 'p1.canvas.1-a-b$asideSuffix';
      File(p(name)).writeAsStringSync(writePage(page('Mine')));
      final open = File(p(name)).openSync();
      try {
        final entries = await store.scan();
        expect(entries.single, isA<UnreadablePage>());
        expect(entries.single.path, p(name));
      } finally {
        open.closeSync();
      }
      expect(File(p(name)).existsSync(), isTrue);
    }, skip: !Platform.isWindows);

    test('a leftover with the target present is surfaced, not deleted', () async {
      final store = PageStore(dir);
      final mine = writePage(page('Mine'));
      final theirs = writePage(page('Theirs'));
      File(p('p1.canvas')).writeAsStringSync(theirs);
      File(p('p1.canvas.1234-ab-cd$asideSuffix')).writeAsStringSync(mine);
      final entries = await store.scan();
      expect(entries.whereType<ReadablePage>(), hasLength(1));
      final copy = entries.whereType<ConflictCopyPage>().single;
      expect(copy.originalPath, p('p1.canvas'));
      expect(File(copy.path).readAsStringSync(), mine);
      expect(File(p('p1.canvas')).readAsStringSync(), theirs);
      expect(names().where((n) => n.endsWith(asideSuffix)), isEmpty);
    });
  });

  group('PageStore.saveIfUnchanged', () {
    NotedPage page(String title) =>
        NotedPage.create(PageMeta.create(id: 'p1', title: title, order: 0));

    test('supersededKept keeps the original as a conflict copy that the scan finds', () async {
      final store = PageStore(dir);
      await store.save(page('Old'));
      final text = await store.readText('p1');
      final theirs = writePage(page('Theirs'));
      final r = await store.saveIfUnchanged(
        page('Mine'),
        text,
        beforePublish: () => File(store.pathFor('p1')).writeAsStringSync(theirs),
      );
      expect(r.outcome, ReplaceOutcome.supersededKept);
      expect(await store.readText('p1'), theirs);
      // The original-only content survives, under a recognised conflict-copy name.
      expect(File(r.keptPath!).readAsStringSync(), text);
      expect(names(), hasLength(2));
      final entries = await store.scan();
      final copy = entries.whereType<ConflictCopyPage>().single;
      expect(copy.path, r.keptPath);
      expect(copy.originalPath, store.pathFor('p1'));
    });

    test('supersededKept keeps the original even when it equals the written text', () async {
      final store = PageStore(dir);
      await store.save(page('Same'));
      final text = await store.readText('p1');
      final r = await store.saveIfUnchanged(
        page('Same'),
        text,
        beforePublish: () => File(store.pathFor('p1')).writeAsStringSync(writePage(page('T'))),
      );
      expect(r.outcome, ReplaceOutcome.supersededKept);
      expect(File(r.keptPath!).readAsStringSync(), text);
    });

    test('a crash after the verify leaves a leftover the scan keeps as a conflict copy', () async {
      final store = PageStore(dir);
      await store.save(page('Old'));
      final text = await store.readText('p1');
      final theirs = writePage(page('Theirs'));
      // Simulate the crash: the hook throws after the original was set aside and
      // verified, and a sync writer has taken the target; the restore also fails.
      await expectLater(
        store.saveIfUnchanged(
          page('Mine'),
          text,
          beforePublish: () {
            File(store.pathFor('p1')).writeAsStringSync(theirs);
            throw StateError('crash');
          },
          beforeRestore: () => throw StateError('crash'),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(names().where((n) => n.endsWith(verifiedSuffix)), hasLength(1));
      final entries = await store.scan();
      final copy = entries.whereType<ConflictCopyPage>().single;
      expect(File(copy.path).readAsStringSync(), text);
      expect(await store.readText('p1'), theirs);
    });

    test('changedKept keeps a leftover that is not verified equal', () async {
      final store = PageStore(dir);
      await store.save(page('Old'));
      final text = await store.readText('p1');
      final other = writePage(page('Other'));
      final r = await store.saveIfUnchanged(
        page('Mine'),
        text,
        beforeMoveAside: () => File(store.pathFor('p1')).writeAsStringSync(other),
        beforeRestore: () => File(store.pathFor('p1')).writeAsStringSync('x'),
      );
      expect(r.outcome, ReplaceOutcome.changedKept);
      expect(File(r.keptPath!).readAsStringSync(), other);
      expect(await store.readText('p1'), 'x');
    });

    test('replaces when unchanged and removes its temp', () async {
      final store = PageStore(dir);
      await store.save(page('Old'));
      final text = await store.readText('p1');
      final r = await store.saveIfUnchanged(page('New'), text);
      expect(r.replaced, isTrue);
      expect((await store.load('p1')).meta.title, 'New');
      expect(names(), ['p1.canvas']);
    });

    test('a sync write between read and replace is not lost', () async {
      final store = PageStore(dir);
      await store.save(page('Old'));
      final text = await store.readText('p1');
      final theirs = writePage(page('Theirs'));
      final r = await store.saveIfUnchanged(
        page('Mine'),
        text,
        beforeMoveAside: () => File(store.pathFor('p1')).writeAsStringSync(theirs),
      );
      expect(r.outcome, ReplaceOutcome.changed);
      expect(await store.readText('p1'), theirs);
      expect(names(), ['p1.canvas']);
    });

    test('removes its temp when a hook throws', () async {
      final store = PageStore(dir);
      await store.save(page('Old'));
      final text = await store.readText('p1');
      await expectLater(
        store.saveIfUnchanged(page('New'), text, beforePublish: () => throw StateError('x')),
        throwsA(isA<FileSystemException>()),
      );
      expect(await store.readText('p1'), text);
      expect(names(), ['p1.canvas']);
    });

    test('absent expected behaves like saveNew', () async {
      final store = PageStore(dir);
      expect((await store.saveIfUnchanged(page('New'), null)).replaced, isTrue);
      expect((await store.saveIfUnchanged(page('Other'), null)).replaced, isFalse);
      expect((await store.load('p1')).meta.title, 'New');
      expect(names(), ['p1.canvas']);
    });
  });
}

void deleteTests() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('noted_cad'));
  tearDown(() async => dir.delete(recursive: true));
  String p(String n) => '${dir.path}${Platform.pathSeparator}$n';
  List<String> names() =>
      dir.listSync().map((f) => f.path.split(RegExp(r'[\\/]')).last).toList()..sort();

  group('deleteFileIfUnchanged', () {
    test('equal bytes: deleted, nothing left', () async {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
      final r = await deleteFileIfUnchanged(p('a.bin'), [1, 2, 3]);
      expect(r.outcome, DeleteOutcome.deleted);
      expect(names(), isEmpty);
    });

    test('no file: absent', () async {
      expect((await deleteFileIfUnchanged(p('a.bin'), [1])).outcome, DeleteOutcome.absent);
    });

    test('different bytes: changed, file untouched', () async {
      File(p('a.bin')).writeAsBytesSync([9]);
      final r = await deleteFileIfUnchanged(p('a.bin'), [1]);
      expect(r.outcome, DeleteOutcome.changed);
      expect(File(p('a.bin')).readAsBytesSync(), [9]);
    });

    test('replaced between the check and the move-aside: put back, byte for byte', () async {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
      final r = await deleteFileIfUnchanged(
        p('a.bin'),
        [1, 2, 3],
        beforeMoveAside: () => File(p('a.bin')).writeAsBytesSync([4, 5]),
      );
      expect(r.outcome, DeleteOutcome.changed);
      expect(File(p('a.bin')).readAsBytesSync(), [4, 5]);
      expect(names(), ['a.bin']);
    });

    test('a file appears while the changed one is set aside: both kept', () async {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
      final r = await deleteFileIfUnchanged(
        p('a.bin'),
        [1, 2, 3],
        beforeMoveAside: () => File(p('a.bin')).writeAsBytesSync([4, 5]),
        afterRead: () => File(p('a.bin')).writeAsBytesSync([7]),
      );
      expect(r.outcome, DeleteOutcome.changedKept);
      expect(File(p('a.bin')).readAsBytesSync(), [7]);
      expect(File(r.keptPath!).readAsBytesSync(), [4, 5]);
      expect(r.keptPath!.endsWith(asideSuffix), isTrue);
    });
  });

  group('deleteFileIfMatches', () {
    test('a matching content identity: deleted', () async {
      File(p('a.png')).writeAsBytesSync([1, 2, 3]);
      final id = ContentIdentity.ofBytes([1, 2, 3]);
      expect(await ContentIdentity.ofFile(p('a.png')), id);
      final r = await deleteFileIfMatches(p('a.png'), identity: id);
      expect(r.outcome, DeleteOutcome.deleted);
      expect(names(), isEmpty);
    });

    test('same length, different content: kept, byte for byte', () async {
      File(p('a.png')).writeAsBytesSync([1, 2, 4]);
      final r = await deleteFileIfMatches(p('a.png'), identity: ContentIdentity.ofBytes([1, 2, 3]));
      expect(r.outcome, DeleteOutcome.changed);
      expect(File(p('a.png')).readAsBytesSync(), [1, 2, 4]);
      expect(names(), ['a.png']);
    });

    test('replaced before the move-aside: the newer file is put back', () async {
      File(p('a.png')).writeAsBytesSync([1, 2, 3]);
      final r = await deleteFileIfMatches(
        p('a.png'),
        identity: ContentIdentity.ofBytes([1, 2, 3]),
        beforeMoveAside: () => File(p('a.png')).writeAsBytesSync([8, 8]),
      );
      expect(r.outcome, DeleteOutcome.changed);
      expect(File(p('a.png')).readAsBytesSync(), [8, 8]);
      expect(names(), ['a.png']);
    });

    test('a file appearing while a changed one is set aside: both kept and reported', () async {
      File(p('a.png')).writeAsBytesSync([1, 2, 3]);
      final r = await deleteFileIfMatches(
        p('a.png'),
        identity: ContentIdentity.ofBytes([1, 2, 3]),
        beforeMoveAside: () => File(p('a.png')).writeAsBytesSync([8, 8]),
        afterRead: () => File(p('a.png')).writeAsBytesSync([7]),
      );
      expect(r.outcome, DeleteOutcome.changedKept);
      expect(File(p('a.png')).readAsBytesSync(), [7]);
      expect(File(r.keptPath!).readAsBytesSync(), [8, 8]);
    });

    test('a failed delete whose put-back is blocked names the kept file', () async {
      File(p('a.png')).writeAsBytesSync([1, 2, 3]);
      Object? error;
      try {
        await deleteFileIfMatches(
          p('a.png'),
          bytes: [1, 2, 3],
          beforeDelete: () async {
            File(p('a.png')).writeAsBytesSync([5]);
            throw StateError('boom');
          },
        );
      } on FileSystemException catch (e) {
        error = e;
      }
      expect(error.toString(), contains('kept as'));
      expect(File(p('a.png')).readAsBytesSync(), [5]);
      final kept = names().singleWhere((n) => n.endsWith(asideSuffix));
      expect(File(p(kept)).readAsBytesSync(), [1, 2, 3]);
      // A non-page leftover comes back through the sweep with no extension.
      File(p('a.png')).deleteSync();
      await sweepAsideFiles(dir, extension: '');
      expect(File(p('a.png')).readAsBytesSync(), [1, 2, 3]);
    });

    test('exactly one of bytes and identity is required', () async {
      expect(() => deleteFileIfMatches(p('a')), throwsArgumentError);
      expect(
        () => deleteFileIfMatches(p('a'), bytes: [1], identity: ContentIdentity.ofBytes([1])),
        throwsArgumentError,
      );
    });
  });

  test('conflictCopyName is recognised by conflictCopyOriginalNames', () {
    final n = conflictCopyName('3f2a-b1.canvas');
    expect(conflictCopyOriginalNames(n), contains('3f2a-b1.canvas'));
    expect(n, startsWith('3f2a-b1-conflict-'));
    final a = conflictCopyName('x.png', extension: '.png');
    expect(a, matches(RegExp(r'^x-conflict-[0-9a-f]{8}\.png$')));
    expect(conflictCopyName('noext', extension: ''), startsWith('noext-conflict-'));
  });

  test('PageStore.deleteIfUnchanged deletes only the expected text', () async {
    final store = PageStore(dir);
    final page = NotedPage.create(PageMeta.create(id: 'p1', title: 'A', order: 0));
    await store.save(page);
    final text = await store.readText('p1');
    final changed = await store.deleteIfUnchanged(
      'p1',
      text,
      beforeMoveAside: () => File(store.pathFor('p1')).writeAsStringSync('newer'),
    );
    expect(changed.outcome, DeleteOutcome.changed);
    expect(File(store.pathFor('p1')).readAsStringSync(), 'newer');
    File(store.pathFor('p1')).writeAsStringSync(text);
    expect((await store.deleteIfUnchanged('p1', text)).deleted, isTrue);
    expect(File(store.pathFor('p1')).existsSync(), isFalse);
  });
}

void saveNewTextTests() {
  test('PageStore.saveNewText writes the given text byte for byte, never over a file', () async {
    final dir = await Directory.systemTemp.createTemp('noted_snt');
    addTearDown(() => dir.delete(recursive: true));
    final store = PageStore(dir);
    final page = NotedPage.create(PageMeta.create(id: 'p1', title: 'A', order: 0));
    final text = '${writePage(page)}\r\n';
    expect(await store.saveNewText(page, text), isTrue);
    expect(File(store.pathFor('p1')).readAsStringSync(), text);
    expect(await store.saveNewText(page, 'other'), isFalse);
    expect(File(store.pathFor('p1')).readAsStringSync(), text);
  });
}
