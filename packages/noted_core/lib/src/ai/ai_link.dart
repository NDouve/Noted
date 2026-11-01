// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// The local link between the MCP server and the running Noted app, protocol
/// `ai-link/2` (run 2026-11-01-02, replacing `ai-link/1`).
///
/// The server never writes a file and never decides who may read what. For a
/// write, and for every request that carries a code, it asks the app, which
/// decides (invariant 4).
///
/// - The app listens on 127.0.0.1 only, on a free port, and writes
///   [aiLinkFileName] in its data folder (next to settings.json):
///   `{"format":1,"port":N,"pid":P,"nonce":NONCE}`, where NONCE is 32 random
///   bytes in base64url, new at every launch. It deletes the file on a clean
///   exit. [readAiLink] reads the port and nonce from it.
/// - Greeting: when a client connects, the app first sends one line,
///   `{"noted":"ai-link/2","nonce":NONCE}` ([aiLinkGreeting]). The client reads
///   it ([readAiLinkGreeting]) and checks the nonce against the file. Only
///   then does it send its request. A wrong or missing greeting means the
///   client sends nothing and reports `not_running`: something else is
///   listening on that port, and the code must not be handed to it.
/// - One request per TCP connection: one UTF-8 JSON object on a single line
///   ending in `\n`, at most [aiLinkMaxRequestBytes]; the app answers with one
///   response line, then the connection closes.
/// - Every request has `"noted":"ai-link/2"`, `"op"`, `"code"` (the whole
///   code, `noted_<id>_<key>`), `"session"` (the server process's random id)
///   and optionally `"app"` (the MCP client's name). Ops ([AiLinkRequest]):
///   - `write_box`: `box`, `mode` (`append`|`replace_ai`|`replace`; the box's
///     Writer permission decides which are allowed, else `not_permitted`),
///     `content` (markdown).
///     Answer: `{"ok":true,"box":BOX_ID}`; the answer gives no page id or
///     title (an AI sees boxes by id only).
///   - `access`: `action` (`read_box`|`read_page`|`list_pages`|`search`) and
///     optionally `target`. The app checks the code, its expiry and its
///     approval (once per code, 0108 as amended), logs the action, and answers with a grant: either
///     `{"ok":true,"grant":{"kind":"box","box":ID,"page":ID}}` or
///     `{"ok":true,"grant":{"kind":"pages","pages":[PAGE_ID,...]}}`. The
///     server then reads the saved files itself; content is never taken from
///     the live screen.
///   - `describe_code`: answer `{"ok":true,"kind":"box"|"page"|"binder",
///     "id":ID,"role":ROLE,"expires":ISO|null}`.
/// - Errors: `{"ok":false,"code":"<code>","message":"<text for the AI>"}`
///   ([AiLinkResponse], [AiLinkCode]).
///
/// What the app's listener must do:
/// - bind 127.0.0.1 only;
/// - enforce [aiLinkMaxRequestBytes] while reading, not after;
/// - drop a connection whose first byte isn't `{`, and one whose line
///   [AiLinkRequest.parse] returns null for (not this protocol, such as an
///   HTTP request): close at once, with no answer;
/// - answer `bad_request` to an [AiLinkMalformed] request;
/// - time out a read after [aiLinkReadTimeout] (5 s), except while it waits
///   for the user to approve a session ([aiLinkApprovalTimeout]);
/// - hold at most [aiLinkMaxConnections] (8) connections at once;
/// - check the code before it looks up anything it points at;
/// - after an approval prompt returns (a session, or a write), check the code
///   again before it acts: it may have been revoked or expired meanwhile;
/// - make the nonce random per launch (the pure helpers here don't make one).
library;

import 'dart:convert';

/// The name of the file in the app's data folder that holds the port.
const String aiLinkFileName = 'ai-link.json';

/// The most bytes a request line may have, including the newline.
const int aiLinkMaxRequestBytes = 1 << 20;

/// How long the app waits for a request before it drops the connection.
const Duration aiLinkReadTimeout = Duration(seconds: 5);

/// How long a request may wait for the user to allow a session or a write
/// before the app answers `not_approved`.
const Duration aiLinkApprovalTimeout = Duration(seconds: 45);

/// The most connections the app serves at the same time.
const int aiLinkMaxConnections = 8;

/// The longest `session` and `app` a request may carry (they are shown to the
/// user and stored); longer ones parse as [AiLinkMalformed].
const int aiLinkMaxSessionLength = 128;
const int aiLinkMaxAppLength = 200;

