// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noted_auth/noted_auth.dart';

String jwt(Map<String, Object?> claims) {
  String part(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part(claims)}.sig';
}

final idToken = jwt({
  'tid': 'tenant1',
  'oid': 'obj1',
  'name': 'Ada Test',
  'preferred_username': 'ada@example.test',
});
const key = 'tenant1.obj1';

/// A fake token endpoint: records the forms it was sent and answers by
/// [handler].
class FakeEndpoint {
  FakeEndpoint(this.handler);

  final Future<http.Response> Function(Map<String, String> form, int n) handler;
  final List<Map<String, String>> forms = [];

  MockClient get client => MockClient((req) async {
    expect(
      req.url.toString(),
      'https://login.microsoftonline.com/common/oauth2/v2.0/token',
    );
    final form = Uri.splitQueryString(req.body);
    forms.add(form);
    return handler(form, forms.length);
  });
}

http.Response ok(Map<String, Object?> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response grantError(String error) =>
    http.Response(jsonEncode({'error': error}), 400);

class FailingStore extends MemoryTokenStore {
  bool failWrites = false;
  bool failReads = false;
  bool dropWrites = false; // writes succeed but nothing is kept

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('read');
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('write');
    if (dropWrites) return;
    return super.write(key, value);
  }
}

void main() {
  late FailingStore store;
  var clock = DateTime(2030);

  AuthSession session(FakeEndpoint e) => AuthSession(
    tokens: TokenClient(
      const AuthConfig(clientId: 'test-client'),
      client: e.client,
    ),
    store: store,
    now: () => clock,
  );

  const grant = AuthGrant(
    code: 'CODE',
    codeVerifier: 'VERIFIER',
    redirectUri: 'io.github.ndouve.noted://auth',
  );

  setUp(() {
    store = FailingStore();
    clock = DateTime(2030);
  });

  Map<String, Object?> tokens(String access, String refresh) => {
    'access_token': access,
    'refresh_token': refresh,
    'id_token': idToken,
    'expires_in': 3600,
  };

  test('the code exchange sends the verifier and no secret, and stores the refresh token', () async {
    final e = FakeEndpoint((f, n) async => ok(tokens('A1', 'R1')));
    final s = session(e);
    await s.signIn(grant);
    expect(e.forms.single, {
      'client_id': 'test-client',
      'scope': 'Files.ReadWrite offline_access openid profile',
      'grant_type': 'authorization_code',
      'code': 'CODE',
      'code_verifier': 'VERIFIER',
      'redirect_uri': 'io.github.ndouve.noted://auth',
    });
    expect(s.state, AuthState.signedIn);
    expect(s.displayName, 'Ada Test');
    expect(s.accountKey, key);
    expect(store.values[AuthSession.refreshKey(key)], 'R1');
    // The access token is never stored.
    expect(store.values.values.any((v) => v.contains('A1')), isFalse);
    expect(await s.accessToken(), 'A1');
    expect(e.forms, hasLength(1));
  });

  test('restore reads the account from the store and refreshes when a token is needed', () async {
    final e = FakeEndpoint((f, n) async => ok(tokens('A2', 'R2')));
    await session(FakeEndpoint((f, n) async => ok(tokens('A1', 'R1'))))
        .signIn(grant);
    final s = session(e);
    await s.restore();
    expect(s.state, AuthState.signedIn);
    expect(s.displayName, 'Ada Test');
    expect(e.forms, isEmpty);
    expect(await s.accessToken(), 'A2');
    expect(e.forms.single['grant_type'], 'refresh_token');
    expect(e.forms.single['refresh_token'], 'R1');
  });

  test('restore with an empty store is signed out; an unreadable store is sign in again', () async {
    final e = FakeEndpoint((f, n) async => ok(tokens('A', 'R')));
    final s = session(e);
    await s.restore();
    expect(s.state, AuthState.signedOut);
    store.failReads = true;
    final t = session(e);
    await t.restore();
    expect(t.state, AuthState.signInAgain);
  });

  test('an expired access token is refreshed; a rotated refresh token replaces the old', () async {
    final e = FakeEndpoint((f, n) async => ok(tokens('A$n', 'R$n')));
    final s = session(e);
    await s.signIn(grant); // A1, R1
    clock = clock.add(const Duration(hours: 2));
    expect(await s.accessToken(), 'A2');
    expect(e.forms.last['refresh_token'], 'R1');
    expect(store.values[AuthSession.refreshKey(key)], 'R2');
  });

  test(
    'rotation with a failing store write keeps the old refresh token',
    () async {
      final e = FakeEndpoint((f, n) async => ok(tokens('A$n', 'R$n')));
      final s = session(e);
      await s.signIn(grant);
      store.failWrites = true;
      clock = clock.add(const Duration(hours: 2));
      expect(await s.accessToken(), 'A2'); // the new access token still works
      expect(store.values[AuthSession.refreshKey(key)], 'R1');
      expect(s.state, AuthState.signedIn);
      store.failWrites = false;
      clock = clock.add(const Duration(hours: 2));
      await s.accessToken();
      expect(e.forms.last['refresh_token'], 'R1'); // the old one still works
    },
  );

  test(
    'rotation whose read-back differs puts the old refresh token back',
    () async {
      final e = FakeEndpoint((f, n) async => ok(tokens('A$n', 'R$n')));
      final s = session(e);
      await s.signIn(grant);
      store.dropWrites =
          true; // the write "succeeds" but the read-back is the old value
      clock = clock.add(const Duration(hours: 2));
      await s.accessToken();
      expect(store.values[AuthSession.refreshKey(key)], 'R1');
    },
  );

  test(
    'a refresh answer without a new refresh token keeps the stored one',
    () async {
      final e = FakeEndpoint(
        (f, n) async => n == 1
            ? ok(tokens('A1', 'R1'))
            : ok({'access_token': 'A2', 'expires_in': 3600}),
      );
      final s = session(e);
      await s.signIn(grant);
      clock = clock.add(const Duration(hours: 2));
      expect(await s.accessToken(), 'A2');
      expect(store.values[AuthSession.refreshKey(key)], 'R1');
    },
  );

  test('invalid_grant on refresh means sign in again', () async {
    final e = FakeEndpoint(
      (f, n) async =>
          n == 1 ? ok(tokens('A1', 'R1')) : grantError('invalid_grant'),
    );
    final s = session(e);
    await s.signIn(grant);
    final states = <AuthState>[];
    s.changes.listen(states.add);
    clock = clock.add(const Duration(hours: 2));
    await expectLater(
      s.accessToken(),
      throwsA(
        isA<AuthException>().having(
          (x) => x.kind,
          'kind',
          AuthErrorKind.invalidGrant,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(s.state, AuthState.signInAgain);
    expect(states, [AuthState.signInAgain]);
    await expectLater(
      s.accessToken(),
      throwsA(
        isA<AuthException>().having(
          (x) => x.kind,
          'kind',
          AuthErrorKind.signInRequired,
        ),
      ),
    );
  });

  test('a store read failure at refresh time means sign in again, without calling Microsoft', () async {
    final e = FakeEndpoint((f, n) async => ok(tokens('A$n', 'R$n')));
    final s = session(e);
    await s.signIn(grant);
    store.failReads = true;
    clock = clock.add(const Duration(hours: 2));
    await expectLater(s.accessToken(), throwsA(isA<AuthException>()));
    expect(s.state, AuthState.signInAgain);
    expect(e.forms, hasLength(1));
  });

  test('a network failure leaves the session signed in', () async {
    final e = FakeEndpoint((f, n) async {
      if (n == 1) return ok(tokens('A1', 'R1'));
      throw http.ClientException('offline');
    });
    final s = session(e);
    await s.signIn(grant);
    clock = clock.add(const Duration(hours: 2));
    await expectLater(
      s.accessToken(),
      throwsA(
        isA<AuthException>().having(
          (x) => x.kind,
          'kind',
          AuthErrorKind.unreachable,
        ),
      ),
    );
    expect(s.state, AuthState.signedIn);
  });

  test(
    'concurrent 401s cause exactly one refresh, and all callers get its token',
    () async {
      final gate = Completer<void>();
      final e = FakeEndpoint((f, n) async {
        if (n == 1) return ok(tokens('A1', 'R1'));
        await gate.future;
        return ok(tokens('A2', 'R2'));
      });
      final s = session(e);
      await s.signIn(grant);
      final rejected = await s.accessToken();
      final calls = [
        for (var i = 0; i < 5; i++) s.tokenAfterRejection(rejected),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 10));
      gate.complete();
      expect(await Future.wait(calls), List.filled(5, 'A2'));
      // A late 401 for the old token also finds the new one: no second refresh.
      expect(await s.tokenAfterRejection(rejected), 'A2');
      expect(
        e.forms.where((f) => f['grant_type'] == 'refresh_token'),
        hasLength(1),
      );
    },
  );

  test('concurrent callers of an expired token share one refresh', () async {
    final e = FakeEndpoint(
      (f, n) async => n == 1 ? ok(tokens('A1', 'R1')) : ok(tokens('A2', 'R2')),
    );
    final s = session(e);
    await s.signIn(grant);
    clock = clock.add(const Duration(hours: 2));
    expect(
      await Future.wait([s.accessToken(), s.accessToken(), s.accessToken()]),
      ['A2', 'A2', 'A2'],
    );
    expect(
      e.forms.where((f) => f['grant_type'] == 'refresh_token'),
      hasLength(1),
    );
  });

  test('sign out removes the stored tokens and needs no network', () async {
    final e = FakeEndpoint((f, n) async => ok(tokens('A1', 'R1')));
    final s = session(e);
    await s.signIn(grant);
    await s.signOut();
    expect(s.state, AuthState.signedOut);
    expect(store.values, isEmpty);
    expect(e.forms, hasLength(1));
    await expectLater(s.accessToken(), throwsA(isA<AuthException>()));
  });

  test('a failed sign-in write leaves the state as it was', () async {
    final e = FakeEndpoint((f, n) async => ok(tokens('A1', 'R1')));
    final s = session(e);
    store.failWrites = true;
    await expectLater(
      s.signIn(grant),
      throwsA(
        isA<AuthException>().having(
          (x) => x.kind,
          'kind',
          AuthErrorKind.storage,
        ),
      ),
    );
    expect(s.state, AuthState.signedOut);
  });

  test(
    'a refused code exchange is an error that holds no code or token',
    () async {
      final e = FakeEndpoint(
        (f, n) async => http.Response(
          jsonEncode({
            'error': 'invalid_request',
            'error_description': 'Bad thing.\r\nTrace ID: 123',
          }),
          400,
        ),
      );
      final s = session(e);
      try {
        await s.signIn(grant);
        fail('should throw');
      } on AuthException catch (x) {
        expect(x.kind, AuthErrorKind.rejected);
        expect(x.message, contains('invalid_request'));
        expect(x.message, isNot(contains('Trace')));
        expect(x.message, isNot(contains('CODE')));
      }
    },
  );

  test(
    'id token claims: account key, display name, fallbacks and bad tokens',
    () {
      final c = IdClaims.fromIdToken(idToken);
      expect(c.accountKey, 'tenant1.obj1');
      expect(c.displayName, 'Ada Test');
      expect(
        IdClaims.fromIdToken(
          jwt({'tid': 't', 'oid': 'o', 'preferred_username': 'u@x.test'}),
        ).displayName,
        'u@x.test',
      );
      expect(
        IdClaims.fromIdToken(jwt({'tid': 't', 'oid': 'o'})).displayName,
        'Microsoft account',
      );
      expect(() => IdClaims.fromIdToken('nope'), throwsA(isA<AuthException>()));
      expect(
        () => IdClaims.fromIdToken(jwt({'tid': 't'})),
        throwsA(isA<AuthException>()),
      );
    },
  );
}
