// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/ai/ai_connections_dialog.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/app_theme.dart';
import 'package:noted/src/settings_menu.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('noted_aiconn');
    file = File('${dir.path}/settings.json');
  });

  tearDown(() => dir.delete(recursive: true));

  group('AppSettings', () {
    test('adds a connection and keeps only a hash of the token', () async {
      final s = AppSettings(file);
      expect(s.aiConnections.value, isEmpty);
      final token = await s.addAiConnection(' Claude Code ');
      final parsed = parseAiToken(token)!;
      expect(s.aiConnections.value.single.id, parsed.id);
      expect(s.aiConnections.value.single.name, 'Claude Code');
      expect(s.aiConnections.value.single.createdAt, greaterThan(0));

      final text = file.readAsStringSync();
      expect(text, isNot(contains(parsed.key)));
      expect(text, isNot(contains(token)));
      final stored = (jsonDecode(text) as Map<String, Object?>)['aiConnections'] as List;
      expect((stored.single as Map<String, Object?>)['hash'], aiKeyHash(parsed.key));
      expect((stored.single as Map<String, Object?>).keys.toSet(), {'id', 'name', 'hash', 'created'});
    });

    test('verifies tokens, also after a restart', () async {
      final s = AppSettings(file);
      final token = await s.addAiConnection('A');
      final other = await s.addAiConnection('B');
      expect(s.verifyAiToken(token)!.name, 'A');
      expect(s.verifyAiToken(other)!.name, 'B');
      expect(s.verifyAiToken('nonsense'), isNull);
      final k = parseAiToken(token)!;
      expect(s.verifyAiToken('noted_${k.id}_${'A' * 43}'), isNull);

      final again = AppSettings(file);
      expect(again.verifyAiToken(token)!.name, 'A');
      expect(again.aiConnections.value.map((c) => c.name), ['A', 'B']);
    });

    test('a missing or damaged settings file accepts no token', () async {
      final s = AppSettings(file);
      final token = await s.addAiConnection('A');
      expect(s.verifyAiToken(token), isNotNull);

      final good = file.readAsStringSync();
      file.writeAsStringSync('{ not json');
      expect(s.verifyAiToken(token), isNull);
      file.deleteSync();
      expect(s.verifyAiToken(token), isNull);

      file.writeAsStringSync(good);
      expect(s.verifyAiToken(token)!.name, 'A');
    });

    test('rename and revoke; revoking takes effect on the next check', () async {
      final s = AppSettings(file);
      final token = await s.addAiConnection('A');
      final id = parseAiToken(token)!.id;
      s.renameAiConnection(id, 'Renamed');
      expect(s.verifyAiToken(token)!.name, 'Renamed');
      s.renameAiConnection(id, '   ');
      expect(s.aiConnections.value.single.name, 'Renamed', reason: 'empty names are ignored');
      expect(AppSettings(file).aiConnections.value.single.name, 'Renamed');

      s.revokeAiConnection(id);
      expect(s.verifyAiToken(token), isNull);
      expect(s.aiConnections.value, isEmpty);
      expect(AppSettings(file).verifyAiToken(token), isNull);
    });

    test('unknown fields and other settings survive, both ways', () async {
      file.writeAsStringSync(
        jsonEncode({
          'format': 1,
          'theme': 'dark',
          'future': {'x': 1},
          'aiConnections': [
            {'id': '0123456789abcdef', 'name': 'Old', 'hash': 'h', 'created': 5, 'extra': 'kept'},
          ],
        }),
      );
      final s = AppSettings(file);
      expect(s.aiConnections.value.single.name, 'Old');
      await s.addAiConnection('New');
      s.theme = ThemeSetting.light;
      final json = jsonDecode(file.readAsStringSync()) as Map;
      expect(json['future'], {'x': 1});
      expect(json['theme'], 'light');
      final list = (json['aiConnections'] as List).cast<Map<String, Object?>>();
      expect(list.map((e) => e['name']), ['Old', 'New']);
      expect(list.first['extra'], 'kept');
      expect(list.first['hash'], 'h');

      // Changing another setting doesn't drop the connections.
      final back = AppSettings(file)..toolbar = AppSettings(file).toolbar;
      expect(back.aiConnections.value, hasLength(2));
    });

    test('the secret is not in the settings object after adding', () async {
      final s = AppSettings(file);
      final token = await s.addAiConnection('A');
      final key = parseAiToken(token)!.key;
      expect(s.aiConnections.value.toString(), isNot(contains(key)));
      expect(jsonEncode(s.aiConnections.value.map((c) => [c.id, c.name, c.createdAt]).toList()), isNot(contains(key)));
    });
  });

  group('two instances over one file', () {
    test('each sees the other\'s new connection and revocation', () async {
      final a = AppSettings(file);
      final b = AppSettings(file);
      final tokenA = await a.addAiConnection('From A');
      expect(b.verifyAiToken(tokenA)!.name, 'From A', reason: 'b re-reads the file');
      expect(b.aiConnections.value.map((c) => c.name), ['From A']);

      final tokenB = await b.addAiConnection('From B');
      expect(a.verifyAiToken(tokenB)!.name, 'From B');
      expect(
        (jsonDecode(file.readAsStringSync()) as Map<String, Object?>)['aiConnections'] as List,
        hasLength(2),
        reason: 'b kept a\'s connection when it wrote',
      );

      a.revokeAiConnection(parseAiToken(tokenA)!.id);
      expect(b.verifyAiToken(tokenA), isNull, reason: 'revoked in the other instance');
      expect(b.verifyAiToken(tokenB), isNotNull);
    });

    test('a theme change in a stale instance does not bring back a revoked token or drop a new one', () async {
      final stale = AppSettings(file);
      final live = AppSettings(file);
      final old = await live.addAiConnection('Old');
      stale.refreshAiConnections();
      live.revokeAiConnection(parseAiToken(old)!.id);
      final fresh = await live.addAiConnection('Fresh');

      stale.theme = ThemeSetting.dark;
      stale.toolbar = AppSettings(null).toolbar;
      expect(live.verifyAiToken(old), isNull);
      expect(live.verifyAiToken(fresh), isNotNull);
      final reread = AppSettings(file);
      expect(reread.verifyAiToken(old), isNull);
      expect(reread.verifyAiToken(fresh), isNotNull);
      expect(reread.theme, ThemeSetting.dark);
    });

    test('a revoked connection stays revoked after a restart', () async {
      final s = AppSettings(file);
      final token = await s.addAiConnection('Gone');
      s.revokeAiConnection(parseAiToken(token)!.id);
      final again = AppSettings(file);
      expect(again.verifyAiToken(token), isNull);
      expect(again.aiConnections.value, isEmpty);
    });
  });

  group('a settings file that can not be written', () {
    // The settings folder is a file, so nothing can be saved.
    AppSettings broken() {
      final blocker = File('${dir.path}/blocker')..writeAsStringSync('x');
      return AppSettings(File('${blocker.path}/settings.json'));
    }

    test('add, rename and revoke throw and change nothing', () async {
      final s = broken();
      await expectLater(s.addAiConnection('x'), throwsA(isA<SettingsSaveException>()));
      expect(s.aiConnections.value, isEmpty);
    });

    testWidgets('the dialog says so and shows no token', (t) async {
      final s = broken();
      await t.pumpWidget(
        MaterialApp(
          theme: buildNotedTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: const ValueKey('open'),
                onPressed: () => showAiConnectionsDialog(context, s),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('open')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ai-add')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('ai-name')), 'Bot');
      await t.tap(find.byKey(const ValueKey('ai-create')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-error')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-token')), findsNothing);
      expect(s.aiConnections.value, isEmpty);
    });
  });

  testWidgets('the token stage is not closed by a click outside or Escape', (t) async {
    final s = AppSettings(null);
    await t.pumpWidget(
      MaterialApp(
        theme: buildNotedTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () => showAiConnectionsDialog(context, s),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('open')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('ai-add')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('ai-name')), 'Bot');
    await t.tap(find.byKey(const ValueKey('ai-create')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-token')), findsOneWidget);

    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-token')), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-token')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('ai-token-done')));
    await t.pumpAndSettle();
    await t.tapAt(const Offset(5, 5)); // the list stage closes as usual
    await t.pumpAndSettle();
    expect(find.text('AI connections'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    group('the dialog (${brightness.name})', () {
      Future<AppSettings> open(WidgetTester t) async {
        final settings = AppSettings(null);
        await t.pumpWidget(
          MaterialApp(
            theme: buildNotedTheme(brightness),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  key: const ValueKey('open'),
                  onPressed: () => showAiConnectionsDialog(context, settings),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.byKey(const ValueKey('open')));
        await t.pumpAndSettle();
        return settings;
      }

      testWidgets('add shows the token once, with Copy', (t) async {
        final copied = <String>[];
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
          return null;
        });
        addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
        final settings = await open(t);
        expect(find.text('AI connections'), findsOneWidget);
        expect(find.textContaining('No AI connections yet'), findsOneWidget);

        await t.tap(find.byKey(const ValueKey('ai-add')));
        await t.pumpAndSettle();
        await t.enterText(find.byKey(const ValueKey('ai-name')), 'Claude Code');
        await t.tap(find.byKey(const ValueKey('ai-create')));
        await t.pumpAndSettle();

        final shown = t.widget<SelectableText>(find.byKey(const ValueKey('ai-token'))).data!;
        expect(parseAiToken(shown), isNotNull);
        expect(settings.verifyAiToken(shown)!.name, 'Claude Code');
        expect(find.text("Copy it now: Noted won't show it again."), findsOneWidget);
        expect(t.widget<SelectableText>(find.byKey(const ValueKey('ai-token'))).style?.fontFamily, 'monospace');

        await t.tap(find.byKey(const ValueKey('ai-copy')));
        await t.pumpAndSettle();
        expect(copied, [shown]);

        await t.tap(find.byKey(const ValueKey('ai-token-done')));
        await t.pumpAndSettle();
        expect(find.text(shown), findsNothing, reason: 'shown once');
        expect(find.byKey(const ValueKey('ai-token')), findsNothing);
        final c = settings.aiConnections.value.single;
        expect(find.text('Claude Code'), findsOneWidget);
        expect(find.textContaining('Created '), findsOneWidget);
        expect(find.byKey(ValueKey('ai-connection-${c.id}')), findsOneWidget);
      });

      testWidgets('rename', (t) async {
        final settings = await open(t);
        final token = await settings.addAiConnection('Old name');
        final id = parseAiToken(token)!.id;
        await t.pumpAndSettle();
        await t.tap(find.byKey(ValueKey('ai-rename-$id')));
        await t.pumpAndSettle();
        await t.enterText(find.byKey(const ValueKey('ai-rename-name')), 'New name');
        await t.tap(find.byKey(const ValueKey('ai-rename-save')));
        await t.pumpAndSettle();
        expect(find.text('New name'), findsOneWidget);
        expect(find.text('Old name'), findsNothing);
        expect(settings.aiConnections.value.single.name, 'New name');
      });

      testWidgets('revoke asks first, then the token stops working', (t) async {
        final settings = await open(t);
        final token = await settings.addAiConnection('Bot');
        final id = parseAiToken(token)!.id;
        await t.pumpAndSettle();

        await t.tap(find.byKey(ValueKey('ai-revoke-$id')));
        await t.pumpAndSettle();
        expect(
          find.text('Bot can no longer read its boxes or write. Its boxes keep their text and become yours.'),
          findsOneWidget,
        );
        await t.tap(find.text('Cancel'));
        await t.pumpAndSettle();
        expect(settings.verifyAiToken(token), isNotNull, reason: 'cancel keeps it');

        await t.tap(find.byKey(ValueKey('ai-revoke-$id')));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('ai-revoke-confirm')));
        await t.pumpAndSettle();
        expect(settings.verifyAiToken(token), isNull);
        expect(find.byKey(ValueKey('ai-connection-$id')), findsNothing);
        expect(find.textContaining('No AI connections yet'), findsOneWidget);
      });
    });
  }

  testWidgets('the gear menu opens it', (t) async {
    final settings = AppSettings(null);
    await t.pumpWidget(
      MaterialApp(
        theme: buildNotedTheme(Brightness.light),
        home: Scaffold(body: SettingsMenu(settings: settings)),
      ),
    );
    await t.tap(find.byKey(const ValueKey('settings-menu')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('settings-ai-connections')));
    await t.pumpAndSettle();
    expect(find.text('AI connections'), findsOneWidget);
  });
}
