// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A new AI connection token (run 2026-11-01-01): `noted_<id>_<key>`, with a random 16-hex
/// id and a 32-byte random key in base64url without padding. The app shows
/// `token` once; it keeps only `id` and `hash` (the SHA-256 of the key).
///
/// Exported from `noted_core.dart` only: the MCP server's library has no
/// hashing code in its import graph.
({String token, String id, String hash}) newAiToken() {
  final random = Random.secure();
  final idBytes = List<int>.generate(8, (_) => random.nextInt(256));
  final keyBytes = List<int>.generate(32, (_) => random.nextInt(256));
  final id = idBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final key = _base64Url(keyBytes);
  return (token: 'noted_${id}_$key', id: id, hash: aiKeyHash(key));
}

/// The SHA-256 of [key] (the secret part of a token), as lowercase hex.
String aiKeyHash(String key) => sha256.convert(utf8.encode(key)).toString();

/// Whether [key] hashes to [hash], compared in constant time.
bool aiKeyMatches(String key, String hash) {
  final a = aiKeyHash(key).codeUnits;
  final b = hash.toLowerCase().codeUnits;
  var diff = a.length ^ b.length;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ (i < b.length ? b[i] : 0);
  }
  return diff == 0;
}

const String _alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

// base64url without padding (dart:convert's encoder pads).
String _base64Url(List<int> bytes) {
  final b = StringBuffer();
  for (var i = 0; i < bytes.length; i += 3) {
    final n =
        (bytes[i] << 16) |
        (i + 1 < bytes.length ? bytes[i + 1] << 8 : 0) |
        (i + 2 < bytes.length ? bytes[i + 2] : 0);
    b.write(_alphabet[(n >> 18) & 63]);
    b.write(_alphabet[(n >> 12) & 63]);
    if (i + 1 < bytes.length) b.write(_alphabet[(n >> 6) & 63]);
    if (i + 2 < bytes.length) b.write(_alphabet[n & 63]);
  }
  return b.toString();
}
