// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/app_theme.dart';
import 'package:noted/src/microsoft_account.dart';
import 'package:noted/src/settings_menu.dart';
import 'package:noted_auth/noted_auth.dart';

String _jwt(Map<String, Object?> claims) {
  String part(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part(claims)}.sig';
}

/// A token endpoint that always says yes (the real one is tested in noted_auth).
class _FakeTokens extends TokenClient {
  _FakeTokens(super.config);

  TokenResponse get _ok => TokenResponse(
    accessToken: 'A',
    refreshToken: 'R',
    idToken: _jwt({'tid': 't', 'oid': 'o', 'name': 'Ada Test'}),
    expiresIn: const Duration(hours: 1),
  );

  @override
  Future<TokenResponse> exchangeCode({
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) async => _ok;

  @override
  Future<TokenResponse> refresh(String refreshToken) async => _ok;
}

/// An account over a real session with a fake token endpoint; [flow] stands in
/// for the browser.
MicrosoftAccount _account(MemoryTokenStore store, {SignInFlow? flow}) {
  const config = AuthConfig(clientId: 'test-client');
  return MicrosoftAccount(
    config: config,
    session: AuthSession(tokens: _FakeTokens(config), store: store),
    flow:
        flow ??
        (_) async =>
            const AuthGrant(code: 'c', codeVerifier: 'v', redirectUri: 'r'),
  );
}

void main() {
  late AppSettings settings;

  setUp(() => settings = AppSettings(null));

  Future<void> pumpMenu(
    WidgetTester t,
    MicrosoftAccount? account, {
    Brightness brightness = Brightness.light,
  }) async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildNotedTheme(brightness),
        home: Scaffold(
          body: SettingsMenu(settings: settings, microsoft: account),
        ),
      ),
    );
  }

  Future<void> openAbout(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('settings-menu')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('settings-about')));
    await t.pumpAndSettle();
  }

  Future<void> tapAbout(WidgetTester t, int n) async {
    for (var i = 0; i < n; i++) {
      await t.tap(find.byKey(const ValueKey('about-line')));
      await t.pump();
    }
  }

  test('a build without a client id has no account', () {
    expect(MicrosoftAccount.create(clientId: ''), isNull);
    expect(MicrosoftAccount.create(clientId: 'x'), isNotNull);
    // This test run defines no client id either.
    expect(microsoftClientId, isEmpty);
  });

  testWidgets('without a client id the menu has no trace of Microsoft', (
    t,
  ) async {
    await pumpMenu(t, null);
    await t.tap(find.byKey(const ValueKey('settings-menu')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-about')), findsNothing);
    expect(find.textContaining('Microsoft'), findsNothing);
  });

  testWidgets('the entry is hidden until the fifth tap on the about line', (
    t,
  ) async {
    final account = _account(MemoryTokenStore());
    await pumpMenu(t, account);
    await openAbout(t);
    expect(find.text('About Noted'), findsOneWidget);
    expect(find.text('Microsoft account (preview)'), findsNothing);
    await tapAbout(t, 4);
    expect(find.text('Microsoft account (preview)'), findsNothing);
    await tapAbout(t, 1);
    expect(find.text('Microsoft account (preview)'), findsOneWidget);
    expect(find.text('Signed out'), findsOneWidget);
    expect(find.byKey(const ValueKey('ms-sign-in')), findsOneWidget);
    expect(find.byKey(const ValueKey('ms-sign-out')), findsNothing);
    // Revealed for the session: it is still there when About is reopened.
    await t.tap(find.byKey(const ValueKey('about-close')));
    await t.pumpAndSettle();
    await openAbout(t);
    expect(find.text('Microsoft account (preview)'), findsOneWidget);
    // A new run (a new account object) hides it again.
    expect(_account(MemoryTokenStore()).revealed, isFalse);
  });

  testWidgets(
    'signing in shows the account name; signing out removes the token',
    (t) async {
      final store = MemoryTokenStore();
      final account = _account(store);
      await pumpMenu(t, account);
      await openAbout(t);
      await tapAbout(t, 5);
      await t.tap(find.byKey(const ValueKey('ms-sign-in')));
      await t.pumpAndSettle();
      expect(find.text('Signed in as Ada Test'), findsOneWidget);
      expect(find.byKey(const ValueKey('ms-sign-in')), findsNothing);
      expect(store.values, isNotEmpty);
      await t.tap(find.byKey(const ValueKey('ms-sign-out')));
      await t.pumpAndSettle();
      expect(find.text('Signed out'), findsOneWidget);
      expect(store.values, isEmpty);
    },
  );

  testWidgets('a stored account reads as signed in', (t) async {
    final store = MemoryTokenStore();
    await t.runAsync(() async {
      final first = _account(store);
      await first.signIn();
    });
    final account = _account(store);
    await t.runAsync(account.start);
    await pumpMenu(t, account);
    await openAbout(t);
    await tapAbout(t, 5);
    expect(find.text('Signed in as Ada Test'), findsOneWidget);
    expect(find.byKey(const ValueKey('ms-sign-out')), findsOneWidget);
  });

  testWidgets('a token that was lost reads as sign in again', (t) async {
    final store = MemoryTokenStore();
    await t.runAsync(() => _account(store).signIn());
    store.values.remove(AuthSession.refreshKey('t.o'));
    final account = _account(store);
    await t.runAsync(account.start);
    await pumpMenu(t, account, brightness: Brightness.dark);
    await openAbout(t);
    await tapAbout(t, 5);
    expect(account.state, AuthState.signInAgain);
    expect(find.text('Session expired'), findsOneWidget);
    expect(find.text('Sign in again'), findsWidgets);
    expect(find.byKey(const ValueKey('ms-sign-in')), findsOneWidget);
    expect(find.byKey(const ValueKey('ms-sign-out')), findsOneWidget);
  });

  testWidgets(
    'a browser that cannot open or a refusal is shown as a plain message',
    (t) async {
      final account = _account(
        MemoryTokenStore(),
        flow: (_) async => throw const AuthException(
          AuthErrorKind.browser,
          'The browser could not be opened.',
        ),
      );
      await pumpMenu(t, account);
      await openAbout(t);
      await tapAbout(t, 5);
      await t.tap(find.byKey(const ValueKey('ms-sign-in')));
      await t.pumpAndSettle();
      expect(find.text('The browser could not be opened.'), findsOneWidget);
      expect(find.text('Signed out'), findsOneWidget);
      expect(find.byKey(const ValueKey('ms-sign-in')), findsOneWidget);
    },
  );

  group('first-launch keychain clean-up (iOS)', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('runs once, then the flag in settings.json stops it', () async {
      final dir = Directory.systemTemp.createTempSync('noted_keychain');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/settings.json');
      // An old-format file: the key is simply absent.
      file.writeAsStringSync('{"format":1,"theme":"dark"}');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      var runs = 0;
      final s = AppSettings(file);
      expect(s.keychainCleaned, isFalse);
      await clearKeychainOnFirstLaunch(s, () async => runs++);
      await clearKeychainOnFirstLaunch(AppSettings(file), () async => runs++);
      expect(runs, 1);
      expect(jsonDecode(file.readAsStringSync()), {
        'format': 1,
        'theme': 'dark',
        'keychainCleaned': true,
      });
    });

    test('the flag cannot be written: the items go, the clean-up is not done', () async {
      final dir = Directory.systemTemp.createTempSync('noted_keychain');
      addTearDown(() => dir.deleteSync(recursive: true));
      // The settings folder is a file, so nothing can be saved there.
      File('${dir.path}/blocker').writeAsStringSync('x');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      var runs = 0;
      final settings = AppSettings(File('${dir.path}/blocker/settings.json'));
      final done = await clearKeychainOnFirstLaunch(settings, () async => runs++);
      expect(runs, 1);
      expect(done, isFalse);
    });

    test('a failed delete leaves the flag unset, blocks restore and sign-in, and the next start retries', () async {
      final dir = Directory.systemTemp.createTempSync('noted_keychain');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/settings.json');
      file.writeAsStringSync('{"format":1}');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final store = MemoryTokenStore();
      await store.write(AuthSession.accountRecordKey, '{"key":"t.o","name":"Old"}');
      await store.write(AuthSession.refreshKey('t.o'), 'R-old');
      var signIns = 0;
      final account = _account(store, flow: (_) async {
        signIns++;
        return const AuthGrant(code: 'c', codeVerifier: 'v', redirectUri: 'r');
      });
      addTearDown(account.dispose);
      await account.start(
        settings: AppSettings(file),
        firstLaunchCleanup: () async => throw StateError('keychain'),
      );
      expect(AppSettings(file).keychainCleaned, isFalse);
      expect(account.state, AuthState.signedOut); // the old account is not restored
      await account.signIn(); // retries the clean-up, which fails again
      expect(account.error, "Noted couldn't prepare sign-in. Try again.");
      expect(signIns, 0);
      expect(account.state, AuthState.signedOut);

      // The next start, with a working delete.
      var deletes = 0;
      final next = _account(store);
      addTearDown(next.dispose);
      await next.start(
        settings: AppSettings(file),
        firstLaunchCleanup: () async {
          deletes++;
          await store.delete(AuthSession.accountRecordKey);
          await store.delete(AuthSession.refreshKey('t.o'));
        },
      );
      expect(deletes, 1);
      expect(AppSettings(file).keychainCleaned, isTrue);
      expect(next.state, AuthState.signedOut);
      await next.signIn();
      expect(next.error, isNull);
      expect(next.state, AuthState.signedIn);
    });

    test('a sign-in in the same session retries a failed delete first', () async {
      final dir = Directory.systemTemp.createTempSync('noted_keychain');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/settings.json')..writeAsStringSync('{}');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      var fail = true;
      final account = _account(MemoryTokenStore());
      addTearDown(account.dispose);
      await account.start(
        settings: AppSettings(file),
        firstLaunchCleanup: () async {
          if (fail) throw StateError('keychain');
        },
      );
      fail = false;
      await account.signIn();
      expect(account.error, isNull);
      expect(account.state, AuthState.signedIn);
      expect(AppSettings(file).keychainCleaned, isTrue);
    });

    test('a flag that cannot be saved after a good delete blocks restore and sign-in', () async {
      final dir = Directory.systemTemp.createTempSync('noted_keychain');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/blocker').writeAsStringSync('x');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final store = MemoryTokenStore();
      await store.write(AuthSession.accountRecordKey, '{"key":"t.o","name":"Old"}');
      await store.write(AuthSession.refreshKey('t.o'), 'R-old');
      var deletes = 0;
      final account = _account(store);
      addTearDown(account.dispose);
      await account.start(
        settings: AppSettings(File('${dir.path}/blocker/settings.json')),
        firstLaunchCleanup: () async => deletes++,
      );
      expect(account.state, AuthState.signedOut);
      await account.signIn();
      expect(account.error, "Noted couldn't prepare sign-in. Try again.");
      expect(account.state, AuthState.signedOut);
      expect(deletes, 1); // not repeated in this session

      // The next start retries (the flag was never saved).
      final next = _account(store);
      addTearDown(next.dispose);
      await next.start(
        settings: AppSettings(File('${dir.path}/blocker/settings.json')),
        firstLaunchCleanup: () async => deletes++,
      );
      expect(deletes, 2);
    });

    test(
      'never runs on other platforms, or when the settings cannot be saved',
      () async {
        var runs = 0;
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await clearKeychainOnFirstLaunch(AppSettings(null), () async => runs++);
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final dir = Directory.systemTemp.createTempSync('noted_keychain');
        addTearDown(() => dir.deleteSync(recursive: true));
        final broken = File('${dir.path}/settings.json')
          ..writeAsStringSync('{ nope');
        await clearKeychainOnFirstLaunch(
          AppSettings(broken),
          () async => runs++,
        );
        expect(runs, 0);
      },
    );
  });
}
