// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'ai_access_read.dart';
import 'ai_code.dart';
import 'ai_token.dart';
import 'locked_file.dart';

export 'ai_access_read.dart' show AiAccessUnreadable, aiAccessFileName, aiAccessFormat;
export 'locked_file.dart' show FileLockTimeout;

/// The contents of `ai-access.json`, edited in place.
///
/// ```json
/// {"format":1,
///  "codes":[{"id":"…","target":{"kind":"box","id":"…","page":"…"},
///            "role":"writer","label":"…","hash":"…","created":"ISO",
///            "lastUsed":"ISO|null","expires":"ISO|null","approved":"ISO|null",
///            "revoked":"ISO (only once revoked)",
///            "sessions":[…kept as written, no longer used…]}],
///  "boxes":{"<boxId>":{"askBeforeWrite":true,"writerPermission":"edit",
///                      "closedWrites":true}}}
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
  factory AiAccessDoc.parse(String text) => AiAccessDoc._(parseAiAccessJson(text));

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

  /// Marks the code [id] revoked at [now]. Returns whether there was a live
  /// one.
  bool revoke(String id, DateTime now) {
    final c = code(id);
    if (c == null || c.isRevoked) return false;
    put(c.copyWith(revoked: now.toUtc()));
    return true;
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
    // The retired Writers come back from the list marked revoked.
    for (final c in list) {
      if (result.retired.contains(c.id)) put(c);
    }
    put(result.record);
    return result;
  }

  /// Checks a code against this document.
  AiCodeVerdict verify(String code, DateTime now) => verifyAiCode(code, codes, now);

  AiAccessView get _view => AiAccessView.of(_json);

  Map<String, Object?>? _box(String boxId) {
    final boxes = _json['boxes'];
    if (boxes is! Map) return null;
    final b = boxes[boxId];
    return b is Map ? b.cast<String, Object?>() : null;
  }

  /// Whether every write to [boxId] asks the user first.
  bool askBeforeWrite(String boxId) => _view.askBeforeWrite(boxId);

  /// The Writer permission of [boxId] (append unless set).
  AiWriterPermission writerPermission(String boxId) => _view.writerPermission(boxId);

  /// Whether [boxId] takes writes while Noted is closed (see
  /// [AiAccessView.closedWrites]: false whenever it asks before each write).
  bool closedWrites(String boxId) => _view.closedWrites(boxId);

  /// Sets [askBeforeWrite] for [boxId]. Other settings of the box are kept;
  /// turning it off removes the entry if nothing else is in it.
  void setAskBeforeWrite(String boxId, bool value) =>
      _setBoxKey(boxId, 'askBeforeWrite', value ? true : null);

  /// Sets the Writer permission of [boxId]. [AiWriterPermission.append], the
  /// default, removes the key.
  void setWriterPermission(String boxId, AiWriterPermission value) =>
      _setBoxKey(boxId, 'writerPermission', value == AiWriterPermission.append ? null : value.wire);

  /// Sets whether [boxId] takes writes while Noted is closed. The stored
  /// switch is kept even while [askBeforeWrite] is on (it has no effect
  /// then).
  void setClosedWrites(String boxId, bool value) =>
      _setBoxKey(boxId, 'closedWrites', value ? true : null);

  // Sets [key] of the box entry, or removes it for a null [value]; the entry
  // goes when nothing else is in it. Other keys are kept.
  void _setBoxKey(String boxId, String key, Object? value) {
    final boxes = <String, Object?>{
      if (_json['boxes'] is Map) for (final e in (_json['boxes']! as Map).entries) e.key as String: e.value,
    };
    final entry = <String, Object?>{...?_box(boxId)};
    if (value != null) {
      entry[key] = value;
    } else {
      entry.remove(key);
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

  /// Revokes the code [id]: it stays in the file marked `revoked` (so its
  /// history stays) until both the app's activity log and the MCP access log
  /// hold nothing for it, when the app removes it, and is rejected from then on. Returns whether there was a
  /// live one; revoking a revoked code keeps its first time.
  bool revoke(String id, {DateTime? now}) => update((d) => d.revoke(id, now ?? DateTime.now()));

  /// Notes that the code [id] was used at [now].
  void recordUse(String id, {DateTime? now}) => update((d) {
    final c = d.code(id);
    if (c != null) d.put(c.copyWith(lastUsed: (now ?? DateTime.now()).toUtc()));
  });

  /// Approves the code [id] (the user allowed it) at [now]. Approval is per
  /// code: it holds until the code is revoked or expires. An already
  /// approved code keeps its time.
  void approveCode(String id, {DateTime? now}) => update((d) {
    final c = d.code(id);
    if (c != null && !c.isApproved) d.put(c.copyWith(approved: (now ?? DateTime.now()).toUtc()));
  });

  /// Allows [session] to use the code [id]. Sessions no longer decide
  /// anything (approval is per code); kept for old callers.
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

  /// The Writer permission of [boxId]. An unreadable file reads as append
  /// (the narrowest).
  AiWriterPermission writerPermission(String boxId) {
    try {
      return read().writerPermission(boxId);
    } on AiAccessUnreadable {
      return AiWriterPermission.append;
    }
  }

  void setWriterPermission(String boxId, AiWriterPermission value) =>
      update((d) => d.setWriterPermission(boxId, value));

  /// Whether [boxId] takes writes while Noted is closed. An unreadable file
  /// reads as false.
  bool closedWrites(String boxId) {
    try {
      return read().closedWrites(boxId);
    } on AiAccessUnreadable {
      return false;
    }
  }

  void setClosedWrites(String boxId, bool value) =>
      update((d) => d.setClosedWrites(boxId, value));
}
