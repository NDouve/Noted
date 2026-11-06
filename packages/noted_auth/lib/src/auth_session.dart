// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';

import 'auth_exception.dart';
import 'id_token.dart';
import 'token_client.dart';
import 'token_store.dart';

/// Where sign-in stands.
enum AuthState {
  /// No account.
  signedOut,

  /// An account whose refresh token is stored.
  signedIn,

  /// There was an account, but its token was refused (`invalid_grant`) or the
  /// secure storage couldn't be read: the user has to sign in again.
  signInAgain,
}

/// What a finished browser sign-in hands over: the code, and what is needed to
/// exchange it.
class AuthGrant {
  const AuthGrant({
    required this.code,
    required this.codeVerifier,
    required this.redirectUri,
  });

  final String code;
  final String codeVerifier;
  final String redirectUri;
}

/// One signed-in Microsoft account.
///
/// - The access token lives in memory only.
/// - The refresh token lives in the [TokenStore], under a key made of the
///   account's tenant and object id.
/// - Refreshing is single-flight: callers that find the token expired or
///   rejected at the same time wait on one request.
/// - A rotated refresh token is written, read back, and only then trusted. If
///   that fails the old one stays, and it still works (Microsoft doesn't revoke
///   it when it issues a new one).
class AuthSession {
  AuthSession({
    required this._tokens,
    required this._store,
    DateTime Function()? now,
    this.expirySkew = const Duration(minutes: 1),
  }) : _now = now ?? DateTime.now;

  /// The store key of the record saying which account is signed in.
  static const String accountRecordKey = 'noted.ms.account';

  static String refreshKey(String accountKey) => 'noted.ms.refresh.$accountKey';

  final TokenClient _tokens;
  final TokenStore _store;
  final DateTime Function() _now;

  /// A token that expires within this long counts as expired.
  final Duration expirySkew;

  final StreamController<AuthState> _changes =
      StreamController<AuthState>.broadcast();

  AuthState _state = AuthState.signedOut;
  String? _accountKey;
  String? _displayName;
  String? _accessToken;
  DateTime? _expiresAt;
  Future<String>? _inflight;

  AuthState get state => _state;

  /// The signed-in (or to-be-signed-in-again) account's display name, if known.
  String? get displayName => _displayName;

  String? get accountKey => _accountKey;

  /// Fires after every change of [state].
  Stream<AuthState> get changes => _changes.stream;

  void dispose() => _changes.close();

  /// Finds out, from the store, whether an account is signed in. No network:
  /// the access token is fetched when it is first needed. A store that can't
  /// be read, or a missing refresh token, gives [AuthState.signInAgain].
  Future<void> restore() async {
    final String? record;
    try {
      record = await _store.read(accountRecordKey);
    } on Object {
      _set(AuthState.signInAgain);
      return;
    }
    if (record == null) {
      _set(AuthState.signedOut);
      return;
    }
    String? key;
    try {
      final d = jsonDecode(record);
      if (d is Map<String, dynamic> && d['key'] is String) {
        key = d['key'] as String;
        _displayName = d['name'] is String ? d['name'] as String : null;
      }
    } on FormatException {
      // Treated as no usable record, below.
    }
    if (key == null) {
      _set(AuthState.signInAgain);
      return;
    }
    _accountKey = key;
    final String? refresh;
    try {
      refresh = await _store.read(refreshKey(key));
    } on Object {
      _set(AuthState.signInAgain);
      return;
    }
    _set(
      refresh == null || refresh.isEmpty
          ? AuthState.signInAgain
          : AuthState.signedIn,
    );
  }

  /// Completes a browser sign-in: exchanges the code and stores the refresh
  /// token. Throws an [AuthException]; on failure the state is as it was.
  Future<void> signIn(AuthGrant grant) async {
    final res = await _tokens.exchangeCode(
      code: grant.code,
      codeVerifier: grant.codeVerifier,
      redirectUri: grant.redirectUri,
    );
    final refresh = res.refreshToken;
    final id = res.idToken;
    if (refresh == null || id == null) {
      throw const AuthException(
        AuthErrorKind.rejected,
        'Microsoft did not allow Noted to stay signed in.',
      );
    }
    final claims = IdClaims.fromIdToken(id);
    final key = claims.accountKey;
    try {
      await _store.write(refreshKey(key), refresh);
      if (await _store.read(refreshKey(key)) != refresh) {
        throw StateError('read-back differs');
      }
      await _store.write(
        accountRecordKey,
        jsonEncode({'key': key, 'name': claims.displayName}),
      );
    } on Object {
      throw const AuthException(
        AuthErrorKind.storage,
        'Noted could not save the sign-in on this device.',
      );
    }
    final previous = _accountKey;
    if (previous != null && previous != key) {
      try {
        await _store.delete(refreshKey(previous));
      } on Object {
        // An unreachable old token is harmless: nothing points at it now.
      }
    }
    _accountKey = key;
    _displayName = claims.displayName;
    _accessToken = res.accessToken;
    _expiresAt = _now().add(res.expiresIn);
    _set(AuthState.signedIn);
  }

