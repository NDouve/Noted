// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// A kill at each row of the stage 3 note's table of steps (a test seam
/// throws), then a new engine on the same folders; and the re-path cases.
void main() {
  late Harness h;
  setUp(() async => h = await Harness.create());
  tearDown(() => h.close());

  void seedMany(int n) {
    for (var i = 0; i < n; i++) {
      h.fake.addFile('Noted/p$i.canvas', Harness.b('page $i'));
    }
  }

  Map<String, dynamic> journal() =>
      jsonDecode(File('${h.state.path}/journal.json').readAsStringSync())
          as Map<String, dynamic>;

  Future<void> killed(String step, {int nth = 1}) async {
    h.killAt(step, nth: nth);
    final r = await h.round();
    expect(r.error, isA<Killed>(), reason: 'the seam $step must be reached');
    h.restart();
  }

  group('kill rows', () {
    test('after a delta page, before the delta link: the round restarts from the old token', () async {
      seedMany(3);
      await killed('deltaFetched');
      expect(File('${h.state.path}/journal.json').existsSync(), isFalse);
      expect(h.tree(), isEmpty);
      await h.round();
      expect(h.tree(), hasLength(3));
    });

    test('map and token saved, nothing applied: the diff applies it', () async {
      seedMany(3);
      await killed('mapSaved');
      expect(journal()['deltaLink'], isNotNull);
      expect(h.tree(), isEmpty);
      await h.round();
      expect(h.tree(), hasLength(3));
    });

    test('a download left in tmp is swept at the start', () async {
      seedMany(3);
      await killed('downloaded');
      expect(h.stateFiles('tmp'), hasLength(1));
      await h.round();
      expect(h.stateFiles('tmp'), isEmpty);
      expect(h.tree(), hasLength(3));
    });

    test('a base blob with no record is swept at the end of a round', () async {
      seedMany(3);
      await killed('blobWritten');
      expect(h.stateFiles('base'), hasLength(1));
      expect((journal()['files'] as Map), isEmpty);
      await h.round();
      expect(h.stateFiles('base'), hasLength(3));
    });

    test('inside a replace: the aside is put back at the start, then the diff retries', () async {
      seedMany(3);
      await h.round();
      h.file('p0.canvas').renameSync('${h.path('p0.canvas')}.77-1-2.cas-old');
      h.fake.replaceFile('Noted/p0.canvas', Harness.b('v2'));
      h.restart();
      await h.round();
      expect(h.read('p0.canvas'), 'v2');
      expect(h.tree().where((p) => p.endsWith('.cas-old')), isEmpty);
    });

    test('a verified aside beside a newer file becomes a conflict copy, which is listed', () async {
      seedMany(3);
      await h.round();
      File('${h.path('p0.canvas')}.77-1-2.cas-verified')
          .writeAsStringSync('older');
      h.restart();
      await h.round();
      final copies = h.tree().where((p) => p.contains('-conflict-')).toList();
      expect(copies, hasLength(1));
      expect(h.engine.issues, hasIssue(copies.single));
      expect(h.read('p0.canvas'), 'page 0');
    });

    test('a new file published, journal old: the file is adopted without a download', () async {
      seedMany(3);
      await killed('published');
      expect(h.tree(), hasLength(1));
      await h.round();
      expect(h.tree(), hasLength(3));
      expect(h.contentRequests(), 3);
    });

    test('a changed file replaced, journal old: local equals remote and is adopted', () async {
      seedMany(3);
      await h.round();
      h.fake.replaceFile('Noted/p0.canvas', Harness.b('v2'));
      h.killAt('published');
      final r = await h.round();
      expect(r.error, isA<Killed>());
      expect(h.read('p0.canvas'), 'v2');
      h.restart();
      final before = h.contentRequests();
      await h.round();
      expect(h.contentRequests(), before);
      expect(h.engine.issues, isEmpty);
      h.fake.replaceFile('Noted/p0.canvas', Harness.b('v3'));
      await h.round();
      expect(h.read('p0.canvas'), 'v3');
    });

    test('a delete done, journal old: the record is dropped', () async {
      seedMany(12);
      await h.round();
      h.fake.delete('Noted/p0.canvas');
      await h.round();
      h.clock.advance(const Duration(seconds: 31));
      h.killAt('deleted');
      final r = await h.round();
      expect(r.error, isA<Killed>());
      expect(h.has('p0.canvas'), isFalse);
      h.restart();
      await h.round();
      expect((journal()['files'] as Map).containsKey('p0.canvas'), isFalse);
      expect(h.engine.issues, isEmpty);
    });

    test(
      'guard waiting: nothing deleted, and asked again after a restart',
      () async {
        seedMany(6);
        await h.round();
        for (var i = 0; i < 4; i++) {
          h.fake.delete('Noted/p$i.canvas');
        }
        await h.roundsWithDelay();
        final q = h.engine.guardQuestion;
        expect(q, isNotNull);
        expect(h.tree(), hasLength(6));
        h.restart();
        await h.round();
        expect(h.engine.guardQuestion, q);
        expect(h.tree(), hasLength(6));
      },
    );

    test('a tracked folder deleted but not yet untracked is untracked at the next round', () async {
      h.fake.addFile('Noted/x.canvas', Harness.b('x'));
      h.fake.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
      for (var i = 0; i < 10; i++) {
        h.fake.addFile('Noted/p$i.canvas', Harness.b('$i'));
      }
      await h.round();
      h.fake.delete('Noted/B');
      await h.round();
      h.clock.advance(const Duration(seconds: 31));
      await h.round();
      await h.engine.answerGuard(h.engine.guardQuestion!, remove: true);
      expect((journal()['folders'] as Map).containsKey('b'), isFalse);
    });
  });

  group('re-path', () {
    test('a file renamed remotely moves, and the old name goes', () async {
      seedMany(3);
      h.fake.addFile('Noted/a.canvas', Harness.b('A'));
      await h.round();
      h.fake.rename('Noted/a.canvas', 'b.canvas');
      final r = await h.round();
      expect(h.read('b.canvas'), 'A');
      expect(h.has('a.canvas'), isFalse);
      expect(changedRel(h, r), containsAll(['a.canvas', 'b.canvas']));
      expect((await h.round()).changedPaths, isEmpty);
    });

    test('to an occupied target: both stay, listed, and it completes when the target is cleared', () async {
      seedMany(3);
      h.fake.addFile('Noted/a.canvas', Harness.b('A'));
      await h.round();
      h.write('b.canvas', 'a file of mine');
      h.fake.rename('Noted/a.canvas', 'b.canvas');
      for (var i = 0; i < 2; i++) {
        await h.round();
        expect(h.read('a.canvas'), 'A');
        expect(h.read('b.canvas'), 'a file of mine');
        expect(h.engine.issues, hasIssue('b.canvas'));
      }
      h.file('b.canvas').deleteSync();
      await h.round();
      expect(h.read('b.canvas'), 'A');
      expect(h.has('a.canvas'), isFalse);
    });

    test('a changed file re-pathed and killed after the delete: the move completes with its base', () async {
      seedMany(3);
      h.fake.addFile('Noted/a.canvas', Harness.b('A'));
      await h.round();
      h.write('a.canvas', 'EDITED in Files');
      h.fake.rename('Noted/a.canvas', 'b.canvas');
      await killed('oldDeleted');
      expect(h.has('a.canvas'), isFalse);
      expect(h.read('b.canvas'), 'EDITED in Files');
      await h.round();
      expect(h.read('b.canvas'), 'EDITED in Files');
      final files = journal()['files'] as Map;
      expect(files.containsKey('a.canvas'), isFalse);
      expect(files['b.canvas']['bs'], identityOf('A').sha256);
      expect(h.engine.issues, hasIssue('b.canvas'));
      expect(journal()['moving'], isNull);
    });

    test('re-path copied, old not yet deleted: both exist until the next round finishes it', () async {
      seedMany(3);
      h.fake.addFile('Noted/a.canvas', Harness.b('A'));
      await h.round();
      h.fake.rename('Noted/a.canvas', 'b.canvas');
      await killed('repathCopied');
      expect(h.read('a.canvas'), 'A');
      expect(h.read('b.canvas'), 'A');
      await h.round();
      expect(h.has('a.canvas'), isFalse);
      expect(h.read('b.canvas'), 'A');
    });

    // A kill after `moving` is written (before the old file is deleted),
    // combined with each change made through the Files app.
    group('killed after moving is written, then a change through Files', () {
      Future<void> setUpKilled() async {
        seedMany(3);
        h.fake.addFile('Noted/a.canvas', Harness.b('A'));
        await h.round();
        h.fake.rename('Noted/a.canvas', 'b.canvas');
        await killed('movingWritten');
        expect(journal()['moving'], isNotNull);
        expect(h.read('a.canvas'), 'A');
        expect(h.read('b.canvas'), 'A');
      }

      test(
        'old changed: nothing is deleted, both stay and are listed',
        () async {
          await setUpKilled();
          h.write('a.canvas', 'A edited');
          await h.round();
          expect(h.read('a.canvas'), 'A edited');
          expect(h.read('b.canvas'), 'A');
          expect(h.engine.issues, hasIssue('b.canvas'));
        },
      );

      test('new changed: the edit is kept and the old file stays', () async {
        await setUpKilled();
        h.write('b.canvas', 'B edited');
        await h.round();
        expect(h.read('b.canvas'), 'B edited');
        expect(h.read('a.canvas'), 'A');
        expect(h.engine.issues, hasIssue('b.canvas'));
      });

      test('new deleted, old surviving: the step is redone', () async {
        await setUpKilled();
        h.file('b.canvas').deleteSync();
        await h.round();
        expect(h.read('b.canvas'), 'A');
        expect(h.has('a.canvas'), isFalse);
      });

      test('both gone: the new path is fetched as a new file', () async {
        await setUpKilled();
        h.file('b.canvas').deleteSync();
        h.file('a.canvas').deleteSync();
        await h.round();
        expect(h.read('b.canvas'), 'A');
        expect(h.has('a.canvas'), isFalse);
        expect((journal()['files'] as Map).containsKey('a.canvas'), isFalse);
      });
    });

    test('killed after the old file is deleted, with the new one changed through Files: the edit stays; OneDrive has the old bytes, so nothing is restored', () async {
      seedMany(3);
      h.fake.addFile('Noted/a.canvas', Harness.b('A'));
      await h.round();
      h.fake.rename('Noted/a.canvas', 'b.canvas');
      await killed('oldDeleted');
      h.write('b.canvas', 'B edited');
      await h.round();
      expect(h.read('b.canvas'), 'B edited');
      expect(h.has('a.canvas'), isFalse);
      expect(h.stateFiles('keep'), isEmpty);
      expect(h.engine.issues, hasIssue('b.canvas'));
    });

    test(
      'the same file under a spelling the volume folds only moves the record',
      () async {
        // The old and the new path name one file, so there is nothing to copy
        // or delete. A case-only change keeps the key, so rename to an
        // equal-folding spelling by hand: the engine must not touch the file.
        seedMany(3);
        h.fake.addFile('Noted/a.canvas', Harness.b('A'));
        await h.round();
        h.fake.rename('Noted/a.canvas', 'A.canvas');
        await h.round();
        expect(h.read('a.canvas'), 'A');
        expect(
          h.tree().where((p) => p.toLowerCase() == 'a.canvas'),
          hasLength(1),
        );
      },
    );
  });

  group('a binder renamed', () {
    void seedBinder() {
      seedMany(10);
      h.fake.addFile('Noted/B1/noted-binder.json', Harness.b('{"id":"b"}'));
      h.fake.addFile('Noted/B1/p.canvas', Harness.b('P'));
      h.fake.addFile('Noted/B1/q.canvas', Harness.b('Q'));
      h.fake.addFile('Noted/B1/p.assets/a.bin', Harness.b('AAA'));
    }

    test('part-way: the binder file is moved last, the attachments are copied and their source kept', () async {
      seedBinder();
      await h.round();
      h.fake.rename('Noted/B1', 'B2');
      await killed('oldDeleted');
      expect(h.has('B1/noted-binder.json'), isTrue);
      expect(h.has('B2/noted-binder.json'), isFalse);
      expect(h.has('B2/p.canvas'), isTrue);
      await h.round();
      expect(h.tree().where((p) => p.startsWith('B2/')), [
        'B2/noted-binder.json',
        'B2/p.assets/a.bin',
        'B2/p.canvas',
        'B2/q.canvas',
      ]);
      // Only the attachment source is left behind, with its bytes.
      expect(h.tree().where((p) => p.startsWith('B1/')), ['B1/p.assets/a.bin']);
      expect(h.read('B1/p.assets/a.bin'), 'AAA');
      final files = journal()['files'] as Map;
      expect(files['b1/p.assets/a.bin']['ret'], isTrue);
      expect(files['b2/p.assets/a.bin']['ret'], isFalse);
      h.restart();
      await h.round();
      h.clock.advance(const Duration(minutes: 5));
      await h.round();
      expect(h.read('B1/p.assets/a.bin'), 'AAA');
      expect(h.read('B2/p.assets/a.bin'), 'AAA');
      expect(h.engine.guardQuestion, isNull);
    });

    test('an occupied target holds the whole folder; the hold lifts when it clears', () async {
      seedBinder();
      await h.round();
      h.write('B2/p.canvas', 'something of mine');
      h.fake.rename('Noted/B1', 'B2');
      h.fake.replaceFile('Noted/B2/q.canvas', Harness.b('Q v2'));
      await h.round();
      expect(h.has('B1/noted-binder.json'), isTrue);
      expect(h.has('B1/q.canvas'), isTrue);
      expect(
        h.read('B1/q.canvas'),
        'Q',
        reason: 'no other change applies while held',
      );
      expect(h.read('B2/p.canvas'), 'something of mine');
      expect(h.has('B2/noted-binder.json'), isFalse);
      expect(h.engine.issues, isNotEmpty);
      h.file('B2/p.canvas').deleteSync();
      await h.round();
      expect(h.read('B2/p.canvas'), 'P');
      expect(h.read('B2/q.canvas'), 'Q v2');
      expect(h.has('B2/noted-binder.json'), isTrue);
      expect(h.has('B1/noted-binder.json'), isFalse);
    });

    test('a target occupied after the check leaves that file behind; the binder file still moves', () async {
      seedBinder();
      await h.round();
      h.fake.rename('Noted/B1', 'B2');
      // Occupy q.canvas's target at the moment the first page is copied.
      var done = false;
      h.engine = h.newEngine(
        onStep: (s) {
          if (s == 'repathCopied' && !done) {
            done = true;
            Directory(h.path('B2')).createSync(recursive: true);
            File(h.path('B2/q.canvas')).writeAsStringSync('late arrival');
          }
        },
      );
      await h.round();
      expect(h.read('B2/q.canvas'), 'late arrival');
      expect(h.read('B1/q.canvas'), 'Q');
      expect(h.has('B2/noted-binder.json'), isTrue);
      expect(h.engine.issues, hasIssue('B2/q.canvas'));
      // That file retries alone, with the hold no longer applying.
      h.file('B2/q.canvas').deleteSync();
      await h.round();
      expect(h.read('B2/q.canvas'), 'Q');
      expect(h.has('B1/q.canvas'), isFalse);
    });
  });

  group('locks', () {
    test('no network request is made while a folder lock is held', () async {
      seedMany(3);
      h.fake.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
      h.fake.addFile('Noted/B/q.canvas', Harness.b('Q'));
      var violations = 0;
      h.fake.onRequest = (_) {
        if (h.locks.busyCount != 0) violations++;
      };
      await h.round();
      h.fake.replaceFile('Noted/p0.canvas', Harness.b('v2'));
      h.fake.rename('Noted/B', 'C');
      await h.round();
      expect(violations, 0);
      expect(h.fake.requests, isNotEmpty);
    });

    test('the engine serialises on the shared locks: nothing lands while the folder is held', () async {
      seedMany(2);
      var inside = <String>[];
      await h.locks.run(h.work, () async {
        final round = h.round();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        inside = h.tree();
        // Leave the lock; the round then finishes.
        await Future<void>.value();
        addTearDown(() async => round);
      });
      expect(inside, isEmpty);
      await h.engine.runRound();
      expect(h.tree(), hasLength(2));
    });
  });
}
