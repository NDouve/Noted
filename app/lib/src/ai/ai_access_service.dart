// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:noted_box_ai/noted_box_ai.dart';
import 'package:noted_core/noted_core.dart';

/// A change to the codes failed; [message] is fit to show the user.
class AiAccessException implements Exception {
  const AiAccessException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The app's end of the per-box codes, and of the codes on pages and binders
/// (run 2026-11-01-02): the local store `ai-access.json` and the activity log
/// `ai-activity.json`, both in the data folder beside settings.json.
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
       log = AiActivityLog(_file(dataFolder, aiActivityFileName)) {
    if (pollInterval != null) {
      _stamp = _stampOf();
      _poll = Timer.periodic(pollInterval, (_) => _check());
    }
  }

  static File _file(Directory dir, String name) => File('${dir.path}${Platform.pathSeparator}$name');

  final AiAccessStore store;
  final AiActivityLog log;

  /// The page a box is on now, to note it on a new box code (informative).
  /// Null: not recorded.
  final Future<String?> Function(String boxId)? pageOfBox;

  Timer? _poll;
  String _stamp = '';
  bool _disposed = false;

  String _stampOf() {
    final b = StringBuffer();
    for (final f in [store.file, log.file]) {
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
    _stamp = now;
    changed();
  }

  /// Tells the listeners that codes, sessions or the log changed.
  void changed() {
    if (_disposed) return;
    if (_poll != null) _stamp = _stampOf();
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

  /// The log entries about a target, oldest first.
  List<AiActivityEntry> activityFor(AiCodeTargetKind kind, String id) => log.entriesFor(kind, id);

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
