// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:noted_core/noted_core_read.dart';

import 'closed_access.dart';
import 'library.dart';
import 'link_client.dart';
import 'running_probe.dart';
import 'tools.dart';

/// What the AI is told when Noted is running (it holds its lock) but its link
/// gave no answer. Nothing was changed.
const String notedBusyText = "Noted is running but didn't answer; try again.";

/// A new random session id: 32 random bytes in base64url, without padding.
/// Each server process makes one at start; the app asks the user to allow a
/// code from a session it hasn't seen.
String newSessionId() {
  final random = Random.secure();
  return base64Url.encode([for (var i = 0; i < 32; i++) random.nextInt(256)]).replaceAll('=', '');
}

/// The app name to send: the MCP client's name, then its version if it said
/// one, cut to [aiLinkMaxAppLength]. Null if there is no name.
String? appLabel(String? name, [String? version]) {
  // Control characters (newlines included) become spaces: the name is shown
  // to the user in a prompt and stored.
  final n = (name ?? '').replaceAll(RegExp(r'[\x00-\x1F\x7F-\x9F]'), ' ').trim();
  if (n.isEmpty) return null;
  final v = (version ?? '').replaceAll(RegExp(r'[\x00-\x1F\x7F-\x9F]'), ' ').trim();
  final label = v.isEmpty ? n : '$n $v';
  return label.length > aiLinkMaxAppLength ? label.substring(0, aiLinkMaxAppLength) : label;
}

/// What the AI is told for a failed request.
///
/// Never includes the code. The text is this server's own for every code it
/// knows, so it reads the same however the app words it.
ToolOutput linkErrorOutput(AiLinkError e) {
  final text = switch (e.code) {
    AiLinkCode.notRunning => AiLinkCode.notRunning.defaultMessage,
    AiLinkCode.badCode =>
      'The code is not valid: it may be mistyped, or the user may have revoked it. Ask the user for the code again.',
    AiLinkCode.expired => 'The code has expired. Ask the user for a new one.',
    AiLinkCode.notApproved =>
      e.message == approveInNotedFirst ? approveInNotedFirst : "The user hasn't allowed this connection in Noted.",
    AiLinkCode.notPermitted => AiLinkCode.notPermitted.defaultMessage,
    AiLinkCode.wrongRole =>
      'This code does not allow that. A Reader code cannot write, and a box code reads only its own box '
          '(with read_box), not pages.',
    AiLinkCode.noBox => 'No such box, or this code does not reach it.',
    AiLinkCode.noRequest =>
      'No such merge request: it may have expired (they last 10 minutes), been withdrawn by the user, or '
          'already been answered. Call merge_requests to see what is waiting.',
    AiLinkCode.conflict => 'The box has a sync conflict in Noted and cannot be written to. Nothing was changed.',
    AiLinkCode.locked => 'The page cannot be edited right now (its binder is locked, or it is read-only). Nothing was changed.',
    AiLinkCode.notWritable when e.message == closedWritesOffText => closedWritesOffText,
    AiLinkCode.notWritable => 'This box does not take writes from an AI right now. Nothing was changed.',
    AiLinkCode.saveFailed => 'Noted could not save the change. Nothing was changed.',
    AiLinkCode.busy when e.message == notedBusyText => notedBusyText,
    AiLinkCode.busy when e.message == storeUnreadableText => storeUnreadableText,
    AiLinkCode.busy =>
      'Noted is busy (it may still be starting, or cannot read its codes for a moment). Nothing was changed. Try again in a moment.',
    AiLinkCode.badRequest => e.message,
    AiLinkCode.unknown => '${e.message} (${e.wireCode})',
  };
  return (text: text, isError: true);
}

/// The tools of the MCP server for one server process: each call reads the
/// saved files afresh, and a call with a code asks the running app first
/// ([AiLinkClient]).
///
/// - No code: Open pages only, read from saved files; works with Noted
///   closed.
/// - A page or binder code: the app answers with the Privileged pages the
///   code covers; the Open pages stay readable too.
/// - A box code: the app answers with that one box. Nothing about its page
///   (title, id, siblings) is in the output.
/// - A write always needs a code and the app.
///
/// Every answer is built here from saved files, never from the live screen
/// (invariant 4); the app only decides who may read what.
final class NotedToolbox {
  NotedToolbox(
    this.dataDir, {
    String? session,
    this.app,
    this.connectTimeout,
    this.greetingTimeout,
    this.responseTimeout,
    this.beforeClosedReplace,
  }) : session = session ?? newSessionId();

  /// Test hook: see [ClosedAccess.beforeReplace].
  final Future<void> Function(int attempt)? beforeClosedReplace;

  final Directory dataDir;

  /// This process's random session id.
  final String session;

  /// The MCP client's name (and version), known after `initialize`.
  String? app;

  final Duration? connectTimeout;
  final Duration? greetingTimeout;
  final Duration? responseTimeout;

