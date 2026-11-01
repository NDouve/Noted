// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_ai/noted_box_ai.dart';
import 'package:noted_box_ai/src/ai_module.dart' show insertAiBox;
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

const ownerId = '0123456789abcdef';

Map<String, Object?> para(String text) => {
  'type': 'paragraph',
  'data': {
    'delta': [
      {'insert': text},
    ],
  },
};

BoxRecord aiRecord(String id, List<Map<String, Object?>> blocks, {String? owner}) {
  const codec = AiCodec();
  final data = AiBoxData({
    'document': {'type': 'page', 'children': blocks},
    'owner': ?owner,
  });
  return commitBox(
    createBox(codec, const Bounds(100, 100, 360, 96)),
    codec,
    data,
  ).withId(id);
}

NotedPage pageOf(List<BoxRecord> boxes) {
  var p = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
  for (final b in boxes) {
    p = p.insertNode(b);
  }
  return p;
}

Map<String, Object?> storedOf(CanvasController c, String id) =>
    ((c.page.node(id)! as BoxRecord).data!.decode()! as Map).cast<String, Object?>();

List<Map<String, Object?>> storedBlocks(CanvasController c, String id) =>
    (((storedOf(c, id)['document']! as Map)['children']!) as List)
        .cast<Map<String, Object?>>();

/// An in-memory [AiBoxAccess] that records what the box asks of it.
class FakeAccess extends ChangeNotifier implements AiBoxAccess {
  final List<AiCode> codes = [];
  final Map<String, bool> ask = {};
  final List<AiActivityEntry> log = [];
  final List<({String box, AiCodeRole role, String label, DateTime? expires})> connects = [];
  final List<String> revoked = [];
  final List<(String, String)> sessionsRevoked = [];
  Object? connectError;

  /// Thrown by revoke, revokeSession and setAskBeforeWrite.
  Object? changeError;

  /// When set, connect waits for it.
  Completer<void>? gate;
  String nextCode = 'noted_0123456789abcdef_secretkey';

  @override
  String? problem;

  void change() => notifyListeners();

  @override
  List<AiCode> connections(String boxId) => [
    for (final c in codes)
      if (c.target.id == boxId) c,
  ];

  @override
  Future<String> connect(
    String boxId, {
    required AiCodeRole role,
    required String label,
    DateTime? expires,
  }) async {
    await gate?.future;
    final error = connectError;
    if (error != null) throw error;
    connects.add((box: boxId, role: role, label: label, expires: expires));
    codes.add(
      AiCode(
        id: 'c${codes.length}'.padRight(16, '0'),
        target: AiCodeTarget.box(boxId),
        roleName: role.wire,
        label: label,
        hash: 'h',
        created: DateTime.now(),
        expires: expires,
      ),
    );
    notifyListeners();
    return nextCode;
  }

  @override
  Future<void> revoke(String codeId) async {
    if (changeError != null) throw changeError!;
    revoked.add(codeId);
    codes.removeWhere((c) => c.id == codeId);
    notifyListeners();
  }

  @override
  Future<void> revokeSession(String codeId, String sessionId) async {
    if (changeError != null) throw changeError!;
    sessionsRevoked.add((codeId, sessionId));
  }

  @override
  bool askBeforeWrite(String boxId) => ask[boxId] ?? false;

  @override
  Future<void> setAskBeforeWrite(String boxId, bool value) async {
    if (changeError != null) throw changeError!;
    ask[boxId] = value;
    notifyListeners();
  }

  final Map<String, AiWriterPermission> permission = {};
  final Map<String, bool> closed = {};

  @override
  AiWriterPermission writerPermission(String boxId) => permission[boxId] ?? AiWriterPermission.append;

  @override
  Future<void> setWriterPermission(String boxId, AiWriterPermission value) async {
    if (changeError != null) throw changeError!;
    permission[boxId] = value;
    notifyListeners();
  }

  @override
  bool closedWrites(String boxId) => !(ask[boxId] ?? false) && (closed[boxId] ?? false);

  @override
  Future<void> setClosedWrites(String boxId, bool value) async {
    if (changeError != null) throw changeError!;
    closed[boxId] = value;
    notifyListeners();
  }

  @override
  List<AiActivityEntry> activity(String boxId) => log;
}

AiCode codeOf(
  String id,
  String boxId, {
  String role = 'writer',
  String label = 'Feedback – work chat',
  DateTime? created,
  DateTime? lastUsed,
  DateTime? expires,
  List<AiCodeSession> sessions = const [],
}) => AiCode(
  id: id,
  target: AiCodeTarget.box(boxId),
  roleName: role,
  label: label,
  hash: 'h',
  created: created ?? DateTime.utc(2026, 11, 1, 9, 30),
  lastUsed: lastUsed,
  expires: expires,
  sessions: sessions,
);

