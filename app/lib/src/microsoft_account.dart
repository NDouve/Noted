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

  /// Reads the stored account (after, on iOS, the one-time keychain
  /// clean-up). Never throws.
  Future<void> start({
    AppSettings? settings,
    Future<void> Function()? firstLaunchCleanup,
  }) async {
    try {
      if (settings != null) {
        await clearKeychainOnFirstLaunch(
          settings,
          firstLaunchCleanup ?? SecureTokenStore.deleteEverything,
        );
      }
      await session.restore();
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
      await session.signIn(await flow(config));
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
/// settings yet) Noted deletes its own keychain items, then sets the flag. The
/// flag is `keychainCleaned` in `settings.json`; without a sync journal yet it
/// is what says "this install has been cleaned". Does nothing on other
/// platforms, or when the settings can't be saved (it would run every launch).
Future<void> clearKeychainOnFirstLaunch(
  AppSettings settings,
  Future<void> Function() deleteAll,
) async {
  if (defaultTargetPlatform != TargetPlatform.iOS) return;
  if (settings.keychainCleaned || !settings.canRememberNotes) return;
  // The flag first, and only a saved flag lets the items go: if it could not
  // be saved the clean-up would repeat and sign the user out at every launch.
  if (!settings.markKeychainCleaned()) return;
  await deleteAll();
}