  AiLinkClient get _client => AiLinkClient(
    dataDir,
    session: session,
    app: app,
    connectTimeout: connectTimeout ?? const Duration(seconds: 2),
    greetingTimeout: greetingTimeout ?? const Duration(seconds: 2),
    responseTimeout: responseTimeout ?? const Duration(seconds: 55),
  );

  /// Whether Noted is running: it holds its lock, or (defence in depth) the
  /// lock says closed but its link file is there and greets with the nonce.
  /// Only then is the link used; otherwise the server works closed.
  Future<bool> _running() async => await isNotedRunning(dataDir) || await _client.greets();

  ClosedAccess get _closed => ClosedAccess(dataDir, app: app, beforeReplace: beforeClosedReplace);

  /// While Noted holds its lock it is running: if its link doesn't answer
  /// (a busy listener, a slow greeting), the answer is "busy", and the server
  /// never falls back to reading codes or writing files itself.
  static AiLinkResponse _ifNoAnswer(AiLinkResponse r) =>
      r is AiLinkError && r.code == AiLinkCode.notRunning ? AiLinkError(AiLinkCode.busy, notedBusyText) : r;

  static ToolOutput _error(String text) => (text: text, isError: true);

  static final ToolOutput _badCode = linkErrorOutput(AiLinkError(AiLinkCode.badCode));

  /// [code] trimmed, or null if the AI gave none (an empty string is none).
  static String? _clean(String? code) {
    final c = code?.trim();
    return c == null || c.isEmpty ? null : c;
  }

  Future<NotedLibrary> _load() => NotedLibrary.load(dataDir);

  // ---------------------------------------------------------------------------
  // reads

  Future<ToolOutput> listPages({String? code}) =>
      _pageTool(code, AiLinkAction.listPages, null, (tools) => tools.listPages());

  Future<ToolOutput> readPage(String pageId, {String? code}) =>
      _pageTool(code, AiLinkAction.readPage, pageId, (tools) => tools.readPage(pageId));

  Future<ToolOutput> search(String query, {String? code}) =>
      _pageTool(code, AiLinkAction.search, query, (tools) => tools.search(query));

  /// [pageId] narrows a read of an Open or granted page (box ids are only
  /// unique per page); a box code ignores it.
  Future<ToolOutput> readBox(String boxId, {String? code, String? pageId}) async {
    final c = _clean(code);
    if (c == null) return NotedTools(await _load()).readBox(boxId, pageId: pageId);
    final grant = await _grant(c, AiLinkAction.readBox, boxId);
    if (grant is ToolOutput) return grant;
    switch (grant) {
      case AiLinkBoxGrant():
        // The app granted one box; it must be the one asked for.
        if (grant.box != boxId) return _error(noSuchBox(boxId));
        return NotedTools(await _load(), openPages: false).readGrantedBox(grant);
      case AiLinkPagesGrant():
        return NotedTools(await _load(), granted: grant.pages.toSet()).readBox(boxId, pageId: pageId);
      default:
        return _error("Noted's answer wasn't understood.");
    }
  }

  Future<ToolOutput> _pageTool(
    String? code,
    AiLinkAction action,
    String? target,
    ToolOutput Function(NotedTools tools) run,
  ) async {
    final c = _clean(code);
    var granted = <String>{};
    if (c != null) {
      final grant = await _grant(c, action, target);
      if (grant is ToolOutput) return grant;
      switch (grant) {
        case AiLinkPagesGrant():
          granted = grant.pages.toSet();
        case AiLinkBoxGrant():
          // A box code is for one box, not pages.
          return linkErrorOutput(AiLinkError(AiLinkCode.wrongRole));
        default:
          return _error("Noted's answer wasn't understood.");
      }
    }
    return run(NotedTools(await _load(), granted: granted));
  }

  /// Asks the app for a grant: an [AiLinkGrant], or the [ToolOutput] error to
  /// return (a malformed code never reaches the app).
  Future<Object> _grant(String code, AiLinkAction action, String? target) async {
    if (parseAiToken(code) == null) return _badCode;
    final response = await _running()
        ? _ifNoAnswer(
            await _client.send(AiLinkAccess(code: code, session: session, app: app, action: action, target: target)),
          )
        : await _closed.grant(code, action, target: target);
    return switch (response) {
      AiLinkGranted(:final grant) => grant,
      AiLinkError() => linkErrorOutput(response),
      _ => _error("Noted's answer wasn't understood."),
    };
  }

  // ---------------------------------------------------------------------------
  // write_box and describe_code