  /// A valid access token, refreshing first if there isn't one. Throws an
  /// [AuthException] of kind `signInRequired` unless [state] is signedIn.
  Future<String> accessToken() async {
    _requireSignedIn();
    final t = _accessToken;
    if (t != null && _valid) return t;
    return _refresh();
  }

  /// For a caller whose request with [rejected] came back 401: a token to retry
  /// with. If another caller has already refreshed (or is refreshing), that
  /// result is used, so any number of 401s cause one refresh.
  Future<String> tokenAfterRejection(String rejected) async {
    _requireSignedIn();
    final pending = _inflight;
    if (pending != null) return pending;
    final t = _accessToken;
    if (t != null && t != rejected && _valid) return t;
    return _refresh();
  }

  /// Signs out: forgets the tokens here and removes the stored refresh token.
  /// Never touches anything on OneDrive. The state is signedOut even if the
  /// store can't be cleaned (that throws an [AuthException] of kind `storage`).
  Future<void> signOut() async {
    final key = _accountKey;
    _accessToken = null;
    _expiresAt = null;
    _accountKey = null;
    _displayName = null;
    _set(AuthState.signedOut);
    var failed = false;
    for (final k in [
      ?(key == null ? null : refreshKey(key)),
      accountRecordKey,
    ]) {
      try {
        await _store.delete(k);
      } on Object {
        failed = true;
      }
    }
    if (failed) {
      throw const AuthException(
        AuthErrorKind.storage,
        'Noted could not remove the sign-in from this device.',
      );
    }
  }

  bool get _valid {
    final e = _expiresAt;
    return e != null && _now().isBefore(e.subtract(expirySkew));
  }

  void _requireSignedIn() {
    if (_state != AuthState.signedIn) {
      throw const AuthException(
        AuthErrorKind.signInRequired,
        'Sign in to Microsoft to continue.',
      );
    }
  }

  Future<String> _refresh() {
    final running = _inflight;
    if (running != null) return running;
    final f = _doRefresh();
    _inflight = f;
    f.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_inflight, f)) _inflight = null;
    });
    return f;
  }

  Future<String> _doRefresh() async {
    final key = _accountKey;
    if (key == null) {
      throw const AuthException(
        AuthErrorKind.signInRequired,
        'Sign in to Microsoft to continue.',
      );
    }
    final String? old;
    try {
      old = await _store.read(refreshKey(key));
    } on Object {
      _set(AuthState.signInAgain);
      throw const AuthException(
        AuthErrorKind.storage,
        'Noted could not read the saved sign-in. Sign in again.',
      );
    }
    if (old == null || old.isEmpty) {
      _set(AuthState.signInAgain);
      throw const AuthException(
        AuthErrorKind.signInRequired,
        'The saved sign-in is gone. Sign in again.',
      );
    }
    final TokenResponse res;
    try {
      res = await _tokens.refresh(old);
    } on AuthException catch (e) {
      if (e.kind == AuthErrorKind.invalidGrant) {
        _accessToken = null;
        _expiresAt = null;
        _set(AuthState.signInAgain);
      }
      rethrow;
    }
    // Signed out while the request was out: don't resurrect the session.
    if (_accountKey != key) {
      throw const AuthException(
        AuthErrorKind.signInRequired,
        'Sign in to Microsoft to continue.',
      );
    }
    _accessToken = res.accessToken;
    _expiresAt = _now().add(res.expiresIn);
    final fresh = res.refreshToken;
    if (fresh != null && fresh != old) await _rotate(key, old, fresh);
    return res.accessToken;
  }

  // Write the new token, read it back; only then is the old one let go. If
  // either step fails the old token is put back (best effort) and kept: it
  // is still valid, so the session carries on with it.
  Future<void> _rotate(String key, String old, String fresh) async {
    try {
      await _store.write(refreshKey(key), fresh);
      if (await _store.read(refreshKey(key)) == fresh) return;
    } on Object {
      // Falls through to the restore below.
    }
    try {
      await _store.write(refreshKey(key), old);
    } on Object {
      // Nothing more can be done; the next refresh finds whichever is there.
    }
  }

  void _set(AuthState s) {
    if (_state == s) return;
    _state = s;
    if (!_changes.isClosed) _changes.add(s);
  }
}