/// The value of `"noted"` in a request and in the greeting.
const String aiLinkProtocol = 'ai-link/2';

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

/// How a write changes the box, as `write_box`'s `mode` says it: `append`,
/// `replace_ai` (replace the box's AI-written text, keep the user's) or
/// `replace` (the whole box; empty content empties it). It mirrors
/// `AiWriteMode` ([replaceAi] is `AiWriteMode.replaceAiText`).
enum AiLinkMode {
  append('append'),
  replaceAi('replace_ai'),
  replace('replace');

  const AiLinkMode(this.wire);

  /// The value on the wire.
  final String wire;

  static AiLinkMode? fromWire(Object? wire) {
    for (final m in values) {
      if (m.wire == wire) return m;
    }
    return null;
  }
}

/// What an `access` request asks to do.
enum AiLinkAction {
  readBox('read_box'),
  readPage('read_page'),
  listPages('list_pages'),
  search('search');

  const AiLinkAction(this.wire);

  final String wire;

  static AiLinkAction? fromWire(Object? wire) {
    for (final a in values) {
      if (a.wire == wire) return a;
    }
    return null;
  }
}

/// A request from the MCP server to the app.
sealed class AiLinkRequest {
  const AiLinkRequest({required this.code, required this.session, this.app});

  /// The whole code, `noted_<id>_<key>`.
  final String code;

  /// The server process's random session id.
  final String session;

  /// The MCP client's name, if it said.
  final String? app;

  /// The `op` on the wire.
  String get op;

  Map<String, Object?> _fields();

  /// The request as one line, without the newline.
  String encode() => jsonEncode({
    'noted': aiLinkProtocol,
    'op': op,
    'code': code,
    'session': session,
    if (app != null) 'app': app,
    ..._fields(),
  });

  /// Reads a request line.
  ///
  /// Returns null for anything that isn't a JSON object with
  /// `"noted":"ai-link/2"`: HTTP, other protocols, garbage. The listener
  /// drops such a connection without answering. A line that is this protocol
  /// but has an unknown `op` or a missing or mistyped field comes back as an
  /// [AiLinkMalformed], which the listener answers with `bad_request`.
  static AiLinkRequest? parse(String line) {
    final Object? json;
    try {
      json = jsonDecode(line.trim());
    } on FormatException {
      return null;
    }
    if (json is! Map || json['noted'] != aiLinkProtocol) return null;
    final code = json['code'];
    final session = json['session'];
    final appValue = json['app'];
    if (code is! String || session is! String || session.isEmpty) {
      return const AiLinkMalformed('The request needs a code and a session.');
    }
    if (session.length > aiLinkMaxSessionLength) {
      return const AiLinkMalformed('The session is too long.');
    }
    if (json.containsKey('app') && appValue is! String) {
      return const AiLinkMalformed('The app name must be text.');
    }
    if (appValue is String && appValue.length > aiLinkMaxAppLength) {
      return const AiLinkMalformed('The app name is too long.');
    }
    final app = appValue as String?;
    switch (json['op']) {
      case 'write_box':
        final box = json['box'];
        final content = json['content'];
        final mode = AiLinkMode.fromWire(json['mode']);
        if (box is! String || content is! String || mode == null) {
          return const AiLinkMalformed('write_box needs box, mode (append, replace_ai or replace) and content.');
        }
        return AiLinkWriteBox(
          code: code,
          session: session,
          app: app,
          box: box,
          mode: mode,
          content: content,
        );
      case 'access':
        final action = AiLinkAction.fromWire(json['action']);
        final target = json['target'];
        if (action == null || (json.containsKey('target') && target != null && target is! String)) {
          return const AiLinkMalformed('access needs an action: read_box, read_page, list_pages or search.');
        }
        if ((action == AiLinkAction.readBox || action == AiLinkAction.readPage) &&
            (target is! String || target.isEmpty)) {
          return const AiLinkMalformed('read_box and read_page need a target.');
        }
        return AiLinkAccess(
          code: code,
          session: session,
          app: app,
          action: action,
          target: target as String?,
        );
      case 'describe_code':
        return AiLinkDescribeCode(code: code, session: session, app: app);
    }
    return const AiLinkMalformed('Unknown op.');
  }
}

