// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:noted_auth/noted_auth.dart';

import 'app_settings.dart';
import 'microsoft_sign_in_flow.dart';
import 'secure_token_store.dart';

/// The application (client) id of Noted's Microsoft registration. It is public
/// in every binary but identifies a registration in a specific tenant, so it is
/// never committed: it comes from the build
/// (`--dart-define=NOTED_MS_CLIENT_ID=...`). A build without it has no
/// Microsoft sign-in at all.
const String microsoftClientId = String.fromEnvironment('NOTED_MS_CLIENT_ID');

/// Runs the browser part of a sign-in and returns the code to exchange.
typedef SignInFlow = Future<AuthGrant> Function(AuthConfig config);

/// The signed-in Microsoft account as the UI sees it (OneDrive sync stage 2:
/// sign-in only, no OneDrive calls). Wraps an [AuthSession] and remembers the
/// last error and whether a sign-in is waiting on the browser.
class MicrosoftAccount extends ChangeNotifier {
  MicrosoftAccount({
    required this.config,
    required this.session,
    required this.flow,
  }) {
    _sub = session.changes.listen((_) => notifyListeners());
  }

  /// The account of this build, or null (sign-in hidden) when the build has no
  /// client id. [clientId], [store] and [flow] are for tests.
  static MicrosoftAccount? create({
    String clientId = microsoftClientId,
    TokenStore? store,
    SignInFlow? flow,
  }) {
    if (clientId.isEmpty) return null;
    final config = AuthConfig(clientId: clientId);
    return MicrosoftAccount(
      config: config,
      session: AuthSession(
        tokens: TokenClient(config),
        store: store ?? SecureTokenStore(),
      ),
      flow: flow ?? systemBrowserSignIn,
    );
  }

  final AuthConfig config;
  final AuthSession session;
  final SignInFlow flow;
  late final StreamSubscription<AuthState> _sub;

  bool _revealed = false;
  bool _busy = false;
  String? _error;

  /// The entry has been uncovered (five taps on the about line) in this run.
  /// Not saved: it is hidden again at the next start.
  bool get revealed => _revealed;

  void reveal() {
    if (_revealed) return;
    _revealed = true;
    notifyListeners();
  }

  AuthState get state => session.state;
  String? get displayName => session.displayName;

  /// A sign-in is waiting on the browser.
  bool get busy => _busy;

  /// Why the last sign-in or sign-out failed, in plain words; null if it didn't.
  String? get error => _error;

  // Set by start(); until the iOS clean-up has succeeded in this session the
  // account is not restored and sign-in is refused.
  AppSettings? _settings;
  Future<void> Function()? _cleanup;
  bool _ready = true;
  bool _deleted = false;
  bool _saveFailed = false;

  /// Runs the clean-up if it is due. True when sign-in may go ahead: nothing to
  /// clean, or the items were deleted and the flag saved.
  Future<bool> _prepare() async {
    final settings = _settings;
    if (settings == null || _ready) return true;
    // A flag that failed to save stays set in the settings object in memory,
    // which would then pass for saved; so it is not retried before the next
    // launch.
    if (_saveFailed) return false;
    try {
      final delete = _cleanup ?? SecureTokenStore.deleteEverything;
      _ready = await clearKeychainOnFirstLaunch(settings, () async {
        await delete();
        _deleted = true;
      });
      if (!_ready && _deleted) _saveFailed = true;
    } on Object {
      _ready = false;
    }
    return _ready;
  }

  /// Reads the stored account (after, on iOS, the one-time keychain
  /// clean-up). Never throws. If the clean-up fails the account is not
  /// restored and sign-in is refused until a later start succeeds.
  Future<void> start({
    AppSettings? settings,
    Future<void> Function()? firstLaunchCleanup,
  }) async {
    _settings = settings;
    _cleanup = firstLaunchCleanup;
    _ready = settings == null;
    _deleted = false;
    _saveFailed = false;
    try {
      if (await _prepare()) await session.restore();
    } on Object {
      // A store that can't be read already leaves the state at sign in again.
    }
    notifyListeners();
  }

  Future<void> signIn() async {
    if (_busy) return;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      if (await _prepare()) {
        await session.signIn(await flow(config));
      } else {
        _error = "Noted couldn't prepare sign-in. Try again.";
      }
    } on AuthException catch (e) {
      _error = e.message;
    } on Object {
      _error = 'Sign-in did not finish.';
    }
    _busy = false;
    notifyListeners();
  }

  /// Removes the stored token. Never touches anything on OneDrive.
  Future<void> signOut() async {
    _error = null;
    try {
      await session.signOut();
    } on AuthException catch (e) {
      _error = e.message;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    session.dispose();
    super.dispose();
  }
}

/// iOS keeps keychain items when the app is deleted, so a reinstall would find
/// the last install's token. On the first launch of an install (no flag in the
/// settings yet) Noted deletes its own keychain items, then saves the flag. The
/// flag is `keychainCleaned` in `settings.json`; it is true only after a delete
/// succeeded and the flag was saved, so a failure of either is retried. No
/// token of this install can exist before the flag is saved, so a retry never
/// deletes its own sign-in. Returns false if the clean-up was due and did not
/// finish (the caller must not restore or sign in); a delete that throws is
/// rethrown. Does nothing, and returns true, on other platforms or when the
/// settings couldn't be read or can't be saved (a reinstall wipes the container,
/// so a missing file is a first launch, but an unreadable one is not).
Future<bool> clearKeychainOnFirstLaunch(
  AppSettings settings,
  Future<void> Function() deleteAll,
) async {
  if (defaultTargetPlatform != TargetPlatform.iOS) return true;
  if (settings.keychainCleaned || !settings.canRememberNotes) return true;
  await deleteAll();
  return settings.markKeychainCleaned();
}
