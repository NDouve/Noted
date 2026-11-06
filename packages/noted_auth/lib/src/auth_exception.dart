// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Why a sign-in step failed.
enum AuthErrorKind {
  /// The refresh token or code was refused (`invalid_grant`): the user has to
  /// sign in again.
  invalidGrant,

  /// Microsoft refused for another reason (an OAuth error, or an answer
  /// that isn't one).
  rejected,

  /// The token endpoint couldn't be reached.
  unreachable,

  /// There is no usable sign-in: signed out, or the session needs a new one.
  signInRequired,

  /// The secure storage couldn't be read or written.
  storage,

  /// The browser couldn't be opened.
  browser,

  /// Nobody finished signing in in time.
  timedOut,

  /// The sign-in page was refused or closed, or the answer wasn't for this
  /// attempt.
  cancelled,
}

/// A sign-in step failed. [message] is plain text fit to show the user; it
/// never holds a code or a token.
class AuthException implements Exception {
  const AuthException(this.kind, this.message);

  final AuthErrorKind kind;
  final String message;

  @override
  String toString() => 'AuthException(${kind.name}): $message';
}
