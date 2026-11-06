// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// What sign-in asks Microsoft for, and where.
class AuthConfig {
  const AuthConfig({
    required this.clientId,
    this.authority = defaultAuthority,
    this.scopes = defaultScopes,
  });

  /// Both work and personal accounts (the registration allows both).
  static const String defaultAuthority =
      'https://login.microsoftonline.com/common';

  /// The whole drive plus a refresh token and the id token's claims.
  static const List<String> defaultScopes = [
    'Files.ReadWrite',
    'offline_access',
    'openid',
    'profile',
  ];

  /// The registration's application (client) id. Public, but never committed:
  /// it comes from the build (`--dart-define=NOTED_MS_CLIENT_ID`).
  final String clientId;
  final String authority;
  final List<String> scopes;

  Uri get authorizationEndpoint =>
      Uri.parse('$authority/oauth2/v2.0/authorize');

  Uri get tokenEndpoint => Uri.parse('$authority/oauth2/v2.0/token');

  String get scope => scopes.join(' ');

  /// The page the user signs in on: authorization code, PKCE S256.
  Uri authorizeUrl({
    required String redirectUri,
    required String codeChallenge,
    required String state,
  }) => authorizationEndpoint.replace(
    queryParameters: {
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'scope': scope,
      'state': state,
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
    },
  );
}
