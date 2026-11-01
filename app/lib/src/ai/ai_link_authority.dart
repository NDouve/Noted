// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:noted_core/noted_core.dart';

import 'ai_access_service.dart';

/// What the user is asked to allow.
class AiApprovalRequest {
  const AiApprovalRequest({
    required this.app,
    required this.write,
    required this.label,
    required this.perWrite,
    required this.expired,
    this.preview,
    this.closedApp = false,
  });

  /// The MCP client's name.
  final String app;

  /// Whether the code may write (a Writer code); else it only reads.
  final bool write;

  /// The code's label.
  final String label;

  /// True for "ask before each write" (a single write, with a [preview]);
  /// false for the one-time approval of a code.
  final bool perWrite;

  /// True when the request was made while Noted was closed and is asked about
  /// now, at startup.
  final bool closedApp;

  /// A short look at what would be written.
  final String? preview;

  /// Completes when the request no longer waits (timed out): a dialog should
  /// close itself.
  final Future<void> expired;

  /// The question: "APP wants to read|read and write LABEL. Allow?" (the verb
  /// follows the code's role), or for a single write "APP wants to write to
  /// LABEL. Allow?". A question about a request made while Noted was closed
  /// says so.
  String get message {
    if (perWrite) return '$app wants to write to $label. Allow?';
    final what = '$app wants to ${write ? 'read and write' : 'read'} $label.';
    return closedApp ? '$what It asked while Noted was closed. Allow?' : '$what Allow?';
  }
}

/// Asks the user; true if they allowed it.
typedef AiApprover = Future<bool> Function(AiApprovalRequest request);

/// The time limits of the link, replaceable in tests.
class AiLinkTimings {
  const AiLinkTimings({
    this.approval = aiLinkApprovalTimeout,
    this.deadline = const Duration(seconds: 50),
    this.denyCooldown = const Duration(seconds: 30),
    this.closedApproval = const Duration(minutes: 5),
  });

  /// How long one question may stay open.
  final Duration approval;

  /// The whole time a request may take, shared by the approval question, the
  /// wait for the notebook to load and the per-write question. It is below
  /// the MCP client's 55 s, so the app answers before the client gives up.
  final Duration deadline;

  /// After the user denies a code, further requests of that code are refused
  /// without a question for this long.
  final Duration denyCooldown;

  /// How long a question about a request made while Noted was closed stays
  /// open (nobody is waiting for the answer, so it is longer).
  final Duration closedApproval;
}

/// How many questions may wait at once, over all codes (one on screen, the
/// rest queued); more get `busy`, so questions can't use up the link's eight
/// connections.
const int aiMaxPendingPrompts = 4;

/// How many questions one code may have waiting at once, so a code can't keep
/// the other codes' questions out.
const int aiMaxPendingPromptsPerCode = 1;

/// What the authority needs from the notebook.
abstract interface class AiLinkHost {
  /// Waits up to [timeout] for the notebook to finish loading; false if it
  /// didn't.
  Future<bool> aiWaitLoaded(Duration timeout);

  /// The page that holds box [boxId], looking at [hint] first; null if none.
  /// The page's AI access is not looked at: a box is reached by its own code.
  Future<String?> aiPageOfBox(String boxId, {String? hint});

  /// The ids of the pages the code target covers that an AI with the code may
  /// read: Open or Privileged by effective access, never Guarded, never a page
  /// of a locked binder.
  List<String> aiReadablePages(AiCodeTarget target);

  /// Applies a write (the 0106 rules without ownership and the page setting).
  /// [recheck] says whether the code still holds and the client is still
  /// there (null) or why not; call it right before the change. [confirm],
  /// when not null, asks the user about this write once the write is known to
  /// be valid: null if allowed, else the refusal (`not_approved`, or `busy`
  /// when no question can be asked now). Waiting for the load ends at
  /// [deadline].
  Future<AiLinkResponse> aiWriteBox(
    AiLinkWriteBox request,
    AiCode code, {
    required DateTime deadline,
    required AiLinkCode? Function() recheck,
    Future<AiLinkCode?> Function()? confirm,
  });
}

enum _Answer { allowed, denied, none }

/// Decides every `ai-link/2` request (invariant 4): the code, its expiry, its
/// role and target, the code's approval (asked once per code), the Writer
/// permission, the per-write question; then it
/// has the notebook act. It logs every request.
///
/// It never builds content: a read only gets a grant, and `noted_mcp` reads the
/// saved files itself.
class AiLinkAuthority {
  AiLinkAuthority({
    required this.service,
    required this.host,
    this.approver,
    this.timings = const AiLinkTimings(),
  });

