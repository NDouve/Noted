// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'auth_exception.dart';

/// The claims Noted reads from an id token.
///
/// DISPLAY ONLY: the token isn't signature-validated, because it came straight
/// from the token endpoint over TLS and nothing is decided from it except
/// which account the stored refresh token belongs to and what to show the
/// user. Never use it to authorise anything.
class IdClaims {
  const IdClaims({
    required this.tenantId,
    required this.objectId,
    this.name,
    this.preferredUsername,
  });

  /// Reads the payload of [idToken] (a JWT). Throws an [AuthException] if it
  /// isn't one or has no `tid` and `oid`.
  factory IdClaims.fromIdToken(String idToken) {
    try {
      final parts = idToken.split('.');
      if (parts.length < 2) throw const FormatException('not a JWT');
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (payload is! Map<String, dynamic>) {
        throw const FormatException('payload');
      }
      final tid = payload['tid'];
      final oid = payload['oid'];
      if (tid is! String || tid.isEmpty || oid is! String || oid.isEmpty) {
        throw const FormatException('no tid or oid');
      }
      final name = payload['name'];
      final user = payload['preferred_username'];
      return IdClaims(
        tenantId: tid,
        objectId: oid,
        name: name is String ? name : null,
        preferredUsername: user is String ? user : null,
      );
    } on FormatException {
      throw const AuthException(
        AuthErrorKind.rejected,
        'Microsoft sent an account answer Noted could not read.',
      );
    }
  }

  /// The `tid` claim.
  final String tenantId;

  /// The `oid` claim.
  final String objectId;

  final String? name;
  final String? preferredUsername;

  /// The key one account's tokens are stored under: tenant plus object id.
  String get accountKey => '$tenantId.$objectId';

  /// What to call the account in the UI.
  String get displayName {
    for (final v in [name, preferredUsername]) {
      if (v != null && v.isNotEmpty) return v;
    }
    return 'Microsoft account';
  }
}
