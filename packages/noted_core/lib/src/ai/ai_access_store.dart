// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'ai_code.dart';
import 'locked_file.dart';

export 'locked_file.dart' show FileLockTimeout;

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

/// The contents of `ai-access.json`, edited in place.
///
/// ```json
/// {"format":1,
///  "codes":[{"id":"…","target":{"kind":"box","id":"…","page":"…"},
///            "role":"writer","label":"…","hash":"…","created":"ISO",
///            "lastUsed":"ISO|null","expires":"ISO|null",
///            "sessions":[{"id":"…","app":"…","approved":"ISO"}]}],
///  "boxes":{"<boxId>":{"askBeforeWrite":true}}}
/// ```
///
/// Fields this build doesn't know, at any of these levels, are kept when the
/// file is written back; so are code entries it can't read.
final class AiAccessDoc {
  AiAccessDoc._(this._json);

  /// A document with no codes: what a missing file means.
  factory AiAccessDoc.empty() => AiAccessDoc._({'format': aiAccessFormat, 'codes': <Object?>[]});

  /// Parses file text. Throws [AiAccessUnreadable] if it isn't a JSON object
  /// with `format` 1.
  factory AiAccessDoc.parse(String text) {
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
    return AiAccessDoc._(copy);
  }

  final Map<String, Object?> _json;

  List<Object?> get _codeList {
    final v = _json['codes'];
    if (v is List<Object?>) return v;
    final fresh = <Object?>[...?(v as List?)];
    _json['codes'] = fresh;
    return fresh;
  }

  /// The codes this build can read, in file order.
  List<AiCode> get codes => [
    for (final e in _codeList) ?AiCode.fromJson(e),
  ];

  AiCode? code(String id) {
    for (final c in codes) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Replaces the code with [c]'s id, in place, or adds it at the end.
  void put(AiCode c) {
    final list = _codeList;
    for (var i = 0; i < list.length; i++) {
      final e = list[i];
      if (e is Map && e['id'] == c.id) {
        list[i] = c.toJson();
        return;
      }
    }
    list.add(c.toJson());
  }

  /// Removes the code [id]. Returns whether there was one.
  bool remove(String id) {
    final before = _codeList.length;
    _codeList.removeWhere((e) => e is Map && e['id'] == id);
    return _codeList.length != before;
  }

  /// Issues a code (see [issueAiCode]), adding it to the document and
  /// retiring the box's old Writer. Returns the one-time code string and the
  /// record.
  AiIssuedCode issue({
    required AiCodeTarget target,
    required AiCodeRole role,
    required String label,
    DateTime? expires,
    DateTime? now,
  }) {
    final list = codes;
    final result = issueAiCode(list, target: target, role: role, label: label, expires: expires, now: now);
    for (final id in result.retired) {
      remove(id);
    }
    put(result.record);
    return result;
  }

  /// Checks a code against this document.
  AiCodeVerdict verify(String code, DateTime now) => verifyAiCode(code, codes, now);

  Map<String, Object?>? _box(String boxId) {
    final boxes = _json['boxes'];
    if (boxes is! Map) return null;
    final b = boxes[boxId];
    return b is Map ? b.cast<String, Object?>() : null;
  }

  /// Whether every write to [boxId] asks the user first.
  bool askBeforeWrite(String boxId) => _box(boxId)?['askBeforeWrite'] == true;

  /// Sets [askBeforeWrite] for [boxId]. Other settings of the box are kept;
  /// turning it off removes the entry if nothing else is in it.
  void setAskBeforeWrite(String boxId, bool value) {
    final boxes = <String, Object?>{
      if (_json['boxes'] is Map) for (final e in (_json['boxes']! as Map).entries) e.key as String: e.value,
    };
    final entry = <String, Object?>{...?_box(boxId)};
    if (value) {
      entry['askBeforeWrite'] = true;
    } else {
      entry.remove('askBeforeWrite');
    }
    if (entry.isEmpty) {
      boxes.remove(boxId);
    } else {
      boxes[boxId] = entry;
    }
    if (boxes.isEmpty) {
      _json.remove('boxes');
    } else {
      _json['boxes'] = boxes;
    }
  }

  /// The file text.
  String encode() => '${const JsonEncoder.withIndent('  ').convert(_json)}\n';
}

/// Reads and modifies `ai-access.json`.
///
/// Every call reads the file again, so a revoke, or another Noted instance,
/// takes effect on the next request. A missing file means no codes; a file
/// that exists but can't be read ([AiAccessUnreadable]) means no code is
/// accepted and nothing is written.
final class AiAccessStore {
  const AiAccessStore(this.file);