  final AiAccessService service;
  final AiLinkHost host;

  /// Shows the question to the user. Null: nobody can be asked, so anything
  /// that needs approval is refused.
  AiApprover? approver;

  final AiLinkTimings timings;

  // Code approvals being asked now, so one code asks once.
  final Map<String, Future<_Answer>> _pending = {};

  // Questions waiting (on screen or queued), by code id. Each code may have
  // [aiMaxPendingPromptsPerCode] of its own, and all codes together
  // [aiMaxPendingPrompts], so one code can't keep the others' questions out.
  // A request that joins a question already asked doesn't count.
  final Map<String, int> _waitingByCode = {};
  int _waiting = 0;

  bool _canWait(String codeId) =>
      _waiting < aiMaxPendingPrompts && (_waitingByCode[codeId] ?? 0) < aiMaxPendingPromptsPerCode;

  void _enter(String codeId) {
    _waiting++;
    _waitingByCode[codeId] = (_waitingByCode[codeId] ?? 0) + 1;
  }

  void _leave(String codeId) {
    _waiting--;
    final n = (_waitingByCode[codeId] ?? 1) - 1;
    if (n <= 0) {
      _waitingByCode.remove(codeId);
    } else {
      _waitingByCode[codeId] = n;
    }
  }

  // One question on screen at a time: each waits for the one before.
  Future<void> _promptTail = Future.value();

  // Codes whose last approval question was denied, until when.
  final Map<String, DateTime> _denied = {};

  // Codes the user denied (or left unanswered) at startup, so a closed-app
  // question isn't asked again in this run.
  final Set<String> _closedAsked = {};

