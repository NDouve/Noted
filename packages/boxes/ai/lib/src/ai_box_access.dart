// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:noted_core/noted_core.dart';

/// What an AI box needs from the app to manage its own connections (per-box
/// codes, run 2026-11-01-02). The app implements it over its local
/// `ai-access.json` store and activity log and hands it to `AiModule`'s
/// constructor; it is not part of the Box API.
///
/// It notifies its listeners whenever codes, sessions, the box's settings or
/// the activity log change, so an open box can refresh.
abstract class AiBoxAccess implements Listenable {
  /// The codes of the box [boxId] (its Writer, if any, and its Readers),
  /// including expired ones. Empty when the store can't be read; see
  /// [problem].
  List<AiCode> connections(String boxId);

  /// Issues a new code for [boxId] with [role] (writer or reader) and the
  /// user's [label], optionally expiring at [expires]. Returns the code text,
  /// shown once and never stored. A new Writer retires the box's old Writer.
  /// Throws when the store can't be written; the message is for the user.
  Future<String> connect(
    String boxId, {
    required AiCodeRole role,
    required String label,
    DateTime? expires,
  });

  /// Revokes the code [codeId]: its requests are rejected at once.
  Future<void> revoke(String codeId);

  /// Removes an approved session from [codeId]; its next request is asked
  /// about again.
  Future<void> revokeSession(String codeId, String sessionId);

  /// Whether every write to [boxId] asks the user first.
  bool askBeforeWrite(String boxId);

  Future<void> setAskBeforeWrite(String boxId, bool value);

  /// The box's activity log, newest last.
  List<AiActivityEntry> activity(String boxId);

  /// A short message when the store can't be read right now, else null.
  String? get problem;
}

/// An [AiBoxAccess] with no app behind it (tests, or a host without AI
/// access): no connections, and connecting fails.
final class NoAiBoxAccess extends ChangeNotifier implements AiBoxAccess {
  @override
  List<AiCode> connections(String boxId) => const [];

  @override
  Future<String> connect(
    String boxId, {
    required AiCodeRole role,
    required String label,
    DateTime? expires,
  }) => Future.error(StateError('AI connections are not available here.'));

  @override
  Future<void> revoke(String codeId) async {}

  @override
  Future<void> revokeSession(String codeId, String sessionId) async {}

  @override
  bool askBeforeWrite(String boxId) => false;

  @override
  Future<void> setAskBeforeWrite(String boxId, bool value) async {}

  @override
  List<AiActivityEntry> activity(String boxId) => const [];

  @override
  String? get problem => null;
}