  final File file;

  /// The current document. Throws [AiAccessUnreadable].
  AiAccessDoc read() {
    final String text;
    try {
      text = file.readAsStringSync();
    } on PathNotFoundException {
      return AiAccessDoc.empty();
    } on FileSystemException catch (e) {
      if (!file.existsSync()) return AiAccessDoc.empty();
      throw AiAccessUnreadable('cannot read: ${e.message}');
    } on FormatException catch (e) {
      throw AiAccessUnreadable('not valid text: ${e.message}');
    }
    return AiAccessDoc.parse(text);
  }

  /// Runs [change] on the current document and writes it back atomically
  /// (a temporary file renamed over the file). Throws [AiAccessUnreadable]
  /// without writing if the file can't be read.
  ///
  /// The read-modify-write holds an exclusive lock (`ai-access.json.lock`),
  /// so two Noted processes can't lose each other's change; the app's
  /// single-instance guard covers the common case. Throws [FileLockTimeout]
  /// (treat as busy) if the lock can't be taken in about two seconds.
  T update<T>(T Function(AiAccessDoc doc) change) => withFileLock(file, () {
    final doc = read();
    final result = change(doc);
    writeFileAtomically(file, doc.encode());
    return result;
  });

  /// The codes this build can read.
  List<AiCode> codes() => read().codes;

  /// Issues a code. See [AiAccessDoc.issue].
  AiIssuedCode issue({
    required AiCodeTarget target,
    required AiCodeRole role,
    required String label,
    DateTime? expires,
    DateTime? now,
  }) => update(
    (d) => d.issue(target: target, role: role, label: label, expires: expires, now: now),
  );

  /// Checks [code]. An unreadable file rejects every code
  /// ([AiCodeFailure.unreadable]).
  AiCodeVerdict verify(String code, {DateTime? now}) {
    try {
      return read().verify(code, now ?? DateTime.now());
    } on AiAccessUnreadable {
      return const AiCodeVerdict.rejected(AiCodeFailure.unreadable);
    }
  }

  /// Revokes (deletes) the code [id]. Returns whether there was one.
  bool revoke(String id) => update((d) => d.remove(id));

  /// Notes that the code [id] was used at [now].
  void recordUse(String id, {DateTime? now}) => update((d) {
    final c = d.code(id);
    if (c != null) d.put(c.copyWith(lastUsed: (now ?? DateTime.now()).toUtc()));
  });

  /// Allows [session] to use the code [id].
  void addSession(String id, AiCodeSession session) => update((d) {
    final c = d.code(id);
    if (c == null) return;
    d.put(c.copyWith(sessions: [...c.sessions.where((s) => s.id != session.id), session]));
  });

  /// Revokes a session of the code [id]: it is asked again next time.
  void removeSession(String id, String sessionId) => update((d) {
    final c = d.code(id);
    if (c == null) return;
    d.put(c.copyWith(sessions: [...c.sessions.where((s) => s.id != sessionId)]));
  });

  /// Whether writes to [boxId] ask first. An unreadable file reads as
  /// true (the safe side).
  bool askBeforeWrite(String boxId) {
    try {
      return read().askBeforeWrite(boxId);
    } on AiAccessUnreadable {
      return true;
    }
  }

  void setAskBeforeWrite(String boxId, bool value) =>
      update((d) => d.setAskBeforeWrite(boxId, value));
}
