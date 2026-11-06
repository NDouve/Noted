// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'auth_config.dart';
import 'auth_exception.dart';
import 'auth_session.dart';
import 'pkce.dart';

/// Opens [url] in the system browser; false if it couldn't be opened.
typedef BrowserLauncher = Future<bool> Function(Uri url);

/// The path the loopback redirect uses (registered as
/// `http://localhost/noted-auth`).
const String loopbackRedirectPath = '/noted-auth';

/// Signs in through the system browser and a one-shot listener on the
/// loopback interface (Windows and Linux).
///
/// Entra ignores the port of a `localhost` redirect for a "Mobile and desktop"
/// registration, so the listener takes any free port on 127.0.0.1 and the
/// redirect sent is `http://localhost:<port>/noted-auth`. The answer must carry
/// this attempt's `state`; anything else is answered and ignored. The code and
/// the tokens are never logged.
///
/// Throws an [AuthException]: `browser` if [launch] fails, `timedOut` after
/// [timeout], `cancelled` if Microsoft sent back an error.
Future<AuthGrant> signInWithLoopback({
  required AuthConfig config,
  required BrowserLauncher launch,
  Duration timeout = const Duration(minutes: 3),
  Random? random,
}) async {
  final HttpServer server;
  try {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  } on Object {
    throw const AuthException(
      AuthErrorKind.browser,
      'Noted could not listen for the sign-in answer on this PC.',
    );
  }
  final pkce = PkcePair.generate(random: random);
  final state = randomState(random: random);
  final redirect = 'http://localhost:${server.port}$loopbackRedirectPath';
  final done = Completer<AuthGrant>();

  Future<void> handle(HttpRequest request) async {
    try {
      final q = request.uri.queryParameters;
      if (request.uri.path != loopbackRedirectPath || q['state'] != state) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final code = q['code'];
      final error = q['error'];
      final ok = error == null && code != null && code.isNotEmpty;
      await _answer(request.response, ok);
      if (done.isCompleted) return;
      if (ok) {
        done.complete(
          AuthGrant(
            code: code,
            codeVerifier: pkce.verifier,
            redirectUri: redirect,
          ),
        );
      } else {
        done.completeError(
          AuthException(
            AuthErrorKind.cancelled,
            error == null
                ? 'Microsoft sent back no sign-in code.'
                : 'The sign-in was refused or cancelled ($error).',
          ),
        );
      }
    } on Object {
      // A broken connection from the browser; the next request may be good.
    }
  }

  final sub = server.listen(handle);
  // "localhost" may resolve to ::1: listen there too, on the same port, with the
  // same handler. Best effort; IPv4 alone is enough where there is no IPv6.
  StreamSubscription<HttpRequest>? sub6;
  HttpServer? server6;
  try {
    server6 = await HttpServer.bind(
      InternetAddress.loopbackIPv6,
      server.port,
      v6Only: true,
    );
    sub6 = server6.listen(handle);
  } on Object {
    server6 = null;
  }

  try {
    final bool opened;
    try {
      opened = await launch(
        config.authorizeUrl(
          redirectUri: redirect,
          codeChallenge: pkce.challenge,
          state: state,
        ),
      );
    } on Object {
      throw const AuthException(
        AuthErrorKind.browser,
        'The browser could not be opened.',
      );
    }
    if (!opened) {
      throw const AuthException(
        AuthErrorKind.browser,
        'The browser could not be opened.',
      );
    }
    return await done.future.timeout(
      timeout,
      onTimeout: () => throw const AuthException(
        AuthErrorKind.timedOut,
        'Nobody signed in before the time ran out.',
      ),
    );
  } finally {
    await sub.cancel();
    await sub6?.cancel();
    await server.close(force: true);
    await server6?.close(force: true);
  }
}

Future<void> _answer(HttpResponse response, bool ok) async {
  final text = ok
      ? 'Signed in. You can close this tab and go back to Noted.'
      : 'Sign-in did not finish. You can close this tab.';
  response.statusCode = HttpStatus.ok;
  response.headers.contentType = ContentType('text', 'html', charset: 'utf-8');
  response.headers.set('Cache-Control', 'no-store');
  response.write(
    '<!doctype html><html><head><meta charset="utf-8"><title>Noted</title></head><body><p>$text</p></body></html>',
  );
  await response.close();
}
