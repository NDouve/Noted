// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// The local link between the MCP server and the running Noted app (run
/// 2026-10-31-02).
///
/// The server never writes a file. To change a box it asks the app, which
/// decides (invariant 4).
///
/// - The app listens on 127.0.0.1 only, on a free port, and writes
///   [aiLinkFileName] in its data folder (next to settings.json):
///   `{"format":1,"port":N,"pid":P,"nonce":NONCE}`, where NONCE is 32 random
///   bytes in base64url, new at every launch. It deletes the file on a clean
///   exit. [readAiLink] reads the port and nonce from it.
/// - Greeting: when a client connects, the app first sends one line,
///   `{"noted":"ai-link/1","nonce":NONCE}` ([aiLinkGreeting]). The client reads
///   it ([readAiLinkGreeting]) and checks the nonce against the file. Only
///   then does it send its request. A wrong or missing greeting means the
///   client sends nothing and reports `not_running`: something else is
///   listening on that port, and the token must not be handed to it.
/// - One request per TCP connection: one UTF-8 JSON object on a single line
///   ending in `\n`, at most [aiLinkMaxRequestBytes]; the app answers with one
///   response line, then the connection closes.
/// - Request: `{"noted":"ai-link/1","token":"...","op":"write_box",
///   "box":BOX_ID,"mode":"replace"|"append","content":MARKDOWN}`
///   ([AiLinkRequest]).
/// - Response: `{"ok":true,"page":"<page id>","box":"<box id>"}` or
///   `{"ok":false,"code":"<code>","message":"<text for the AI>"}`
///   ([AiLinkResponse], [AiLinkCode]).
///
/// What the app's listener must do:
/// - bind 127.0.0.1 only;
/// - enforce [aiLinkMaxRequestBytes] while reading, not after;
/// - drop a connection whose first byte isn't `{`;
/// - time out a read after [aiLinkReadTimeout] (5 s);
/// - hold at most [aiLinkMaxConnections] (8) connections at once;
/// - check the token before it looks up the box;
/// - make the nonce random per launch (the pure helpers here don't make one).
library;

import 'dart:convert';

/// The name of the file in the app's data folder that holds the port.
const String aiLinkFileName = 'ai-link.json';

/// The most bytes a request line may have, including the newline.
const int aiLinkMaxRequestBytes = 1 << 20;

/// How long the app waits for a request before it drops the connection.
const Duration aiLinkReadTimeout = Duration(seconds: 5);

/// The most connections the app serves at the same time.
const int aiLinkMaxConnections = 8;

/// The value of `"noted"` in a request and in the greeting.
const String aiLinkProtocol = 'ai-link/1';

/// The port and nonce in the text of [aiLinkFileName], or null if it is
/// unreadable or has no nonce.
({int port, String nonce})? readAiLink(String fileText) {
  try {
    final json = jsonDecode(fileText);
    if (json is! Map || json['format'] != 1) return null;
    final port = json['port'];
    final nonce = json['nonce'];
    if (port is! int || port <= 0 || port >= 65536) return null;
    if (nonce is! String || nonce.isEmpty) return null;
    return (port: port, nonce: nonce);
  } on FormatException {
    return null;
  }
}

/// The greeting line (without the newline) the app sends first.
String aiLinkGreeting(String nonce) =>
    jsonEncode({'noted': aiLinkProtocol, 'nonce': nonce});

/// The nonce in a greeting line, or null if it is malformed.
String? readAiLinkGreeting(String line) {
  try {
    final json = jsonDecode(line.trim());
    if (json is! Map || json['noted'] != aiLinkProtocol) return null;
    final nonce = json['nonce'];
    return nonce is String && nonce.isNotEmpty ? nonce : null;
  } on FormatException {
    return null;
  }
}

/// How a write changes the box. It mirrors `AiWriteMode` by name; this one
/// lives here so the read-only library needs nothing from the Box API.
enum AiLinkMode { replace, append }

