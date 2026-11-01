// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// What the app and the MCP server both know of an AI connection (run 2026-10-31-02): its
/// id and name. The secret half of its token is never stored; only a hash of
/// it is, in settings.json (see `ai_token.dart`).
final class AiConnectionInfo {
  const AiConnectionInfo({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  /// 16 lowercase hex characters.
  final String id;
  final String name;

  /// When the connection was made, in milliseconds since the epoch.
  final int createdAt;

  @override
  bool operator ==(Object other) =>
      other is AiConnectionInfo &&
      other.id == id &&
      other.name == name &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, name, createdAt);
}

/// The key in settings.json that lists the AI connections: a list of
/// `{"id": ID, "name": TEXT, "hash": SHA256_HEX_OF_KEY, "created": MS}`,
/// where ID is 16 lowercase hex characters.
const String aiConnectionsSettingKey = 'aiConnections';

final RegExp _idPattern = RegExp(r'^[0-9a-f]{16}$');
final RegExp _keyPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

/// Whether [id] is a well-formed connection id.
bool isAiConnectionId(String id) => _idPattern.hasMatch(id);

/// Splits a token of the form `noted_<id>_<key>`, where id is 16 lowercase
/// hex characters and key is 43 base64url characters (32 random bytes, no
/// padding). Returns null if [token] is malformed. Surrounding whitespace is
/// ignored.
({String id, String key})? parseAiToken(String token) {
  final t = token.trim();
  if (!t.startsWith('noted_')) return null;
  final rest = t.substring('noted_'.length);
  // id (16), '_', key (43).
  if (rest.length != 16 + 1 + 43 || rest[16] != '_') return null;
  final id = rest.substring(0, 16);
  final key = rest.substring(17);
  if (!_idPattern.hasMatch(id) || !_keyPattern.hasMatch(key)) return null;
  return (id: id, key: key);
}

/// The connections listed in the decoded settings.json [settingsJson].
/// Missing or malformed entries are skipped; the hash is ignored.
List<AiConnectionInfo> readAiConnections(Object? settingsJson) {
  if (settingsJson is! Map) return const [];
  final list = settingsJson[aiConnectionsSettingKey];
  if (list is! List) return const [];
  final out = <AiConnectionInfo>[];
  final seen = <String>{};
  for (final e in list) {
    if (e is! Map) continue;
    final id = e['id'];
    if (id is! String || !_idPattern.hasMatch(id) || !seen.add(id)) continue;
    final name = e['name'];
    final created = e['created'];
    out.add(
      AiConnectionInfo(
        id: id,
        name: name is String ? name : '',
        createdAt: created is num ? created.toInt() : 0,
      ),
    );
  }
  return out;
}
