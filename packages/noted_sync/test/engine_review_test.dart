// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_sync/noted_sync.dart';

import 'fake_graph.dart';
import 'harness.dart';

/// What the review of the engine asked for: the journal as untrusted input,
/// address leaks, locks, the identity checks, and item-level errors.
void main() {
  late Harness h;
  setUp(() async => h = await Harness.create());
  tearDown(() => h.close());

  void seedMany(int n) {
    for (var i = 0; i < n; i++) {
      h.fake.addFile('Noted/p$i.canvas', Harness.b('page $i'));
    }
  }

  void seedBinder() {
    seedMany(10);
    h.fake.addFile('Noted/B1/noted-binder.json', Harness.b('{"id":"b"}'));
    h.fake.addFile('Noted/B1/p.canvas', Harness.b('P'));
    h.fake.addFile('Noted/B1/q.canvas', Harness.b('Q'));
    h.fake.addFile('Noted/B1/p.assets/a.bin', Harness.b('AAA'));
  }

  File journalFile() => File('${h.state.path}/journal.json');
  Map<String, dynamic> readJournal() =>
      jsonDecode(journalFile().readAsStringSync()) as Map<String, dynamic>;
  void writeJournal(Map<String, dynamic> j) =>
      journalFile().writeAsStringSync(jsonEncode(j));

  Future<void> killed(String step, {int nth = 1}) async {
    h.killAt(step, nth: nth);
    final r = await h.round();
    expect(r.error, isA<Killed>(), reason: 'the seam $step must be reached');
    h.restart();
  }

  group('the journal is untrusted', () {
    File outside() => File('${h.base.path}/outside.canvas');

    test('a file path that leaves the working copy is unreadable, and nothing outside is deleted', () async {
      seedMany(12);
      await h.round();
      outside().writeAsStringSync('keep me');
      final j = readJournal();
      (j['files'] as Map)['p0.canvas']['path'] = '../outside.canvas';
      (j['files'] as Map)['p0.canvas']['bl'] = 'keep me'.length;
      (j['files'] as Map)['p0.canvas']['bs'] = identityOf('keep me').sha256;
      writeJournal(j);
      h.fake.delete('Noted/p0.canvas');
      h.restart();
      await h.roundsWithDelay();
      expect(h.engine.status.state, SyncState.journalUnreadable);
      expect(outside().readAsStringSync(), 'keep me');
    });

    test('a tracked folder that leaves the working copy is unreadable, and nothing is published outside', () async {
      h.fake.addFile('Noted/b/noted-binder.json', Harness.b('{}'));
      await h.round();
      final j = readJournal();
      (j['folders'] as Map)['b'] = '../evil';
      writeJournal(j);
      Directory('${h.base.path}/evil').createSync();
      h.fake.addFile('Noted/b/new.canvas', Harness.b('N'));
      h.restart();
      await h.round();
      expect(h.engine.status.state, SyncState.journalUnreadable);
      expect(Directory('${h.base.path}/evil').listSync(), isEmpty);
    });

    for (final bad in [
      '../x.canvas',
      '/abs.canvas',
      r'a\b.canvas',
      'a//b',
      '',
      'C:evil',
    ]) {
      test('a moving path "$bad" is unreadable', () async {
        seedMany(3);
        await h.round();
        final j = readJournal();
        j['moving'] = {
          'ok': 'p0.canvas',
          'op': bad,
          'nk': 'p1.canvas',
          'np': 'p1.canvas',
          'len': 1,
          'sha': 'ab',
        };
        writeJournal(j);
        h.restart();
        await h.round();
        expect(h.engine.status.state, SyncState.journalUnreadable);
        expect(readJournal()['moving'], isNotNull, reason: 'never overwritten');
      });
    }

    test('wrong-typed values are unreadable, not a crash later', () async {
      seedMany(2);
      await h.round();
      for (final edit in <void Function(Map<String, dynamic>)>[
        (j) => j['kept'] = [1, 2],
        (j) => j['folders'] = {'a': 5},
        (j) => j['firstSeen'] = {'a': 'x'},
        (j) => j['mismatches'] = {'a': 'x'},
        (j) => j['approved'] = [3],
        (j) => j['deltaLink'] = 'not a link',
      ]) {
        final j = readJournal();
        edit(j);
        final text = jsonEncode(j);
        journalFile().writeAsStringSync(text);
        h.restart();
        final r = await h.round();
        expect(r.error, isA<JournalUnreadable>(), reason: text);
        expect('${r.error}', isNot(contains('not a link')));
        expect(journalFile().readAsStringSync(), text);
      }
    });
  });

  group('addresses are not leaked', () {
    test('a lost download behind a redirect with a signed address shows no address', () async {
      final id = h.fake.addFile('Noted/a.canvas', Harness.b('A'));
      h.fake.redirectTo = '${h.fake.origin}/storage/$id/1?sig=SECRETSIG';
      h.fake.fail('/storage/', lose: true);
      final r = await h.round();
      expect(r.error, isNotNull);
      expect('${r.error}', isNot(contains('SECRETSIG')));
      expect('${h.engine.status}', isNot(contains('SECRETSIG')));
      expect('${h.engine.status}', isNot(contains('127.0.0.1')));
    });

    test('a lost delta page shows no address either', () async {
      seedMany(1);
      h.fake.fail('/delta', lose: true);
      final r = await h.round();
      expect('${r.error}', isNot(contains('127.0.0.1')));
      expect('${h.engine.status}', isNot(contains('delta')));
    });

    test(
      'an unparsable redirect target is a refused link, not a format error',
      () async {
        final id = h.fake.addFile('Noted/a.canvas', Harness.b('A'));
        h.fake.redirectTo = 'http://[bad';
        final r = await h.round();
        expect(r.error, isA<GraphRefusedLink>());
        expect(id, isNotEmpty);
      },
    );
  });

  group('attachments are never deleted by a move', () {
    test(
      'an attachment moved to a non-attachment path keeps its source',
      () async {
        seedMany(3);
        h.fake.addFile('Noted/p.assets/a.bin', Harness.b('AAA'));
        h.fake.addFolder('Noted/templates');
        await h.round();
        h.fake.move('Noted/p.assets/a.bin', 'Noted/templates');
        await h.round();
        expect(h.read('p.assets/a.bin'), 'AAA');
        expect(h.read('templates/a.bin'), 'AAA');
      },
    );
  });

  group('a binder rename killed part-way', () {
    for (final (step, nth) in [('repathCopied', 2), ('movingWritten', 1)]) {
      test(
        'at $step: the copy the engine made is not "a different file"',
        () async {
          seedBinder();
          await h.round();
          h.fake.rename('Noted/B1', 'B2');
          await killed(step, nth: nth);
          expect(h.has('B1/noted-binder.json'), isTrue);
          await h.round();
          expect(h.has('B2/noted-binder.json'), isTrue);
          expect(h.read('B2/p.canvas'), 'P');
          expect(h.read('B2/q.canvas'), 'Q');
          expect(h.has('B1/p.canvas'), isFalse);
          expect(h.has('B1/noted-binder.json'), isFalse);
          expect(h.engine.issues, isEmpty);
        },
      );
    }

    test('a failed compare-and-delete (the old page edited just before) leaves both, lists the old, and the binder file still moves', () async {
      seedBinder();
      await h.round();
      h.fake.rename('Noted/B1', 'B2');
      h.engine = h.newEngine(
        onStep: (s) {
          if (s == 'movingWritten') {
            h.write('B1/p.canvas', 'edited in Files');
          }
        },
      );
      await h.round();
      expect(h.read('B1/p.canvas'), 'edited in Files');
      expect(h.read('B2/p.canvas'), 'P');
      expect(h.has('B2/noted-binder.json'), isTrue);
      expect(h.engine.issues, hasIssue('B1/p.canvas'));
      expect(readJournal()['moving'], isNull);
    });
  });

  group('the identity checks hold', () {
    test(
      'a file edited through Files after the download is not replaced',
      () async {
        seedMany(3);
        await h.round();
        h.fake.replaceFile('Noted/p0.canvas', Harness.b('remote v2'));
        h.engine = h.newEngine(
          onStep: (s) {
            if (s == 'downloaded') h.write('p0.canvas', 'edited meanwhile');
          },
        );
        await h.round();
        expect(h.read('p0.canvas'), 'edited meanwhile');
        expect(h.engine.issues, hasIssue('p0.canvas'));
        expect(h.tree().where((p) => p.contains('.cas-')), isEmpty);
      },
    );

    test(
      'an old page edited after it was copied is not deleted by the re-path',
      () async {
        seedMany(3);
        h.fake.addFile('Noted/a.canvas', Harness.b('A'));
        await h.round();
        h.fake.rename('Noted/a.canvas', 'b.canvas');
        h.engine = h.newEngine(
          onStep: (s) {
            if (s == 'movingWritten') h.write('a.canvas', 'A edited late');
          },
        );
        await h.round();
        expect(h.read('a.canvas'), 'A edited late');
        expect(h.read('b.canvas'), 'A');
        expect(h.engine.issues, hasIssue('a.canvas'));
      },
    );

    test('a replace that throws after the page was set aside gets it back by a sweep', () async {
      seedMany(3);
      await h.round();
      h.fake.replaceFile('Noted/p0.canvas', Harness.b('v2'));
      h.engine = h.newEngine(
        onStep: (s) {
          if (s == 'replaceBeforePublish' || s == 'replaceBeforeRestore') {
            throw const FileSystemException('injected');
          }
        },
      );
      await h.round();
      expect(h.read('p0.canvas'), 'page 0');
      expect(h.tree().where((p) => p.contains('.cas-')), isEmpty);
      expect(h.engine.issues, hasIssue('p0.canvas'));
    });

    test('a delete that throws after the page was set aside gets it back by a sweep', () async {
      seedMany(12);
      await h.round();
      h.fake.delete('Noted/p0.canvas');
      await h.round();
      h.clock.advance(const Duration(seconds: 31));
      h.engine = h.newEngine(
        onStep: (s) {
          if (s == 'deleteBeforeDelete' || s == 'deleteBeforeRestore') {
            throw const FileSystemException('injected');
          }
        },
      );
      await h.round();
      expect(h.read('p0.canvas'), 'page 0');
      expect(h.tree().where((p) => p.contains('.cas-')), isEmpty);
    });
  });

  group('the binder folder lock', () {
    test(
      'blocks a publish into the binder and into its assets folder',
      () async {
        h.fake.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
        await h.round();
        h.fake.addFile('Noted/B/x.canvas', Harness.b('X'));
        h.fake.addFile('Noted/B/x.assets/a.bin', Harness.b('A'));
        Future<RoundResult>? round;
        var during = <String>[];
        await h.locks.run(Directory(h.path('B')), () async {
          round = h.round();
          await Future<void>.delayed(const Duration(milliseconds: 400));
          during = h.tree();
        });
        expect(during, ['B/noted-binder.json']);
        await round;
        expect(h.tree(), contains('B/x.canvas'));
        expect(h.tree(), contains('B/x.assets/a.bin'));
      },
    );

    test('a file left behind after the binder file moved still uses the binder lock', () async {
      seedBinder();
      await h.round();
      h.fake.rename('Noted/B1', 'B2');
      var done = false;
      h.engine = h.newEngine(
        onStep: (s) {
          if (s == 'repathCopied' && !done) {
            done = true;
            File(h.path('B2/q.canvas')).writeAsStringSync('late arrival');
          }
        },
      );
      await h.round();
      expect(h.has('B2/noted-binder.json'), isTrue);
      expect(h.read('B1/q.canvas'), 'Q');
      expect(h.has('B1/noted-binder.json'), isFalse);
      h.restart();
      h.file('B2/q.canvas').deleteSync();
      Future<RoundResult>? round;
      await h.locks.run(Directory(h.path('B1')), () async {
        round = h.round();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(h.has('B1/q.canvas'), isTrue, reason: 'its delete waits');
      });
      await round;
      expect(h.has('B1/q.canvas'), isFalse);
      expect(h.read('B2/q.canvas'), 'Q');
    });

    test('removing a folder uses the binder lock, and the old page delete waits for it', () async {
      seedBinder();
      await h.round();
      h.fake.rename('Noted/B1', 'B2');
      Future<RoundResult>? round;
      await h.locks.run(Directory(h.path('B1')), () async {
        round = h.round();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(h.has('B1/q.canvas'), isTrue, reason: 'its delete waits');
        expect(h.has('B1/noted-binder.json'), isTrue);
      });
      await round;
      expect(h.has('B1/q.canvas'), isFalse);
      expect(h.has('B2/noted-binder.json'), isTrue);
    });
  });

  group('item-level errors', () {
    test(
      'a permanent 403 on one file lists it and the round goes on',
      () async {
        seedMany(3);
        final bad = h.fake.idOf('Noted/p1.canvas');
        h.fake.fail('/items/$bad/content', status: 403, times: 100);
        final r = await h.round();
        expect(r.error, isNull);
        expect(h.has('p0.canvas'), isTrue);
        expect(h.has('p2.canvas'), isTrue);
        expect(h.has('p1.canvas'), isFalse);
        expect(h.engine.issues, hasIssue('p1.canvas'));
        expect(h.engine.status.state, SyncState.idle);
      },
    );

    test('a 401 ends the round', () async {
      seedMany(2);
      final g = GraphClient(
        origin: h.fake.origin,
        clock: h.clock,
        token: ({bool forceRefresh = false}) async => 'wrong',
      );
      final e = PullEngine(
        workingCopy: h.work,
        stateDir: h.state,
        locks: h.locks,
        graph: g,
        driveId: FakeGraph.driveId,
        rootItemId: h.rootId,
        clock: h.clock,
      );
      final r = await e.runRound();
      expect(r.error, isNotNull);
      expect(e.status.state, SyncState.signedOut);
    });
  });

  group('odd items in delta', () {
    test('a live item with no parent keeps its known parent; an unknown one fails the round', () async {
      seedMany(10);
      await h.round();
      final id = h.fake.idOf('Noted/p0.canvas');
      h.fake.noParentRef.add(id);
      h.fake.touch('Noted/p0.canvas');
      await h.roundsWithDelay();
      expect(h.has('p0.canvas'), isTrue);
      final r0 = readJournal();
      expect((r0['map'] as Map)[id]['p'], h.rootId);
      // An unknown one.
      h.fake.noParentRef.add('NOPARENT1');
      h.fake.addFile('Noted/new.canvas', Harness.b('N'), id: 'NOPARENT1');
      final r = await h.round();
      expect(r.error, isA<GraphException>());
      expect(h.has('new.canvas'), isFalse);
    });

    test('shortcuts and packages are listed and never fetched', () async {
      seedMany(2);
      h.fake.addSpecial('Noted/short.canvas', 'remoteItem');
      h.fake.addSpecial('Noted/book.canvas', 'package');
      final r = await h.round();
      expect(r.error, isNull);
      expect(h.has('short.canvas'), isFalse);
      expect(h.has('book.canvas'), isFalse);
      expect(h.engine.issues, hasIssue('short.canvas'));
      expect(h.engine.issues, hasIssue('book.canvas'));
      expect(h.contentRequests(), 2);
    });

    test(
      'business and consumer shapes: no cTag, function-form links, paging',
      () async {
        h.fake
          ..omitCTag = true
          ..functionLinks = true
          ..pageSize = 2;
        seedMany(5);
        final r0 = await h.round();
        expect(r0.error, isNull);
        expect(h.tree(), hasLength(5));
        h.fake.replaceFile('Noted/p0.canvas', Harness.b('v2'));
        h.fake.addFile('Noted/p9.canvas', Harness.b('9'));
        await h.round();
        expect(h.read('p0.canvas'), 'v2');
        expect(h.read('p9.canvas'), '9');
      },
    );

    test(
      'a 404 on the folder delta falls back to the drive-root delta',
      () async {
        seedMany(2);
        h.fake.addFile('Other/x.canvas', Harness.b('not ours'));
        h.fake.folderDeltaNotFound = true;
        final r = await h.round();
        expect(r.error, isNull);
        expect(h.tree(), ['p0.canvas', 'p1.canvas']);
        expect(readJournal()['endpoint'], 'drive');
      },
    );
  });

  group('held and stranded', () {
    test('a swap waits and is listed, and nothing is applied to it', () async {
      seedMany(10);
      h.fake.addFile('Noted/a.canvas', Harness.b('A'));
      h.fake.addFile('Noted/b.canvas', Harness.b('B'));
      await h.round();
      h.fake.rename('Noted/a.canvas', 'tmp.canvas');
      h.fake.rename('Noted/b.canvas', 'a.canvas');
      h.fake.rename('Noted/tmp.canvas', 'b.canvas');
      await h.round();
      expect(h.read('a.canvas'), 'A');
      expect(h.read('b.canvas'), 'B');
      expect(h.engine.issues, isNotEmpty);
    });

    test('a lasting delete under a held binder folder waits', () async {
      seedBinder();
      await h.round();
      h.write('B2/p.canvas', 'in the way');
      h.fake.rename('Noted/B1', 'B2');
      h.fake.delete('Noted/B2/q.canvas');
      await h.roundsWithDelay();
      await h.round();
      expect(h.read('B1/q.canvas'), 'Q');
      expect(h.engine.guardQuestion, isNull);
    });

    test('a re-path never publishes over a path that holds an aside', () async {
      seedMany(3);
      h.fake.addFile('Noted/a.canvas', Harness.b('A'));
      await h.round();
      File('${h.path('b.canvas')}.9-9-9.cas-old').writeAsStringSync('older b');
      h.fake.rename('Noted/a.canvas', 'b.canvas');
      await h.round();
      expect(h.read('a.canvas'), 'A');
      expect(h.has('b.canvas'), isFalse);
      expect(h.engine.issues.any((i) => i.path == 'b.canvas'), isTrue);
    });
  });

  group('ordinary changes are not held', () {
    test('a file renamed to a -PC copy while a new item takes its name applies both', () async {
      seedMany(10);
      h.fake.addFile('Noted/x.canvas', Harness.b('X old'));
      await h.round();
      h.fake.rename('Noted/x.canvas', 'x-PC.canvas');
      h.fake.addFile('Noted/x.canvas', Harness.b('X new'));
      for (var i = 0; i < 3; i++) {
        final r = await h.round();
        expect(r.error, isNull);
        h.clock.advance(const Duration(seconds: 31));
      }
      expect(h.read('x.canvas'), 'X new');
      expect(h.read('x-PC.canvas'), 'X old');
      expect(h.engine.issues, isEmpty);
    });

    test(
      'a deleted name taken over by a rename applies, and the old name goes',
      () async {
        seedMany(10);
        h.fake.addFile('Noted/a.canvas', Harness.b('A'));
        h.fake.addFile('Noted/b.canvas', Harness.b('B'));
        await h.round();
        h.fake.delete('Noted/b.canvas');
        h.fake.rename('Noted/a.canvas', 'b.canvas');
        for (var i = 0; i < 4; i++) {
          await h.round();
          h.clock.advance(const Duration(seconds: 31));
        }
        expect(h.read('b.canvas'), 'A');
        expect(h.has('a.canvas'), isFalse);
        expect(h.engine.issues, isEmpty);
      },
    );

    test('a chain of renames resolves over rounds', () async {
      seedMany(10);
      h.fake.addFile('Noted/a.canvas', Harness.b('A'));
      h.fake.addFile('Noted/b.canvas', Harness.b('B'));
      await h.round();
      h.fake.rename('Noted/b.canvas', 'c.canvas');
      h.fake.rename('Noted/a.canvas', 'b.canvas');
      for (var i = 0; i < 3; i++) {
        await h.round();
      }
      expect(h.read('c.canvas'), 'B');
      expect(h.read('b.canvas'), 'A');
      expect(h.has('a.canvas'), isFalse);
      expect(h.engine.issues, isEmpty);
    });

    test('a pending move is listed in every round', () async {
      seedMany(10);
      h.fake.addFile('Noted/a.canvas', Harness.b('A'));
      h.fake.addFile('Noted/b.canvas', Harness.b('B'));
      await h.round();
      h.fake.rename('Noted/a.canvas', 'tmp.canvas');
      h.fake.rename('Noted/b.canvas', 'a.canvas');
      h.fake.rename('Noted/tmp.canvas', 'b.canvas');
      for (var i = 0; i < 3; i++) {
        await h.round();
        expect(h.engine.issues, hasIssue('a.canvas'));
        expect(h.engine.issues, hasIssue('b.canvas'));
      }
    });
  });

  group('surviving mutants and the identical-files case', () {
    test('identical a and b, b removed here, then b deleted and a renamed to b: a stays and is listed', () async {
      seedMany(10);
      h.fake.addFile('Noted/a.canvas', Harness.b('SAME'));
      h.fake.addFile('Noted/b.canvas', Harness.b('SAME'));
      await h.round();
      h.file('b.canvas').deleteSync();
      h.fake.delete('Noted/b.canvas');
      h.fake.rename('Noted/a.canvas', 'b.canvas');
      for (var i = 0; i < 4; i++) {
        await h.round();
        h.clock.advance(const Duration(seconds: 31));
      }
      expect(h.read('a.canvas'), 'SAME', reason: 'the only copy stays');
      expect(h.has('b.canvas'), isFalse);
      expect(h.engine.issues, hasIssue('a.canvas'));
      expect(h.engine.issues, hasIssue('b.canvas'));
    });

    test('a binder rename goes on when an old page is absent here and its target is taken', () async {
      seedBinder();
      await h.round();
      h.file('B1/q.canvas').deleteSync();
      h.write('B2/q.canvas', 'mine');
      h.fake.rename('Noted/B1', 'B2');
      await h.round();
      expect(h.has('B2/noted-binder.json'), isTrue);
      expect(h.read('B2/q.canvas'), 'mine');
      expect(h.read('B2/p.canvas'), 'P');
    });

    test('a root-level Templates folder (not the exact name) is a binder folder for locks', () async {
      h.fake.addFile('Noted/Templates/noted-binder.json', Harness.b('{}'));
      await h.round();
      h.fake.addFile('Noted/Templates/x.canvas', Harness.b('X'));
      Future<RoundResult>? round;
      var during = <String>[];
      await h.locks.run(Directory(h.path('Templates')), () async {
        round = h.round();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        during = h.tree();
      });
      expect(during, ['Templates/noted-binder.json']);
      await round;
      expect(h.has('Templates/x.canvas'), isTrue);
    });
  });

  group('more checks', () {
    test('a known item with no parent keeps it, without an error', () async {
      seedMany(10);
      await h.round();
      final id = h.fake.idOf('Noted/p0.canvas');
      h.fake.noParentRef.add(id);
      h.fake.replaceFile('Noted/p0.canvas', Harness.b('v2'));
      final r = await h.round();
      expect(r.error, isNull);
      expect(h.read('p0.canvas'), 'v2');
      expect(h.engine.status.state, SyncState.idle);
    });

    test('a 401 on a download ends the round as signed out', () async {
      seedMany(2);
      h.fake.fail('/content', status: 401, times: 100);
      final r = await h.round();
      expect(r.error, isNotNull);
      expect(h.engine.status.state, SyncState.signedOut);
    });

    test('a 429 on a download that does not clear ends the round', () async {
      seedMany(2);
      h.fake.fail('/content', status: 429, retryAfter: '1', times: 100);
      final r = await h.round();
      expect(r.error, isA<GraphThrottled>());
      expect(h.engine.status.state, SyncState.paused);
    });

    test(
      'the root lock blocks a publish into a root-level assets folder',
      () async {
        seedMany(2);
        await h.round();
        h.fake.addFile('Noted/x.assets/a.bin', Harness.b('A'));
        Future<RoundResult>? round;
        var during = <String>[];
        await h.locks.run(h.work, () async {
          round = h.round();
          await Future<void>.delayed(const Duration(milliseconds: 400));
          during = h.tree();
        });
        expect(during, ['p0.canvas', 'p1.canvas']);
        await round;
        expect(h.has('x.assets/a.bin'), isTrue);
      },
    );

    test(
      'a root deleted between the seed and the folder delta pauses at the root',
      () async {
        seedMany(2);
        h.fake.folderDeltaNotFound = true;
        h.fake.onRequest = (path) {
          if (path.endsWith('/delta')) h.fake.delete('Noted');
        };
        await h.round();
        expect(h.engine.status.state, SyncState.rootGone);
        expect(h.engine.guardQuestion, isNull);
      },
    );

    test('shared-folder shortcuts are left out of the picker', () async {
      h.fake.addSpecial('Share', 'remoteItem');
      h.fake.items[h.fake.idOf('Share')]!.folder = true;
      h.fake.addFolder('Mine');
      final folders = await h.newGraph().listFolders();
      expect(folders.map((f) => f.name), ['Mine', 'Noted']);
    });
  });

  group('bookkeeping', () {
    test('mismatch counts for a path that left the plan are dropped', () async {
      final id = h.fake.addFile('Noted/a.canvas', Harness.b('AAA'));
      h.fake.corruptContent = true;
      for (var i = 0; i < 3; i++) {
        await h.round();
      }
      expect(h.engine.status.state, SyncState.paused);
      h.fake.delete('Noted/a.canvas');
      await h.round();
      expect(h.engine.status.state, SyncState.idle);
      expect(readJournal()['mismatches'], isEmpty);
      expect(id, isNotEmpty);
    });

    test('files under a tracked folder removed through Files are not downloaded each poll', () async {
      h.fake.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
      await h.round();
      Directory(h.path('B')).deleteSync(recursive: true);
      for (var i = 0; i < 3; i++) {
        h.fake.addFile('Noted/B/n$i.canvas', Harness.b('$i'));
      }
      await h.round();
      final before = h.contentRequests();
      await h.round();
      await h.round();
      expect(h.contentRequests(), before);
      expect(h.engine.issues, hasIssue('B/n0.canvas'));
    });

    test(
      'an answer while a round runs is applied once and does not race',
      () async {
        seedMany(6);
        await h.round();
        for (var i = 0; i < 4; i++) {
          h.fake.delete('Noted/p$i.canvas');
        }
        await h.roundsWithDelay();
        final q = h.engine.guardQuestion!;
        final a = h.engine.answerGuard(q, remove: true);
        final r = h.round();
        await Future.wait([a, r]);
        await h.round();
        expect(h.tree(), ['p4.canvas', 'p5.canvas']);
        expect(h.engine.guardQuestion, isNull);
      },
    );
  });
}
