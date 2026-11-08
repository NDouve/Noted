// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noted_sync/noted_sync.dart';

import 'helpers.dart';

/// The origin rules with https-looking origins, which the in-process fake
/// server can't serve.
void main() {
  GraphClient client(http.Client c) => GraphClient(
    origin: Uri.parse('https://graph.example'),
    client: c,
    clock: FakeClock(),
    token: ({bool forceRefresh = false}) async => 'tok',
  );

  test('a link must match scheme, host and port', () {
    final c = client(MockClient((_) async => http.Response('', 500)));
    expect(
      c.checkLink(Uri.parse('https://graph.example/v1.0/x?t=1')),
      isA<Uri>(),
    );
    for (final bad in [
      'http://graph.example/v1.0/x',
      'http://graph.example:443/v1.0/x',
      'https://graph.example:8443/v1.0/x',
      'https://other.example/v1.0/x',
      'https://graph.example.evil.example/x',
      '/v1.0/relative',
    ]) {
      expect(
        () => c.checkLink(Uri.parse(bad)),
        throwsA(isA<GraphRefusedLink>()),
        reason: bad,
      );
    }
  });

  test(
    'a download follows an https redirect to a storage host without the token',
    () async {
      final seen = <Uri, String?>{};
      final c = client(
        MockClient.streaming((req, body) async {
          seen[req.url] = req.headers['Authorization'];
          if (req.url.host == 'graph.example') {
            return http.StreamedResponse(
              const Stream.empty(),
              302,
              headers: {
                'location': 'https://storage.example/blob?sig=SECRETSIG',
              },
            );
          }
          return http.StreamedResponse(Stream.value([1, 2, 3]), 200);
        }),
      );
      final tmp = await Directory.systemTemp.createTemp('origin');
      addTearDown(() => tmp.delete(recursive: true));
      final f = File('${tmp.path}/out');
      await c.download('d', 'i', f);
      expect(f.readAsBytesSync(), [1, 2, 3]);
      final graph = seen.entries.firstWhere(
        (e) => e.key.host == 'graph.example',
      );
      final storage = seen.entries.firstWhere(
        (e) => e.key.host == 'storage.example',
      );
      expect(graph.value, 'Bearer tok');
      expect(storage.value, isNull);
    },
  );

  test('a redirect down to http on another host is refused', () async {
    final c = client(
      MockClient.streaming(
        (req, body) async => http.StreamedResponse(
          const Stream.empty(),
          302,
          headers: {'location': 'http://storage.example/blob'},
        ),
      ),
    );
    final tmp = await Directory.systemTemp.createTemp('origin');
    addTearDown(() => tmp.delete(recursive: true));
    await expectLater(
      c.download('d', 'i', File('${tmp.path}/out')),
      throwsA(isA<GraphRefusedLink>()),
    );
  });

  test(
    'a transport error never carries the address it was talking to',
    () async {
      final c = client(
        MockClient.streaming((req, body) async {
          throw http.ClientException(
            'lost',
            Uri.parse('https://storage.example/blob?sig=SECRETSIG'),
          );
        }),
      );
      try {
        await c.getItem('d', 'i');
        fail('expected an error');
      } on GraphException catch (e) {
        expect('$e', isNot(contains('SECRETSIG')));
        expect('$e', isNot(contains('storage.example')));
      }
      final timeout = client(
        MockClient.streaming(
          (req, body) async =>
              throw TimeoutException('slow', const Duration(seconds: 1)),
        ),
      );
      await expectLater(
        timeout.getItem('d', 'i'),
        throwsA(isA<GraphTransportException>()),
      );
    },
  );

  test('a bad address in a link is refused, not a format error', () async {
    final c = client(
      MockClient.streaming(
        (req, body) async => http.StreamedResponse(
          Stream.value(
            '{"value":[],"@odata.nextLink":"http://[bad"}'.codeUnits,
          ),
          200,
        ),
      ),
    );
    await expectLater(c.deltaStart('d', 'i'), throwsA(isA<GraphRefusedLink>()));
  });
}
