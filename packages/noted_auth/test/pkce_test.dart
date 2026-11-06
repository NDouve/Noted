// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_auth/noted_auth.dart';

void main() {
  test('S256 challenge for the RFC 7636 appendix B verifier', () {
    expect(
      PkcePair.challengeFor('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
  });

  test('a generated verifier is 43 unreserved characters and matches its challenge', () {
    final p = PkcePair.generate(random: Random(1));
    expect(p.verifier, matches(RegExp(r'^[A-Za-z0-9\-._~]{43,128}$')));
    expect(p.challenge, PkcePair.challengeFor(p.verifier));
    expect(PkcePair.generate().verifier, isNot(PkcePair.generate().verifier));
  });

  test('the authorize URL asks for a code with S256 and the scopes', () {
    const config = AuthConfig(clientId: 'test-client');
    final url = config.authorizeUrl(
      redirectUri: 'http://localhost:5/noted-auth',
      codeChallenge: 'CH',
      state: 'ST',
    );
    expect(url.origin, 'https://login.microsoftonline.com');
    expect(url.path, '/common/oauth2/v2.0/authorize');
    expect(url.queryParameters, {
      'client_id': 'test-client',
      'response_type': 'code',
      'redirect_uri': 'http://localhost:5/noted-auth',
      'scope': 'Files.ReadWrite offline_access openid profile',
      'state': 'ST',
      'code_challenge': 'CH',
      'code_challenge_method': 'S256',
    });
  });
}
