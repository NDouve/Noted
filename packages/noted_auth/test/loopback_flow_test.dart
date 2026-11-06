// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_auth/noted_auth.dart';

const config = AuthConfig(clientId: 'test-client');

/// Plays the browser: reads the redirect and state out of the authorize URL
/// and calls the loopback listener with [answer] (given the redirect and state).
Future<bool> Function(Uri) browser(
  Future<void> Function(Uri redirect, String state) answer,
) => (url) async {
  final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
  final state = url.queryParameters['state']!;
  unawaited(answer(redirect, state));
  return true;
};

Future<(int, String)> get(Uri u) async {
  final c = HttpClient();
  try {
    final r = await (await c.getUrl(
      Uri.parse(u.toString().replaceFirst('localhost', '127.0.0.1')),
    )).close();
    final body = await r.transform(const SystemEncoding().decoder).join();
    return (r.statusCode, body);
  } finally {
    c.close(force: true);
  }
}

void main() {
  test('returns the code for the matching state, and answers with a plain close-this-tab page', () async {
    late String page;
    final grant = await signInWithLoopback(
      config: config,
      launch: browser((redirect, state) async {
        final (status, body) = await get(
          redirect.replace(
            queryParameters: {'code': 'THE-CODE', 'state': state},
          ),
        );
        expect(status, 200);
        page = body;
      }),
    );
    expect(grant.code, 'THE-CODE');
    expect(
      grant.redirectUri,
      matches(RegExp(r'^http://localhost:\d+/noted-auth$')),
    );
    expect(grant.codeVerifier, hasLength(43));
    expect(page, contains('You can close this tab'));
    expect(page, isNot(contains('THE-CODE')));
  });

  test(
    'the authorize URL carries the S256 challenge of the verifier handed back',
    () async {
      late Uri sent;
      final grant = await signInWithLoopback(
        config: config,
        launch: (url) async {
          sent = url;
          final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
          unawaited(
            get(
              redirect.replace(
                queryParameters: {
                  'code': 'c',
                  'state': url.queryParameters['state']!,
                },
              ),
            ),
          );
          return true;
        },
      );
      expect(
        sent.queryParameters['code_challenge'],
        PkcePair.challengeFor(grant.codeVerifier),
      );
      expect(sent.queryParameters['code_challenge_method'], 'S256');
    },
  );

  test('also answers on the IPv6 loopback when there is one', () async {
    var hasV6 = true;
    try {
      (await ServerSocket.bind(InternetAddress.loopbackIPv6, 0)).close();
    } on Object {
      hasV6 = false;
    }
    final grant = await signInWithLoopback(
      config: config,
      launch: browser((redirect, state) async {
        final c = HttpClient();
        try {
          final host = hasV6 ? '[::1]' : '127.0.0.1';
          final u = Uri.parse(
            'http://$host:${redirect.port}/noted-auth?code=V6&state=$state',
          );
          await (await (await c.getUrl(u)).close()).drain<void>();
        } finally {
          c.close(force: true);
        }
      }),
    );
    expect(grant.code, 'V6');
  });

  test('a wrong state is ignored; the right one then completes', () async {
    final grant = await signInWithLoopback(
      config: config,
      launch: browser((redirect, state) async {
        final (bad, _) = await get(
          redirect.replace(queryParameters: {'code': 'EVIL', 'state': 'other'}),
        );
        expect(bad, 404);
        await get(
          redirect.replace(queryParameters: {'code': 'GOOD', 'state': state}),
        );
      }),
    );
    expect(grant.code, 'GOOD');
  });

  test('an error answer is cancelled, without the description', () async {
    await expectLater(
      signInWithLoopback(
        config: config,
        launch: browser((redirect, state) async {
          await get(
            redirect.replace(
              queryParameters: {
                'error': 'access_denied',
                'error_description': 'secret words',
                'state': state,
              },
            ),
          );
        }),
      ),
      throwsA(
        isA<AuthException>()
            .having((e) => e.kind, 'kind', AuthErrorKind.cancelled)
            .having(
              (e) => e.message,
              'message',
              allOf(contains('access_denied'), isNot(contains('secret'))),
            ),
      ),
    );
  });

  test('times out, and the listener is closed afterwards', () async {
    late Uri redirect;
    await expectLater(
      signInWithLoopback(
        config: config,
        timeout: const Duration(milliseconds: 100),
        launch: (url) async {
          redirect = Uri.parse(url.queryParameters['redirect_uri']!);
          return true;
        },
      ),
      throwsA(
        isA<AuthException>().having(
          (e) => e.kind,
          'kind',
          AuthErrorKind.timedOut,
        ),
      ),
    );
    await expectLater(get(redirect), throwsA(isA<SocketException>()));
  });

  test('a browser that cannot open is reported', () async {
    for (final launch in <Future<bool> Function(Uri)>[
      (_) async => false,
      (_) async => throw StateError('x'),
    ]) {
      await expectLater(
        signInWithLoopback(config: config, launch: launch),
        throwsA(
          isA<AuthException>().having(
            (e) => e.kind,
            'kind',
            AuthErrorKind.browser,
          ),
        ),
      );
    }
  });
}
