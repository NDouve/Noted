// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A PKCE code verifier and its S256 challenge (RFC 7636).
class PkcePair {
  const PkcePair(this.verifier, this.challenge);

  /// A fresh pair: 32 random bytes as an unpadded base64url verifier (43
  /// characters, within RFC 7636's 43 to 128). [random] is for tests.
  factory PkcePair.generate({Random? random}) {
    final verifier = _randomToken(random);
    return PkcePair(verifier, challengeFor(verifier));
  }

  /// `BASE64URL(SHA256(ASCII(verifier)))`, no padding.
  static String challengeFor(String verifier) =>
      _b64(sha256.convert(ascii.encode(verifier)).bytes);

  final String verifier;
  final String challenge;
}

/// A random `state` value: it ties the answer to the request that was sent.
String randomState({Random? random}) => _randomToken(random);

String _randomToken(Random? random) {
  final r = random ?? Random.secure();
  return _b64(
    Uint8List.fromList([for (var i = 0; i < 32; i++) r.nextInt(256)]),
  );
}

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
