// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

final RegExp _idPattern = RegExp(r'^[0-9a-f]{16}$');
final RegExp _keyPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

/// Whether [id] is a well-formed code id (16 lowercase hex characters).
bool isAiCodeId(String id) => _idPattern.hasMatch(id);

/// Splits a code of the form `noted_<id>_<key>`, where id is 16 lowercase
/// hex characters and key is 43 base64url characters (32 random bytes, no
/// padding). Returns null if [code] is malformed. Surrounding whitespace is
/// ignored.
///
/// Only the shape is checked here (see [aiKeyMatches] for the hash); the MCP server's
/// library has this (it can tell a malformed code before asking the app).
({String id, String key})? parseAiToken(String code) {
  final t = code.trim();
  if (!t.startsWith('noted_')) return null;
  final rest = t.substring('noted_'.length);
  // id (16), '_', key (43).
  if (rest.length != 16 + 1 + 43 || rest[16] != '_') return null;
  final id = rest.substring(0, 16);
  final key = rest.substring(17);
  if (!_idPattern.hasMatch(id) || !_keyPattern.hasMatch(key)) return null;
  return (id: id, key: key);
}

/// The SHA-256 of [key] (the secret part of a token), as lowercase hex.
///
/// SHA-256 from `package:crypto` is the only hashing in the read export: the
/// MCP server may check a code by its hash (invariant 4).
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
