// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:noted_box_ai/noted_box_ai.dart';
import 'package:noted_core/noted_core.dart';

/// A client's app name made fit to show the user: control characters become
/// spaces, format characters (bidi overrides, zero-width) are dropped. An empty
/// name becomes [fallback].
String cleanAiAppName(String? name, {String fallback = 'An AI app'}) {
  final a = name
      ?.replaceAll(RegExp(r'[\p{Cc}  ]', unicode: true), ' ')
      .replaceAll(RegExp(r'\p{Cf}', unicode: true), '')
      .trim();
  return a == null || a.isEmpty ? fallback : a;
}

/// A change to the codes failed; [message] is fit to show the user.
class AiAccessException implements Exception {
  const AiAccessException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The app's end of the per-box codes, and of the codes on pages and binders
/// (run 2026-11-01-02): the local store `ai-access.json` and the activity log
/// `ai-activity.json`, both in the data folder (beside binders.json and settings.json on desktop).
///
/// It is what an AI box sees ([AiBoxAccess]) and what the settings panel for
/// pages and binders uses ([codesFor], [issue], [activityFor] ...). It reads
/// the files again on every call, so another Noted's change shows at once, and
/// notifies whenever something changes: here, through the link ([changed]),
/// or, with [pollInterval], in the files themselves.
class AiAccessService extends ChangeNotifier implements AiBoxAccess {
  AiAccessService({
    required Directory dataFolder,
    this.pageOfBox,
    Duration? pollInterval,
  }) : store = AiAccessStore(_file(dataFolder, aiAccessFileName)),
       log = AiActivityLog(_file(dataFolder, aiActivityFileName)),
       mcpLog = _file(dataFolder, aiMcpLogFileName) {
    if (pollInterval != null) {
      trimMcpLog();
      pruneRevokedCodes();
      _stamp = _stampOf();
      _poll = Timer.periodic(pollInterval, (_) => _check());
    }
  }

  static File _file(Directory dir, String name) => File('${dir.path}${Platform.pathSeparator}$name');

  final AiAccessStore store;
  final AiActivityLog log;

  /// The MCP server's access log (`ai-mcp-log.jsonl`): what it did while Noted
  /// wasn't running. The server appends; this service reads it and trims it.
  final File mcpLog;

  /// The page a box is on now, to note it on a new box code (informative).
  /// Null: not recorded.
  final Future<String?> Function(String boxId)? pageOfBox;

  Timer? _poll;
  String _stamp = '';
  bool _disposed = false;

  String _stampOf() {
    final b = StringBuffer();
    for (final f in [store.file, log.file, mcpLog]) {
      try {
        final s = f.statSync();
        b.write('${s.modified.microsecondsSinceEpoch}/${s.size};');
      } on Object {
        b.write('-;');
      }
    }
    return b.toString();
  }

  void _check() {
    final now = _stampOf();
    if (now == _stamp) return;
    trimMcpLog();
    _pruneRevoked();
    _stamp = _stampOf();
    changed();
  }

