// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noted_sync/noted_sync.dart';

import 'fake_webdav.dart';
import 'helpers.dart';

List<int> b(String s) => utf8.encode(s);

void main() {
  late FakeWebDav dav;
  late FakeClock clock;
  late Directory tmp;
  setUp(() async {
    dav = await FakeWebDav.start();
    clock = FakeClock();
    tmp = Directory.systemTemp.createTempSync('davclient');
    dav.addFolder('Noted');
  });
  tearDown(() async {
    await dav.close();
    tmp.deleteSync(recursive: true);
  });

  WebDavClient client({
    http.Client? inner,
    String? path,
    int maxDepth = 32,
    int maxFolders = 10000,
    int maxItems = 100000,
    int maxResponseBytes = 8 * 1024 * 1024,
    int maxThrottleRetries = 8,
    bool allowLoopbackHttp = true,
    Uri? root,
  }) => WebDavClient(
    root: root ?? dav.urlOf(path ?? 'Noted'),
    user: FakeWebDav.user,
    password: dav.password,
    client: inner,
    clock: clock,
    allowLoopbackHttp: allowLoopbackHttp,
    maxDepth: maxDepth,
    maxFolders: maxFolders,
    maxItems: maxItems,
    maxResponseBytes: maxResponseBytes,
    maxThrottleRetries: maxThrottleRetries,
  );

  List<String> paths(DavListing l) =>
      [for (final n in l.nodes) '${n.segments.join('/')}${n.folder ? '/' : ''}']
        ..sort();

  File dest() => File('${tmp.path}/dl-${tmp.listSync().length}');

  group('what is asked for, and of whom', () {
    test(
      'https only; loopback http only when allowed, and only to loopback',
      () {
        expect(
          () => client(root: Uri.parse('http://example.org/dav/')),
          throwsA(isA<RemoteRefused>()),
        );
        expect(
          () => client(root: Uri.parse('ftp://127.0.0.1/dav/')),
          throwsA(isA<RemoteRefused>()),
        );
        expect(
          () => client(allowLoopbackHttp: false),
          throwsA(isA<RemoteRefused>()),
          reason: 'http to loopback is for tests only',
        );
        expect(
          () => client(root: Uri.parse('http://example.org/dav/')),
          throwsA(isA<RemoteRefused>()),
          reason: 'not loopback',
        );
        expect(client().root.host, '127.0.0.1');
        client(root: Uri.parse('https://example.org/dav/')).close();
      },
    );

    test('every request sends identity encoding and Basic auth, and only reads', () async {
      dav.addFile('Noted/a.canvas', b('A'));
      final c = client();
      await c.checkDav();
      final l = await c.list();
      final n = l.nodes.firstWhere((n) => !n.folder);
      await c.download(n.url, etag: n.etag!, size: n.size, dest: dest());
      expect(dav.requests.map((r) => r.method).toSet(), {
        'OPTIONS',
        'PROPFIND',
        'GET',
      });
      for (final r in dav.requests) {
        expect(r.acceptEncoding, 'identity', reason: '$r');
        expect(
          r.authorization,
          'Basic ${base64.encode(utf8.encode('${FakeWebDav.user}:app-password'))}',
        );
      }
      expect(
        dav.requests.where((r) => r.method == 'PROPFIND').map((r) => r.depth),
        everyElement('1'),
      );
    });

    test(
      'a server that gzips is not asked to: the download matches the listing',
      () async {
        dav.gzipEtags = true;
        dav.addFile('Noted/a.canvas', b('A' * 500));
        final c = client();
        final n = (await c.list()).nodes.firstWhere((n) => !n.folder);
        final d = dest();
        await c.download(n.url, etag: n.etag!, size: n.size, dest: d);
        expect(d.readAsStringSync(), 'A' * 500);
      },
    );

    test('OPTIONS must list class 1 in DAV', () async {
      await client().checkDav();
      dav.omitDavHeader = true;
      await expectLater(
        client().checkDav(),
        throwsA(isA<RemoteNotSupported>()),
      );
    });
  });

  group('the walk', () {
    test('nested folders, with the root first', () async {
      dav.addFile('Noted/a.canvas', b('A'));
      dav.addFile('Noted/B/noted-binder.json', b('{}'));
      dav.addFile('Noted/B/p.assets/i.png', b('I'));
      dav.addFolder('Noted/Empty');
      final l = await client().list();
      expect(l.nodes.first.segments, isEmpty);
      expect(l.nodes.first.folder, isTrue);
      expect(paths(l), [
        '/',
        'B/',
        'B/noted-binder.json',
        'B/p.assets/',
        'B/p.assets/i.png',
        'Empty/',
        'a.canvas',
      ]);
      expect(l.issues, isEmpty);
    });

    for (final style in FakeDavXml.values) {
      for (final href in FakeDavHrefs.values) {
        test('namespaces ${style.name}, hrefs ${href.name}', () async {
          dav.xml = style;
          dav.hrefs = href;
          dav.addFile('Noted/a b.canvas', b('A'));
          dav.addFile('Noted/B/q.canvas', b('Q'));
          final l = await client().list();
          expect(paths(l), ['/', 'B/', 'B/q.canvas', 'a b.canvas']);
          final a = l.nodes.firstWhere((n) => n.name == 'a b.canvas');
          expect(a.etag, isNotNull);
          expect(a.size, 1);
        });
      }
    }

    test(
      'each part is decoded on its own: %2F inside a name stays in that name',
      () async {
        dav.addFile('Noted/a%2Fb', b('X'));
        dav.addFile('Noted/café/ü.canvas', b('U'));
        dav.addFile('Noted/100% sure.canvas', b('S'));
        final l = await client().list();
        expect(l.nodes.map((n) => n.name), contains('a%2Fb'));
        // A name that really holds a slash is one part, never two.
        dav.nodes.values.firstWhere((n) => n.name == 'a%2Fb').name = 'a/b';
        final l2 = await client().list();
        expect(
          l2.nodes.any(
            (n) => n.segments.length == 1 && n.segments.first == 'a/b',
          ),
          isTrue,
        );
        expect(
          l2.nodes.any(
            (n) => n.segments.length == 2 && n.segments[1] == 'ü.canvas',
          ),
          isTrue,
        );
        expect(l2.nodes.map((n) => n.name), contains('100% sure.canvas'));
        // Its id is the same however the server spells it.
        expect(l2.nodes.firstWhere((n) => n.name == 'a/b').pathId, 'a%2Fb');
      },
    );

    test('the id properties: resource-id, oc:fileid, or none (a 404 propstat is normal)', () async {
      for (final ids in FakeDavIds.values.where((i) => i != FakeDavIds.both)) {
        dav.ids = ids;
        dav.addFile('Noted/a$ids.canvas', b('A'));
        final l = await client().list();
        final n = l.nodes.firstWhere((n) => n.name == 'a$ids.canvas');
        expect(
          n.resourceId,
          ids == FakeDavIds.resourceId ? startsWith('urn:uuid:') : isNull,
        );
        expect(
          n.fileId,
          ids == FakeDavIds.ocFileId ? endsWith('ocfake') : isNull,
        );
        expect(n.idFor(DavIdKind.path), 'a$ids.canvas');
      }
    });

    test('a folder asked for without its slash is followed to it', () async {
      dav.redirectNoSlash = true;
      dav.addFile('Noted/B/q.canvas', b('Q'));
      final root = dav.urlOf('Noted').replace(path: '/dav/Noted');
      final l = await client(root: root).list();
      expect(paths(l), ['/', 'B/', 'B/q.canvas']);
    });

    test(
      'an address outside the folder is skipped and listed; the rest is read',
      () async {
        dav.addFile('Noted/a.canvas', b('A'));
        dav.addFile('Noted/B/q.canvas', b('Q'));
        dav.strayHrefs.addAll([
          '/dav/Elsewhere/x.canvas',
          '/dav/Noted/B/deep/er/y.canvas',
          'http://other.example/dav/Noted/z.canvas',
        ]);
        final l = await client().list();
        expect(l.issues, hasLength(greaterThanOrEqualTo(3)));
        expect(l.issues.first.reason, contains('outside'));
        expect(paths(l), ['/', 'B/', 'B/q.canvas', 'a.canvas']);
      },
    );
  });

  group('a listing that cannot be trusted is incomplete', () {
    test('a response whose own status is not 2xx', () async {
      dav.addFile('Noted/a.canvas', b('A'));
      dav.responseStatus['Noted/a.canvas'] = 'HTTP/1.1 403 Forbidden';
      await expectLater(client().list(), throwsA(isA<WebDavIncomplete>()));
    });

    test('a file with no version: incomplete, or refused at connect', () async {
      dav.addFile('Noted/a.canvas', b('A'));
      dav.omitEtags = true;
      await expectLater(client().list(), throwsA(isA<WebDavIncomplete>()));
      await expectLater(
        client().list(connecting: true),
        throwsA(
          isA<RemoteNotSupported>().having(
            (e) => e.message,
            'message',
            contains('file versions'),
          ),
        ),
      );
    });

    test('a file with no size', () async {
      dav.addFile('Noted/a.canvas', b('A'));
      dav.omitLengths = true;
      await expectLater(client().list(), throwsA(isA<WebDavIncomplete>()));
    });

    test('an item with no resourcetype', () async {
      dav.addFile('Noted/a.canvas', b('A'));
      // The fake always sends it; take it out by answering as another server.
      final c = client(
        inner: MockClient.streaming((req, body) async {
          return http.StreamedResponse(
            Stream.value(
              b(
                '<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/Noted/</d:href>'
                '<d:propstat><d:prop><d:getetag>"x"</d:getetag></d:prop>'
                '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
                '</d:multistatus>',
              ),
            ),
            207,
          );
        }),
      );
      await expectLater(c.list(), throwsA(isA<WebDavIncomplete>()));
    });

    test('a transport error in the middle of the walk', () async {
      dav.addFile('Noted/A/a.canvas', b('A'));
      dav.addFile('Noted/B/b.canvas', b('B'));
      var n = 0;
      dav.onRequest = (m, p) {
        if (m == 'PROPFIND' && ++n == 2) dav.loseNextListing();
      };
      await expectLater(client().list(), throwsA(isA<RemoteTransport>()));
      dav.onRequest = null;
      expect(paths(await client().list()), hasLength(5));
    });

    test('a folder that goes away in the middle of the walk', () async {
      dav.addFile('Noted/A/a.canvas', b('A'));
      var n = 0;
      dav.onRequest = (m, p) {
        if (m == 'PROPFIND' && ++n == 2) dav.delete('Noted/A');
      };
      await expectLater(client().list(), throwsA(isA<WebDavIncomplete>()));
    });

    test('a reply that is not XML, a DOCTYPE, an entity', () async {
      dav.addFile('Noted/a.canvas', b('A'));
      for (final inject in [
        '<!DOCTYPE x [<!ENTITY a "b">]>',
        '<!DOCTYPE x SYSTEM "http://example.org/x.dtd">',
      ]) {
        dav.injectAfterDeclaration = inject;
        await expectLater(
          client().list(),
          throwsA(isA<WebDavIncomplete>()),
          reason: inject,
        );
      }
      dav.injectAfterDeclaration = null;
      final c = client(
        inner: MockClient.streaming(
          (req, body) async =>
              http.StreamedResponse(Stream.value(b('<html>')), 207),
        ),
      );
      await expectLater(c.list(), throwsA(isA<WebDavIncomplete>()));
    });

    test(
      'a status other than 207 for a listing is an error, not an empty folder',
      () async {
        dav.fail('PROPFIND', status: 500);
        await expectLater(
          client().list(),
          throwsA(
            isA<RemoteException>().having((e) => e.statusCode, 'status', 500),
          ),
        );
      },
    );
  });

  group('the caps (N11)', () {
    void tree() {
      dav.addFile('Noted/a.canvas', b('A'));
      dav.addFile('Noted/B/b.canvas', b('B'));
      dav.addFile('Noted/B/C/c.canvas', b('C'));
    }

    test('folder depth', () async {
      tree();
      // Root 0, B 1, C 2.
      expect(paths(await client(maxDepth: 2).list()), hasLength(6));
      await expectLater(
        client(maxDepth: 1).list(),
        throwsA(
          isA<WebDavIncomplete>().having(
            (e) => e.message,
            'message',
            startsWith('Too large to sync'),
          ),
        ),
      );
    });

    test('number of folders', () async {
      tree();
      expect(paths(await client(maxFolders: 3).list()), hasLength(6));
      await expectLater(
        client(maxFolders: 2).list(),
        throwsA(isA<WebDavIncomplete>()),
      );
    });

    test('number of items', () async {
      tree();
      expect(paths(await client(maxItems: 6).list()), hasLength(6));
      await expectLater(
        client(maxItems: 5).list(),
        throwsA(isA<WebDavIncomplete>()),
      );
    });

    test('size of a response, read as a stream and abandoned', () async {
      tree();
      dav.padListing = 5000;
      expect(paths(await client(maxResponseBytes: 20000).list()), hasLength(6));
      await expectLater(
        client(maxResponseBytes: 4000).list(),
        throwsA(isA<WebDavIncomplete>()),
      );
    });

    test('a response without a length is abandoned past the cap too', () async {
      final big = b(
        '<d:multistatus xmlns:d="DAV:">${' ' * 10000}</d:multistatus>',
      );
      final c = client(
        maxResponseBytes: 1000,
        inner: MockClient.streaming(
          (req, body) async => http.StreamedResponse(
            Stream.fromIterable([
              for (var i = 0; i < big.length; i += 500)
                big.sublist(i, i + 500 > big.length ? big.length : i + 500),
            ]),
            207,
          ),
        ),
      );
      await expectLater(c.list(), throwsA(isA<WebDavIncomplete>()));
    });
  });

  group('download', () {
    Future<DavNode> listed() async =>
        (await client().list()).nodes.firstWhere((n) => n.name == 'a.canvas');

    test('writes the bytes', () async {
      dav.addFile('Noted/a.canvas', b('hello'));
      final n = await listed();
      final d = dest();
      await client().download(n.url, etag: n.etag!, size: n.size, dest: d);
      expect(d.readAsStringSync(), 'hello');
    });

    test('weak and strong forms of one ETag are equal', () async {
      dav.addFile('Noted/a.canvas', b('hello'));
      final n = await listed();
      final tag = stripWeak(n.etag!);
      for (final (listedTag, sentWeak) in [
        (tag, true),
        ('W/$tag', false),
        ('W/$tag', true),
        (tag, false),
      ]) {
        dav.weakEtags = sentWeak;
        final d = dest();
        await client().download(n.url, etag: listedTag, size: n.size, dest: d);
        expect(d.readAsStringSync(), 'hello');
      }
      expect(etagsMatch('W/"a"', '"a"'), isTrue);
      expect(etagsMatch('"a"', 'W/"a"'), isTrue);
      expect(etagsMatch('W/"a"', 'W/"a"'), isTrue);
      expect(etagsMatch('"a"', '"b"'), isFalse);
      expect(etagsMatch(null, '"a"'), isFalse);
    });

    test(
      'an ETag that differs, a length that differs: RemoteChanged',
      () async {
        dav.addFile('Noted/a.canvas', b('hello'));
        final n = await listed();
        dav.replaceFile('Noted/a.canvas', b('hello'));
        await expectLater(
          client().download(n.url, etag: n.etag!, size: n.size, dest: dest()),
          throwsA(isA<RemoteChanged>()),
        );
        final n2 = await listed();
        dav.replaceFile('Noted/a.canvas', b('hello, longer'));
        await expectLater(
          client().download(
            n2.url,
            etag: n2.etag!,
            size: n2.size,
            dest: dest(),
          ),
          throwsA(isA<RemoteChanged>()),
        );
        // The size alone, when the server keeps the ETag.
        final n3 = await listed();
        dav.getEtagOverride = n3.etag;
        await expectLater(
          client().download(
            n3.url,
            etag: n3.etag!,
            size: n3.size + 1,
            dest: dest(),
          ),
          throwsA(isA<RemoteChanged>()),
        );
      },
    );

    test('a body shorter than the length it announced: RemoteChanged, not a short file', () async {
      dav.addFile('Noted/a.canvas', b('hello'));
      final n = await listed();
      final c = client(
        inner: MockClient.streaming(
          (req, body) async => http.StreamedResponse(
            Stream.value(b('hel')),
            200,
            headers: {'etag': n.etag!},
          ),
        ),
      );
      await expectLater(
        c.download(n.url, etag: n.etag!, size: 5, dest: dest()),
        throwsA(isA<RemoteChanged>()),
      );
    });

    test(
      'with no ETag on the GET, a PROPFIND after it must show the same one',
      () async {
        dav.addFile('Noted/a.canvas', b('hello'));
        dav.omitGetEtag = true;
        final n = await listed();
        final d = dest();
        await client().download(n.url, etag: n.etag!, size: n.size, dest: d);
        expect(d.readAsStringSync(), 'hello');
        final calls = dav.requests
            .map((r) => '${r.method}${r.depth ?? ''}')
            .toList();
        expect(calls.sublist(calls.length - 2), ['GET', 'PROPFIND0']);
        // It moved after the GET.
        dav.onRequest = (m, p) {
          if (m == 'PROPFIND' && dav.requests.last.depth == '0') {
            dav.replaceFile('Noted/a.canvas', b('HELLO'));
          }
        };
        await expectLater(
          client().download(n.url, etag: n.etag!, size: n.size, dest: dest()),
          throwsA(isA<RemoteChanged>()),
        );
        // It went after the GET.
        dav.onRequest = (m, p) {
          if (m == 'PROPFIND' && dav.requests.last.depth == '0') {
            dav.delete('Noted/a.canvas');
          }
        };
        await expectLater(
          client().download(n.url, etag: n.etag!, size: n.size, dest: dest()),
          throwsA(isA<RemoteChanged>()),
        );
      },
    );

    test('404, 403 and 401 are told apart', () async {
      dav.addFile('Noted/a.canvas', b('hello'));
      final n = await listed();
      dav.fail('GET', status: 403);
      await expectLater(
        client().download(n.url, etag: n.etag!, size: n.size, dest: dest()),
        throwsA(
          isA<RemoteException>().having((e) => e.statusCode, 'status', 403),
        ),
      );
      dav.delete('Noted/a.canvas');
      await expectLater(
        client().download(n.url, etag: n.etag!, size: n.size, dest: dest()),
        throwsA(isA<RemoteNotFound>()),
      );
      final stale = client();
      dav.password = 'changed';
      await expectLater(
        stale.download(n.url, etag: n.etag!, size: n.size, dest: dest()),
        throwsA(isA<RemoteUnauthorized>()),
      );
    });
  });

  group('sign-in', () {
    test('a 401 is signed out, for every call', () async {
      final c = client();
      dav.password = 'rotated';
      await expectLater(c.checkDav(), throwsA(isA<RemoteUnauthorized>()));
      await expectLater(c.list(), throwsA(isA<RemoteUnauthorized>()));
      await expectLater(c.stat(c.root), throwsA(isA<RemoteUnauthorized>()));
    });
  });

  group('throttling', () {
    test('429 and 503 wait for Retry-After and then go on', () async {
      dav.addFile('Noted/a.canvas', b('A'));
      dav.fail('PROPFIND', status: 429, retryAfter: '7');
      expect(paths(await client().list()), hasLength(2));
      expect(clock.delays, [const Duration(seconds: 7)]);
      dav.fail('PROPFIND', status: 503, retryAfter: '3');
      await client().list();
      expect(clock.delays.last, const Duration(seconds: 3));
      final n = (await client().list()).nodes.firstWhere((n) => !n.folder);
      dav.fail('GET', status: 503, retryAfter: '5');
      await client().download(
        n.url,
        etag: n.etag!,
        size: n.size,
        dest: File('${tmp.path}/x'),
      );
      expect(clock.delays.last, const Duration(seconds: 5));
    });

    test('with no Retry-After the wait doubles from 2 s', () async {
      dav.fail('PROPFIND', status: 503, times: 3);
      await client().list();
      expect(clock.delays, [
        const Duration(seconds: 2),
        const Duration(seconds: 4),
        const Duration(seconds: 8),
      ]);
    });

    test('a date in Retry-After counts from the clock', () async {
      dav.fail(
        'PROPFIND',
        status: 429,
        retryAfter: HttpDate.format(
          clock.now().add(const Duration(seconds: 40)),
        ),
      );
      await client().list();
      expect(clock.delays.single.inSeconds, inInclusiveRange(38, 41));
    });

    test('a throttle that does not clear ends the call as throttled', () async {
      dav.fail('PROPFIND', status: 429, retryAfter: '1', times: 100);
      await expectLater(
        client(maxThrottleRetries: 2).list(),
        throwsA(isA<RemoteThrottled>()),
      );
      expect(clock.delays, hasLength(2));
    });
  });

  group('redirects and where the password goes', () {
    late HttpServer other;
    final otherSeen = <String?>[];
    setUp(() async {
      otherSeen.clear();
      other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      other.listen((req) {
        otherSeen.add(req.headers.value('authorization') ?? 'none');
        req.response.statusCode = 200;
        req.response.close();
      });
    });
    tearDown(() => other.close(force: true));

    test(
      'a redirect on the same origin is followed, with the password',
      () async {
        dav.addFile('Noted/a.canvas', b('A'));
        final n = (await client().list()).nodes.firstWhere((n) => !n.folder);
        dav.redirect(
          'Noted/a.canvas',
          '/dav/Noted/a.canvas',
          times: 2,
          status: 307,
        );
        final d = dest();
        await client().download(n.url, etag: n.etag!, size: n.size, dest: d);
        expect(d.readAsStringSync(), 'A');
        final gets = dav.requests.where((r) => r.method == 'GET');
        expect(gets, hasLength(3));
        expect(gets.every((r) => r.authorization != null), isTrue);
      },
    );

    test(
      'a redirect to another origin is refused, and nothing is sent there',
      () async {
        dav.addFile('Noted/a.canvas', b('A'));
        final n = (await client().list()).nodes.firstWhere((n) => !n.folder);
        final target = 'http://127.0.0.1:${other.port}/steal';
        dav.redirect('Noted/a.canvas', target);
        await expectLater(
          client().download(n.url, etag: n.etag!, size: n.size, dest: dest()),
          throwsA(isA<RemoteRefused>()),
        );
        dav.redirect('Noted', target);
        await expectLater(client().list(), throwsA(isA<RemoteRefused>()));
        await expectLater(client().checkDav(), throwsA(isA<RemoteRefused>()));
        // Another host name for the same server is another origin too.
        dav.redirect('Noted', 'http://localhost:${dav.origin.port}/dav/Noted/');
        await expectLater(client().list(), throwsA(isA<RemoteRefused>()));
        expect(otherSeen, isEmpty, reason: 'the password never went there');
      },
    );

    test('a scheme change is another origin', () async {
      dav.redirect('Noted', 'https://127.0.0.1:${dav.origin.port}/dav/Noted/');
      await expectLater(client().list(), throwsA(isA<RemoteRefused>()));
    });

    test(
      'too many redirects, a redirect with no Location, a bad one',
      () async {
        dav.redirect('Noted', '/dav/Noted/');
        await expectLater(client().list(), throwsA(isA<RemoteRefused>()));
        expect(
          dav.requests.where((r) => r.method == 'PROPFIND'),
          hasLength(6),
          reason: 'the first request and 5 hops',
        );
        final c = client(
          inner: MockClient.streaming(
            (req, body) async =>
                http.StreamedResponse(const Stream.empty(), 302),
          ),
        );
        await expectLater(c.list(), throwsA(isA<RemoteException>()));
      },
    );
  });

  group('errors say nothing about the address', () {
    test('a refused certificate is a refusal, never skipped', () async {
      final c = client(
        inner: MockClient.streaming(
          (req, body) => throw const HandshakeException('bad certificate'),
        ),
      );
      await expectLater(c.checkDav(), throwsA(isA<RemoteRefused>()));
      await expectLater(c.list(), throwsA(isA<RemoteRefused>()));
    });

    test(
      'a connection error is a transport error with no address in it',
      () async {
        final c = client(
          inner: MockClient.streaming(
            (req, body) => throw SocketException(
              'no route',
              address: InternetAddress.loopbackIPv4,
              port: 9,
            ),
          ),
        );
        await expectLater(
          c.list(),
          throwsA(
            isA<RemoteTransport>().having(
              (e) => '${e.message} $e',
              'text',
              isNot(
                anyOf(contains('127.0.0.1'), contains('/dav/'), contains('9')),
              ),
            ),
          ),
        );
      },
    );

    test('a request that times out is a transport error', () async {
      final c = WebDavClient(
        root: dav.urlOf('Noted'),
        user: FakeWebDav.user,
        password: dav.password,
        allowLoopbackHttp: true,
        timeout: const Duration(milliseconds: 50),
        clock: clock,
        client: MockClient.streaming(
          (req, body) => Completer<http.StreamedResponse>().future,
        ),
      );
      await expectLater(c.list(), throwsA(isA<RemoteTransport>()));
    });
  });

  group('review fixes', () {
    test('an empty folder with one stray address is empty; one that held children is incomplete', () async {
      dav.addFile('Noted/a.canvas', b('A'));
      dav.addFolder('Noted/Empty');
      dav.strayHrefs.add('/dav/Elsewhere/x.canvas');
      expect(paths(await client().list()), contains('Empty/'));
      expect(
        paths(await client().list(populated: {'B'})),
        contains('Empty/'),
        reason: 'another folder held children, not this one',
      );
      await expectLater(
        client().list(populated: {'Empty'}),
        throwsA(isA<WebDavIncomplete>()),
      );
    });

    test(
      'a body longer than listed stops at once and leaves no file',
      () async {
        dav.addFile('Noted/a.canvas', b('hello'));
        final n = (await client().list()).nodes.firstWhere((n) => !n.folder);
        dav.endlessBody = 1024;
        final d = dest();
        await expectLater(
          client().download(n.url, etag: n.etag!, size: n.size, dest: d),
          throwsA(isA<RemoteChanged>()),
        );
        expect(d.existsSync(), isFalse);
        expect(dav.endlessSent, lessThan(2 * 1024 * 1024));
      },
    );

    test('the address: no user name, no invalid escapes, loopback http is refused outside debug', () {
      expect(
        () => client(root: Uri.parse('https://u:p@example.org/dav/')),
        throwsA(isA<RemoteRefused>()),
      );
      expect(
        () => client(root: Uri.parse('https://example.org/a%ff')),
        throwsA(isA<RemoteRefused>()),
      );
      // Asserts are on in tests, so the flag works here; a release build
      // (asserts off) refuses it, which `allowLoopbackHttp: false` shows.
      expect(
        () => client(allowLoopbackHttp: false),
        throwsA(isA<RemoteRefused>()),
      );
    });

    test('a redirect that carries a user name is refused', () async {
      dav.redirect(
        'Noted',
        'http://u:p@127.0.0.1:${dav.origin.port}/dav/Noted/',
      );
      await expectLater(client().list(), throwsA(isA<RemoteRefused>()));
    });

    test(
      'odd hrefs are skipped and listed, never read as items of the folder',
      () async {
        dav.addFile('Noted/a.canvas', b('A'));
        dav.strayHrefs.addAll([
          '/dav/Noted/%2E%2E/Elsewhere/x.canvas',
          '//evil.example/dav/Noted/x.canvas',
          'javascript:alert(1)',
          '/DAV/NOTED/y.canvas',
          'http://user:pw@127.0.0.1:${dav.origin.port}/dav/Noted/z.canvas',
        ]);
        final l = await client().list();
        expect(l.issues, hasLength(5));
        expect(paths(l), ['/', 'a.canvas']);
      },
    );

    test(
      'a double-encoded slash is a name with a percent sign, not a path',
      () async {
        dav.addFile('Noted/a.canvas', b('A'));
        dav.strayHrefs.add('/dav/Noted/a%252Fb.canvas');
        final l = await client().list();
        expect(l.issues, isEmpty);
        final n = l.nodes.firstWhere((n) => n.name == 'a%2Fb.canvas');
        expect(n.segments, ['a%2Fb.canvas']);
      },
    );

    test('a listing whose every entry was skipped is incomplete, not an empty folder', () async {
      dav.addFile('Noted/a.canvas', b('A'));
      dav.addFile('Noted/B/q.canvas', b('Q'));
      dav.hrefs = FakeDavHrefs.absoluteUrl;
      dav.hrefHost = 'localhost';
      await expectLater(client().list(), throwsA(isA<WebDavIncomplete>()));
      // A real empty folder is still empty.
      dav.hrefHost = null;
      dav.addFolder('Noted/Empty');
      expect(paths(await client().list()), contains('Empty/'));
    });
  });
}