  /// Asks the app to write [content] (markdown) to the AI box [boxId] with
  /// the Writer [code].
  Future<ToolOutput> writeBox({
    required String boxId,
    required String? code,
    required String mode,
    required String content,
  }) async {
    final c = _clean(code);
    if (c == null) {
      return _error(
        'write_box needs the code the user gave you for this box (a Writer code). Ask the user for it.',
      );
    }
    if (parseAiToken(c) == null) return _badCode;
    final m = AiLinkMode.fromWire(mode);
    if (m == null) return _error('mode must be "append", "replace_ai" or "replace".');
    if (boxId.isEmpty) return _error('box_id is required.');
    final response = await _running()
        ? _ifNoAnswer(
            await _client.send(
              AiLinkWriteBox(code: c, session: session, app: app, box: boxId, mode: m, content: content),
            ),
          )
        : await _closed.write(token: c, boxId: boxId, mode: m, content: content);
    return switch (response) {
      AiLinkWritten(:final box) => (text: 'Written to box $box.', isError: false),
      AiLinkError() => linkErrorOutput(response),
      _ => _error("Noted's answer wasn't understood."),
    };
  }

  // ---------------------------------------------------------------------------
  // merge_requests and propose_merge (run 2026-11-01-04)

  /// The sync-conflict merges the user asked the page AI for that [code]
  /// reaches, as JSON. Needs Noted running: the requests exist only in the
  /// app, which builds the two versions from the saved page file.
  Future<ToolOutput> mergeRequests(String? code) async {
    final c = _clean(code);
    if (c == null || parseAiToken(c) == null) return _badCode;
    if (!await _running()) return linkErrorOutput(AiLinkClient.notRunning);
    final response = _ifNoAnswer(await _client.send(AiLinkMergeRequests(code: c, session: session, app: app)));
    return switch (response) {
      AiLinkMerges(:final items) when items.isEmpty => (
        text: 'No merge requests are waiting for this code. The user asks for one in Noted, from a sync conflict.',
        isError: false,
      ),
      AiLinkMerges(:final items) => await _mergeOutput(items),
      AiLinkError() => linkErrorOutput(response),
      _ => _error("Noted's answer wasn't understood."),
    };
  }

  // The app granted these requests (it checked the code and that the pages
  // are readable). The content comes from here: the saved page file's
  // conflict record, rendered by the same code as read_box, which re-checks
  // each page's access in the saved settings. A request this server can't
  // show is listed as unavailable, never dropped.
  Future<ToolOutput> _mergeOutput(List<AiLinkMergeItem> items) async {
    final tools = NotedTools(await _load(), granted: {for (final i in items) i.page});
    Map<String, Object?> label(AiLinkMergeVersion v) => {'device': v.device, 'at': v.at};
    final out = <Map<String, Object?>>[];
    for (final i in items) {
      final v = tools.conflictVersions(i.page, i.box);
      out.add({
        'id': i.id,
        'page': i.page,
        'box': i.box,
        'type': i.type,
        if (v == null)
          'unavailable':
              'These versions cannot be shown (the page is not readable by an AI, the box is encrypted, '
              'a version is too large, or the conflict has been settled).'
        else ...{
          'mine': {...label(i.mine), 'markdown': v.mine},
          'theirs': {...label(i.theirs), 'markdown': v.theirs},
        },
      });
    }
    return (text: const JsonEncoder.withIndent('  ').convert({'requests': out}), isError: false);
  }

  /// Sends the merged markdown for the request [requestId]. The user decides
  /// in Noted; nothing changes until they accept.
  Future<ToolOutput> proposeMerge({
    required String? code,
    required String requestId,
    required String content,
  }) async {
    final c = _clean(code);
    if (c == null || parseAiToken(c) == null) return _badCode;
    if (requestId.trim().isEmpty) return _error('request_id is required (from merge_requests).');
    if (!await _running()) return linkErrorOutput(AiLinkClient.notRunning);
    final response = _ifNoAnswer(
      await _client.send(
        AiLinkProposeMerge(code: c, session: session, app: app, request: requestId.trim(), content: content),
      ),
    );
    return switch (response) {
      AiLinkProposed() => (
        text: 'Proposed. The user sees your merge next to both versions in Noted and decides; nothing has changed yet.',
        isError: false,
      ),
      AiLinkError() => linkErrorOutput(response),
      _ => _error("Noted's answer wasn't understood."),
    };
  }

  /// What [code] grants, from the app: kind (box, page or binder), id, role
  /// and expiry, as JSON.
  Future<ToolOutput> describeCode(String? code) async {
    final c = _clean(code);
    if (c == null || parseAiToken(c) == null) return _badCode;
    if (!await _running()) return linkErrorOutput(AiLinkClient.notRunning);
    final response = _ifNoAnswer(await _client.send(AiLinkDescribeCode(code: c, session: session, app: app)));
    return switch (response) {
      AiLinkDescribed() => (
        text: const JsonEncoder.withIndent(
          '  ',
        ).convert({'kind': response.kind, 'id': response.id, 'role': response.role, 'expires': response.expires}),
        isError: false,
      ),
      AiLinkError() => linkErrorOutput(response),
      _ => _error("Noted's answer wasn't understood."),
    };
  }
}