  /// Tells the listeners that codes, sessions or the log changed.
  void changed() {
    if (_disposed) return;
    if (_poll != null) {
      // An app-side change (a revoke, a log trim) can leave a revoked code
      // with no activity; prune before the stamp is taken, or the next poll
      // sees the same stamp and never does.
      // Only when there is a revoked code, so a plain request doesn't read
      // both logs.
      if (_hasRevoked()) _pruneRevoked();
      _stamp = _stampOf();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _poll = null;
    super.dispose();
  }

  // Codes by target ----------------------------------------------------------

  /// The codes of a target (a box, page or binder), including expired ones;
  /// empty if the store can't be read ([problem]).
  List<AiCode> codesFor(AiCodeTargetKind kind, String id) {
    try {
      return [
        for (final c in store.codes())
          if (c.target.kind == kind && c.target.id == id) c,
      ];
    } on AiAccessUnreadable {
      return const [];
    }
  }

  /// Issues a code for [target]. Returns the code text, shown once and never
  /// stored. Throws an [AiAccessException] if the store can't be written.
  Future<String> issue(
    AiCodeTarget target, {
    required AiCodeRole role,
    required String label,
    DateTime? expires,
  }) async {
    final name = label.trim();
    try {
      final issued = store.issue(
        target: target,
        role: role,
        label: name.isEmpty ? 'AI connection' : name,
        expires: expires,
      );
      changed();
      return issued.code;
    } on Object catch (e) {
      throw _failure(e);
    }
  }

  /// Renames the code [codeId].
  Future<void> rename(String codeId, String label) async {
    final name = label.trim();
    if (name.isEmpty) return;
    try {
      store.update((d) {
        final c = d.code(codeId);
        if (c != null) d.put(c.copyWith(label: name));
      });
      changed();
    } on Object catch (e) {
      throw _failure(e);
    }
  }

  /// Sets or clears when the code [codeId] expires.
  Future<void> setExpires(String codeId, DateTime? expires) async {
    try {
      store.update((d) {
        final c = d.code(codeId);
        if (c != null) d.put(c.withExpires(expires?.toUtc()));
      });
      changed();
    } on Object catch (e) {
      throw _failure(e);
    }
  }

  /// The activity about a target, oldest first: Noted's own log plus what the
  /// MCP server did while Noted was closed (those entries carry
  /// `extra['closed'] == true`).
  List<AiActivityEntry> activityFor(AiCodeTargetKind kind, String id) {
    final known = {for (final c in codesFor(kind, id)) c.id: c};
    // An entry of a revoked code stays, marked (`extra['revoked']`).
    AiActivityEntry mark(AiActivityEntry e) => known[e.code]?.isRevoked ?? false
        ? AiActivityEntry(
            time: e.time,
            code: e.code,
            target: e.target,
            op: e.op,
            app: e.app,
            label: e.label,
            result: e.result,
            extra: {...e.extra, 'revoked': true},
          )
        : e;
    final own = [for (final e in log.entriesFor(kind, id)) mark(e)];
    final closed = [
      for (final e in mcpLogEntries())
        // Only entries of a code that exists for this target: the file is
        // appended to by another process, so a stray line shows nothing.
        if (e.target.kind == kind && e.target.id == id && known[e.code] != null)
          AiActivityEntry(
            time: e.time,
            code: e.code,
            target: e.target,
            op: e.op,
            app: e.app.isEmpty ? '' : cleanAiAppName(e.app),
            // The code's name now, not the one the server saw.
            label: known[e.code]!.label,
            result: e.result,
            extra: {'closed': true, if (known[e.code]!.isRevoked) 'revoked': true},
          ),
    ];
    if (closed.isEmpty) return own;
    // A stable merge by time: on a tie Noted's own entry comes first.
    final all = [...own, ...closed];
    final order = {for (var i = 0; i < all.length; i++) all[i]: i};
    return all..sort((a, b) {
      final c = a.time.compareTo(b.time);
      return c != 0 ? c : order[a]!.compareTo(order[b]!);
    });
  }

  /// When the user last answered (Allow or Deny) a question about [code] that
  /// was asked at startup for a request made while Noted was closed; null if
  /// never. Kept on the code record as `pendingAnswered`.
  static DateTime? pendingAnswered(AiCode code) {
    final v = code.extra['pendingAnswered'];
    return v is String ? DateTime.tryParse(v)?.toUtc() : null;
  }

  /// Notes that the user answered the startup question about [codeId] at
  /// [at]. Throws what the store throws.
  void markPendingAnswered(String codeId, DateTime at) => store.update((d) {
    final c = d.code(codeId);
    if (c == null) return;
    d.put(
      AiCode(
        id: c.id,
        target: c.target,
        roleName: c.roleName,
        label: c.label,
        hash: c.hash,
        created: c.created,
        lastUsed: c.lastUsed,
        expires: c.expires,
        approved: c.approved,
        revoked: c.revoked,
        sessions: c.sessions,
        extra: {...c.extra, 'pendingAnswered': at.toUtc().toIso8601String()},
        rawTimes: c.rawTimes,
      ),
    );
  });

  /// The entries of the MCP server's log, in file order. Empty if the file is
  /// missing or can't be read.
  List<AiMcpLogEntry> mcpLogEntries() {
    try {
      // As bytes, decoded leniently: a multi-byte character cut by a crash
      // mid-write must not hide the other entries.
      return parseAiMcpLog(utf8.decode(mcpLog.readAsBytesSync(), allowMalformed: true));
    } on Object {
      return const [];
    }
  }

  /// Keeps the last [keep] lines of the MCP server's log once it holds more.
  /// The file is rewritten in place under a lock on the file itself, so a
  /// server appending at the same moment waits instead of being lost; a line
  /// it was in the middle of writing is kept. A file that can't be opened or
  /// read is not touched. Returns whether it trimmed.
  bool trimMcpLog({int keep = aiActivityMaxEntries}) {
    RandomAccessFile? raf;
    try {
      if (!mcpLog.existsSync()) return false;
      raf = mcpLog.openSync(mode: FileMode.append);
      // A short wait for the lock; if another process keeps it, leave the
      // file as it is (the next change tries again).
      final until = DateTime.now().add(const Duration(milliseconds: 500));
      while (true) {
        try {
          raf.lockSync(FileLock.exclusive);
          break;
        } on FileSystemException {
          if (DateTime.now().isAfter(until)) return false;
          sleep(const Duration(milliseconds: 20));
        }
      }
      try {
        final length = raf.lengthSync();
        raf.setPositionSync(0);
        final bytes = raf.readSync(length);
        if (bytes.length != length) return false;
        // Line ends; a last line without one is a line being written.
        final ends = <int>[
          for (var i = 0; i < bytes.length; i++)
            if (bytes[i] == 0x0A) i,
        ];
        final lines = ends.length + (bytes.isNotEmpty && bytes.last != 0x0A ? 1 : 0);
        if (lines <= keep) return false;
        final from = ends[lines - keep - 1] + 1;
        final tail = bytes.sublist(from);
        // Opened with FileMode.append, the file is still read-write: the kept
        // lines are written over its start and only then is it shortened. A
        // crash part way leaves the kept lines whole (at worst repeated, with
        // one broken line at the seam, which the parser skips); nothing is
        // lost.
        try {
          raf.setPositionSync(0);
          raf.writeFromSync(tail);
          raf.flushSync();
          raf.truncateSync(tail.length);
          raf.flushSync();
        } on Object {
          return false;
        }
        return true;
      } finally {
        raf.unlockSync();
      }
    } on Object {
      return false;
    } finally {
      try {
        raf?.closeSync();
      } on Object {
        // Nothing to do.
      }
    }
  }

  // The text of a log file for the prune check: '' if it is missing, null if
  // it exists but can't be read (then nothing is pruned).
  String? _rawLog(File f) {
    try {
      return utf8.decode(f.readAsBytesSync(), allowMalformed: true);
    } on Object {
      return FileSystemEntity.typeSync(f.path) == FileSystemEntityType.notFound ? '' : null;
    }
  }

  /// Removes the records of revoked codes with no activity left in either log
  /// (Noted's `ai-activity.json` and the MCP server's `ai-mcp-log.jsonl`),
  /// so `ai-access.json` doesn't grow with every revoke. A code that isn't
  /// revoked, or has any entry left, stays. The check is on the raw log text
  /// (the code id appearing anywhere), so a line this build can't parse keeps
  /// its code. A log that can't be read, or a store that can't be read or
  /// written, prunes nothing. Returns the number removed.
  int pruneRevokedCodes() {
    final removed = _pruneRevoked();
    if (removed > 0) changed();
    return removed;
  }

  bool _hasRevoked() {
    try {
      return store.codes().any((c) => c.isRevoked);
    } on Object {
      return false;
    }
  }

  // The MCP log's text read under the same lock the server's append and
  // [trimMcpLog] use; the lock is held until [release]. '' if the file is
  // missing; null if it can't be locked or read (then nothing is pruned).
  ({String? text, void Function() release}) _lockedMcpLog() {
    RandomAccessFile? raf;
    void release() {
      try {
        raf?.unlockSync();
      } on Object {
        // Nothing to do.
      }
      try {
        raf?.closeSync();
      } on Object {
        // Nothing to do.
      }
      raf = null;
    }

    try {
      if (!mcpLog.existsSync()) return (text: '', release: release);
      raf = mcpLog.openSync(mode: FileMode.append);
      final until = DateTime.now().add(const Duration(milliseconds: 500));
      while (true) {
        try {
          raf!.lockSync(FileLock.exclusive);
          break;
        } on FileSystemException {
          if (DateTime.now().isAfter(until)) {
            release();
            return (text: null, release: release);
          }
          sleep(const Duration(milliseconds: 20));
        }
      }
      final length = raf!.lengthSync();
      raf!.setPositionSync(0);
      final bytes = raf!.readSync(length);
      if (bytes.length != length) {
        release();
        return (text: null, release: release);
      }
      return (text: utf8.decode(bytes, allowMalformed: true), release: release);
    } on Object {
      release();
      return (text: null, release: release);
    }
  }

  int _pruneRevoked() {
    try {
      // Look first, so the file isn't rewritten when there is nothing to do.
      final own0 = _rawLog(log.file);
      final closed0 = _rawLog(mcpLog);
      if (own0 == null || closed0 == null) return 0;
      if (!store.codes().any((c) => c.isRevoked && !own0.contains(c.id) && !closed0.contains(c.id))) return 0;
      var removed = 0;
      store.update((d) {
        final revoked = [
          for (final c in d.codes)
            if (c.isRevoked) c,
        ];
        if (revoked.isEmpty) return;
        // The MCP log is locked from the read to the end of the removal, so an
        // append the server makes in that span waits and is seen. A request the
        // server checked against the store before the revoke can still append
        // after the prune; closing that would need the server to take the
        // store lock.
        final locked = _lockedMcpLog();
        try {
          final own = _rawLog(log.file);
          final closed = locked.text;
          if (own == null || closed == null) return;
          for (final c in revoked) {
            if (!own.contains(c.id) && !closed.contains(c.id) && d.remove(c.id)) removed++;
          }
        } finally {
          locked.release();
        }
      });
      return removed;
    } on Object {
      return 0;
    }
  }

  AiAccessException _failure(Object e) {
    if (e is AiAccessUnreadable) {
      return const AiAccessException(
        "Noted can't read its AI codes file, so nothing was changed. The file is kept as it is.",
      );
    }
    if (e is FileLockTimeout) {
      return const AiAccessException('The AI codes are busy. Try again in a moment.');
    }
    if (e is ArgumentError) return AiAccessException('${e.message}');
    return const AiAccessException("Noted couldn't save the AI codes. Check that its data folder can be written to.");
  }

  // AiBoxAccess --------------------------------------------------------------

  @override
  List<AiCode> connections(String boxId) => codesFor(AiCodeTargetKind.box, boxId);

  @override
  Future<String> connect(
    String boxId, {
    required AiCodeRole role,
    required String label,
    DateTime? expires,
  }) async {
    String? page;
    try {
      page = await pageOfBox?.call(boxId);
    } on Object {
      page = null;
    }
    return issue(AiCodeTarget.box(boxId, page: page), role: role, label: label, expires: expires);
  }

  @override
  Future<void> revoke(String codeId) async {
    try {
      store.revoke(codeId);
      changed();
    } on Object catch (e) {
      throw _failure(e);
    }
  }

  @override
  Future<void> revokeSession(String codeId, String sessionId) async {
    try {
      store.removeSession(codeId, sessionId);
      changed();
    } on Object catch (e) {
      throw _failure(e);
    }
  }

  @override
  bool askBeforeWrite(String boxId) => store.askBeforeWrite(boxId);

  @override
  Future<void> setAskBeforeWrite(String boxId, bool value) async {
    try {
      store.setAskBeforeWrite(boxId, value);
      changed();
    } on Object catch (e) {
      throw _failure(e);
    }
  }

  @override
  AiWriterPermission writerPermission(String boxId) => store.writerPermission(boxId);

  @override
  Future<void> setWriterPermission(String boxId, AiWriterPermission value) async {
    try {
      store.setWriterPermission(boxId, value);
      changed();
    } on Object catch (e) {
      throw _failure(e);
    }
  }

  @override
  bool closedWrites(String boxId) => store.closedWrites(boxId);

  @override
  Future<void> setClosedWrites(String boxId, bool value) async {
    try {
      store.setClosedWrites(boxId, value);
      changed();
    } on Object catch (e) {
      throw _failure(e);
    }
  }

  @override
  List<AiActivityEntry> activity(String boxId) => activityFor(AiCodeTargetKind.box, boxId);

  @override
  String? get problem {
    try {
      store.read();
      return null;
    } on AiAccessUnreadable {
      return "Noted can't read its AI codes file. No code works until it is fixed or removed.";
    }
  }
}
