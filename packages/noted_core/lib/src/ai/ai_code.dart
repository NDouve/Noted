// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'ai_code_format.dart';

/// What a code points at.
enum AiCodeTargetKind {
  box('box'),
  page('page'),
  binder('binder');

  const AiCodeTargetKind(this.wire);

  final String wire;

  static AiCodeTargetKind? fromWire(Object? wire) {
    for (final k in values) {
      if (k.wire == wire) return k;
    }
    return null;
  }
}

/// What a code lets its holder do. A role this build doesn't know (written
/// by a newer app, such as a later `organize`) is kept in the file as written
/// and grants nothing here.
enum AiCodeRole {
  /// Read and write one box (a box target only).
  writer('writer'),

  /// Read the target.
  reader('reader');

  const AiCodeRole(this.wire);

  final String wire;

  static AiCodeRole? fromWire(Object? wire) {
    for (final r in values) {
      if (r.wire == wire) return r;
    }
    return null;
  }
}

Map<String, Object?> _extras(Map<Object?, Object?> json, Set<String> known) => {
  for (final e in json.entries)
    if (e.key is String && !known.contains(e.key)) e.key as String: e.value,
};

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;

String _iso(DateTime t) => t.toUtc().toIso8601String();

/// What a code points at: a box, a page or a binder. For a box, [page] is the
/// page the box was on when the code was issued (informative only).
final class AiCodeTarget {
  const AiCodeTarget({
    required this.kindName,
    required this.id,
    this.page,
    this.extra = const {},
  });

  const AiCodeTarget.box(String box, {String? page})
    : this(kindName: 'box', id: box, page: page);
  const AiCodeTarget.page(String page) : this(kindName: 'page', id: page);
  const AiCodeTarget.binder(String binder) : this(kindName: 'binder', id: binder);

  /// The kind as written; [kind] is null for one this build doesn't know.
  final String kindName;
  final String id;
  final String? page;

  /// Fields this build doesn't know, kept when the code is written back.
  final Map<String, Object?> extra;

  AiCodeTargetKind? get kind => AiCodeTargetKind.fromWire(kindName);

  /// Reads a stored target, or null if it has no kind or id.
  static AiCodeTarget? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = json['kind'];
    final id = json['id'];
    if (kind is! String || id is! String || id.isEmpty) return null;
    final page = json['page'];
    return AiCodeTarget(
      kindName: kind,
      id: id,
      page: page is String ? page : null,
      extra: _extras(json, const {'kind', 'id', 'page'}),
    );
  }

  Map<String, Object?> toJson() => {
    'kind': kindName,
    'id': id,
    if (page != null) 'page': page,
    ...extra,
  };

  bool sameTarget(AiCodeTarget other) => other.kindName == kindName && other.id == id;

  @override
  bool operator ==(Object other) =>
      other is AiCodeTarget && other.kindName == kindName && other.id == id && other.page == page;

  @override
  int get hashCode => Object.hash(kindName, id, page);
}

/// A session (one MCP server process) the user allowed to use a code.
final class AiCodeSession {
  const AiCodeSession({
    required this.id,
    required this.app,
    this.approved,
    this.extra = const {},
  });

  final String id;

  /// The MCP client's name, as it said at `initialize`.
  final String app;
  final DateTime? approved;
  final Map<String, Object?> extra;

  static AiCodeSession? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final app = json['app'];
    return AiCodeSession(
      id: id,
      app: app is String ? app : '',
      approved: _time(json['approved']),
      extra: _extras(json, const {'id', 'app', 'approved'}),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'app': app,
    'approved': approved == null ? null : _iso(approved!),
    ...extra,
  };
}

/// A code as stored in `ai-access.json` (0105): the key itself is never
/// kept, only its SHA-256 [hash].
final class AiCode {
  const AiCode({
    required this.id,
    required this.target,
    required this.roleName,
    required this.label,
    required this.hash,
    required this.created,
    this.lastUsed,
    this.expires,
    this.approved,
    this.revoked,
    this.sessions = const [],
    this.extra = const {},
    this.rawTimes = const {},
  });

  /// 16 lowercase hex characters.
  final String id;
  final AiCodeTarget target;

  /// The role as written; [role] is null for one this build doesn't know.
  final String roleName;
  final String label;

  /// The SHA-256 of the key, lowercase hex.
  final String hash;
  final DateTime created;
  final DateTime? lastUsed;

  /// After this the code is rejected (`expired`); null: never.
  final DateTime? expires;

  /// When the user allowed this code (0108, amended: once per code, not per
  /// session); null: not approved yet. It stays approved until the code is
  /// revoked or expires. An unparseable stored value counts as not approved.
  final DateTime? approved;

  /// When the user revoked this code; null: not revoked. A revoked code stays
  /// in the file so its history stays visible, but it is rejected like an
  /// unknown one (`bad_code`). A stored `revoked` that isn't a valid time still
  /// counts as revoked (the safe side).
  final DateTime? revoked;
  final List<AiCodeSession> sessions;

  /// Fields this build doesn't know, kept when the code is written back.
  final Map<String, Object?> extra;

  /// Present `created`, `lastUsed`, `expires`, `approved` or `revoked` values that are
  /// not valid times, as stored; they are written back unchanged. An
  /// unparseable `expires` counts as expired (the safe side), an unparseable
  /// `approved` as not approved.
  final Map<String, Object?> rawTimes;

  AiCodeRole? get role => AiCodeRole.fromWire(roleName);

  /// Whether the code may write its box: a Writer on a box target. Unknown
  /// roles and kinds grant nothing.
  bool get canWriteBox => role == AiCodeRole.writer && target.kind == AiCodeTargetKind.box;

