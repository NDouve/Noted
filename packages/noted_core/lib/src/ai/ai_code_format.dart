// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

final RegExp _idPattern = RegExp(r'^[0-9a-f]{16}$');
final RegExp _keyPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

/// Whether [id] is a well-formed code id (16 lowercase hex characters).
bool isAiCodeId(String id) => _idPattern.hasMatch(id);

/// Splits a code of the form `noted_<id>_<key>`, where id is 16 lowercase
/// hex characters and key is 43 base64url characters (32 random bytes, no
/// padding). Returns null if [code] is malformed. Surrounding whitespace is
/// ignored.
///
/// Only the shape is checked; no hashing is involved, so the MCP server's
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
