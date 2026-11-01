// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'ai_code.dart';
import 'locked_file.dart';

/// The name of the activity log in the app's data folder (next to
/// settings.json).
const String aiActivityFileName = 'ai-activity.json';

/// The most entries the log keeps, over all codes. The oldest go first.
const int aiActivityMaxEntries = 1000;

/// The operations an entry names (`op`). The set is open: a newer app may
/// log others.
abstract final class AiActivityOp {
  static const String readBox = 'read_box';
  static const String readPage = 'read_page';
  static const String listPages = 'list_pages';
  static const String search = 'search';
  static const String writeBox = 'write_box';
  static const String describeCode = 'describe_code';
}

/// One thing an AI did with a code (or tried to).
final class AiActivityEntry {
  const AiActivityEntry({
    required this.time,
    required this.code,
    required this.target,
    required this.op,
    required this.app,
    required this.label,
    required this.result,
    this.extra = const {},
  });

  final DateTime time;

  /// The code id.
  final String code;
  final AiCodeTarget target;
  final String op;

  /// The MCP client's name.
  final String app;

  /// The code's label when this happened.
  final String label;

  /// `ok`, or the error code (`not_approved`, `expired`, ...).
  final String result;

  /// Fields this build doesn't know.
  final Map<String, Object?> extra;

  bool get ok => result == 'ok';

  static AiActivityEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final time = json['time'] is String ? DateTime.tryParse(json['time'] as String) : null;
    final target = AiCodeTarget.fromJson(json['target']);
    final code = json['code'];
    final op = json['op'];
    if (time == null || target == null || code is! String || op is! String) return null;
    final app = json['app'];
    final label = json['label'];
    final result = json['result'];
    return AiActivityEntry(
      time: time.toUtc(),
      code: code,
      target: target,
      op: op,
      app: app is String ? app : '',
      label: label is String ? label : '',
      result: result is String ? result : '',
      extra: {
        for (final e in json.entries)
          if (e.key is String && !const {'time', 'code', 'target', 'op', 'app', 'label', 'result'}.contains(e.key))
            e.key as String: e.value,
      },
    );
  }

  Map<String, Object?> toJson() => {
    'time': time.toUtc().toIso8601String(),
    'code': code,
    'target': target.toJson(),
    'op': op,
    'app': app,
    'label': label,
    'result': result,
    ...extra,
  };
}

/// The capped activity log, `{"format":1,"entries":[...]}`, newest last.
///
/// The log is a convenience, not a record the app relies on: a missing file
/// or text that isn't JSON is an empty log and the next entry starts a new
/// one; a file that can't be read, or that is in another format, is left
/// alone and entries are skipped.
final class AiActivityLog {
  const AiActivityLog(this.file, {this.maxEntries = aiActivityMaxEntries});

  final File file;
  final int maxEntries;

  // The log as a map. Only a missing file or text that isn't valid JSON is an
  // empty log. Any other read error, or JSON that isn't a format-1 log (maybe
  // a newer app's), returns null: the file is left alone.
  Map<String, Object?>? _read() {
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException {
      return file.existsSync() ? null : {'format': 1, 'entries': <Object?>[]};
    } on FormatException {
      return null;
    }
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return {'format': 1, 'entries': <Object?>[]};
    }
    if (json is Map && json['format'] == 1 && json['entries'] is List) {
      return {for (final e in json.entries) e.key as String: e.value};
    }
    return null;
  }

  /// The entries this build can read, oldest first.
  List<AiActivityEntry> entries() => [
    for (final e in (_read()?['entries'] as List?) ?? const []) ?AiActivityEntry.fromJson(e),
  ];

  /// The entries about a target of [kind] with [id] (a box, a page or a
  /// binder), oldest first.
  List<AiActivityEntry> entriesFor(AiCodeTargetKind kind, String id) => [
    for (final e in entries())
      if (e.target.kind == kind && e.target.id == id) e,
  ];

  /// Adds [entry] at the end and drops the oldest beyond the cap. Returns
  /// whether it was written: it isn't when the file can't be read (or is in
  /// another format), which is then left alone, or when another process holds
  /// the lock (`ai-activity.json.lock`) for more than about two seconds. The
  /// app's single-instance guard covers the common case.
  bool append(AiActivityEntry entry) {
    try {
      return withFileLock(file, () {
        final json = _read();
        if (json == null) return false;
        final list = [...json['entries']! as List, entry.toJson()];
        json['entries'] = list.length > maxEntries ? list.sublist(list.length - maxEntries) : list;
        writeFileAtomically(file, '${jsonEncode(json)}\n');
        return true;
      });
    } on FileLockTimeout {
      return false;
    }
  }
}
