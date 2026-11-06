// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_config.dart';
import 'auth_exception.dart';

/// What the token endpoint answered with.
class TokenResponse {
  const TokenResponse({
    required this.accessToken,
    this.refreshToken,
    this.idToken,
    required this.expiresIn,
  });

  final String accessToken;

  /// Absent when Microsoft didn't rotate it.
  final String? refreshToken;
  final String? idToken;
  final Duration expiresIn;
}

/// Calls the token endpoint: the authorization-code exchange and the refresh.
/// A public client, so there is no secret. Tokens are never logged.
class TokenClient {
  TokenClient(
    this.config, {
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  final AuthConfig config;
  final Duration timeout;
  final http.Client _client;

  Future<TokenResponse> exchangeCode({
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) => _post({
    'grant_type': 'authorization_code',
    'code': code,
    'code_verifier': codeVerifier,
    'redirect_uri': redirectUri,
  });

  Future<TokenResponse> refresh(String refreshToken) =>
      _post({'grant_type': 'refresh_token', 'refresh_token': refreshToken});

  void close() => _client.close();

  Future<TokenResponse> _post(Map<String, String> form) async {
    final http.Response res;
    try {
      res = await _client
          .post(
            config.tokenEndpoint,
            headers: {'Accept': 'application/json'},
            body: {
              'client_id': config.clientId,
              'scope': config.scope,
              ...form,
            },
          )
          .timeout(timeout);
    } on Object {
      throw const AuthException(
        AuthErrorKind.unreachable,
        'Could not reach Microsoft. Check the connection and try again.',
      );
    }
    Map<String, dynamic>? json;
    try {
      final d = jsonDecode(utf8.decode(res.bodyBytes));
      if (d is Map<String, dynamic>) json = d;
    } on FormatException {
      // Not JSON: handled below.
    }
    if (res.statusCode != 200) {
      final error = json?['error'];
      if (error == 'invalid_grant') {
        throw const AuthException(
          AuthErrorKind.invalidGrant,
          'Microsoft no longer accepts this sign-in.',
        );
      }
      final desc = json?['error_description'];
      // The first line only: later ones are trace and correlation ids.
      final first = desc is String
          ? desc.split(RegExp(r'\r?\n')).first.trim()
          : '';
      throw AuthException(
        AuthErrorKind.rejected,
        'Microsoft refused the sign-in${error is String ? ' ($error)' : ' (HTTP ${res.statusCode})'}'
        '${first.isEmpty ? '' : ': $first'}',
      );
    }
    final access = json?['access_token'];
    if (access is! String || access.isEmpty) {
      throw const AuthException(
        AuthErrorKind.rejected,
        'Microsoft sent an answer Noted could not read.',
      );
    }
    final refresh = json?['refresh_token'];
    final id = json?['id_token'];
    final expires = json?['expires_in'];
    final seconds = expires is int ? expires : int.tryParse('$expires') ?? 3600;
    return TokenResponse(
      accessToken: access,
      refreshToken: refresh is String && refresh.isNotEmpty ? refresh : null,
      idToken: id is String ? id : null,
      expiresIn: Duration(seconds: seconds),
    );
  }
}
