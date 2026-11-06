// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io' show Platform;

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:noted_auth/noted_auth.dart';
import 'package:url_launcher/url_launcher.dart';

/// The redirect of the sheet-based sign-in (iOS, Android, macOS): a custom
/// scheme built from the already-public bundle id, registered under "Mobile and
/// desktop applications" in the app registration.
const String appRedirectUri = 'io.github.ndouve.noted://auth';

/// Signs in the way this platform does it, and returns the code to exchange.
///
/// - iOS, Android and macOS: `flutter_appauth`'s `authorize()` only (a system
///   web sheet or Custom Tab). The code exchange is `noted_auth`'s, not the
///   plugin's.
/// - Windows and Linux: the system browser through `url_launcher` and a
///   loopback listener ([signInWithLoopback]).
Future<AuthGrant> systemBrowserSignIn(AuthConfig config) {
  if (Platform.isIOS || Platform.isAndroid || Platform.isMacOS) {
    return _appAuthSignIn(config);
  }
  return signInWithLoopback(
    config: config,
    launch: (url) => launchUrl(url, mode: LaunchMode.externalApplication),
  );
}

Future<AuthGrant> _appAuthSignIn(AuthConfig config) async {
  final AuthorizationResponse res;
  try {
    res = await const FlutterAppAuth().authorize(
      AuthorizationRequest(
        config.clientId,
        appRedirectUri,
        serviceConfiguration: AuthorizationServiceConfiguration(
          authorizationEndpoint: config.authorizationEndpoint.toString(),
          tokenEndpoint: config.tokenEndpoint.toString(),
        ),
        scopes: config.scopes,
      ),
    );
  } on FlutterAppAuthUserCancelledException {
    throw const AuthException(
      AuthErrorKind.cancelled,
      'Sign-in was cancelled.',
    );
  } on PlatformException {
    throw const AuthException(
      AuthErrorKind.rejected,
      'The sign-in page was refused or could not be shown.',
    );
  }
  final code = res.authorizationCode;
  final verifier = res.codeVerifier;
  if (code == null || code.isEmpty || verifier == null) {
    throw const AuthException(
      AuthErrorKind.rejected,
      'Microsoft sent back no sign-in code.',
    );
  }
  return AuthGrant(
    code: code,
    codeVerifier: verifier,
    redirectUri: appRedirectUri,
  );
}
