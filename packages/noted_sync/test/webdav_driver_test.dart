// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noted_sync/noted_sync.dart';

import 'fake_webdav.dart';
import 'harness.dart';
import 'helpers.dart';

List<int> b(String s) => utf8.encode(s);

void main() {
  group('the driver', _driverCases);
  for (final kind in [RemoteKind.davPath, RemoteKind.davFileId]) {
    group('the engine on ${kind.label}', () => _engineCases(kind));
  }
}

void _driverCases() {
  late FakeWebDav dav;
  late FakeClock clock;
  late Directory tmp;
  setUp(() async {
    dav = await FakeWebDav.start();
    clock = FakeClock();
    tmp = Directory.systemTemp.createTempSync('davdriver');
    dav.addFolder('Noted');
  });
  tearDown(() async {
    await dav.close();
    tmp.deleteSync(recursive: true);
  });

  WebDavClient client({
    http.Client? inner,
    String path = 'Noted',
    int maxItems = 100000,
  }) => WebDavClient(
    root: dav.urlOf(path),
    user: FakeWebDav.user,
    password: dav.password,
    client: inner,
    clock: clock,
    allowLoopbackHttp: true,
    maxItems: maxItems,
  );

  File dest() => File('${tmp.path}/dl-${tmp.listSync().length}');

  group('connect', () {
    test('the id kind is what the server gives every item', () async {
      for (final (ids, kind) in [
        (FakeDavIds.path, DavIdKind.path),
        (FakeDavIds.ocFileId, DavIdKind.fileId),
        (FakeDavIds.resourceId, DavIdKind.resourceId),
        (FakeDavIds.both, DavIdKind.resourceId),
      ]) {
        dav.ids = ids;
        dav.addFile('Noted/B/$ids.canvas', b('A'));
        final d = await WebDavDriver.connect(client());
        expect(d.idKind, kind, reason: '$ids');
        expect(
          d.rootId,
          ids == FakeDavIds.path ? '/' : dav.idOf('Noted'),
          reason: '$ids',
        );
        expect(d.provider, 'webdav');
        expect(d.displayName, 'WebDAV');
        expect(d.caps.serverHash, isFalse);
        expect(d.caps.fullListing, isTrue);
      }
    });

    test('an id one item lacks is no id: the next kind, or the path', () async {
      dav.ids = FakeDavIds.both;
      dav.addFile('Noted/a.canvas', b('A'));
      dav.addFile('Noted/b.canvas', b('B'));
      dav.noIdFor.add('Noted/b.canvas');
      expect((await WebDavDriver.connect(client())).idKind, DavIdKind.path);
    });

    test('the path root is /', () async {
      dav.addFile('Noted/a.canvas', b('A'));
      expect((await WebDavDriver.connect(client())).rootId, '/');
    });

    test('a server that is not WebDAV, a file, no versions, a bad password, a bad certificate', () async {
      dav.addFile('Noted/a.canvas', b('A'));
      dav.omitDavHeader = true;
      await expectLater(
        WebDavDriver.connect(client()),
        throwsA(isA<RemoteNotSupported>()),
      );
      dav.omitDavHeader = false;
      await expectLater(
        WebDavDriver.connect(client(path: 'Noted/a.canvas')),
        throwsA(
          isA<RemoteNotSupported>().having(
            (e) => e.message,
            'message',
            contains('not a folder'),
          ),
        ),
      );
      dav.omitEtags = true;
      await expectLater(
        WebDavDriver.connect(client()),
        throwsA(
          isA<RemoteNotSupported>().having(
            (e) => e.message,
            'message',
            "This server doesn't report file versions",
          ),
        ),
      );
      dav.omitEtags = false;
      final c = client();
      dav.password = 'rotated';
      await expectLater(
        WebDavDriver.connect(c),
        throwsA(isA<RemoteUnauthorized>()),
      );
      dav.password = 'app-password';
      await expectLater(
        WebDavDriver.connect(
          client(
            inner: MockClient.streaming(
              (req, body) => throw const HandshakeException('self-signed'),
            ),
          ),
        ),
        throwsA(isA<RemoteRefused>()),
      );
      await expectLater(
        WebDavDriver.connect(client(path: 'Nothing')),
        throwsA(isA<RemoteNotFound>()),
      );
    });

    test(
      'the walk at connect asks for versions of every file, deep ones too',
      () async {
        dav.addFile('Noted/a.canvas', b('A'));
        dav.addFile('Noted/B/C/deep.canvas', b('D'));
        await WebDavDriver.connect(client());
        dav.omitEtags = true;
        await expectLater(
          WebDavDriver.connect(client()),
          throwsA(isA<RemoteNotSupported>()),
        );
      },
    );
  });

  group('fetch', () {
    for (final ids in [
      FakeDavIds.path,
      FakeDavIds.ocFileId,
      FakeDavIds.resourceId,
    ]) {
      test('the map, with ids of ${ids.name}', () async {
        dav.ids = ids;
        dav.addFile('Noted/a.canvas', b('AAA'));
        dav.addFile('Noted/B/noted-binder.json', b('{}'));
        dav.addFile('Noted/B/p.assets/i.png', b('II'));
        final d = await WebDavDriver.connect(client());
        final f = (await d.fetch({}, null, null, 0))!;
        expect(f.cursor, startsWith('webdav:'));
        expect(f.endpoint, 'full');
        final byName = {for (final e in f.map.values) e.name: e};
        expect(f.map[d.rootId]!.parent, isNull);
        expect(f.map[d.rootId]!.folder, isTrue);
        expect(byName.keys.toSet(), {
          '',
          'a.canvas',
          'B',
          'noted-binder.json',
          'p.assets',
          'i.png',
        });
        expect(byName['a.canvas']!.size, 3);
        expect(byName['a.canvas']!.hash, isNull);
        expect(byName['a.canvas']!.cTag, isNotNull);
        expect(byName['a.canvas']!.parent, d.rootId);
        expect(byName['B']!.parent, d.rootId);
        expect(byName['p.assets']!.parent, byName['B']!.id);
        expect(byName['i.png']!.parent, byName['p.assets']!.id);
        expect(byName['p.assets']!.folder, isTrue);
        expect(
          byName['a.canvas']!.id,
          ids == FakeDavIds.path ? 'a.canvas' : dav.idOf('Noted/a.canvas'),
        );
        expect(f.issues, isEmpty);
      });
    }

    test(
      'a weak ETag is kept without its W/, so weak and strong are one version',
      () async {
        dav.addFile('Noted/a.canvas', b('AAA'));
        final d = await WebDavDriver.connect(client());
        final strong = (await d.fetch(
          {},
          null,
          null,
          0,
        ))!.map.values.firstWhere((e) => e.name == 'a.canvas').cTag;
        dav.weakEtags = true;
        final weak = (await d.fetch(
          {},
          null,
          null,
          0,
        ))!.map.values.firstWhere((e) => e.name == 'a.canvas').cTag;
        expect(weak, strong);
        expect(weak, isNot(startsWith('W/')));
      },
    );

    test('an item that did not change keeps its sequence; a changed one gets a new one', () async {
      dav.addFile('Noted/a.canvas', b('AAA'));
      dav.addFile('Noted/b.canvas', b('BBB'));
      final d = await WebDavDriver.connect(client());
      final one = (await d.fetch({}, null, null, 0))!;
      final two = (await d.fetch(one.map, one.cursor, one.endpoint, one.seq))!;
      for (final e in one.map.values) {
        expect(two.map[e.id]!.seq, e.seq, reason: e.name);
      }
      expect(two.seq, one.seq);
      dav.replaceFile('Noted/a.canvas', b('AAAA'));
      final three = (await d.fetch(
        two.map,
        two.cursor,
        two.endpoint,
        two.seq,
      ))!;
      final a = dav.idOf('Noted/a.canvas').replaceFirst('Noted/', '');
      final bb = dav.idOf('Noted/b.canvas').replaceFirst('Noted/', '');
      expect(three.map[a]!.seq, greaterThan(two.seq));
      expect(three.map[bb]!.seq, two.map[bb]!.seq);
    });

    test('a round in which an item lacks the id kind is incomplete', () async {
      for (final ids in [FakeDavIds.ocFileId, FakeDavIds.resourceId]) {
        dav.ids = ids;
        dav.addFile('Noted/$ids.canvas', b('A'));
        final d = await WebDavDriver.connect(client());
        dav.noIdFor.add('Noted/$ids.canvas');
        await expectLater(
          d.fetch({}, null, null, 0),
          throwsA(isA<WebDavIncomplete>()),
          reason: '$ids',
        );
        dav.noIdFor.clear();
      }
    });

    test('two items with one id are incomplete', () async {
      dav.ids = FakeDavIds.ocFileId;
      dav.addFile('Noted/a.canvas', b('A'));
      dav.addFile('Noted/b.canvas', b('B'));
      final d = await WebDavDriver.connect(client());
      dav.nodes.values.firstWhere((n) => n.name == 'b.canvas').id = dav
          .nodes
          .values
          .firstWhere((n) => n.name == 'a.canvas')
          .id;
      await expectLater(
        d.fetch({}, null, null, 0),
        throwsA(isA<WebDavIncomplete>()),
      );
    });

    test(
      'a different folder at the root address is a root that is gone',
      () async {
        dav.ids = FakeDavIds.ocFileId;
        dav.addFile('Noted/a.canvas', b('A'));
        final d = await WebDavDriver.connect(client());
        expect((await d.root()).deleted, isFalse);
        dav.delete('Noted');
        dav.addFolder('Noted');
        expect(await d.fetch({}, null, null, 0), isNull);
        expect((await d.root()).deleted, isTrue);
      },
    );

    test('a root with no id property is incomplete, not gone', () async {
      dav.ids = FakeDavIds.ocFileId;
      dav.addFile('Noted/a.canvas', b('A'));
      final d = await WebDavDriver.connect(client());
      dav.noIdFor.add('Noted');
      await expectLater(d.root(), throwsA(isA<WebDavIncomplete>()));
    });

    test('a root that is missing, or is a file', () async {
      dav.addFile('Noted/a.canvas', b('A'));
      final d = await WebDavDriver.connect(client());
      dav.delete('Noted');
      await expectLater(
        d.fetch({}, null, null, 0),
        throwsA(isA<RemoteNotFound>()),
      );
      await expectLater(d.root(), throwsA(isA<RemoteNotFound>()));
      final file = WebDavDriver(
        client: client(path: 'Gone'),
        idKind: DavIdKind.path,
        rootId: '/',
      );
      dav.addFile('Gone', b('x'));
      expect((await file.root()).isFolder, isFalse);
      await expectLater(
        file.fetch({}, null, null, 0),
        throwsA(isA<RemoteNotFound>()),
      );
    });

    test('a name that no path may have is in the map, for the engine to skip and list', () async {
      dav.addFile('Noted/ok.canvas', b('A'));
      dav.addFile('Noted/x', b('X'));
      dav.nodes.values.firstWhere((n) => n.name == 'x').name = 'a/b.canvas';
      final d = await WebDavDriver.connect(client());
      final f = (await d.fetch({}, null, null, 0))!;
      final names = f.map.values.map((e) => e.name).toList();
      expect(names, containsAll(['ok.canvas', 'a/b.canvas']));
      expect(isSafeName('a/b.canvas'), isFalse);
    });

    test('every caps overrun is a round that applies nothing', () async {
      dav.addFile('Noted/a.canvas', b('A'));
      dav.addFile('Noted/b.canvas', b('B'));
      final d = WebDavDriver(
        client: client(maxItems: 2),
        idKind: DavIdKind.path,
        rootId: '/',
      );
      await expectLater(
        d.fetch({}, null, null, 0),
        throwsA(
          isA<WebDavIncomplete>().having(
            (e) => e.message,
            'message',
            startsWith('Too large to sync'),
          ),
        ),
      );
    });
  });

  group('download', () {
    for (final ids in [
      FakeDavIds.path,
      FakeDavIds.ocFileId,
      FakeDavIds.resourceId,
    ]) {
      test('by the id of the latest listing (${ids.name})', () async {
        dav.ids = ids;
        dav.addFile('Noted/B/a b.canvas', b('hello'));
        final d = await WebDavDriver.connect(client());
        final f = (await d.fetch({}, null, null, 0))!;
        final e = f.map.values.firstWhere((e) => e.name == 'a b.canvas');
        final out = dest();
        await d.download(e, out);
        expect(out.readAsStringSync(), 'hello');
        expect(dav.requests.last.method, 'GET');
        expect(dav.requests.last.path, '/dav/Noted/B/a b.canvas');
      });
    }

    test('path ids need no listing first; the others do', () async {
      dav.addFile('Noted/a.canvas', b('hello'));
      final listed = (await (await WebDavDriver.connect(
        client(),
      )).fetch({}, null, null, 0))!.map.values.firstWhere((e) => !e.folder);
      final fresh = WebDavDriver(
        client: client(),
        idKind: DavIdKind.path,
        rootId: '/',
      );
      final out = dest();
      await fresh.download(listed, out);
      expect(out.readAsStringSync(), 'hello');
      dav.ids = FakeDavIds.ocFileId;
      final byId = WebDavDriver(
        client: client(),
        idKind: DavIdKind.fileId,
        rootId: dav.idOf('Noted'),
      );
      await expectLater(
        byId.download(listed, dest()),
        throwsA(isA<RemoteNotFound>()),
      );
    });

    test(
      'a version that moved is RemoteChanged; an item that went is not found',
      () async {
        dav.addFile('Noted/a.canvas', b('hello'));
        final d = await WebDavDriver.connect(client());
        final e = (await d.fetch(
          {},
          null,
          null,
          0,
        ))!.map.values.firstWhere((e) => !e.folder);
        dav.replaceFile('Noted/a.canvas', b('HELLO'));
        await expectLater(d.download(e, dest()), throwsA(isA<RemoteChanged>()));
        dav.delete('Noted/a.canvas');
        await expectLater(
          d.download(e, dest()),
          throwsA(isA<RemoteNotFound>()),
        );
      },
    );
  });

  group('choosing a folder', () {
    test('listFolders, children and folderHint', () async {
      dav.addFile('Top/zeta/x.txt', b('x'));
      dav.addFile('Top/Alpha/noted-binder.json', b('{}'));
      dav.addFile('Top/mid/a.canvas', b('A'));
      dav.addFile('Top/mid/b.canvas', b('B'));
      dav.addFile('Top/mid/B1/noted-binder.json', b('{}'));
      dav.addFile('Top/mid/B2/other.txt', b('x'));
      dav.addFile('Top/file.txt', b('f'));
      final d = WebDavDriver(
        client: client(path: 'Top'),
        idKind: DavIdKind.path,
        rootId: '/',
      );
      final top = await d.listFolders();
      expect(top.map((f) => f.name), ['Alpha', 'mid', 'zeta']);
      final kids = await d.children('/');
      expect(kids.map((k) => k.name), containsAll(['Alpha', 'file.txt']));
      final mid = top.firstWhere((f) => f.name == 'mid');
      expect((await d.listFolders(parentItemId: mid.id)).map((f) => f.name), [
        'B1',
        'B2',
      ]);
      final hint = await d.folderHint(mid.id);
      expect(hint.canvasCount, 2);
      expect(hint.binderCount, 1);
      expect(hint.holdsBinderFile, isFalse);
      expect(
        (await d.folderHint(top.firstWhere((f) => f.name == 'Alpha').id))
            .holdsBinderFile,
        isTrue,
      );
      // A chosen folder can start its own driver.
      expect(d.urlOf(mid.id).toString(), endsWith('/dav/Top/mid/'));
    });

    test(
      'with ids that are not paths, a folder found by listing can be listed',
      () async {
        dav.ids = FakeDavIds.ocFileId;
        dav.addFile('Top/mid/B1/x.canvas', b('A'));
        final d = WebDavDriver(
          client: client(path: 'Top'),
          idKind: DavIdKind.fileId,
          rootId: dav.idOf('Top'),
        );
        final mid = (await d.listFolders()).single;
        expect(mid.id, dav.idOf('Top/mid'));
        expect((await d.listFolders(parentItemId: mid.id)).single.name, 'B1');
        await expectLater(
          d.listFolders(parentItemId: 'not-seen'),
          throwsA(isA<RemoteNotFound>()),
        );
      },
    );

    test('a folder with an unusable name is not offered', () async {
      dav.addFile('Top/ok/x.canvas', b('A'));
      dav.addFolder('Top/bad:name');
      final d = WebDavDriver(
        client: client(path: 'Top'),
        idKind: DavIdKind.path,
        rootId: '/',
      );
      expect((await d.listFolders()).map((f) => f.name), ['ok']);
    });
  });
}

