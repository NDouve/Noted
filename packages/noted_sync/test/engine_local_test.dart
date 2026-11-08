// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_sync/noted_sync.dart';

import 'harness.dart';

/// G4: a local file that differs from its base, attachments, and a journal
/// that is lost or unreadable.
void main() {
  late Harness h;
  setUp(() async => h = await Harness.create());
  tearDown(() => h.close());

  void seedMany(int n) {
    for (var i = 0; i < n; i++) {
      h.fake.addFile('Noted/p$i.canvas', Harness.b('page $i'));
    }
  }

  group('G4 rows', () {
    test('remote changed, local changed through Files: untouched and listed each round', () async {
      seedMany(3);
      await h.round();
      h.write('p0.canvas', 'edited in Files');
      h.fake.replaceFile('Noted/p0.canvas', Harness.b('remote v2'));
      for (var i = 0; i < 2; i++) {
        final r = await h.round();
        expect(changedRel(h, r), isEmpty);
        expect(h.read('p0.canvas'), 'edited in Files');
        expect(h.engine.issues, hasIssue('p0.canvas'));
      }
    });

    test('remote changed, local changed to exactly the remote: adopted as the base', () async {
      seedMany(3);
      await h.round();
      h.write('p0.canvas', 'remote v2');
      h.fake.replaceFile('Noted/p0.canvas', Harness.b('remote v2'));
      final before = h.contentRequests();
      await h.round();
      expect(h.contentRequests(), before);
      expect(h.engine.issues, isEmpty);
      // It is the base now, so a later remote change applies.
      h.fake.replaceFile('Noted/p0.canvas', Harness.b('remote v3'));
      await h.round();
      expect(h.read('p0.canvas'), 'remote v3');
    });

    test('remote unchanged, local differs or is missing: nothing is done, it is listed', () async {
      seedMany(3);
      await h.round();
      h.write('p0.canvas', 'mine');
      h.file('p1.canvas').deleteSync();
      final r = await h.round();
      expect(changedRel(h, r), isEmpty);
      expect(h.read('p0.canvas'), 'mine');
      expect(h.has('p1.canvas'), isFalse);
      expect(h.engine.issues, hasIssue('p0.canvas'));
      expect(h.engine.issues, hasIssue('p1.canvas'));
    });

    test('new path, file present: equal is adopted, different is untouched and listed', () async {
      h.write('same.canvas', 'S');
      h.write('other.canvas', 'mine');
      h.fake.addFile('Noted/same.canvas', Harness.b('S'));
      h.fake.addFile('Noted/other.canvas', Harness.b('theirs'));
      final r = await h.round();
      expect(h.contentRequests(), 0);
      expect(changedRel(h, r), isEmpty);
      expect(h.read('other.canvas'), 'mine');
      expect(h.engine.issues, hasIssue('other.canvas'));
      expect(h.engine.issues.any((i) => i.path == 'same.canvas'), isFalse);
    });

    test(
      'remote deleted, local changed or no base: untouched and listed',
      () async {
        seedMany(12);
        await h.round();
        h.write('p0.canvas', 'mine');
        h.fake.delete('Noted/p0.canvas');
        await h.roundsWithDelay();
        expect(h.read('p0.canvas'), 'mine');
        expect(h.engine.issues, hasIssue('p0.canvas'));
      },
    );

    test(
      'a lost journal with files present: nothing differing is overwritten',
      () async {
        seedMany(4);
        await h.round();
        h.write('p0.canvas', 'mine');
        File('${h.state.path}/journal.json').deleteSync();
        h.fake.replaceFile('Noted/p1.canvas', Harness.b('remote v2'));
        h.fake.delete('Noted/p2.canvas');
        h.restart();
        await h.round();
        await h.roundsWithDelay();
        expect(h.read('p0.canvas'), 'mine');
        expect(h.read('p1.canvas'), 'page 1', reason: 'no base, so it differs');
        expect(h.has('p2.canvas'), isTrue, reason: 'no base is never deleted');
        expect(h.read('p3.canvas'), 'page 3');
        expect(h.tree().where((p) => p.contains('-remote-')), isEmpty);
        expect(h.engine.issues, hasIssue('p0.canvas'));
      },
    );

    test(
      'files nothing mirrors are ignored, and page-like copies are listed',
      () async {
        seedMany(2);
        await h.round();
        h.write('p0-conflict-1234abcd.canvas', 'c');
        h.write('p0-recovered-1234abcd.canvas', 'r');
        h.write('noted-binder-remote-ab12cd.json', '{}');
        h.write('notes.txt', 'n');
        await h.round();
        expect(h.engine.issues, hasIssue('p0-conflict-1234abcd.canvas'));
        expect(h.engine.issues, hasIssue('p0-recovered-1234abcd.canvas'));
        expect(h.engine.issues, hasIssue('noted-binder-remote-ab12cd.json'));
        expect(h.engine.issues.any((i) => i.path == 'notes.txt'), isFalse);
        expect(h.tree(), hasLength(6));
      },
    );
  });

  group('the journal', () {
    test('an unreadable journal pauses and is never overwritten', () async {
      seedMany(2);
      await h.round();
      final journal = File('${h.state.path}/journal.json');
      journal.writeAsStringSync('{ this is not json');
      h.fake.addFile('Noted/new.canvas', Harness.b('N'));
      h.restart();
      for (var i = 0; i < 2; i++) {
        final r = await h.round();
        expect(r.error, isA<JournalUnreadable>());
        expect(h.engine.status.state, SyncState.journalUnreadable);
        expect(journal.readAsStringSync(), '{ this is not json');
        expect(h.has('new.canvas'), isFalse);
      }
      // Wrong shapes are unreadable too.
      journal.writeAsStringSync('{"v":1}');
      h.restart();
      await h.round();
      expect(h.engine.status.state, SyncState.journalUnreadable);
      expect(journal.readAsStringSync(), '{"v":1}');
    });

    test(
      'journal and blobs live outside the working copy, and blobs are swept',
      () async {
        h.fake.addFile('Noted/a.canvas', Harness.b('A'));
        h.fake.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
        await h.round();
        expect(h.stateFiles('base'), hasLength(2));
        expect(File('${h.state.path}/journal.json').existsSync(), isTrue);
        expect(h.tree().any((p) => p.contains('journal')), isFalse);
        h.fake.replaceFile('Noted/a.canvas', Harness.b('A2'));
        await h.round();
        expect(
          h.stateFiles('base'),
          hasLength(2),
          reason: 'the old base is swept',
        );
      },
    );
  });

  group('attachments', () {
    void seedAttachments(String dir) {
      seedMany(10);
      h.fake.addFile('Noted/$dir/pg.canvas', Harness.b('PAGE'));
      h.fake.addFile('Noted/$dir/pg.assets/a.bin', Harness.b('AAA'));
      h.fake.addFile('Noted/$dir/pg.assets/b.bin', Harness.b('BBB'));
    }

    for (final inBinder in [false, true]) {
      test(
        'a page changed through Files keeps its attachments when they are deleted remotely (${inBinder ? 'in a binder' : 'at the root'})',
        () async {
          if (inBinder) {
            h.fake.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
          }
          final prefix = inBinder ? 'B/' : '';
          seedMany(10);
          h.fake.addFile('Noted/${prefix}pg.canvas', Harness.b('PAGE'));
          h.fake.addFile('Noted/${prefix}pg.assets/a.bin', Harness.b('AAA'));
          h.fake.addFile('Noted/${prefix}pg.assets/b.bin', Harness.b('BBB'));
          await h.round();
          h.write('${prefix}pg.canvas', 'edited in Files');
          h.fake.delete('Noted/${prefix}pg.canvas');
          h.fake.delete('Noted/${prefix}pg.assets');
          await h.roundsWithDelay();
          h.clock.advance(const Duration(minutes: 5));
          await h.round();
          expect(h.read('${prefix}pg.canvas'), 'edited in Files');
          expect(h.read('${prefix}pg.assets/a.bin'), 'AAA');
          expect(h.read('${prefix}pg.assets/b.bin'), 'BBB');
          expect(h.engine.guardQuestion, isNull);
          // Survives a restart and more rounds.
          h.restart();
          await h.round();
          h.clock.advance(const Duration(minutes: 5));
          await h.round();
          expect(h.read('${prefix}pg.assets/a.bin'), 'AAA');
          expect(h.read('${prefix}pg.assets/b.bin'), 'BBB');
        },
      );
    }

    test('a retained attachment that comes back is adopted when equal, listed when different', () async {
      seedAttachments('B');
      h.fake.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
      await h.round();
      h.fake.delete('Noted/B/pg.assets');
      await h.roundsWithDelay();
      expect(h.has('B/pg.assets/a.bin'), isTrue);
      final before = h.contentRequests();
      h.fake.addFile('Noted/B/pg.assets/a.bin', Harness.b('AAA'));
      h.fake.addFile('Noted/B/pg.assets/b.bin', Harness.b('DIFFERENT'));
      await h.round();
      expect(
        h.contentRequests(),
        before,
        reason: 'equal bytes are adopted, not downloaded',
      );
      expect(h.read('B/pg.assets/b.bin'), 'BBB');
      expect(h.engine.issues, hasIssue('B/pg.assets/b.bin'));
    });

    test('a differing attachment is neither replaced nor downloaded again each round', () async {
      seedAttachments('B');
      h.fake.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
      await h.round();
      h.fake.replaceFile(
        'Noted/B/pg.assets/a.bin',
        Harness.b('REMOTE CHANGED'),
      );
      final before = h.contentRequests();
      for (var i = 0; i < 3; i++) {
        await h.round();
      }
      expect(h.contentRequests(), before);
      expect(h.read('B/pg.assets/a.bin'), 'AAA');
      expect(h.engine.issues, hasIssue('B/pg.assets/a.bin'));
    });
  });

  group('folders', () {
    test(
      'a tracked folder removed through Files is listed, not recreated',
      () async {
        h.fake.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
        await h.round();
        Directory(h.path('B')).deleteSync(recursive: true);
        h.fake.addFile('Noted/B/new.canvas', Harness.b('N'));
        await h.round();
        expect(Directory(h.path('B')).existsSync(), isFalse);
        expect(h.engine.issues, hasIssue('B/new.canvas'));
      },
    );

    test(
      'a tracked folder that is gone and no longer wanted is simply untracked',
      () async {
        h.fake.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
        for (var i = 0; i < 10; i++) {
          h.fake.addFile('Noted/p$i.canvas', Harness.b('$i'));
        }
        await h.round();
        h.fake.delete('Noted/B');
        // The folder disappears (as a kill between its delete and the journal).
        Directory(h.path('B')).deleteSync(recursive: true);
        await h.roundsWithDelay();
        await h.round();
        expect(h.engine.issues.where((i) => i.path.startsWith('B')), isEmpty);
      },
    );

    test('an empty tracked folder is removed once nothing needs it', () async {
      h.fake.addFile('Noted/x.assets/a.bin', Harness.b('A'));
      h.fake.addFile('Noted/p.canvas', Harness.b('P'));
      await h.round();
      expect(Directory(h.path('x.assets')).existsSync(), isTrue);
      h.fake.delete('Noted/x.assets');
      await h.roundsWithDelay();
      // Attachments are never deleted, so the folder stays with its file.
      expect(h.has('x.assets/a.bin'), isTrue);
    });

    test(
      'a page whose files are all gone leaves no empty binder folder behind',
      () async {
        h.fake.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
        h.fake.addFile('Noted/B/q.canvas', Harness.b('Q'));
        for (var i = 0; i < 10; i++) {
          h.fake.addFile('Noted/p$i.canvas', Harness.b('$i'));
        }
        await h.round();
        h.fake.delete('Noted/B');
        await h.roundsWithDelay();
        expect(h.engine.guardQuestion, isNotNull);
        await h.engine.answerGuard(h.engine.guardQuestion!, remove: true);
        expect(Directory(h.path('B')).existsSync(), isFalse);
      },
    );
  });

  test(
    'a path holding an aside counts as present: nothing is dropped or restored',
    () async {
      seedMany(12);
      await h.round();
      final aside = '${h.path('p0.canvas')}.1-2-3.cas-old';
      h.file('p0.canvas').renameSync(aside);
      await h.round();
      expect(h.engine.issues.any((i) => i.path == 'p0.canvas'), isTrue);
      h.fake.delete('Noted/p0.canvas');
      await h.roundsWithDelay();
      expect(File(aside).existsSync(), isTrue);
      // At the next start the sweep puts it back, and the delete then applies.
      h.restart();
      await h.round();
      expect(h.has('p0.canvas'), isFalse);
      expect(File(aside).existsSync(), isFalse);
    },
  );
}
