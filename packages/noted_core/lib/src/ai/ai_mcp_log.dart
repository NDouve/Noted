// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'ai_code.dart';
import 'ai_link.dart';

/// The name of the MCP server's access log, beside `ai-access.json` in the
/// app's data folder (run 2026-11-01-03). The server appends to it, one JSON
/// object per line, and never edits or deletes a line. Noted merges the
/// entries into each box's activity and may trim the file. Local to the
/// device: never synced.
const String aiMcpLogFileName = 'ai-mcp-log.jsonl';

/// The `result` of an entry that did what was asked.
const String aiMcpResultOk = 'ok';

/// The `result` of an entry for a code that was refused because the user has
/// not approved it yet (Noted was closed). Noted asks about such codes the
/// next time it opens.
const String aiMcpResultPendingApproval = 'pending_approval';

/// One line of the server's access log: a code-based read or write the
/// server handled while Noted wasn't running.
///
/// ```json
/// {"time":"ISO","code":"<code id>","target":{"kind":"box","id":"…","page":"…"},
///  "op":"write_box","app":"<MCP client>","label":"<code label>",
///  "result":"ok"}
/// ```
///
/// `code` is the code's id (16 hex characters), never the key. `result` is
/// [aiMcpResultOk], an [AiLinkCode] wire value (`not_permitted`, `expired`,
/// …), `ambiguous`, `binder_unusable` (the MCP server's own refusals) or
/// [aiMcpResultPendingApproval].
final class AiMcpLogEntry {
  const AiMcpLogEntry({
    required this.time,
    required this.code,
    required this.target,
    required this.op,
    required this.result,
    this.app = '',
    this.label = '',
  });

  final DateTime time;

  /// The id of the code used.
  final String code;

  /// What the request was about: a box, a page or a binder. For a box, `page`
  /// is the page it was on, when the server knew.
  final AiCodeTarget target;

  /// The operation, such as `write_box`, `read_box`, `read_page`,
  /// `list_pages` or `search`.
  final String op;

  /// The MCP client's name, if it said ('' otherwise).
  final String app;

  /// The label of the code when the server handled the request.
  final String label;

  /// `ok`, an error code, or `pending_approval`.
  final String result;

  bool get isOk => result == aiMcpResultOk;
  bool get isPendingApproval => result == aiMcpResultPendingApproval;

  /// Reads one entry, or null if it lacks a valid time, code, target, op or
  /// result.
  static AiMcpLogEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final time = json['time'];
    final code = json['code'];
    final op = json['op'];
    final result = json['result'];
    final target = AiCodeTarget.fromJson(json['target']);
    if (time is! String || code is! String || code.isEmpty) return null;
    if (op is! String || op.isEmpty || result is! String || result.isEmpty || target == null) return null;
    final t = DateTime.tryParse(time);
    if (t == null) return null;
    final app = json['app'];
    final label = json['label'];
    return AiMcpLogEntry(
      time: t.toUtc(),
      code: code,
      target: target,
      op: op,
      app: app is String ? app : '',
      label: label is String ? label : '',
      result: result,
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
  };

  /// The entry as one line, without the newline.
  String encode() => jsonEncode(toJson());
}

/// Reads the text of the log: every line that is a valid entry, in file
/// order. A blank line, a line that isn't JSON (a half-written last line,
/// say) and a line that isn't a valid entry are skipped, so one bad line never
/// hides the rest.
List<AiMcpLogEntry> parseAiMcpLog(String text) {
  if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) text = text.substring(1);
  final entries = <AiMcpLogEntry>[];
  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isEmpty) continue;
    final Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException {
      continue;
    }
    final entry = AiMcpLogEntry.fromJson(json);
    if (entry != null) entries.add(entry);
  }
  return entries;
}
