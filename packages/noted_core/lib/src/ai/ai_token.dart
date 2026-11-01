// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';

import 'ai_code.dart';
import 'ai_code_format.dart';

/// A new AI code (0105): `noted_<id>_<key>`, with a random 16-hex
/// id and a 32-byte random key in base64url without padding. The app shows
/// `token` once; it keeps only `id` and `hash` (the SHA-256 of the key).
///
/// Exported from `noted_core.dart` only: the MCP server's library makes no
/// codes and has no random key generation in its import graph.
({String token, String id, String hash}) newAiToken() {
  final random = Random.secure();
  final idBytes = List<int>.generate(8, (_) => random.nextInt(256));
  final keyBytes = List<int>.generate(32, (_) => random.nextInt(256));
  final id = idBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final key = _base64Url(keyBytes);
  return (token: 'noted_${id}_$key', id: id, hash: aiKeyHash(key));
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

/// A freshly issued code: [code] is the text to show the user once, and
/// [record] is what the app keeps. [retired] lists the ids of the Writer
/// codes it replaced.
typedef AiIssuedCode = ({String code, AiCode record, List<String> retired});

/// Makes a new code for [target] and adds it to [codes] (a mutable list of
/// the stored codes).
///
/// A Writer is for a box target only ([ArgumentError] otherwise). Issuing a
/// Writer retires the box's old live Writer code, marking it revoked at [now]
/// in [codes] (its history stays); a box has one live Writer at a time. Any
/// number of Readers can exist.
AiIssuedCode issueAiCode(
  List<AiCode> codes, {
  required AiCodeTarget target,
  required AiCodeRole role,
  required String label,
  DateTime? expires,
  DateTime? now,
}) {
  if (target.kind == null) {
    throw ArgumentError.value(target.kindName, 'target', 'unknown target kind');
  }
  if (role == AiCodeRole.writer && target.kind != AiCodeTargetKind.box) {
    throw ArgumentError.value(role, 'role', 'a Writer code is for a box');
  }
  final retired = <String>[];
  if (role == AiCodeRole.writer) {
    for (var i = 0; i < codes.length; i++) {
      final c = codes[i];
      final old =
          !c.isRevoked &&
          c.role == AiCodeRole.writer &&
          c.target.kind == AiCodeTargetKind.box &&
          c.target.id == target.id;
      if (!old) continue;
      retired.add(c.id);
      codes[i] = c.copyWith(revoked: (now ?? DateTime.now()).toUtc());
    }
  }
  final token = newAiToken();
  final record = AiCode(
    id: token.id,
    target: target,
    roleName: role.wire,
    label: label,
    hash: token.hash,
    created: (now ?? DateTime.now()).toUtc(),
    expires: expires?.toUtc(),
  );
  codes.add(record);
  return (code: token.token, record: record, retired: retired);
}