  /// Whether the code may read what it points at: a Reader or a Writer, on a
  /// known kind of target. Unknown roles and kinds grant nothing.
  bool get canRead => (role == AiCodeRole.reader || role == AiCodeRole.writer) && target.kind != null;

  /// Whether the code was revoked ([revoked] is set, or stored unparseable).
  bool get isRevoked => revoked != null || rawTimes.containsKey('revoked');

  bool isExpired(DateTime now) =>
      rawTimes.containsKey('expires') || (expires != null && !now.isBefore(expires!));

  /// Whether the user has approved this code ([approved] is set).
  bool get isApproved => approved != null;

  /// The session [sessionId], if the user allowed it. Sessions are no longer
  /// used to decide anything (approval is per code); an old file's list is
  /// kept as written.
  AiCodeSession? session(String sessionId) {
    for (final s in sessions) {
      if (s.id == sessionId) return s;
    }
    return null;
  }

  AiCode copyWith({
    String? label,
    DateTime? lastUsed,
    DateTime? approved,
    DateTime? revoked,
    List<AiCodeSession>? sessions,
  }) => AiCode(
    id: id,
    target: target,
    roleName: roleName,
    label: label ?? this.label,
    // Revoking also blanks the hash, so a build that doesn't know `revoked`
    // (an older noted_mcp, a downgraded app) can't match the key either.
    hash: revoked != null ? '' : hash,
    created: created,
    lastUsed: lastUsed ?? this.lastUsed,
    expires: expires,
    approved: approved ?? this.approved,
    revoked: revoked ?? this.revoked,
    sessions: sessions ?? this.sessions,
    extra: extra,
    rawTimes: {
      ...rawTimes,
    }..removeWhere(
      (k, _) =>
          (k == 'lastUsed' && lastUsed != null) ||
          (k == 'approved' && approved != null) ||
          (k == 'revoked' && revoked != null),
    ),
  );

  /// A copy with [expires] changed (null: never expires).
  AiCode withExpires(DateTime? expires) => AiCode(
    id: id,
    target: target,
    roleName: roleName,
    label: label,
    hash: hash,
    created: created,
    lastUsed: lastUsed,
    expires: expires,
    approved: approved,
    revoked: revoked,
    sessions: sessions,
    extra: extra,
    rawTimes: {...rawTimes}..remove('expires'),
  );

  /// Reads a stored code, or null if it lacks an id, a hash or a target.
  static AiCode? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final hash = json['hash'];
    final target = AiCodeTarget.fromJson(json['target']);
    if (id is! String || !isAiCodeId(id) || hash is! String || target == null) return null;
    final role = json['role'];
    final label = json['label'];
    final sessions = json['sessions'];
    return AiCode(
      id: id,
      target: target,
      roleName: role is String ? role : '',
      label: label is String ? label : '',
      hash: hash,
      created: _time(json['created']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      lastUsed: _time(json['lastUsed']),
      expires: _time(json['expires']),
      approved: _time(json['approved']),
      revoked: _time(json['revoked']),
      rawTimes: {
        for (final k in const ['created', 'lastUsed', 'expires', 'approved', 'revoked'])
          if (json[k] != null && _time(json[k]) == null) k: json[k],
      },
      sessions: [
        if (sessions is List)
          for (final s in sessions) ?AiCodeSession.fromJson(s),
      ],
      extra: _extras(json, const {
        'id', 'target', 'role', 'label', 'hash', 'created', 'lastUsed', 'expires', 'approved', 'revoked',
        'sessions',
      }),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'target': target.toJson(),
    'role': roleName,
    'label': label,
    'hash': hash,
    'created': rawTimes.containsKey('created') ? rawTimes['created'] : _iso(created),
    'lastUsed': rawTimes.containsKey('lastUsed')
        ? rawTimes['lastUsed']
        : (lastUsed == null ? null : _iso(lastUsed!)),
    'expires': rawTimes.containsKey('expires')
        ? rawTimes['expires']
        : (expires == null ? null : _iso(expires!)),
    'approved': rawTimes.containsKey('approved')
        ? rawTimes['approved']
        : (approved == null ? null : _iso(approved!)),
    if (isRevoked) 'revoked': rawTimes.containsKey('revoked') ? rawTimes['revoked'] : _iso(revoked!),
    'sessions': [for (final s in sessions) s.toJson()],
    ...extra,
  };
}

/// Why a code was not accepted.
enum AiCodeFailure {
  /// Malformed, unknown or revoked (a revoked code is still in the file).
  badCode,

  /// Past its expiry.
  expired,

  /// `ai-access.json` exists but can't be read: no code is accepted.
  unreadable,
}

/// The result of checking a code: the stored [code], or the [failure].
final class AiCodeVerdict {
  const AiCodeVerdict.accepted(AiCode this.code) : failure = null;
  const AiCodeVerdict.rejected(AiCodeFailure this.failure) : code = null;

  final AiCode? code;
  final AiCodeFailure? failure;

  bool get ok => code != null;
}

/// Checks [code] (`noted_<id>_<key>`) against the stored [codes]: the shape,
/// then the hash of the key in constant time, then revoked, then the expiry (so an expired
/// code is only reported to a holder who has the key).
AiCodeVerdict verifyAiCode(String code, Iterable<AiCode> codes, DateTime now) {
  final parsed = parseAiToken(code);
  if (parsed == null) return const AiCodeVerdict.rejected(AiCodeFailure.badCode);
  for (final c in codes) {
    if (c.id != parsed.id) continue;
    if (!aiKeyMatches(parsed.key, c.hash)) break;
    if (c.isRevoked) break;
    if (c.isExpired(now)) return const AiCodeVerdict.rejected(AiCodeFailure.expired);
    return AiCodeVerdict.accepted(c);
  }
  return const AiCodeVerdict.rejected(AiCodeFailure.badCode);
}