void _engineCases(RemoteKind kind) {
  late Harness h;
  setUp(() async => h = await Harness.create(kind: kind));
  tearDown(() => h.close());

  void seedMany(int n) {
    for (var i = 0; i < n; i++) {
      h.remote.addFile('Noted/p$i.canvas', Harness.b('page $i'));
    }
  }

  Map<String, dynamic> journal() =>
      jsonDecode(File('${h.state.path}/journal.json').readAsStringSync())
          as Map<String, dynamic>;

  test('a pull reads only: no request but OPTIONS, PROPFIND and GET', () async {
    seedMany(4);
    h.remote.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
    await h.round();
    h.remote.replaceFile('Noted/p0.canvas', Harness.b('v2'));
    h.remote.delete('Noted/p1.canvas');
    await h.roundsWithDelay();
    expect(h.read('p0.canvas'), 'v2');
    expect(
      h.dav.requests.map((r) => r.method).toSet().difference({
        'OPTIONS',
        'PROPFIND',
        'GET',
      }),
      isEmpty,
    );
    expect(
      h.dav.requests
          .where((r) => r.method == 'PROPFIND')
          .every((r) => r.acceptEncoding == 'identity'),
      isTrue,
    );
  });

  test('a 401 is signed out, and changes nothing', () async {
    seedMany(2);
    await h.round();
    h.dav.password = 'rotated';
    h.remote.replaceFile('Noted/p0.canvas', Harness.b('v2'));
    final r = await h.round();
    expect(r.error, isA<RemoteUnauthorized>());
    expect(h.engine.status.state, SyncState.signedOut);
    expect(h.read('p0.canvas'), 'page 0');
  });

  test('a 401 on a download alone is signed out too', () async {
    seedMany(2);
    h.dav.fail('GET', status: 401, times: 100);
    final r = await h.round();
    expect(r.error, isA<RemoteUnauthorized>());
    expect(h.engine.status.state, SyncState.signedOut);
  });

  test('a 403 on one file skips only that file', () async {
    seedMany(3);
    h.dav.fail('GET', status: 403);
    final r = await h.round();
    expect(r.error, isNull);
    expect(h.tree(), hasLength(2));
    expect(h.engine.issues, hasLength(1));
    expect(h.issueText().single, contains('403'));
    expect(h.engine.status.state, SyncState.idle);
    // Next round: the refused one comes.
    await h.round();
    expect(h.tree(), hasLength(3));
    expect(h.engine.issues, isEmpty);
  });

  test('a 404 on one file (it went between the listing and the GET) skips only that file', () async {
    seedMany(3);
    h.dav.onRequest = (m, p) {
      if (m == 'GET' && p.endsWith('p1.canvas')) {
        h.remote.delete('Noted/p1.canvas');
      }
    };
    final r = await h.round();
    expect(r.error, isNull);
    expect(h.tree(), ['p0.canvas', 'p2.canvas']);
    expect(h.engine.issues, hasIssue('p1.canvas'));
    expect(h.engine.status.state, SyncState.idle);
  });

  test('a version that moves during the GET is retried, listed after 3 in a row, never a mismatch', () async {
    h.remote.addFile('Noted/a.canvas', Harness.b('AAA'));
    h.dav.getEtagOverride = '"somewhere-else"';
    await h.round();
    await h.round();
    expect(h.engine.issues, isEmpty);
    expect(h.has('a.canvas'), isFalse);
    expect(h.engine.status.state, SyncState.idle);
    await h.round();
    expect(h.engine.issues, hasIssue('a.canvas'));
    expect(journal()['mismatches'], isEmpty);
    expect(h.engine.status.state, SyncState.idle);
    h.dav.getEtagOverride = null;
    await h.round();
    expect(h.read('a.canvas'), 'AAA');
    expect(h.engine.issues, isEmpty);
  });

  test('a file that is replaced between the listing and the GET is picked up the next round', () async {
    h.remote.addFile('Noted/a.canvas', Harness.b('AAA'));
    var done = false;
    h.dav.onRequest = (m, p) {
      if (m == 'GET' && !done) {
        done = true;
        h.remote.replaceFile('Noted/a.canvas', Harness.b('BBBB'));
      }
    };
    await h.round();
    expect(h.has('a.canvas'), isFalse);
    expect(h.engine.issues, isEmpty);
    await h.round();
    expect(h.read('a.canvas'), 'BBBB');
  });

  test('weak and strong forms of the ETag are one version: switching changes nothing', () async {
    seedMany(3);
    await h.round();
    final before = h.contentRequests();
    h.dav.weakEtags = true;
    final r = await h.round();
    expect(r.changedPaths, isEmpty);
    expect(h.contentRequests(), before);
    h.dav.weakEtags = false;
    await h.round();
    expect(h.contentRequests(), before);
    // A weak server still downloads fine.
    h.dav.weakEtags = true;
    h.remote.replaceFile('Noted/p0.canvas', Harness.b('v2'));
    await h.round();
    expect(h.read('p0.canvas'), 'v2');
  });

  test('a server that gzips (ETags tagged -gzip) works, because identity is asked for', () async {
    h.dav.gzipEtags = true;
    seedMany(3);
    h.remote.addFile('Noted/big.canvas', Harness.b('x' * 4000));
    await h.round();
    expect(h.tree(), hasLength(4));
    expect(h.read('big.canvas'), 'x' * 4000);
    expect(h.engine.issues, isEmpty);
  });

  test('unusable names are skipped with their subtree and listed, as the provider says', () async {
    h.remote.addFile('Noted/ok.canvas', Harness.b('A'));
    var n = 0;
    for (final name in [
      'a/b.canvas',
      'c:evil.canvas',
      'dot.',
      'space ',
      'x\u0001y.canvas',
    ]) {
      h.remote.addFile('Noted/f${n++}', Harness.b('X'));
      h.dav.nodes.values.firstWhere((e) => e.name == 'f${n - 1}').name = name;
    }
    h.remote.addFile('Noted/B/noted-binder.json', Harness.b('{}'));
    h.dav.nodes.values.firstWhere((e) => e.name == 'B').name = 'bad/dir';
    await h.round();
    await h.round();
    final outside = h.base
        .listSync()
        .map((e) => e.path.split(RegExp(r'[\\/]')).last)
        .toSet();
    expect(outside, {'work', 'state'});
    expect(h.tree(), ['ok.canvas']);
    expect(h.engine.issues.length, greaterThanOrEqualTo(5));
    expect(h.issueText().join('\n'), contains('WebDAV sent a name'));
    expect(h.issueText().join('\n'), isNot(contains('OneDrive')));
  });

  test(
    'an address outside the folder is skipped and listed; the pull goes on',
    () async {
      seedMany(2);
      h.dav.strayHrefs.add('/dav/Elsewhere/x.canvas');
      final r = await h.round();
      expect(r.error, isNull);
      expect(h.tree(), hasLength(2));
      expect(h.engine.issues, isNotEmpty);
      expect(h.issueText().join('\n'), contains('outside'));
      h.dav.strayHrefs.clear();
      await h.round();
      expect(h.engine.issues, isEmpty);
    },
  );

  test('a listing that cannot be trusted applies nothing and pauses', () async {
    seedMany(3);
    h.dav.responseStatus['Noted/p1.canvas'] =
        'HTTP/1.1 500 Internal Server Error';
    final r = await h.round();
    expect(r.error, isA<WebDavIncomplete>());
    expect(h.engine.status.state, SyncState.paused);
    expect(h.tree(), isEmpty);
    h.dav.responseStatus.clear();
    await h.round();
    expect(h.tree(), hasLength(3));
  });

  test('a length that keeps differing from the listing pauses after three rounds', () async {
    h.remote.addFile('Noted/a.canvas', Harness.b('AAA'));
    h.dav.listedLengthExtra = 1;
    for (var i = 0; i < 3; i++) {
      expect(h.engine.status.state, isNot(SyncState.paused), reason: '$i');
      await h.round();
      expect(h.has('a.canvas'), isFalse);
      expect(h.stateFiles('tmp'), isEmpty);
    }
    expect(h.engine.status.state, SyncState.paused);
    expect(h.engine.status.reason, contains('checksum'));
    h.dav.listedLengthExtra = 0;
    await h.round();
    expect(h.read('a.canvas'), 'AAA');
    expect(h.engine.status.state, SyncState.idle);
  });

  test('a listing that is cut short never reads as deletions', () async {
    seedMany(10);
    await h.round();
    h.dav.fail('PROPFIND', status: 500);
    h.clock.advance(const Duration(seconds: 60));
    final r = await h.round();
    expect(r.error, isNotNull);
    h.clock.advance(const Duration(seconds: 60));
    await h.round();
    expect(h.tree(), hasLength(10));
  });

  test('a cap passed makes the round incomplete, and the status says "Too large to sync"', () async {
    seedMany(5);
    h.engine = h.newEngine(
      driver: WebDavDriver(
        client: WebDavClient(
          root: h.dav.urlOf(h.rootName),
          user: FakeWebDav.user,
          password: h.dav.password,
          clock: h.clock,
          allowLoopbackHttp: true,
          maxItems: 3,
        ),
        idKind: kind == RemoteKind.davPath ? DavIdKind.path : DavIdKind.fileId,
        rootId: h.rootId,
      ),
    );
    final r = await h.round();
    expect(r.error, isA<WebDavIncomplete>());
    expect(h.engine.status.state, SyncState.paused);
    expect(h.engine.status.reason, startsWith('Too large to sync'));
    expect(h.tree(), isEmpty);
  });

  test('a folder that is gone pauses as a root that is gone', () async {
    seedMany(3);
    await h.round();
    h.remote.delete('Noted');
    await h.round();
    expect(h.engine.status.state, SyncState.rootGone);
    expect(h.tree(), hasLength(3));
  });

  test(
    'a redirect to another origin is a refusal, and the round applies nothing',
    () async {
      seedMany(2);
      h.dav.redirect('Noted', 'http://127.0.0.1:9/elsewhere');
      final r = await h.round();
      expect(r.error, isA<RemoteRefused>());
      expect(h.engine.status.state, SyncState.paused);
      expect(h.tree(), isEmpty);
    },
  );

  test('case-only renames settle on one file, and nothing flaps', () async {
    h.remote.addFile('Noted/x.canvas', Harness.b('X'));
    await h.round();
    h.remote.rename('Noted/x.canvas', 'X.canvas');
    await h.round();
    await h.roundsWithDelay();
    expect(h.tree().where((p) => p.toLowerCase() == 'x.canvas'), hasLength(1));
    expect(h.read(h.tree().single), 'X');
    expect(h.engine.issues, isEmpty);
  });

  test('two names that differ only by case: the one that arrived last wins, and it stays so', () async {
    h.remote.addFile('Noted/y.canvas', Harness.b('one'));
    await h.round();
    expect(h.read('y.canvas'), 'one');
    h.remote.addFile('Noted/Y.canvas', Harness.b('two!'));
    await h.round();
    await h.round();
    expect(h.read('y.canvas'), 'two!');
    final before = h.contentRequests();
    final r = await h.round();
    await h.round();
    expect(r.changedPaths, isEmpty);
    expect(h.contentRequests(), before);
  });

  test('a move ends as a new file and, once the delay has passed, the removal of the old one', () async {
    seedMany(10);
    h.remote.addFile('Noted/a.canvas', Harness.b('A'));
    await h.round();
    h.remote.rename('Noted/a.canvas', 'b.canvas');
    await h.round();
    expect(h.read('b.canvas'), 'A');
    if (kind == RemoteKind.davPath) {
      // A delete plus a new file: the old one goes only after 30 s.
      expect(h.has('a.canvas'), isTrue);
      h.clock.advance(const Duration(seconds: 31));
      await h.round();
    }
    expect(h.has('a.canvas'), isFalse);
    expect(h.read('b.canvas'), 'A');
  });

  test(
    'a binder moved ends as a new folder; the old one goes through the guard',
    () async {
      seedMany(10);
      h.remote.addFile('Noted/B1/noted-binder.json', Harness.b('{"id":"b"}'));
      h.remote.addFile('Noted/B1/q.canvas', Harness.b('Q'));
      await h.round();
      h.remote.rename('Noted/B1', 'B2');
      await h.round();
      expect(h.read('B2/q.canvas'), 'Q');
      if (kind == RemoteKind.davPath) {
        h.clock.advance(const Duration(seconds: 31));
        await h.round();
        final q = h.engine.guardQuestion;
        expect(q, isNotNull, reason: 'a whole binder gone asks');
        expect(h.has('B1/q.canvas'), isTrue);
        await h.engine.answerGuard(q!, remove: true);
      }
      expect(h.has('B1/noted-binder.json'), isFalse);
      expect(h.read('B2/noted-binder.json'), '{"id":"b"}');
      expect(h.engine.guardQuestion, isNull);
    },
  );

  test('a kill after a file is published: the next round adopts it after one download, with no "different file" issue', () async {
    seedMany(3);
    var seen = 0;
    h.engine = h.newEngine(
      onStep: (s) {
        if (s == 'published' && ++seen == 1) throw Killed(s);
      },
    );
    expect((await h.round()).error, isA<Killed>());
    h.engine = h.newEngine();
    final before = h.contentRequests();
    await h.round();
    expect(h.tree(), hasLength(3));
    expect(h.engine.issues, isEmpty);
    expect(h.contentRequests() - before, 3, reason: 'one to compare, two new');
    expect(h.stateFiles('tmp'), isEmpty);
  });

  test('the same with a differing local file: listed, not adopted', () async {
    seedMany(3);
    var seen = 0;
    h.engine = h.newEngine(
      onStep: (s) {
        if (s == 'published' && ++seen == 1) throw Killed(s);
      },
    );
    await h.round();
    h.write('p0.canvas', 'PAGE 0');
    h.engine = h.newEngine();
    await h.round();
    expect(h.read('p0.canvas'), 'PAGE 0');
    expect(h.issueText().join('\n'), contains('different file'));
    expect(h.tree(), hasLength(3));
  });

  for (final binder in [true, false]) {
    test(
      'a synced ${binder ? 'binder' : 'plain folder'} renamed to an unusable name keeps its files here and is listed',
      () async {
        seedMany(10);
        // A plain folder is only mirrored below templates.
        final dir = binder ? 'Noted/S' : 'Noted/templates/S';
        final local = binder ? 'S' : 'templates/S';
        if (binder) {
          h.remote.addFile('$dir/noted-binder.json', Harness.b('{"id":"s"}'));
        }
        h.remote.addFile('$dir/a.canvas', Harness.b('A'));
        await h.round();
        expect(h.read('$local/a.canvas'), 'A');
        h.remote.rename(dir, 'bad:name');
        for (var i = 0; i < 3; i++) {
          await h.roundsWithDelay();
        }
        expect(h.read('$local/a.canvas'), 'A');
        expect(
          h.engine.issues.map((i) => i.path),
          contains(endsWith('bad:name')),
        );
        if (kind == RemoteKind.davPath) {
          // The removal that is held is shown, with the unusable name.
          expect(h.engine.issues, hasIssue(local));
          expect(h.issueText().join('\n'), contains('kept here while'));
          expect(h.issueText().join('\n'), contains('bad:name'));
        }
        // Still there on the next rounds, with nothing asked.
        await h.roundsWithDelay();
        expect(h.read('$local/a.canvas'), 'A');
        // Back to a usable name: still there, no copy, no issue.
        h.remote.rename('${dir.substring(0, dir.length - 1)}bad:name', 'S');
        await h.roundsWithDelay();
        expect(h.read('$local/a.canvas'), 'A');
        expect(h.engine.issues, isEmpty);
        // And an unusable folder that goes away lets a real removal through.
        h.remote.delete(dir);
        await h.roundsWithDelay();
        await h.roundsWithDelay();
        if (!binder) {
          expect(h.has('$local/a.canvas'), isFalse);
        }
      },
    );
  }

  test('a folder that answers an empty listing is incomplete, not empty: nothing is removed', () async {
    seedMany(10);
    h.remote.addFile('Noted/templates/S/a.canvas', Harness.b('A'));
    await h.round();
    expect(h.read('templates/S/a.canvas'), 'A');
    h.dav.emptyListings.add('Noted/templates/S');
    for (var i = 0; i < 3; i++) {
      h.clock.advance(const Duration(seconds: 31));
      final r = await h.round();
      expect(r.error, isA<WebDavIncomplete>());
      expect(h.engine.status.state, SyncState.paused);
    }
    expect(h.read('templates/S/a.canvas'), 'A');
    // A real answer again: still there, and nothing was lost.
    h.dav.emptyListings.clear();
    await h.roundsWithDelay();
    expect(h.read('templates/S/a.canvas'), 'A');
    expect(h.engine.issues, isEmpty);
  });

  test(
    'an unusable name that is not a page does not hold back a real removal',
    () async {
      seedMany(30);
      h.remote.addFile('Noted/templates/gone.canvas', Harness.b('G'));
      h.remote.addFile('Noted/icon', Harness.b(''));
      h.remote.addFile('Noted/meeting', Harness.b('x'));
      h.remote.addFile('Noted/templates/D/x.canvas', Harness.b('X'));
      h.dav.nodes.values.firstWhere((n) => n.name == 'icon').name = 'Icon\r';
      h.dav.nodes.values.firstWhere((n) => n.name == 'meeting').name =
          'Meeting 10:30.txt';
      // Beside the page and the folder that go: unusable names of other kinds.
      h.remote.addFile('Noted/templates/odd', Harness.b('GGGGG'));
      h.dav.nodes.values.firstWhere((n) => n.name == 'odd').name = 'Icon\r';
      await h.round();
      expect(h.read('p0.canvas'), 'page 0');
      h.remote.delete('Noted/p0.canvas');
      h.remote.delete('Noted/templates/D');
      h.remote.delete('Noted/templates/gone.canvas');
      await h.roundsWithDelay();
      await h.roundsWithDelay();
      expect(h.has('p0.canvas'), isFalse);
      expect(h.has('templates/D/x.canvas'), isFalse);
      expect(h.has('templates/gone.canvas'), isFalse);
      expect(h.read('p1.canvas'), 'page 1');
      expect(h.issueText().join('\n'), isNot(contains('kept here while')));
    },
  );

  test(
    'a file renamed to an unusable name keeps its local copy and is listed',
    () async {
      seedMany(10);
      h.remote.addFile('Noted/templates/t.canvas', Harness.b('T'));
      h.remote.addFile('Noted/templates/u.canvas', Harness.b('U'));
      await h.round();
      expect(h.read('templates/t.canvas'), 'T');
      h.remote.rename('Noted/templates/t.canvas', 'bad:t.canvas');
      for (var i = 0; i < 3; i++) {
        await h.roundsWithDelay();
      }
      expect(h.read('templates/t.canvas'), 'T');
      expect(h.read('templates/u.canvas'), 'U');
      expect(
        h.engine.issues.map((i) => i.path),
        contains(endsWith('bad:t.canvas')),
      );
      if (kind == RemoteKind.davPath) {
        expect(h.engine.issues, hasIssue('templates/t.canvas'));
        expect(h.issueText().join('\n'), contains('kept here while'));
      }
      // The unusable file goes: the removal then goes through.
      h.remote.delete('Noted/templates/bad:t.canvas');
      await h.roundsWithDelay();
      await h.roundsWithDelay();
      expect(h.has('templates/t.canvas'), isFalse);
      expect(h.read('templates/u.canvas'), 'U');
    },
  );

  test('an unusable folder next to a plain folder that is really deleted: the deletion waits, listed, until the unusable one is gone', () async {
    seedMany(10);
    h.remote.addFile('Noted/templates/S/a.canvas', Harness.b('A'));
    h.remote.addFolder('Noted/templates/bad:name');
    await h.round();
    h.remote.delete('Noted/templates/S');
    for (var i = 0; i < 3; i++) {
      await h.roundsWithDelay();
    }
    if (kind == RemoteKind.davPath) {
      expect(h.read('templates/S/a.canvas'), 'A');
    }
    h.remote.delete('Noted/templates/bad:name');
    await h.roundsWithDelay();
    await h.roundsWithDelay();
    expect(h.has('templates/S/a.canvas'), isFalse);
  });
  test('a compare that found a different file is not repeated until the version or the file changes', () async {
    h.remote.addFile('Noted/a.canvas', Harness.b('AAA'));
    h.write('a.canvas', 'BBB');
    await h.round();
    await h.round();
    await h.round();
    expect(h.contentRequests(), 1);
    h.remote.replaceFile('Noted/a.canvas', Harness.b('DDD'));
    await h.round();
    expect(h.contentRequests(), 2);
  });
}
