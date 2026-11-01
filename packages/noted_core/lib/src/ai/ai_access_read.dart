// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'ai_code.dart';
import 'ai_link.dart';

/// The name of the codes file in the app's data folder (next to
/// settings.json). It is local to the device: never synced, never in a page
/// file.
const String aiAccessFileName = 'ai-access.json';

/// The `format` of [aiAccessFileName] this build reads and writes.
const int aiAccessFormat = 1;

/// `ai-access.json` exists but can't be read as a format-1 file (damaged, or
/// written by a newer app). No code is accepted and the file is not
/// overwritten.
final class AiAccessUnreadable implements Exception {
  const AiAccessUnreadable(this.message);

  final String message;

  @override
  String toString() => 'AiAccessUnreadable: $message';
}

/// What a box's Writer code may do to it (run 2026-11-01-03). The user picks
/// it per AI box. Anything missing or unknown reads as [append], the
/// narrowest.
enum AiWriterPermission {
  /// Add text at the end.
  append('append'),

  /// Append, and replace the AI's own text.
  edit('edit'),

  /// Also replace the whole box, which includes emptying it.
  full('full');

  const AiWriterPermission(this.wire);

  final String wire;

  /// The permission named [wire]; [append] for a missing or unknown one.
  static AiWriterPermission fromWire(Object? wire) {
    for (final p in values) {
      if (p.wire == wire) return p;
    }
    return append;
  }

  /// Whether a write in [mode] is within this permission: [append] allows
  /// `append`; [edit] adds `replace_ai`; [full] adds `replace`.
  bool allows(AiLinkMode mode) => switch (mode) {
    AiLinkMode.append => true,
    AiLinkMode.replaceAi => this != append,
    AiLinkMode.replace => this == full,
  };
}

/// Parses the text of `ai-access.json` into its JSON object. Throws
/// [AiAccessUnreadable] if it isn't a JSON object with `format` 1, or its
/// `codes` or `boxes` have the wrong shape.
Map<String, Object?> parseAiAccessJson(String text) {
  if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) text = text.substring(1);
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException catch (e) {
    throw AiAccessUnreadable('not valid JSON: ${e.message}');
  }
  if (json is! Map) throw const AiAccessUnreadable('not a JSON object');
  if (json['format'] != aiAccessFormat) {
    throw AiAccessUnreadable('format ${json['format']} is not $aiAccessFormat');
  }
  final copy = <String, Object?>{for (final e in json.entries) e.key as String: e.value};
  final codes = copy['codes'];
  if (codes != null && codes is! List) throw const AiAccessUnreadable('"codes" is not a list');
  final boxes = copy['boxes'];
  if (boxes != null && boxes is! Map) throw const AiAccessUnreadable('"boxes" is not an object');
  return copy;
}

/// A read-only view of `ai-access.json`: its codes and the per-box settings.
/// Pure Dart with no file access and no way to change anything, so the MCP
/// server can use it to check a code by hash (invariant 4) while the app's
/// writer (`AiAccessStore`) stays out of its import graph.
///
/// ```json
/// {"format":1,
///  "codes":[{"id":"…","target":{"kind":"box","id":"…","page":"…"},
///            "role":"writer","label":"…","hash":"…","created":"ISO",
///            "lastUsed":"ISO|null","expires":"ISO|null","approved":"ISO|null",
///            "sessions":[…]}],
///  "boxes":{"<boxId>":{"askBeforeWrite":true,
///                      "writerPermission":"append|edit|full",
///                      "closedWrites":true}}}
/// ```
final class AiAccessView {
  /// A view of [json], which it reads live (it is not copied).
  const AiAccessView.of(this._json);

  /// A view with no codes: what a missing file means.
  factory AiAccessView.empty() => AiAccessView.of({'format': aiAccessFormat, 'codes': <Object?>[]});

  /// Parses file text. Throws [AiAccessUnreadable].
  factory AiAccessView.parse(String text) => AiAccessView.of(parseAiAccessJson(text));

  final Map<String, Object?> _json;

  /// The codes this build can read, in file order.
  List<AiCode> get codes {
    final v = _json['codes'];
    return [
      if (v is List)
        for (final e in v) ?AiCode.fromJson(e),
    ];
  }

  AiCode? code(String id) {
    for (final c in codes) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Checks a code (`noted_<id>_<key>`): the shape, the hash of the key in
  /// constant time, then the expiry. Approval is not part of the verdict:
  /// check [AiCode.isApproved] on the accepted code.
  AiCodeVerdict verify(String code, DateTime now) => verifyAiCode(code, codes, now);

  Map<String, Object?>? _box(String boxId) {
    final boxes = _json['boxes'];
    if (boxes is! Map) return null;
    final b = boxes[boxId];
    return b is Map ? b.cast<String, Object?>() : null;
  }

  /// Whether every write to [boxId] asks the user first.
  bool askBeforeWrite(String boxId) => _box(boxId)?['askBeforeWrite'] == true;

  /// The Writer permission of [boxId]: [AiWriterPermission.append] unless the
  /// file says otherwise (a missing or unknown value is append).
  AiWriterPermission writerPermission(String boxId) =>
      AiWriterPermission.fromWire(_box(boxId)?['writerPermission']);

  /// Whether [boxId] takes writes while Noted is closed, without approval.
  /// Off by default, and off whenever the box asks before each write
  /// ([askBeforeWrite]), whatever the stored switch says.
  bool closedWrites(String boxId) =>
      _box(boxId)?['closedWrites'] == true && !askBeforeWrite(boxId);
}