/// A request to write to an AI box.
final class AiLinkWriteBox extends AiLinkRequest {
  const AiLinkWriteBox({
    required super.code,
    required super.session,
    super.app,
    required this.box,
    required this.mode,
    required this.content,
  });

  final String box;
  final AiLinkMode mode;

  /// Markdown.
  final String content;

  @override
  String get op => 'write_box';

  @override
  Map<String, Object?> _fields() => {'box': box, 'mode': mode.wire, 'content': content};
}

/// A request for permission to read: the app answers with a grant.
final class AiLinkAccess extends AiLinkRequest {
  const AiLinkAccess({
    required super.code,
    required super.session,
    super.app,
    required this.action,
    this.target,
  });

  final AiLinkAction action;

  /// The box id for `read_box`, the page id for `read_page`; unused (or the
  /// query, for the activity log) for the other actions.
  final String? target;

  @override
  String get op => 'access';

  @override
  Map<String, Object?> _fields() => {'action': action.wire, if (target != null) 'target': target};
}

/// A request for what a code points at and may do.
final class AiLinkDescribeCode extends AiLinkRequest {
  const AiLinkDescribeCode({required super.code, required super.session, super.app});

  @override
  String get op => 'describe_code';

  @override
  Map<String, Object?> _fields() => const {};
}

/// A line in this protocol that the app can't act on. It is not sent, only
/// returned by [AiLinkRequest.parse]; answer it with `bad_request`.
final class AiLinkMalformed extends AiLinkRequest {
  const AiLinkMalformed(this.message) : super(code: '', session: '');

  /// What was wrong, for the answer.
  final String message;

  @override
  String get op => '';

  @override
  Map<String, Object?> _fields() => const {};
}

/// Why a request failed.
enum AiLinkCode {
  badRequest('bad_request', 'The request was not understood.'),

  /// Unknown, revoked or malformed.
  badCode('bad_code', 'The code is not valid. It may have been revoked.'),

  /// Past its expiry.
  expired('expired', 'The code has expired.'),

  /// The user did not allow it: denied, or no answer in time.
  notApproved('not_approved', 'The user did not allow this.'),

  /// A Reader tried to write, or a code was used for what it doesn't cover
  /// (a box code for pages).
  wrongRole('wrong_role', 'This code does not allow that.'),

  /// No such box, or its page is not one the code reaches: the same answer
  /// either way.
  noBox('no_box', 'No such box.'),

  /// The box is conflicted (0020).
  conflict('conflict', 'The box has a sync conflict and cannot be written to.'),

  /// The page can't be edited: a locked binder or a read-only page.
  locked('locked', 'The page cannot be edited right now.'),
  notWritable('not_writable', 'This box does not take writes from an AI.'),

  /// The mode is outside the box's Writer permission (append, edit or full).
  notPermitted(
    'not_permitted',
    "This box's Writer permission doesn't allow that. Ask the user to change it in the box.",
  ),
  saveFailed('save_failed', 'The app could not save the change.'),

  /// The app can't take a request yet (it is still opening the notebook, or
  /// can't read its codes for a moment): nothing was changed.
  busy('busy', 'Noted is busy (it may still be starting), so nothing was changed. Try again in a moment.'),

  /// Used by the client only, when the app can't be reached.
  notRunning(
    'not_running',
    'This needs Noted running: codes are checked by the app. Open Noted and try again.',
  ),

  /// A code from a newer app that this build doesn't know (see
  /// [AiLinkError.wireCode]). Never sent by this build.
  unknown('unknown', 'The request failed.');

  const AiLinkCode(this.wire, this.defaultMessage);

  /// The name on the wire.
  final String wire;
  final String defaultMessage;

  /// The known code named [wire], or null (including for `unknown`).
  static AiLinkCode? fromWire(Object? wire) {
    for (final c in values) {
      if (c != unknown && c.wire == wire) return c;
    }
    return null;
  }
}

/// What an `access` request is granted: how the server reads saved files.
sealed class AiLinkGrant {
  const AiLinkGrant();

  Map<String, Object?> toJson();

  static AiLinkGrant? fromJson(Object? json) {
    if (json is! Map) return null;
    switch (json['kind']) {
      case 'box':
        final box = json['box'];
        final page = json['page'];
        return box is String && page is String ? AiLinkBoxGrant(box: box, page: page) : null;
      case 'pages':
        final pages = json['pages'];
        if (pages is! List || pages.any((p) => p is! String)) return null;
        return AiLinkPagesGrant(pages: List<String>.unmodifiable(pages.cast<String>()));
    }
    return null;
  }
}

