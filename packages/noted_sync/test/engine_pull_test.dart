// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_sync/noted_sync.dart';

import 'fake_graph.dart';
import 'harness.dart';

void main() {
  late Harness h;
  setUp(() async => h = await Harness.create());
  tearDown(() => h.close());

  void seedMany(int n) {
    for (var i = 0; i < n; i++) {
      h.fake.addFile('Noted/p$i.canvas', Harness.b('page $i'));
    }
  }

  group('first sync and polls', () {
    test('mirrors pages, binders, attachments and templates only', () async {
      h.fake.addFile('Noted/a.canvas', Harness.b('A'));
      h.fake.addFile('Noted/a.assets/img.png', Harness.b('IMG'));
      h.fake.addFile('Noted/templates/t.canvas', Harness.b('T'));
      h.fake.addFile('Noted/B1/noted-binder.json', Harness.b('{}'));
      h.fake.addFile('Noted/B1/b.canvas', Harness.b('B'));
      h.fake.addFile('Noted/B1/b.assets/x.bin', Harness.b('X'));
      // Not mirrored.
      h.fake.addFile('Noted/notes.txt', Harness.b('txt'));
      h.fake.addFile('Noted/a-remote-0123abcd.canvas', Harness.b('copy'));
      h.fake.addFile('Noted/a.canvas.tmp', Harness.b('tmp'));
      h.fake.addFile('Noted/Plain/p.canvas', Harness.b('P'));
      h.fake.addFile('Noted/noted-binder.json', Harness.b('{}'));
      final r = await h.round();
      expect(r.error, isNull);
      expect(h.engine.status.state, SyncState.idle);
      expect(h.tree(), [
        'B1/b.assets/x.bin',
        'B1/b.canvas',
        'B1/noted-binder.json',
        'a.assets/img.png',
        'a.canvas',
        'templates/t.canvas',
      ]);
      expect(h.read('a.canvas'), 'A');
      expect(r.anyBinderChange, isTrue);
      expect(changedRel(h, r), contains('B1/b.canvas'));
      expect(h.issueText().join('\n'), contains('noted-binder.json'));
    });

    test('a quiet poll downloads nothing and changes nothing', () async {
      seedMany(3);
      await h.round();
      final before = h.contentRequests();
      final r = await h.round();
      expect(h.contentRequests(), before);
      expect(r.changedPaths, isEmpty);
    });

    test(
      'rounds never overlap: a call during a round returns the running one',
      () async {
        seedMany(2);
        final a = h.engine.runRound();
        final b = h.engine.runRound();
        expect(identical(a, b), isTrue);
        await a;
      },
    );

    test(
      'works over delta pages, children first, a duplicate and no root item',
      () async {
        seedMany(6);
        h.fake.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
        h.fake.addFile('Noted/B/q.canvas', Harness.b('Q'));
        h.fake
          ..pageSize = 2
          ..childrenFirst = true
          ..duplicateItems = true
          ..omitRootInDelta = true;
        final r = await h.round();
        expect(r.error, isNull);
        expect(h.tree(), hasLength(8));
      },
    );

    test(
      'the drive-root delta is used when the folder form is not supported',
      () async {
        seedMany(2);
        h.fake.addFile('Other/x.canvas', Harness.b('not ours'));
        h.fake.folderDeltaSupported = false;
        final r = await h.round();
        expect(r.error, isNull);
        expect(h.tree(), ['p0.canvas', 'p1.canvas']);
        h.fake.addFile('Noted/p2.canvas', Harness.b('new'));
        h.fake.addFile('Other/y.canvas', Harness.b('not ours either'));
        await h.round();
        expect(h.tree(), ['p0.canvas', 'p1.canvas', 'p2.canvas']);
      },
    );

    test('an item with no hash and a size is listed, not applied', () async {
      h.fake.addFile('Noted/a.canvas', Harness.b('A'));
      h.fake.includeHashes = false;
      await h.round();
      expect(h.has('a.canvas'), isFalse);
      expect(h.engine.issues, hasIssue('a.canvas'));
    });
  });

  group('remote changes', () {
    test('a changed file replaces the local one', () async {
      seedMany(2);
      await h.round();
      h.fake.replaceFile('Noted/p0.canvas', Harness.b('page 0 v2'));
      final r = await h.round();
      expect(h.read('p0.canvas'), 'page 0 v2');
      expect(changedRel(h, r), ['p0.canvas']);
    });

    test('an id-changing replace, with or without a name on the delete, is a content change', () async {
      seedMany(6);
      await h.round();
      h.fake.replaceFile('Noted/p0.canvas', Harness.b('v2'), newId: true);
      h.fake.replaceFile(
        'Noted/p1.canvas',
        Harness.b('v2b'),
        newId: true,
        withName: false,
      );
      await h.round();
      h.clock.advance(const Duration(seconds: 60));
      await h.round();
      expect(h.read('p0.canvas'), 'v2');
      expect(h.read('p1.canvas'), 'v2b');
      expect(h.engine.issues, isEmpty);
    });

    test('a delete takes effect only when planned again 30 s later', () async {
      seedMany(8);
      await h.round();
      h.fake.delete('Noted/p0.canvas');
      await h.round();
      expect(h.has('p0.canvas'), isTrue);
      h.clock.advance(const Duration(seconds: 20));
      await h.round();
      expect(h.has('p0.canvas'), isTrue);
      h.clock.advance(const Duration(seconds: 11));
      final r = await h.round();
      expect(h.has('p0.canvas'), isFalse);
      expect(changedRel(h, r), ['p0.canvas']);
    });

    test(
      'a brief absence between a delete and a re-create removes nothing',
      () async {
        seedMany(8);
        await h.round();
        h.fake.delete('Noted/p0.canvas', withName: true);
        await h.round();
        h.clock.advance(const Duration(seconds: 10));
        h.fake.addFile('Noted/p0.canvas', Harness.b('back, new id'));
        await h.round();
        h.clock.advance(const Duration(seconds: 60));
        await h.round();
        expect(h.read('p0.canvas'), 'back, new id');
      },
    );

    test(
      'a folder rename without descendants moves the binder, its file last',
      () async {
        h.fake.addFile('Noted/B1/noted-binder.json', Harness.b('{"id":"b"}'));
        h.fake.addFile('Noted/B1/a.canvas', Harness.b('A'));
        h.fake.addFile('Noted/B1/a.assets/i.png', Harness.b('I'));
        await h.round();
        h.fake.rename('Noted/B1', 'Renamed');
        final order = <String>[];
        h.engine = h.newEngine(
          onStep: (s) {
            if (s == 'oldDeleted') order.add(s);
          },
        );
        final r = await h.round();
        expect(h.tree(), contains('Renamed/noted-binder.json'));
        expect(h.tree(), contains('Renamed/a.canvas'));
        expect(h.tree(), contains('Renamed/a.assets/i.png'));
        expect(h.has('B1/noted-binder.json'), isFalse);
        expect(h.has('B1/a.canvas'), isFalse);
        // The attachment's source stays (it is never deleted by a pull).
        expect(h.has('B1/a.assets/i.png'), isTrue);
        expect(r.anyBinderChange, isTrue);
        // The binder file moved after the page.
        final paths = changedRel(h, r);
        expect(
          paths.indexOf('Renamed/a.canvas'),
          allOf(
            isNonNegative,
            lessThan(paths.indexOf('Renamed/noted-binder.json')),
          ),
        );
        // Settled: a further round does nothing.
        final again = await h.round();
        expect(again.changedPaths, isEmpty);
      },
    );

    test('a case-only rename of a folder keeps the disk name and new files go in it', () async {
      h.fake.addFile('Noted/Notes/noted-binder.json', Harness.b('{}'));
      await h.round();
      h.fake.rename('Noted/Notes', 'notes');
      h.fake.addFile('Noted/notes/new.canvas', Harness.b('N'));
      await h.round();
      final names = [
        for (final e in h.work.listSync()) e.path.split(RegExp(r'[\\/]')).last,
      ];
      expect(names, ['Notes']);
      expect(h.read('Notes/new.canvas'), 'N');
    });
  });

  group('the guard', () {
    test('a whole binder removed asks, and Remove applies', () async {
      seedMany(30);
      h.fake.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
      h.fake.addFile('Noted/B/q.canvas', Harness.b('Q'));
      await h.round();
      h.fake.delete('Noted/B');
      await h.round();
      h.clock.advance(const Duration(seconds: 31));
      await h.round();
      expect(h.engine.status.state, SyncState.guardWaiting);
      final q = h.engine.guardQuestion!;
      expect(q.paths, ['B/noted-binder.json', 'B/q.canvas']);
      expect(h.has('B/q.canvas'), isTrue);
      // Asked again while waiting, and still nothing deleted.
      await h.round();
      expect(h.engine.guardQuestion, q);
      expect(h.has('B/q.canvas'), isTrue);
      await h.engine.answerGuard(q, remove: true);
      expect(h.has('B/q.canvas'), isFalse);
      expect(h.has('B/noted-binder.json'), isFalse);
      expect(h.engine.guardQuestion, isNull);
      expect(h.engine.status.state, SyncState.idle);
      expect(Directory(h.path('B')).existsSync(), isFalse);
    });

    test('Keep leaves them and does not ask again', () async {
      seedMany(30);
      h.fake.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
      h.fake.addFile('Noted/B/q.canvas', Harness.b('Q'));
      await h.round();
      h.fake.delete('Noted/B');
      await h.round();
      h.clock.advance(const Duration(seconds: 31));
      await h.round();
      await h.engine.answerGuard(h.engine.guardQuestion!, remove: false);
      expect(h.has('B/q.canvas'), isTrue);
      h.clock.advance(const Duration(seconds: 90));
      await h.round();
      expect(h.engine.guardQuestion, isNull);
      expect(h.has('B/q.canvas'), isTrue);
      // A restart keeps the choice.
      h.restart();
      await h.round();
      expect(h.engine.guardQuestion, isNull);
      expect(h.has('B/noted-binder.json'), isTrue);
    });

    test(
      'more than 20 percent of the pages asks; many attachments do not count',
      () async {
        seedMany(12);
        for (var i = 0; i < 40; i++) {
          h.fake.addFile('Noted/p0.assets/a$i.bin', Harness.b('att $i'));
        }
        await h.round();
        // Two of twelve pages: under the threshold.
        h.fake.delete('Noted/p0.canvas');
        h.fake.delete('Noted/p1.canvas');
        await h.roundsWithDelay();
        expect(h.engine.guardQuestion, isNull);
        expect(h.has('p0.canvas'), isFalse);
        expect(h.has('p1.canvas'), isFalse);
        // Deleting every attachment asks nothing and removes nothing.
        h.fake.delete('Noted/p0.assets');
        await h.roundsWithDelay();
        expect(h.engine.guardQuestion, isNull);
        expect(
          h.tree().where((p) => p.startsWith('p0.assets/')),
          hasLength(40),
        );
        // Three more of the ten left: 30 percent.
        for (final n in ['p2', 'p3', 'p4']) {
          h.fake.delete('Noted/$n.canvas');
        }
        await h.roundsWithDelay();
        expect(h.engine.guardQuestion?.paths, [
          'p2.canvas',
          'p3.canvas',
          'p4.canvas',
        ]);
        expect(h.has('p2.canvas'), isTrue);
      },
    );
  });

  group('410', () {
    test(
      'resyncChangesApplyDifferences: a missing path reads as removed',
      () async {
        seedMany(8);
        await h.round();
        h.fake.delete('Noted/p0.canvas');
        h.fake.expireTokens();
        await h.round();
        expect(h.has('p0.canvas'), isTrue);
        h.clock.advance(const Duration(seconds: 31));
        await h.round();
        expect(h.has('p0.canvas'), isFalse);
        expect(h.has('p1.canvas'), isTrue);
      },
    );

    test('resyncChangesUploadDifferences: a missing path is kept and listed, even after a kill', () async {
      seedMany(8);
      await h.round();
      h.fake.delete('Noted/p0.canvas');
      h.fake.expireTokens(uploadDifferences: true);
      h.killAt('mapSaved');
      final r = await h.round();
      expect(r.error, isA<Killed>());
      h.restart();
      await h.round();
      h.clock.advance(const Duration(seconds: 120));
      await h.round();
      expect(h.has('p0.canvas'), isTrue);
      expect(h.engine.issues, hasIssue('p0.canvas'));
      // A path that comes back is treated normally again.
      h.fake.addFile('Noted/p0.canvas', Harness.b('back'));
      await h.round();
      await h.round();
      expect(h.read('p0.canvas'), 'back');
    });

    test('a 410 whose Location is on another origin fails the round', () async {
      seedMany(2);
      await h.round();
      h.fake.expireTokens();
      h.fake.foreignLink = 'https://evil.example/x';
      final r = await h.round();
      expect(r.error, isA<GraphRefusedLink>());
      expect(h.engine.status.state, SyncState.paused);
      expect(h.has('p0.canvas'), isTrue);
    });
  });

  group('folders moved', () {
    test('a folder moved in from outside gets its children listed', () async {
      seedMany(2);
      h.fake.addFile('Other/Sub/noted-binder.json', Harness.b('{}'));
      h.fake.addFile('Other/Sub/q.canvas', Harness.b('Q'));
      h.fake.addFile('Other/Sub/q.assets/a.bin', Harness.b('A'));
      await h.round();
      h.fake.move('Other/Sub', 'Noted');
      await h.round();
      expect(h.read('Sub/q.canvas'), 'Q');
      expect(h.read('Sub/q.assets/a.bin'), 'A');
      expect(h.has('Sub/noted-binder.json'), isTrue);
    });

    test('a folder moved out of the root is a removal of its subtree, through the guard (drive-root delta)', () async {
      h.fake.folderDeltaSupported = false;
      h.fake.addFolder('Other');
      seedMany(10);
      h.fake.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
      h.fake.addFile('Noted/B/q.canvas', Harness.b('Q'));
      await h.round();
      h.fake.move('Noted/B', 'Other');
      await h.roundsWithDelay();
      expect(h.engine.guardQuestion?.paths, [
        'B/noted-binder.json',
        'B/q.canvas',
      ]);
      expect(h.has('B/q.canvas'), isTrue);
    });
  });

  test('changes fire for rounds', () async {
    seedMany(1);
    var n = 0;
    final sub = h.engine.changes.listen((_) => n++);
    await h.round();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(n, greaterThan(0));
  });

  group('the root', () {
    for (final driveDelta in [true, false]) {
      test(
        'a root deleted in the delta pauses and applies nothing (${driveDelta ? 'drive-root' : 'folder'} delta)',
        () async {
          seedMany(4);
          h.fake.folderDeltaSupported = !driveDelta;
          await h.round();
          h.fake.delete('Noted');
          final r = await h.round();
          h.clock.advance(const Duration(minutes: 5));
          await h.round();
          expect(r.error, isNull);
          expect(h.engine.status.state, SyncState.rootGone);
          expect(h.tree(), hasLength(4));
          expect(h.engine.guardQuestion, isNull);
        },
      );
    }

    test('a root that is gone at the start pauses', () async {
      h.fake.delete('Noted');
      await h.round();
      expect(h.engine.status.state, SyncState.rootGone);
    });

    test('a working copy that is missing pauses and changes nothing', () async {
      seedMany(2);
      await h.round();
      h.work.deleteSync(recursive: true);
      final r = await h.round();
      expect(r.error, isNull);
      expect(h.engine.status.state, SyncState.paused);
      expect(h.work.existsSync(), isFalse);
    });
  });

  group('names from the server', () {
    test('unusable names are skipped with their subtree and listed', () async {
      seedMany(1);
      await h.round();
      final root = h.rootId;
      var n = 100;
      for (final name in [
        '..',
        '.',
        'a/b',
        r'a\b',
        'x\u0000y',
        'c:evil',
        'dot.',
        '',
      ]) {
        h.fake.logRaw({
          'id': 'EVIL${n++}',
          'name': name,
          'size': 3,
          'cTag': 'c',
          'parentReference': {'id': root, 'driveId': FakeGraph.driveId},
          'file': {
            'hashes': {'quickXorHash': 'AAAAAAAAAAAAAAAAAAAAAAAAAAA='},
          },
        });
      }
      await h.round();
      await h.round();
      final outside = h.base
          .listSync()
          .map((e) => e.path.split(RegExp(r'[\\/]')).last)
          .toSet();
      expect(outside, {'work', 'state'});
      expect(
        h.tree().where((p) => p.contains('..') || p.contains('evil')),
        isEmpty,
      );
      expect(h.engine.issues.length, greaterThanOrEqualTo(7));
    });

    test('the state folder is below the support folder with safe parts', () {
      final d = syncStateDir(Directory('/support'), '../evil', 'ROOT!1');
      final parts = d.path.replaceAll(r'\', '/').split('/');
      expect(parts.sublist(parts.length - 3).first, 'onedrive');
      expect(parts.last, 'ROOT!1');
      expect(parts.contains('..'), isFalse);
    });

    test('state folder parts: unsafe ids are hashed', () {
      expect(safePathPart('01ABC!def_-.x'), '01ABC!def_-.x');
      for (final bad in ['..', '.', 'a/b', r'a\b', '', 'x y', '../x', 'end.']) {
        final s = safePathPart(bad);
        expect(s, matches(RegExp(r'^[0-9a-f]{64}$')), reason: bad);
      }
    });
  });

  group('lost responses and checksums', () {
    test(
      'a lost delta page fails the round and the next one succeeds',
      () async {
        seedMany(2);
        h.fake.fail('/delta', lose: true);
        final r = await h.round();
        expect(r.error, isNotNull);
        expect(h.engine.status.state, SyncState.paused);
        expect(h.tree(), isEmpty);
        final r2 = await h.round();
        expect(r2.error, isNull);
        expect(h.tree(), hasLength(2));
      },
    );

    test(
      'a lost download leaves no temp and the next round finishes',
      () async {
        seedMany(3);
        h.fake.fail('/content', lose: true);
        final r = await h.round();
        expect(r.error, isNotNull);
        expect(h.stateFiles('tmp'), isEmpty);
        final applied = h.tree().length;
        expect(applied, lessThan(3));
        await h.round();
        expect(h.tree(), hasLength(3));
      },
    );

    test('a download that fails the checksum is discarded; repeated mismatches show as a status', () async {
      h.fake.addFile('Noted/a.canvas', Harness.b('AAA'));
      h.fake.corruptContent = true;
      for (var i = 0; i < 3; i++) {
        await h.round();
        expect(h.has('a.canvas'), isFalse);
        expect(h.stateFiles('tmp'), isEmpty);
      }
      expect(h.engine.status.state, SyncState.paused);
      expect(h.engine.status.reason, contains('checksum'));
      h.fake.corruptContent = false;
      await h.round();
      expect(h.read('a.canvas'), 'AAA');
      expect(h.engine.status.state, SyncState.idle);
    });

    test(
      'a 429 in the middle of a round pauses requests and the round completes',
      () async {
        seedMany(3);
        h.fake.fail('/content', status: 429, retryAfter: '9');
        final r = await h.round();
        expect(r.error, isNull);
        expect(h.clock.delays, contains(const Duration(seconds: 9)));
        expect(h.tree(), hasLength(3));
      },
    );
  });

  group('sign-in state', () {
    test(
      'a signed-out token callback sets the status and changes nothing',
      () async {
        seedMany(2);
        final g = GraphClient(
          origin: h.fake.origin,
          clock: h.clock,
          token: ({bool forceRefresh = false}) async =>
              throw const SignedOutException(),
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
        expect(r.error, isA<SignedOutException>());
        expect(e.status.state, SyncState.signedOut);
        expect(h.tree(), isEmpty);
      },
    );
  });
}