/// A request to write to an AI box.
final class AiLinkRequest {
  const AiLinkRequest({
    required this.token,
    required this.box,
    required this.mode,
    required this.content,
  });

  /// The whole token, `noted_<id>_<key>`.
  final String token;
  final String box;
  final AiLinkMode mode;

  /// Markdown.
  final String content;

  /// The request as one line, without the newline.
  String encode() => jsonEncode({
    'noted': aiLinkProtocol,
    'token': token,
    'op': 'write_box',
    'box': box,
    'mode': mode.name,
    'content': content,
  });

  /// Reads a request line, or null for anything malformed: not a JSON
  /// object, the wrong `noted` value, an unknown `op` or `mode`, or a field
  /// of the wrong type.
  static AiLinkRequest? decode(String line) {
    final Object? json;
    try {
      json = jsonDecode(line.trim());
    } on FormatException {
      return null;
    }
    if (json is! Map || json['noted'] != aiLinkProtocol) return null;
    if (json['op'] != 'write_box') return null;
    final token = json['token'];
    final box = json['box'];
    final content = json['content'];
    final wireMode = json['mode'];
    final mode = AiLinkMode.values.where((m) => m.name == wireMode);
    if (token is! String || box is! String || content is! String) return null;
    if (mode.isEmpty) return null;
    return AiLinkRequest(
      token: token,
      box: box,
      mode: mode.first,
      content: content,
    );
  }
}

/// Why a request failed.
enum AiLinkCode {
  badRequest('bad_request', 'The request was not understood.'),

  /// Malformed, unknown or revoked.
  badToken('bad_token', 'The token is not valid. It may have been revoked.'),

  /// No such box, or its page's AI setting is Off: the same answer either way.
  noBox('no_box', 'No such box.'),
  notOwner('not_owner', 'This box belongs to another AI connection.'),

  /// The box is conflicted (0020).
  conflict('conflict', 'The box has a sync conflict and cannot be written to.'),

  /// The page can't be edited: a locked binder or a read-only page.
  locked('locked', 'The page cannot be edited right now.'),
  notWritable('not_writable', 'This box does not take writes from an AI.'),
  saveFailed('save_failed', 'The app could not save the change.'),

  /// Used by the client only, when the app can't be reached.
  notRunning(
    'not_running',
    'Noted is not running, so nothing can be written. Ask the user to open Noted.',
  );

  const AiLinkCode(this.wire, this.defaultMessage);

  /// The name on the wire.
  final String wire;
  final String defaultMessage;

  static AiLinkCode? fromWire(Object? wire) {
    for (final c in values) {
      if (c.wire == wire) return c;
    }
    return null;
  }
}

/// The app's answer to an [AiLinkRequest].
final class AiLinkResponse {
  const AiLinkResponse.ok({required String this.page, required String this.box})
    : code = null,
      message = null;

  AiLinkResponse.error(AiLinkCode this.code, [String? message])
    : message = message ?? code.defaultMessage,
      page = null,
      box = null;

  final String? page;
  final String? box;
  final AiLinkCode? code;
  final String? message;

  bool get ok => code == null;

  /// The response as one line, without the newline.
  String encode() => ok
      ? jsonEncode({'ok': true, 'page': page, 'box': box})
      : jsonEncode({'ok': false, 'code': code!.wire, 'message': message});

  /// Reads a response line, or null if it is malformed.
  static AiLinkResponse? decode(String line) {
    final Object? json;
    try {
      json = jsonDecode(line.trim());
    } on FormatException {
      return null;
    }
    if (json is! Map) return null;
    if (json['ok'] == true) {
      final page = json['page'];
      final box = json['box'];
      if (page is! String || box is! String) return null;
      return AiLinkResponse.ok(page: page, box: box);
    }
    if (json['ok'] != false) return null;
    final code = AiLinkCode.fromWire(json['code']);
    if (code == null) return null;
    final message = json['message'];
    return AiLinkResponse.error(code, message is String ? message : null);
  }
}
