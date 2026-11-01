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
  });

  /// The MCP client's name.
  final String app;

  /// Whether it wants to write (else read).
  final bool write;

  /// The code's label.
  final String label;

  /// True for "ask before each write" (a single write, with a [preview]);
  /// false for a new session.
  final bool perWrite;

  /// A short look at what would be written.
  final String? preview;

  /// Completes when the request no longer waits (timed out): a dialog should
  /// close itself.
  final Future<void> expired;

  /// The question: "APP wants to read|write LABEL. Allow?"
  String get message => perWrite
      ? '$app wants to write to $label. Allow?'
      : '$app wants to ${write ? 'write' : 'read'} $label. Allow?';
}

/// Asks the user; true if they allowed it.
typedef AiApprover = Future<bool> Function(AiApprovalRequest request);

/// What the authority needs from the notebook.
abstract interface class AiLinkHost {
  /// Waits for the notebook to finish loading; false if it didn't in time.
  Future<bool> aiWaitLoaded();

  /// The page that holds box [boxId], looking at [hint] first; null if none.
  /// The page's AI access is not looked at: a box is reached by its own code.
  Future<String?> aiPageOfBox(String boxId, {String? hint});

  /// The ids of the pages the code target covers that an AI with the code may
  /// read: Open or Privileged by effective access, never Guarded, never a page
  /// of a locked binder.
  List<String> aiReadablePages(AiCodeTarget target);

  /// Applies a write (the 0106 rules without ownership and the page setting).
  /// [recheck] says whether the code still holds (null) or why not; call it
  /// right before the change. [confirm], when not null, asks the user about
  /// this write once the write is known to be valid.
  Future<AiLinkResponse> aiWriteBox(
    AiLinkWriteBox request,
    AiCode code, {
    required AiLinkCode? Function() recheck,
    Future<bool> Function()? confirm,
  });
}

/// Decides every `ai-link/2` request (invariant 4): the code, its expiry, its
/// role and target, the session's approval, the per-write question; then it
/// has the notebook act. It logs every request.
///
/// It never builds content: a read only gets a grant, and `noted_mcp` reads the
/// saved files itself.
class AiLinkAuthority {
  AiLinkAuthority({
    required this.service,
    required this.host,
    this.approver,
    this.approvalTimeout = aiLinkApprovalTimeout,
  });

  final AiAccessService service;
  final AiLinkHost host;

  /// Shows the question to the user. Null: nobody can be asked, so anything
  /// that needs approval is refused.
  AiApprover? approver;

  final Duration approvalTimeout;

  // Session approvals being asked now, so one new session asks once.
  final Map<String, Future<bool>> _pending = {};

  /// Answers [request].
  Future<AiLinkResponse> handle(AiLinkRequest request) async {
    if (request is AiLinkMalformed) {
      return AiLinkResponse.error(AiLinkCode.badRequest, request.message);
    }
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

    if (code.session(request.session) == null) {
      final allowed = await _approveSession(request, code);
      // Revoked or expired while the question was open: refuse.
      final again = _verify(request.code);
      if (again.error != null) {
        final known = again.known ?? code;
        _log(request, known, again.error!.wire);
        return AiLinkResponse.error(again.error!);
      }
      code = again.code!;
      if (!allowed) return done(AiLinkResponse.error(AiLinkCode.notApproved));
      try {
        service.store.addSession(
          code.id,
          AiCodeSession(id: request.session, app: _appName(request), approved: DateTime.now().toUtc()),
        );
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
        response = await _write(request, code);
      case AiLinkAccess():
        response = await _access(request, code);
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

  // Whether the code still holds, as a refusal code.
  AiLinkCode? _recheck(String codeText, String codeId) {
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

  Future<bool> _approveSession(AiLinkRequest req, AiCode code) {
    final key = '${code.id}/${req.session}';
    return _pending[key] ??= _ask(
      app: _appName(req),
      write: req is AiLinkWriteBox,
      label: code.label,
      perWrite: false,
    ).whenComplete(() {
      _pending.remove(key);
    });
  }

  String _appName(AiLinkRequest req) {
    // The name comes from the client: control characters become spaces.
    final a = req.app?.replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f  ]'), ' ').trim();
    return a == null || a.isEmpty ? 'An AI app' : a;
  }

  Future<bool> _ask({
    required String app,
    required bool write,
    required String label,
    required bool perWrite,
    String? preview,
  }) async {
    final ask = approver;
    if (ask == null) return false;
    final expired = Completer<void>();
    final timer = Timer(approvalTimeout, () {
      if (!expired.isCompleted) expired.complete();
    });
    try {
      return await Future.any<bool>([
        ask(
          AiApprovalRequest(
            app: app,
            write: write,
            label: label.isEmpty ? 'this connection' : label,
            perWrite: perWrite,
            preview: preview,
            expired: expired.future,
          ),
        ),
        expired.future.then((_) => false),
      ]);
    } on Object {
      return false;
    } finally {
      timer.cancel();
      if (!expired.isCompleted) expired.complete();
    }
  }

  Future<AiLinkResponse> _write(AiLinkWriteBox req, AiCode code) {
    final ask = service.store.askBeforeWrite(req.box);
    return host.aiWriteBox(
      req,
      code,
      recheck: () => _recheck(req.code, code.id),
      confirm: !ask
          ? null
          : () => _ask(
              app: _appName(req),
              write: true,
              label: code.label,
              perWrite: true,
              preview: _preview(req),
            ),
    );
  }

  String _preview(AiLinkWriteBox req) {
    final flat = req.content.replaceAll(RegExp(r'\s+'), ' ').trim();
    final short = flat.length > 200 ? '${flat.substring(0, 200)}…' : flat;
    return '${req.mode == AiLinkMode.append ? 'Add: ' : 'Replace with: '}$short';
  }

  Future<AiLinkResponse> _access(AiLinkAccess req, AiCode code) async {
    if (!await host.aiWaitLoaded()) return AiLinkResponse.error(AiLinkCode.busy);
    if (code.target.kind == AiCodeTargetKind.box) {
      final page = await host.aiPageOfBox(code.target.id, hint: code.target.page);
      if (page == null) return AiLinkResponse.error(AiLinkCode.noBox);
      final refusal = _recheck(req.code, code.id);
      if (refusal != null) return AiLinkResponse.error(refusal);
      return AiLinkResponse.granted(AiLinkBoxGrant(box: code.target.id, page: page));
    }
    final refusal = _recheck(req.code, code.id);
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