/// One box, and the page it is on (for the server to find the saved file).
final class AiLinkBoxGrant extends AiLinkGrant {
  const AiLinkBoxGrant({required this.box, required this.page});

  final String box;
  final String page;

  @override
  Map<String, Object?> toJson() => {'kind': 'box', 'box': box, 'page': page};
}

/// The ids of the pages the code lets the AI read, besides the Open ones.
final class AiLinkPagesGrant extends AiLinkGrant {
  const AiLinkPagesGrant({required this.pages});

  final List<String> pages;

  @override
  Map<String, Object?> toJson() => {'kind': 'pages', 'pages': pages};
}

/// The app's answer to an [AiLinkRequest].
sealed class AiLinkResponse {
  const AiLinkResponse();

  /// The answer to a `write_box`.
  const factory AiLinkResponse.written({required String box}) = AiLinkWritten;

  /// The answer to an `access`.
  const factory AiLinkResponse.granted(AiLinkGrant grant) = AiLinkGranted;

  /// The answer to a `describe_code`.
  const factory AiLinkResponse.described({
    required String kind,
    required String id,
    required String role,
    String? expires,
  }) = AiLinkDescribed;

  /// A failure.
  factory AiLinkResponse.error(AiLinkCode code, [String? message]) = AiLinkError;

  bool get ok => this is! AiLinkError;

  /// The response as one line, without the newline.
  String encode();

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
      if (json.containsKey('grant')) {
        final grant = AiLinkGrant.fromJson(json['grant']);
        return grant == null ? null : AiLinkGranted(grant);
      }
      if (json.containsKey('kind')) {
        final kind = json['kind'];
        final id = json['id'];
        final role = json['role'];
        final expires = json['expires'];
        if (kind is! String || id is! String || role is! String) return null;
        if (expires != null && expires is! String) return null;
        return AiLinkDescribed(kind: kind, id: id, role: role, expires: expires as String?);
      }
      final box = json['box'];
      return box is String ? AiLinkWritten(box: box) : null;
    }
    if (json['ok'] != false) return null;
    // A code from a newer app is a failure this build doesn't know: keep its
    // wire code and the app's message, which still says what happened.
    final code = AiLinkCode.fromWire(json['code']);
    final message = json['message'];
    if (code == null) {
      final wire = json['code'];
      return wire is String && message is String ? AiLinkError(AiLinkCode.unknown, message, wire) : null;
    }
    return AiLinkError(code, message is String ? message : null);
  }
}

/// A write went through.
final class AiLinkWritten extends AiLinkResponse {
  const AiLinkWritten({required this.box});

  final String box;

  @override
  String encode() => jsonEncode({'ok': true, 'box': box});
}

/// What an `access` is granted.
final class AiLinkGranted extends AiLinkResponse {
  const AiLinkGranted(this.grant);

  final AiLinkGrant grant;

  @override
  String encode() => jsonEncode({'ok': true, 'grant': grant.toJson()});
}

/// What a code is.
final class AiLinkDescribed extends AiLinkResponse {
  const AiLinkDescribed({
    required this.kind,
    required this.id,
    required this.role,
    this.expires,
  });

  /// `box`, `page` or `binder`.
  final String kind;

  /// The box id, the page id, or a stable binder id (no title).
  final String id;

  /// The role as stored (`writer`, `reader`, or one this build doesn't know).
  final String role;

  /// ISO 8601, or null for a code that doesn't expire.
  final String? expires;

  @override
  String encode() => jsonEncode({'ok': true, 'kind': kind, 'id': id, 'role': role, 'expires': expires});
}

/// A request that failed.
final class AiLinkError extends AiLinkResponse {
  /// [wireCode] is only for [AiLinkCode.unknown]: the code as the app wrote
  /// it.
  AiLinkError(this.code, [String? message, String? wireCode])
    : message = message ?? code.defaultMessage,
      wireCode = code == AiLinkCode.unknown ? (wireCode ?? code.wire) : code.wire;

  final AiLinkCode code;
  final String message;

  /// The code as it is on the wire: [AiLinkCode.wire], or for an unknown code
  /// from a newer app, the text it sent.
  final String wireCode;

  @override
  String encode() => jsonEncode({'ok': false, 'code': wireCode, 'message': message});
}
