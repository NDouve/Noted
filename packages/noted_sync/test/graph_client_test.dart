// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_sync/noted_sync.dart';

import 'fake_graph.dart';
import 'helpers.dart';

void main() {
  late FakeGraph fake;
  late FakeClock clock;
  late Directory tmp;
  var refreshes = 0;
  var tokenCalls = 0;

  GraphClient client({int maxThrottleRetries = 8, TokenCallback? token}) =>
      GraphClient(
        origin: fake.origin,
        clock: clock,
        maxThrottleRetries: maxThrottleRetries,
        token:
            token ??
            ({bool forceRefresh = false}) async {
              tokenCalls++;
              if (forceRefresh) {
                refreshes++;
                fake.expectedToken = 'tok2';
              }
              return fake.expectedToken;
            },
      );

  setUp(() async {
    fake = await FakeGraph.start();
    clock = FakeClock();
    refreshes = 0;
    tokenCalls = 0;
    tmp = await Directory.systemTemp.createTemp('graph_client');
  });
  tearDown(() async {
    await fake.close();
    await tmp.delete(recursive: true);
  });

  test(
    'item, delta and children carry the token to the Graph origin',
    () async {
      fake.addFile('Noted/a.canvas', utf8.encode('a'));
      final root = fake.idOf('Noted');
      final c = client();
      final item = await c.getItem(FakeGraph.driveId, root);
      expect(item.isFolder, isTrue);
      final page = await c.deltaStart(FakeGraph.driveId, root);
      expect(page.items.map((i) => i.name), containsAll(['Noted', 'a.canvas']));
      expect(page.deltaLink, isNotNull);
      final kids = await c.children(FakeGraph.driveId, root);
      expect(kids.single.quickXorHash, isNotNull);
      expect(
        fake.requests.every((r) => r.authorization == 'Bearer tok'),
        isTrue,
      );
    },
  );

  test(
    'a 401 asks for a fresh token once and retries; a second 401 gives up',
    () async {
      fake.addFolder('Noted');
      fake.expectedToken = 'old';
      var calls = 0;
      final c = client(
        token: ({bool forceRefresh = false}) async {
          calls++;
          if (forceRefresh) {
            fake.expectedToken = 'new';
            return 'new';
          }
          return 'stale';
        },
      );
      await c.getItem(FakeGraph.driveId, fake.idOf('Noted'));
      expect(calls, 2);

      final never = client(
        token: ({bool forceRefresh = false}) async => 'wrong',
      );
      await expectLater(
        never.getItem(FakeGraph.driveId, fake.idOf('Noted')),
        throwsA(isA<GraphUnauthorized>()),
      );
    },
  );

  test(
    'a signed-out error from the token callback reaches the caller',
    () async {
      final c = client(
        token: ({bool forceRefresh = false}) async =>
            throw const SignedOutException(),
      );
      await expectLater(
        c.getItem(FakeGraph.driveId, 'x'),
        throwsA(isA<SignedOutException>()),
      );
      expect(fake.requests, isEmpty);
    },
  );

  test(
    'a next link on another origin is refused and no token goes there',
    () async {
      fake.addFile('Noted/a.canvas', [1]);
      fake.addFile('Noted/b.canvas', [2]);
      fake.pageSize = 1;
      fake.foreignLink = 'https://evil.example/v1.0/next';
      final c = client();
      await expectLater(
        c.deltaStart(FakeGraph.driveId, fake.idOf('Noted')),
        throwsA(isA<GraphRefusedLink>()),
      );
    },
  );

  test(
    'a 410 reports its Location and resync type; a foreign Location is refused',
    () async {
      fake.addFile('Noted/a.canvas', [1]);
      final c = client();
      final first = await c.deltaStart(FakeGraph.driveId, fake.idOf('Noted'));
      for (final upload in [false, true]) {
        fake.expireTokens(uploadDifferences: upload);
        try {
          await c.deltaAt(first.deltaLink!);
          fail('expected 410');
        } on GraphGone catch (e) {
          expect(e.uploadDifferences, upload);
          expect(e.location, isNotNull);
          expect(e.location!.origin, fake.origin.origin);
        }
      }
      fake.foreignLink = 'https://evil.example/restart';
      await expectLater(
        c.deltaAt(first.deltaLink!),
        throwsA(isA<GraphRefusedLink>()),
      );
    },
  );

  test('folder delta unsupported is told apart from a plain 403', () async {
    fake.addFolder('Noted');
    fake.folderDeltaSupported = false;
    final c = client();
    await expectLater(
      c.deltaStart(FakeGraph.driveId, fake.idOf('Noted')),
      throwsA(isA<GraphNotSupported>()),
    );
    fake.folderDeltaSupported = true;
    fake.fail('delta', status: 403);
    await expectLater(
      c.deltaStart(FakeGraph.driveId, fake.idOf('Noted')),
      throwsA(
        isA<GraphException>().having(
          (e) => e is GraphNotSupported,
          'not supported',
          isFalse,
        ),
      ),
    );
  });

  group('downloads', () {
    test('follow the redirect by hand with no Authorization on it', () async {
      final id = fake.addFile('Noted/a.canvas', utf8.encode('hello'));
      final dest = File('${tmp.path}/out');
      await client().download(FakeGraph.driveId, id, dest);
      expect(await dest.readAsString(), 'hello');
      final storage = fake.requests.where(
        (r) => r.path.startsWith('/storage/'),
      );
      expect(storage, hasLength(1));
      expect(storage.single.authorization, isNull);
    });

    test('five hops are allowed, six are refused', () async {
      final id = fake.addFile('Noted/a.canvas', [1, 2, 3]);
      fake.extraRedirects = 4;
      await client().download(FakeGraph.driveId, id, File('${tmp.path}/ok'));
      fake.extraRedirects = 6;
      await expectLater(
        client().download(FakeGraph.driveId, id, File('${tmp.path}/no')),
        throwsA(isA<GraphRefusedLink>()),
      );
      for (final r in fake.requests.where(
        (r) => r.path.startsWith('/redirect/'),
      )) {
        expect(r.authorization, isNull);
      }
    });

    test(
      'a redirect to a plain http host that is not the origin is refused',
      () async {
        final id = fake.addFile('Noted/a.canvas', [1]);
        fake.redirectTo = 'http://other.example/file';
        await expectLater(
          client().download(FakeGraph.driveId, id, File('${tmp.path}/no')),
          throwsA(isA<GraphRefusedLink>()),
        );
      },
    );

    test('a lost response fails the download', () async {
      final id = fake.addFile('Noted/a.canvas', [1]);
      fake.fail('/content', lose: true);
      await expectLater(
        client().download(FakeGraph.driveId, id, File('${tmp.path}/no')),
        throwsA(isA<Exception>()),
      );
    });
  });

  test('a lost response on a delta page fails the call', () async {
    fake.addFolder('Noted');
    fake.fail('/delta', lose: true);
    await expectLater(
      client().deltaStart(FakeGraph.driveId, fake.idOf('Noted')),
      throwsA(isA<Exception>()),
    );
  });

  group('throttling', () {
    test('429 with Retry-After pauses every request for that long', () async {
      fake.addFolder('Noted');
      final root = fake.idOf('Noted');
      final manual = FakeClock(manual: true);
      final c = GraphClient(
        origin: fake.origin,
        clock: manual,
        token: ({bool forceRefresh = false}) async => 'tok',
      );
      fake.fail('/items/$root', status: 429, retryAfter: '7');
      final a = c.getItem(FakeGraph.driveId, root);
      while (manual.pending.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(manual.delays.single, const Duration(seconds: 7));
      final before = fake.requests.length;
      // A different request, started during the pause, waits too.
      final b = c.children(FakeGraph.driveId, root);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        fake.requests.length,
        before,
        reason: 'nothing is sent while paused',
      );
      manual.release();
      await a;
      await b;
      expect(fake.requests.length, greaterThan(before));
    });

    test('503 without Retry-After backs off 2 s, 4 s, 8 s and resets after a success', () async {
      fake.addFolder('Noted');
      final root = fake.idOf('Noted');
      final c = client();
      fake.fail('/items/$root', times: 3);
      await c.getItem(FakeGraph.driveId, root);
      expect(clock.delays, [
        const Duration(seconds: 2),
        const Duration(seconds: 4),
        const Duration(seconds: 8),
      ]);
      clock.delays.clear();
      fake.fail('/items/$root');
      await c.getItem(FakeGraph.driveId, root);
      expect(clock.delays, [const Duration(seconds: 2)]);
    });

    test('the back-off stops at 5 minutes', () async {
      fake.addFolder('Noted');
      final root = fake.idOf('Noted');
      final c = client(maxThrottleRetries: 12);
      fake.fail('/items/$root', times: 11);
      await c.getItem(FakeGraph.driveId, root);
      expect(
        clock.delays.reduce((a, b) => a > b ? a : b),
        const Duration(minutes: 5),
      );
      expect(clock.delays.last, const Duration(minutes: 5));
    });

    test('it gives up after the retry limit', () async {
      fake.addFolder('Noted');
      final root = fake.idOf('Noted');
      final c = client(maxThrottleRetries: 2);
      fake.fail('/items/$root', times: 10);
      await expectLater(
        c.getItem(FakeGraph.driveId, root),
        throwsA(isA<GraphThrottled>()),
      );
    });
  });

  test('at most four requests are in flight', () async {
    fake.addFolder('Noted');
    final root = fake.idOf('Noted');
    var active = 0;
    var most = 0;
    final release = Completer<void>();
    fake.slow = (path) async {
      active++;
      if (active > most) most = active;
      await release.future;
      active--;
    };
    final c = client();
    final all = [
      for (var i = 0; i < 9; i++) c.getItem(FakeGraph.driveId, root),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(most, 4);
    release.complete();
    await Future.wait(all);
    expect(most, 4);
  });

  test('picker calls: folders, hint and a folder that is a binder', () async {
    fake.addFile('Notes/a.canvas', [1]);
    fake.addFile('Notes/b.canvas', [2]);
    fake.addFile('Notes/B1/noted-binder.json', [3]);
    fake.addFolder('Notes/Plain');
    fake.addFile('Binder/noted-binder.json', [4]);
    final c = client();
    final folders = await c.listFolders();
    expect(folders.map((f) => f.name), ['Binder', 'Notes']);
    final hint = await c.folderHint(fake.idOf('Notes'));
    expect(hint.canvasCount, 2);
    expect(hint.binderCount, 1);
    expect(hint.holdsBinderFile, isFalse);
    expect(await c.holdsBinderFile(fake.idOf('Binder')), isTrue);
    expect(await c.holdsBinderFile(fake.idOf('Notes')), isFalse);
    expect(
      (await c.listFolders(parentItemId: fake.idOf('Notes')))
          .map((f) => f.name),
      ['B1', 'Plain'],
    );
    expect(tokenCalls, greaterThan(0));
    expect(refreshes, 0);
  });
}