void main() {
  late FakeAccess access;
  late ModuleRegistry modules;

  setUp(() {
    access = FakeAccess();
    modules = ModuleRegistry()
      ..register(const NoteModule(), alwaysOn: true, isDefault: true)
      ..register(AiModule(access: access));
  });

  tearDown(() => access.dispose());

  Future<(CanvasController, GlobalKey<PageCanvasState>)> pump(
    WidgetTester t,
    NotedPage page, {
    Brightness brightness = Brightness.light,
    ToolbarArrangement layout = contextualToolbarLayout,
    bool readOnly = false,
  }) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = CanvasController(page, modules);
    final key = GlobalKey<PageCanvasState>();
    await t.pumpWidget(
      MaterialApp(
        theme: notedThemeData(brightness),
        localizationsDelegates: noteLocalizationsDelegates,
        home: Scaffold(
          body: PageCanvas(
            key: key,
            controller: c,
            readOnly: readOnly,
            toolbar: layout,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    return (c, key);
  }

  Finder marks() => find.byKey(const ValueKey('note-block-mark'));
  Finder k(String key) => find.byKey(ValueKey(key));
  Future<void> typeLabel(WidgetTester t, String text) async {
    await t.enterText(k('ai-label'), text);
    // The Create button follows the text.
    await t.pump();
  }

  group('the box', () {
    testWidgets('has an AI label and shows its content', (t) async {
      await pump(t, pageOf([aiRecord('a', [para('hello')])]));
      expect(find.byKey(const ValueKey('ai-box-label')), findsOneWidget);
      expect(find.text('AI'), findsOneWidget);
      expect(find.textContaining('hello', findRichText: true), findsOneWidget);
    });

    for (final b in Brightness.values) {
      testWidgets('marks AI-written blocks only (${b.name})', (t) async {
        await pump(
          t,
          pageOf([
            aiRecord('a', [
              para('user line'),
              markAiWritten(para('ai line')),
            ]),
          ]),
          brightness: b,
        );
        expect(marks(), findsOneWidget);
        final bar = t.widget<DecoratedBox>(marks());
        final color = (bar.decoration as BoxDecoration).color!;
        expect(color.a, greaterThan(0));
        // The mark is the muted text color of the theme.
        final scheme = notedThemeData(b).colorScheme;
        expect(
          color.toARGB32(),
          scheme.onSurfaceVariant.withValues(alpha: 0.6).toARGB32(),
        );
      });
    }

    testWidgets('a mark that no longer matches the text is not drawn', (t) async {
      final stale = markAiWritten(para('before'));
      (((stale['data']! as Map)['delta']! as List).first as Map)['insert'] = 'after';
      await pump(t, pageOf([aiRecord('a', [stale])]));
      expect(marks(), findsNothing);
    });

    testWidgets('the mark takes no room', (t) async {
      final (c, _) = await pump(
        t,
        pageOf([
          aiRecord('plain', [para('same text')]),
          aiRecord('marked', [markAiWritten(para('same text'))]).withBounds(
            const Bounds(600, 100, 360, 96),
          ),
        ]),
      );
      expect(
        c.page.node('plain')!.bounds!.height,
        c.page.node('marked')!.bounds!.height,
      );
    });

    testWidgets('consecutive marked blocks draw one unbroken 2 px bar', (t) async {
      await pump(
        t,
        pageOf([
          aiRecord('a', [
            markAiWritten(para('first')),
            markAiWritten(para('second')),
            markAiWritten(para('third')),
          ]),
        ]),
      );
      expect(marks(), findsNWidgets(3));
      final rects = [for (var i = 0; i < 3; i++) t.getRect(marks().at(i))];
      for (final r in rects) {
        expect(r.width, 2);
        expect(r.left, rects.first.left);
      }
      rects.sort((x, y) => x.top.compareTo(y.top));
      expect(rects[0].bottom, closeTo(rects[1].top, 0.5));
      expect(rects[1].bottom, closeTo(rects[2].top, 0.5));
    });

    testWidgets('the bar stays left of the text, inside the box', (t) async {
      await pump(
        t,
        pageOf([
          aiRecord('a', [
            markAiWritten({
              'type': 'bulleted_list',
              'data': {
                'delta': [
                  {'insert': 'a bullet'},
                ],
              },
            }),
          ]),
        ]),
      );
      final bar = t.getRect(marks());
      final glyph = t.getRect(find.text('●'));
      final box = t.getRect(find.byKey(const ValueKey('ai-box-label')));
      expect(bar.right, lessThanOrEqualTo(glyph.left));
      expect(bar.left, greaterThanOrEqualTo(box.left - 8));
    });
  });

  group('connecting a chat', () {
    Future<void> openConnect(WidgetTester t) async {
      await t.tap(k('ai-box-connect'));
      await t.pumpAndSettle();
    }

    testWidgets('the header has Connect a chat and the connections indicator', (t) async {
      access.codes.add(codeOf('a000000000000001', 'a'));
      access.codes.add(codeOf('a000000000000002', 'a', role: 'reader'));
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      expect(find.text('Connect a chat'), findsOneWidget);
      expect(find.text('2 chats'), findsOneWidget);
      access.codes.clear();
      access.change();
      await t.pump();
      expect(find.text('No chats'), findsOneWidget);
    });

    testWidgets('an expired code is not counted in the indicator', (t) async {
      access.codes.add(codeOf('a000000000000001', 'a', expires: DateTime.utc(2000)));
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      expect(find.text('No chats'), findsOneWidget);
    });

    for (final role in AiCodeRole.values) {
      testWidgets('a ${role.name} is issued with its label and no expiry', (t) async {
        await pump(t, pageOf([aiRecord('a', [para('x')])]));
        await openConnect(t);
        await t.tap(k('ai-role-${role.name}'));
        await t.pumpAndSettle();
        await typeLabel(t, '  Feedback – work chat ');
        await t.tap(k('ai-connect-create'));
        await t.pumpAndSettle();
        expect(access.connects, hasLength(1));
        final c = access.connects.single;
        expect(c.box, 'a');
        expect(c.role, role);
        expect(c.label, 'Feedback – work chat');
        expect(c.expires, isNull);
        // The code is shown once, under a title naming the connection.
        expect(find.text('Code for Feedback – work chat'), findsOneWidget);
        expect(find.text(access.nextCode), findsOneWidget);
        expect(find.textContaining('only once'), findsOneWidget);
        expect(find.textContaining('only on this computer'), findsOneWidget);
      });
    }

    testWidgets('Enter in the label field submits', (t) async {
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await openConnect(t);
      await t.tap(k('ai-role-reader'));
      await t.pumpAndSettle();
      await typeLabel(t, 'Reading group');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(access.connects.single.label, 'Reading group');
      expect(k('ai-code'), findsOneWidget);
    });

    testWidgets('an empty label is not submitted', (t) async {
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await openConnect(t);
      await t.tap(k('ai-role-writer'));
      await t.pumpAndSettle();
      await typeLabel(t, '   ');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(access.connects, isEmpty);
      expect(t.widget<FilledButton>(k('ai-connect-create')).onPressed, isNull);
    });

    for (final days in [1, 7, 30]) {
      testWidgets('an expiry of $days days is passed on', (t) async {
        await pump(t, pageOf([aiRecord('a', [para('x')])]));
        await openConnect(t);
        await t.tap(k('ai-role-reader'));
        await t.pumpAndSettle();
        await typeLabel(t, 'Temp');
        await t.tap(k('ai-expiry-$days'));
        await t.pump();
        final before = DateTime.now();
        await t.tap(k('ai-connect-create'));
        await t.pumpAndSettle();
        final e = access.connects.single.expires!;
        final span = e.difference(before);
        expect(span, greaterThan(Duration(days: days) - const Duration(minutes: 1)));
        expect(span, lessThan(Duration(days: days) + const Duration(minutes: 1)));
      });
    }

    testWidgets('the code stays until Done: Escape and a click outside keep it', (t) async {
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await openConnect(t);
      await t.tap(k('ai-role-writer'));
      await t.pumpAndSettle();
      await typeLabel(t, 'Chat');
      await t.tap(k('ai-connect-create'));
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(k('ai-code'), findsOneWidget);
      await t.tapAt(const Offset(4, 4));
      await t.pumpAndSettle();
      expect(k('ai-code'), findsOneWidget);
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await t.tap(k('ai-copy'));
      await t.pumpAndSettle();
      expect(copied, access.nextCode);
      expect(find.text('Copied'), findsOneWidget);
      await t.tap(k('ai-code-done'));
      await t.pumpAndSettle();
      expect(k('ai-code'), findsNothing);
      expect(find.text(access.nextCode), findsNothing);
    });

    testWidgets('issuing a Writer when one exists warns', (t) async {
      access.codes.add(codeOf('a000000000000001', 'a', label: 'Old chat'));
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await openConnect(t);
      await t.tap(k('ai-role-writer'));
      await t.pumpAndSettle();
      expect(k('ai-writer-warning'), findsOneWidget);
      expect(find.textContaining('Old chat'), findsOneWidget);
      expect(find.textContaining('stops working'), findsOneWidget);
      // A Reader needs no warning.
      await t.tap(k('ai-connect-back'));
      await t.pumpAndSettle();
      await t.tap(k('ai-role-reader'));
      await t.pumpAndSettle();
      expect(k('ai-writer-warning'), findsNothing);
    });

    testWidgets('a Reader-only box gives no Writer warning', (t) async {
      access.codes.add(codeOf('a000000000000001', 'a', role: 'reader'));
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await openConnect(t);
      await t.tap(k('ai-role-writer'));
      await t.pumpAndSettle();
      expect(k('ai-writer-warning'), findsNothing);
    });

    testWidgets('a failure to issue shows its message and no code', (t) async {
      access.connectError = StateError('Could not save the code.');
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await openConnect(t);
      await t.tap(k('ai-role-writer'));
      await t.pumpAndSettle();
      await typeLabel(t, 'Chat');
      await t.tap(k('ai-connect-create'));
      await t.pumpAndSettle();
      expect(find.text('Could not save the code.'), findsOneWidget);
      expect(k('ai-code'), findsNothing);
    });

    testWidgets('without AI access Connect is off and says why', (t) async {
      modules = ModuleRegistry()
        ..register(const NoteModule(), alwaysOn: true, isDefault: true)
        ..register(AiModule());
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      expect(t.widget<TextButton>(k('ai-box-connect')).onPressed, isNull);
      expect(k('ai-box-connections'), findsNothing);
      await t.longPress(k('ai-box-connect'));
      await t.pumpAndSettle();
      expect(find.text('AI connections are not available here'), findsOneWidget);
    });

    testWidgets('a read-only page has no Connect control but shows connections', (t) async {
      access.codes.add(codeOf('a000000000000001', 'a'));
      await pump(
        t,
        pageOf([aiRecord('a', [para('x')])]),
        readOnly: true,
      );
      expect(k('ai-box-connect'), findsNothing);
      expect(find.text('1 chat'), findsOneWidget);
    });

    testWidgets('works in dark mode', (t) async {
      await pump(
        t,
        pageOf([aiRecord('a', [para('x')])]),
        brightness: Brightness.dark,
      );
      await openConnect(t);
      expect(k('ai-role-writer'), findsOneWidget);
    });

    testWidgets('a legacy owner stays in the box, untouched', (t) async {
      final (c, _) = await pump(
        t,
        pageOf([aiRecord('a', [markAiWritten(para('kept'))], owner: ownerId)]),
      );
      expect(find.textContaining('kept', findRichText: true), findsOneWidget);
      expect(marks(), findsOneWidget);
      expect(storedOf(c, 'a')['owner'], ownerId);
    });
  });

  group('failures and waiting', () {
    Future<void> toDetails(WidgetTester t, String key) async {
      await t.tap(k('ai-box-connect'));
      await t.pumpAndSettle();
      await t.tap(k(key));
      await t.pumpAndSettle();
    }

    testWidgets('a code being issued cannot be dismissed or backed out of', (t) async {
      access.gate = Completer<void>();
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await toDetails(t, 'ai-role-writer');
      await typeLabel(t, 'Chat');
      await t.tap(k('ai-connect-create'));
      await t.pump();
      expect(t.widget<TextButton>(k('ai-connect-back')).onPressed, isNull);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(k('ai-label'), findsOneWidget);
      await t.tapAt(const Offset(4, 4));
      await t.pump();
      expect(k('ai-label'), findsOneWidget);
      access.gate!.complete();
      await t.pumpAndSettle();
      expect(k('ai-code'), findsOneWidget);
    });

    testWidgets('a problem with the store is shown and Create is off', (t) async {
      access.problem = 'ai-access.json could not be read.';
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await toDetails(t, 'ai-role-reader');
      await typeLabel(t, 'Chat');
      expect(find.text('ai-access.json could not be read.'), findsWidgets);
      expect(t.widget<FilledButton>(k('ai-connect-create')).onPressed, isNull);
    });

    testWidgets('an error that is not a StateError shows a generic message', (t) async {
      access.connectError = const FileSystemException('denied', r'C:\secret\ai-access.json');
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await toDetails(t, 'ai-role-reader');
      await typeLabel(t, 'Chat');
      await t.tap(k('ai-connect-create'));
      await t.pumpAndSettle();
      expect(find.text('Could not create the code.'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
    });

    for (final error in <Object>[
      StateError('Could not write ai-access.json.'),
      const FileSystemException('denied', r'C:\secret\ai-access.json'),
    ]) {
      testWidgets('a failed change shows in the panel (${error.runtimeType})', (t) async {
        access.codes.add(
          codeOf(
            'a000000000000001',
            'a',
            sessions: [AiCodeSession(id: 's1', app: 'App')],
          ),
        );
        await pump(t, pageOf([aiRecord('a', [para('x')])]));
        await t.tap(k('ai-box-connections'));
        await t.pumpAndSettle();
        access.changeError = error;
        final expected = error is StateError ? error.message : 'Could not save the change.';

        await t.tap(k('ai-session-revoke-s1'));
        await t.pumpAndSettle();
        expect(find.text(expected), findsOneWidget);
        expect(find.textContaining('secret'), findsNothing);

        await t.tap(k('ai-ask-switch'));
        await t.pumpAndSettle();
        expect(access.ask['a'], isNull);
        expect(find.text(expected), findsOneWidget);

        await t.tap(k('ai-revoke-a000000000000001'));
        await t.pumpAndSettle();
        await t.tap(k('ai-revoke-confirm'));
        await t.pumpAndSettle();
        expect(find.text(expected), findsOneWidget);
        expect(access.revoked, isEmpty);
        expect(find.text('Feedback \u2013 work chat'), findsOneWidget);
      });
    }
  });

  group('the connections panel', () {
    Future<void> open(WidgetTester t) async {
      await t.tap(k('ai-box-connections'));
      await t.pumpAndSettle();
    }

    testWidgets('lists each code with its facts and sessions', (t) async {
      access.codes.add(
        codeOf(
          'a000000000000001',
          'a',
          lastUsed: DateTime.utc(2026, 11, 2, 12, 5),
          sessions: [
            AiCodeSession(
              id: 's1',
              app: 'Claude Code',
              approved: DateTime.utc(2026, 11, 1, 10),
            ),
          ],
        ),
      );
      access.codes.add(
        codeOf(
          'a000000000000002',
          'a',
          role: 'reader',
          label: 'Reading group',
          expires: DateTime.utc(2000),
        ),
      );
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await open(t);
      expect(find.text('Feedback – work chat'), findsOneWidget);
      expect(find.text('Reading group'), findsOneWidget);
      final facts = t.widget<Text>(k('ai-facts-a000000000000001')).data!;
      expect(facts, contains('Writer'));
      expect(facts, contains('Created'));
      expect(facts, contains('Last used'));
      final readerFacts = t.widget<Text>(k('ai-facts-a000000000000002')).data!;
      expect(readerFacts, contains('Reader'));
      expect(readerFacts, contains('Never used'));
      expect(k('ai-expired-a000000000000002'), findsOneWidget);
      expect(k('ai-expired-a000000000000001'), findsNothing);
      expect(find.textContaining('Claude Code'), findsOneWidget);
      expect(k('ai-session-s1'), findsOneWidget);
    });

    testWidgets('icons are muted, not text colour', (t) async {
      access.codes.add(
        codeOf(
          'a000000000000001',
          'a',
          sessions: [AiCodeSession(id: 's1', app: 'App')],
        ),
      );
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await open(t);
      final muted = notedThemeData(Brightness.light).colorScheme.onSurfaceVariant;
      for (final key in ['ai-revoke-a000000000000001', 'ai-session-revoke-s1']) {
        final icon = t.widget<Icon>(
          find.descendant(of: k(key), matching: find.byType(Icon)),
        );
        expect(icon.color, muted);
      }
    });

    testWidgets('revoking a code asks first, then calls through', (t) async {
      access.codes.add(codeOf('a000000000000001', 'a'));
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await open(t);
      await t.tap(k('ai-revoke-a000000000000001'));
      await t.pumpAndSettle();
      expect(find.textContaining('Revoke Feedback'), findsOneWidget);
      // Cancel changes nothing.
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(access.revoked, isEmpty);
      await t.tap(k('ai-revoke-a000000000000001'));
      await t.pumpAndSettle();
      await t.tap(k('ai-revoke-confirm'));
      await t.pumpAndSettle();
      expect(access.revoked, ['a000000000000001']);
      // The list refreshed from the access notification.
      expect(k('ai-no-codes'), findsOneWidget);
    });

    testWidgets('revoking a session calls through', (t) async {
      access.codes.add(
        codeOf(
          'a000000000000001',
          'a',
          sessions: [AiCodeSession(id: 's1', app: 'Claude Code')],
        ),
      );
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await open(t);
      await t.tap(k('ai-session-revoke-s1'));
      await t.pumpAndSettle();
      expect(access.sessionsRevoked, [('a000000000000001', 's1')]);
    });

    testWidgets('Ask before each write toggles through', (t) async {
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await open(t);
      expect(t.widget<SwitchListTile>(k('ai-ask-switch')).value, isFalse);
      await t.tap(k('ai-ask-switch'));
      await t.pumpAndSettle();
      expect(access.ask['a'], isTrue);
      expect(t.widget<SwitchListTile>(k('ai-ask-switch')).value, isTrue);
      await t.tap(k('ai-ask-switch'));
      await t.pumpAndSettle();
      expect(access.ask['a'], isFalse);
    });

    testWidgets('activity is listed newest first', (t) async {
      AiActivityEntry entry(int minute, String op, String result) => AiActivityEntry(
        time: DateTime.utc(2026, 11, 1, 12, minute),
        code: 'a000000000000001',
        target: const AiCodeTarget.box('a'),
        op: op,
        app: 'Claude Code',
        label: 'Feedback – work chat',
        result: result,
      );
      access.log.addAll([
        entry(1, 'read_box', 'ok'),
        entry(2, 'write_box', 'not_approved'),
      ]);
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await open(t);
      final first = t.getTopLeft(k('ai-activity-0')).dy;
      final second = t.getTopLeft(k('ai-activity-1')).dy;
      expect(first, lessThan(second));
      expect(
        find.descendant(of: k('ai-activity-0'), matching: find.text('Not approved')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: k('ai-activity-0'), matching: find.textContaining('Write box')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: k('ai-activity-1'), matching: find.text('OK')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: k('ai-activity-1'), matching: find.textContaining('Claude Code')),
        findsOneWidget,
      );
    });

    testWidgets('no activity says so', (t) async {
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await open(t);
      expect(k('ai-no-activity'), findsOneWidget);
    });

    testWidgets('shows the problem when the store cannot be read', (t) async {
      access.problem = 'ai-access.json could not be read.';
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      expect(find.text('Connections unavailable'), findsOneWidget);
      await open(t);
      expect(find.text('ai-access.json could not be read.'), findsOneWidget);
    });

    testWidgets('refreshes when the access changes', (t) async {
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await open(t);
      expect(k('ai-no-codes'), findsOneWidget);
      access.codes.add(codeOf('a000000000000001', 'a', label: 'Fresh chat'));
      access.change();
      await t.pump();
      expect(find.text('Fresh chat'), findsOneWidget);
    });
  });

  group('editing', () {
    EditorState editorOf(WidgetTester t) =>
        t.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;

    Future<EditorState> edit(WidgetTester t, {int path = 0, int? offset}) async {
      await t.tap(find.textContaining('ai one', findRichText: true));
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      final editor = editorOf(t);
      final node = editor.getNodeAtPath([path])!;
      editor.selection = Selection.collapsed(
        Position(path: [path], offset: offset ?? node.delta!.length),
      );
      await t.pump();
      return editor;
    }

    testWidgets('typing in an AI block ends its mark and strips the tag', (
      t,
    ) async {
      final (c, _) = await pump(
        t,
        pageOf([
          aiRecord('a', [
            markAiWritten(para('ai one')),
            markAiWritten(para('ai two')),
          ], owner: ownerId),
        ]),
      );
      expect(marks(), findsNWidgets(2));
      final editor = await edit(t, path: 0);
      await editor.insertTextAtCurrentSelection('!');
      await t.pump(const Duration(milliseconds: 50));
      await t.pump(const Duration(milliseconds: 50));

      final blocks = storedBlocks(c, 'a');
      expect(isAiWritten(blocks[0]), isFalse);
      expect((blocks[0]['data']! as Map).containsKey('noted_ai'), isFalse);
      expect(isAiWritten(blocks[1]), isTrue);
      expect(marks(), findsOneWidget);
      // The owner survives editing.
      expect(storedOf(c, 'a')['owner'], ownerId);
    });

    testWidgets('a real commit keeps a legacy owner and the other blocks', (t) async {
      final (c, _) = await pump(
        t,
        pageOf([
          aiRecord('a', [markAiWritten(para('ai one')), para('mine')], owner: ownerId),
        ]),
      );
      final editor = await edit(t, path: 0);
      await editor.insertTextAtCurrentSelection('!');
      await t.pump(const Duration(milliseconds: 50));
      await t.pump(const Duration(milliseconds: 50));
      expect(aiBlockText(storedBlocks(c, 'a').first), 'ai one!');
      expect(aiBlockText(storedBlocks(c, 'a').last), 'mine');
      final stored = storedOf(c, 'a');
      expect(stored['owner'], ownerId);
      expect(stored.keys.toSet(), {'document', 'owner'});
    });

    testWidgets('the bar stops at the block\'s own row, not across nested children', (t) async {
      await pump(
        t,
        pageOf([
          aiRecord('a', [
            markAiWritten({
              'type': 'bulleted_list',
              'data': {
                'delta': [
                  {'insert': 'ai one'},
                ],
              },
              'children': [
                {
                  'type': 'bulleted_list',
                  'data': {
                    'delta': [
                      {'insert': 'nested by the user'},
                    ],
                  },
                },
              ],
            }),
          ]),
        ]),
      );
      await edit(t);
      await t.pump(const Duration(milliseconds: 100));
      final bar = t.getRect(marks());
      final nested = t.getRect(find.textContaining('nested by the user', findRichText: true));
      expect(bar.bottom, lessThanOrEqualTo(nested.top + 1));
      expect(bar.height, greaterThan(10));
    });

    testWidgets('a block the user adds never carries a valid mark', (t) async {
      final (c, _) = await pump(
        t,
        pageOf([aiRecord('a', [markAiWritten(para('ai one'))], owner: ownerId)]),
      );
      final editor = await edit(t);
      await editor.insertNewLine();
      await editor.insertTextAtCurrentSelection('mine');
      await t.pump(const Duration(milliseconds: 50));
      await t.pump(const Duration(milliseconds: 50));

      final blocks = storedBlocks(c, 'a');
      expect(blocks, hasLength(2));
      expect(isAiWritten(blocks[0]), isTrue);
      expect(isAiWritten(blocks[1]), isFalse);
      expect((blocks[1]['data']! as Map).containsKey('noted_ai'), isFalse);
      expect(marks(), findsOneWidget);
    });

    testWidgets('turning an AI paragraph into a heading ends the mark', (
      t,
    ) async {
      final (c, _) = await pump(
        t,
        pageOf([aiRecord('a', [markAiWritten(para('ai one'))])]),
      );
      final editor = await edit(t);
      final node = editor.getNodeAtPath([0])!;
      await editor.apply(
        editor.transaction
          ..updateNode(node, {'level': 1})
          ..insertNode(
            [1],
            Node(type: 'heading', attributes: {...node.attributes, 'level': 1}),
          )
          ..deleteNode(node),
      );
      await t.pump(const Duration(milliseconds: 50));
      await t.pump(const Duration(milliseconds: 50));
      final blocks = storedBlocks(c, 'a');
      expect(blocks.single['type'], 'heading');
      expect(isAiWritten(blocks.single), isFalse);
      expect((blocks.single['data']! as Map).containsKey('noted_ai'), isFalse);
    });

    testWidgets('a rebuild between two edits keeps the same editor', (t) async {
      final (c, _) = await pump(
        t,
        pageOf([aiRecord('a', [para('ai one')], owner: ownerId)]),
      );
      final first = await edit(t);
      await first.insertTextAtCurrentSelection('1');
      await t.pump(const Duration(milliseconds: 100));

      // A change of the access state rebuilds the header, not the editor.
      access.change();
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(milliseconds: 500));

      final second = editorOf(t);
      expect(identical(second, first), isTrue);
      second.selection = Selection.collapsed(
        Position(path: [0], offset: second.getNodeAtPath([0])!.delta!.length),
      );
      await t.pump();
      await second.insertTextAtCurrentSelection('2');
      await t.pump(const Duration(milliseconds: 100));
      expect(identical(editorOf(t), first), isTrue);
      expect(aiBlockText(storedBlocks(c, 'a').single), 'ai one12');
    });

    testWidgets('an AI write of content the editor had restarts it', (t) async {
      const codec = AiCodec();
      AiBoxData write(CanvasController c) => codec.aiWrite(
        codec.decode((c.page.node('a')! as BoxRecord).data!.decode(), 1),
        AiWrite(connectionId: ownerId, content: 'A', mode: AiWriteMode.replace),
      )!;
      final (c, _) = await pump(t, pageOf([aiRecord('a', [para('')], owner: ownerId)]));
      c.replaceBoxData({'a': write(c)});
      await t.pumpAndSettle();

      // The user types "!" after the AI's "A": the box stores "A!".
      await t.tap(find.text('A', findRichText: true).last);
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      var editor = editorOf(t);
      editor.selection = Selection.collapsed(Position(path: [0], offset: 1));
      await t.pump();
      await editor.insertTextAtCurrentSelection('!');
      await t.pump(const Duration(milliseconds: 100));
      expect(aiBlockText(storedBlocks(c, 'a').single), 'A!');

      // The AI writes "A" again; the editor starts over from it.
      c.replaceBoxData({'a': write(c)});
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(aiBlockText(storedBlocks(c, 'a').single), 'A');
      if (find.byType(AppFlowyEditor).evaluate().isEmpty) {
        await t.tap(find.text('A', findRichText: true).last);
        for (var i = 0; i < 5; i++) {
          await t.pump(const Duration(milliseconds: 50));
        }
      }
      editor = editorOf(t);
      editor.selection = Selection.collapsed(Position(path: [0], offset: 1));
      await t.pump();
      await editor.insertTextAtCurrentSelection('x');
      await t.pump(const Duration(milliseconds: 100));
      // Based on the AI's write, not on the "A!" the editor had.
      expect(aiBlockText(storedBlocks(c, 'a').single), 'Ax');
    });

    testWidgets('a box being edited stays edited through an AI write, so Escape still leaves it', (t) async {
      const codec = AiCodec();
      final (c, _) = await pump(t, pageOf([aiRecord('a', [para('B')], owner: ownerId)]));
      await t.tap(find.text('B', findRichText: true).last);
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(c.editingId, 'a');

      c.replaceBoxData({
        'a': codec.aiWrite(
          codec.decode((c.page.node('a')! as BoxRecord).data!.decode(), 1),
          AiWrite(connectionId: ownerId, content: 'A', mode: AiWriteMode.replace),
        )!,
      });
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(c.editingId, 'a');
      expect(find.byType(AppFlowyEditor), findsOneWidget);
      final focus = FocusManager.instance.primaryFocus;
      expect(
        focus?.context != null &&
            find.descendant(of: find.byType(AppFlowyEditor), matching: find.byWidget(focus!.context!.widget)).evaluate().isNotEmpty,
        isTrue,
        reason: 'the new editor has the focus',
      );

      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(c.editingId, isNull);
    });

    testWidgets('an AI write into a box not being edited takes no focus', (t) async {
      const codec = AiCodec();
      final (c, _) = await pump(t, pageOf([aiRecord('a', [para('B')], owner: ownerId)]));
      expect(c.editingId, isNull);
      final before = FocusManager.instance.primaryFocus;
      c.replaceBoxData({
        'a': codec.aiWrite(
          codec.decode((c.page.node('a')! as BoxRecord).data!.decode(), 1),
          AiWrite(connectionId: ownerId, content: 'A', mode: AiWriteMode.replace),
        )!,
      });
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(c.editingId, isNull);
      expect(FocusManager.instance.primaryFocus, before);
      expect(find.byType(AppFlowyEditor), findsNothing, reason: 'still the light view');
    });

    testWidgets('an AI write shows in the open box at once', (t) async {
      final (c, _) = await pump(t, pageOf([aiRecord('a', [para('')], owner: ownerId)]));
      expect(marks(), findsNothing);
      const codec = AiCodec();
      final box = c.page.node('a')! as BoxRecord;
      final data = codec.decode(box.data!.decode(), 1);
      final next = codec.aiWrite(
        data,
        AiWrite(connectionId: ownerId, content: 'from the AI', mode: AiWriteMode.replace),
      )!;
      c.editBox('a', next);
      await t.pumpAndSettle();
      expect(find.textContaining('from the AI', findRichText: true), findsOneWidget);
      expect(marks(), findsOneWidget);
    });
  });

  group('insert command', () {
    testWidgets('inserts an AI box and selects it', (t) async {
      final (c, key) = await pump(t, pageOf([]));
      final cmd = key.currentState!.commands[AiCommands.insert]!;
      expect(cmd.label, 'AI box');
      expect(cmd.icon, Icons.auto_awesome_rounded);
      expect(cmd.enabled, isTrue);
      await cmd.run();
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(c.page.nodes, hasLength(1));
      final box = c.page.nodes.single as BoxRecord;
      expect(box.typeId, aiBoxTypeId);
      expect(c.selectedId, box.id);
      expect(find.byKey(const ValueKey('ai-box-label')), findsOneWidget);
      expect(storedOf(c, box.id).containsKey('owner'), isFalse);
    });

    testWidgets('with no view, and a page whose only node has no bounds, '
        'the box goes at the margin', (t) async {
      final foreign = ForeignNode.read(
        RawJson.trusted('{"id":"f"}'),
        fallbackId: 'f',
      );
      expect(foreign.bounds, isNull);
      final c = CanvasController(pageOf([]).insertNode(foreign), modules);
      insertAiBox(c, null);
      final added = c.page.nodes.whereType<BoxRecord>().single;
      expect(added.bounds.x, 40);
      expect(added.bounds.y, 40);
      expect(added.typeId, aiBoxTypeId);
    });

    testWidgets('is centred on the view, selected and focused', (t) async {
      final (c, key) = await pump(t, pageOf([aiRecord('a', [para('x')])]));
      final centre = key.currentState!.viewCentre!;
      await key.currentState!.commands[AiCommands.insert]!.run();
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      final added = c.page.nodes.firstWhere((n) => n.id != 'a');
      final b = added.bounds!;
      expect(b.x + b.width / 2, closeTo(centre.dx, 1));
      expect(b.y + b.height / 2, closeTo(centre.dy, 25));
      expect(c.selectedId, added.id);
      expect(c.editingId, added.id);
    });

    testWidgets('a chat can be connected right after inserting', (t) async {
      final (c, key) = await pump(t, pageOf([]));
      await key.currentState!.commands[AiCommands.insert]!.run();
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.tap(k('ai-box-connect'));
      await t.pumpAndSettle();
      await t.tap(k('ai-role-writer'));
      await t.pumpAndSettle();
      await typeLabel(t, 'Chat');
      await t.tap(k('ai-connect-create'));
      await t.pumpAndSettle();
      expect(access.connects.single.box, c.page.nodes.single.id);
      expect(k('ai-code'), findsOneWidget);
    });

    for (final layout in [tabbedToolbarLayout, contextualToolbarLayout]) {
      testWidgets('replaces the placeholder in the ${layout.runtimeType}', (
        t,
      ) async {
        await pump(t, pageOf([]), layout: layout);
        t.view.physicalSize = const Size(2400, 800);
        await t.pumpAndSettle();
        if (layout is TabbedToolbarLayout) {
          await t.tap(find.byKey(CommandToolbar.tabKey('insert')));
          await t.pump();
        }
        expect(find.byKey(const ValueKey(AiCommands.insert)), findsOneWidget);
        expect(find.byTooltip('AI box (coming later)'), findsNothing);
        expect(find.text('AI box'), findsOneWidget);
      });
    }

    testWidgets('without the module the placeholder stays', (t) async {
      modules = ModuleRegistry()
        ..register(const NoteModule(), alwaysOn: true, isDefault: true);
      final (_, key) = await pump(t, pageOf([]));
      expect(
        key.currentState!.commands[AiCommands.insert]!.label,
        'AI box (coming later)',
      );
    });
  });
}