  Duration _remaining(DateTime deadline) {
    final d = deadline.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  /// Answers [request]. [clientOpen] says whether the client is still
  /// connected; a write is not applied once it isn't.
  Future<AiLinkResponse> handle(AiLinkRequest request, {bool Function()? clientOpen}) async {
    if (request is AiLinkMalformed) {
      return AiLinkResponse.error(AiLinkCode.badRequest, request.message);
    }
    final deadline = DateTime.now().add(timings.deadline);
    final open = clientOpen ?? () => true;
    final first = _verify(request.code);
    if (first.error != null) {
      final known = first.known;
      if (known != null) _log(request, known, first.error!.wire);
      return AiLinkResponse.error(first.error!);
    }
    var code = first.code!;

    AiLinkResponse done(AiLinkResponse r) {
      _log(request, code, r is AiLinkError ? r.wireCode : 'ok');
      return r;
    }

    final misfit = _fit(code, request);
    if (misfit != null) return done(AiLinkResponse.error(misfit));

    if (!code.isApproved) {
      final refusal = await _approveCode(_appName(request), code, deadline);
      // Revoked or expired while the question was open: refuse.
      final again = _verify(request.code);
      if (again.error != null) {
        final known = again.known ?? code;
        _log(request, known, again.error!.wire);
        return AiLinkResponse.error(again.error!);
      }
      code = again.code!;
      if (refusal != null) return done(AiLinkResponse.error(refusal));
      try {
        service.store.approveCode(code.id);
        service.changed();
      } on Object {
        return done(AiLinkResponse.error(AiLinkCode.busy));
      }
    }
    try {
      service.store.recordUse(code.id);
    } on Object {
      return done(AiLinkResponse.error(AiLinkCode.busy));
    }

    final AiLinkResponse response;
    switch (request) {
      case AiLinkWriteBox():
        response = await _write(request, code, deadline, open);
      case AiLinkAccess():
        response = await _access(request, code, deadline, open);
      case AiLinkDescribeCode():
        response = AiLinkResponse.described(
          kind: code.target.kindName,
          id: code.target.id,
          role: code.roleName,
          expires: code.expires?.toUtc().toIso8601String(),
        );
      case AiLinkMalformed():
        response = AiLinkResponse.error(AiLinkCode.badRequest);
    }
    return done(response);
  }

  // Checks the code against the store as it is now.
  ({AiCode? code, AiCode? known, AiLinkCode? error}) _verify(String text) {
    final v = service.store.verify(text);
    if (v.ok) return (code: v.code, known: null, error: null);
    switch (v.failure!) {
      case AiCodeFailure.unreadable:
        return (code: null, known: null, error: AiLinkCode.busy);
      case AiCodeFailure.expired:
        AiCode? known;
        final id = parseAiToken(text)?.id;
        try {
          for (final c in service.store.codes()) {
            if (c.id == id) known = c;
          }
        } on AiAccessUnreadable {
          known = null;
        }
        return (code: null, known: known, error: AiLinkCode.expired);
      case AiCodeFailure.badCode:
        return (code: null, known: null, error: AiLinkCode.badCode);
    }
  }

  // Whether the code still holds and the client is still there, as a refusal.
  AiLinkCode? _recheck(String codeText, String codeId, bool Function() open) {
    if (!open()) return AiLinkCode.busy; // nobody is waiting for the answer
    final v = _verify(codeText);
    if (v.error != null) return v.error;
    return v.code!.id == codeId ? null : AiLinkCode.badCode;
  }

  // The role and target against the op: the refusal, or null if it fits.
  AiLinkCode? _fit(AiCode code, AiLinkRequest req) {
    switch (req) {
      case AiLinkWriteBox():
        if (!code.canWriteBox) return AiLinkCode.wrongRole;
        // The code's own box only; the same answer as a box that isn't there.
        if (req.box != code.target.id) return AiLinkCode.noBox;
        // Within the box's Writer permission, before anyone is asked.
        if (!service.store.writerPermission(req.box).allows(req.mode)) return AiLinkCode.notPermitted;
        return null;
      case AiLinkAccess():
        if (!code.canRead) return AiLinkCode.wrongRole;
        if (code.target.kind == AiCodeTargetKind.box) {
          if (req.action != AiLinkAction.readBox) return AiLinkCode.wrongRole;
          if (req.target != code.target.id) return AiLinkCode.noBox;
        }
        return null;
      case AiLinkDescribeCode():
      case AiLinkMalformed():
        return null;
    }
  }

  // Asks about a code that isn't approved yet: null if the user allowed it,
  // else the refusal. One question per code, shared by every request of it.
  Future<AiLinkCode?> _approveCode(
    String app,
    AiCode code,
    DateTime deadline, {
    bool closedApp = false,
    Duration? limit,
  }) async {
    final cooling = _denied[code.id];
    if (cooling != null) {
      if (DateTime.now().isBefore(cooling)) return AiLinkCode.notApproved;
      _denied.remove(code.id);
    }
    final key = code.id;
    var asking = _pending[key];
    if (asking == null) {
      // A new question: it takes one of the waiting places until answered.
      if (!_canWait(code.id)) return AiLinkCode.busy;
      _enter(code.id);
      asking = _pending[key] = _ask(
        app: app,
        write: code.canWriteBox,
        label: code.label,
        perWrite: false,
        closedApp: closedApp,
        limit: limit,
        deadline: deadline,
      ).whenComplete(() {
        _pending.remove(key);
        _leave(code.id);
      });
    }
    final answer = await asking;
    if (answer == _Answer.denied) {
      _denied[code.id] = DateTime.now().add(timings.denyCooldown);
    }
    return answer == _Answer.allowed ? null : AiLinkCode.notApproved;
  }

  /// Asks, once each, about the codes an AI app tried to use while Noted was
  /// closed: every code that exists, isn't expired and isn't approved, and has
  /// a `pending_approval` entry in the server's log newer than the code. Call
  /// it after the notebook has loaded. A code the user denies (or leaves
  /// unanswered) is not asked about again in this run. Allow approves the
  /// code.
  Future<void> askPendingApprovals() async {
    if (approver == null) return;
    final List<AiCode> codes;
    try {
      codes = service.store.codes();
    } on AiAccessUnreadable {
      return;
    }
    final entries = service.mcpLogEntries().where((e) => e.isPendingApproval).toList();
    if (entries.isEmpty) return;
    for (final code in codes) {
      final now = DateTime.now();
      if (code.isApproved || code.isExpired(now) || _closedAsked.contains(code.id)) continue;
      AiMcpLogEntry? latest;
      for (final e in entries) {
        if (e.code == code.id && e.time.isAfter(code.created)) latest = e;
      }
      if (latest == null) continue;
      _closedAsked.add(code.id);
      final limit = timings.closedApproval;
      final refusal = await _approveCode(
        _cleanName(latest.app),
        code,
        DateTime.now().add(limit),
        closedApp: true,
        limit: limit,
      );
      if (refusal != null) continue;
      try {
        // Revoked or expired while the question was open: nothing to approve.
        final still = service.store.codes().where((c) => c.id == code.id).firstOrNull;
        if (still == null || still.isExpired(DateTime.now())) continue;
        service.store.approveCode(code.id);
        service.changed();
      } on Object {
        // The store is busy or unreadable: asked again next start.
      }
    }
  }

  // The name comes from the client, and is shown to the user: control
  // characters become spaces, and format characters (bidi overrides,
  // zero-width) are dropped.
  String _appName(AiLinkRequest req) => _cleanName(req.app);

  String _cleanName(String? name) {
    final a = name
        ?.replaceAll(RegExp(r'[\p{Cc}  ]', unicode: true), ' ')
        .replaceAll(RegExp(r'\p{Cf}', unicode: true), '')
        .trim();
    return a == null || a.isEmpty ? 'An AI app' : a;
  }

  // Shows one question, when it is its turn and while the request has time.
  Future<_Answer> _ask({
    required String app,
    required bool write,
    required String label,
    required bool perWrite,
    required DateTime deadline,
    String? preview,
    bool closedApp = false,
    Duration? limit,
  }) async {
    final ask = approver;
    if (ask == null) return _Answer.none;
    final prev = _promptTail;
    final gate = Completer<void>();
    _promptTail = gate.future;
    try {
      await prev.timeout(_remaining(deadline));
    } on TimeoutException {
      // Never got its turn: the next one still waits for the one on screen.
      unawaited(prev.then((_) => gate.complete()));
      return _Answer.none;
    }
    final cap = limit ?? timings.approval;
    final time = _remaining(deadline) < cap ? _remaining(deadline) : cap;
    if (time == Duration.zero) {
      gate.complete();
      return _Answer.none;
    }
    final expired = Completer<void>();
    final timer = Timer(time, () {
      if (!expired.isCompleted) expired.complete();
    });
    try {
      final answer = await Future.any<bool?>([
        ask(
          AiApprovalRequest(
            app: app,
            write: write,
            label: label.isEmpty ? 'this connection' : label,
            perWrite: perWrite,
            preview: preview,
            closedApp: closedApp,
            expired: expired.future,
          ),
        ),
        expired.future.then((_) => null),
      ]);
      return answer == null ? _Answer.none : (answer ? _Answer.allowed : _Answer.denied);
    } on Object {
      return _Answer.none;
    } finally {
      timer.cancel();
      if (!expired.isCompleted) expired.complete();
      gate.complete();
    }
  }

  Future<AiLinkResponse> _write(AiLinkWriteBox req, AiCode code, DateTime deadline, bool Function() open) {
    final ask = service.store.askBeforeWrite(req.box);
    return host.aiWriteBox(
      req,
      code,
      deadline: deadline,
      recheck: () => _recheck(req.code, code.id, open),
      confirm: !ask
          ? null
          : () async {
              // No room to ask now: busy (try again), not a refusal.
              if (!_canWait(code.id)) return AiLinkCode.busy;
              _enter(code.id);
              try {
                final answer = await _ask(
                  app: _appName(req),
                  write: true,
                  label: code.label,
                  perWrite: true,
                  preview: _preview(req),
                  deadline: deadline,
                );
                return answer == _Answer.allowed ? null : AiLinkCode.notApproved;
              } finally {
                _leave(code.id);
              }
            },
    );
  }

  String _preview(AiLinkWriteBox req) {
    final flat = req.content.replaceAll(RegExp(r'\s+'), ' ').trim();
    final short = flat.length > 200 ? '${flat.substring(0, 200)}…' : flat;
    return switch (req.mode) {
      AiLinkMode.append => 'Add: $short',
      AiLinkMode.replaceAi => 'Replace the AI text with: $short',
      AiLinkMode.replace => short.isEmpty ? 'Empty the box' : 'Replace with: $short',
    };
  }

  Future<AiLinkResponse> _access(AiLinkAccess req, AiCode code, DateTime deadline, bool Function() open) async {
    if (!await host.aiWaitLoaded(_remaining(deadline))) return AiLinkResponse.error(AiLinkCode.busy);
    if (code.target.kind == AiCodeTargetKind.box) {
      final page = await host.aiPageOfBox(code.target.id, hint: code.target.page);
      if (page == null) return AiLinkResponse.error(AiLinkCode.noBox);
      final refusal = _recheck(req.code, code.id, open);
      if (refusal != null) return AiLinkResponse.error(refusal);
      return AiLinkResponse.granted(AiLinkBoxGrant(box: code.target.id, page: page));
    }
    final refusal = _recheck(req.code, code.id, open);
    if (refusal != null) return AiLinkResponse.error(refusal);
    return AiLinkResponse.granted(AiLinkPagesGrant(pages: host.aiReadablePages(code.target)));
  }

  // Logs the request; never throws (the log is a convenience).
  void _log(AiLinkRequest req, AiCode code, String result) {
    final op = req is AiLinkAccess ? req.action.wire : req.op;
    try {
      service.log.append(
        AiActivityEntry(
          time: DateTime.now().toUtc(),
          code: code.id,
          target: code.target,
          op: op,
          app: _appName(req),
          label: code.label,
          result: result,
        ),
      );
      service.changed();
    } on Object {
      // Nothing to do.
    }
  }
}
