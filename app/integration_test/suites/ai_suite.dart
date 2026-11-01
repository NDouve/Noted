// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart' show startAiLink;
import 'package:noted_box_ai/noted_box_ai.dart';
import 'package:noted_core/noted_core.dart';

import '../support/harness.dart';
import '../support/note_helpers.dart';

/// Sends one write_box request over the app's real loopback link, the way
/// the MCP server does (the greeting's nonce is checked against ai-link.json
/// before the token is sent).
Future<AiLinkResponse> _linkWrite(
  Directory dataDir,
  String token,
  String box,
  String content, {
  AiLinkMode mode = AiLinkMode.replace,
}) async {
  final link = readAiLink(await File('${dataDir.path}${Platform.pathSeparator}$aiLinkFileName').readAsString())!;
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, link.port);
  try {
    final lines = socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());
    final it = StreamIterator(lines);
    // Plain checks, not expect(): this future is not awaited inside the test
    // body, where expect() would break the live binding. [_send] rethrows.
    if (!await it.moveNext() || readAiLinkGreeting(it.current) != link.nonce) {
      throw StateError('the link did not greet with the nonce of ai-link.json');
    }
    socket.write('${AiLinkRequest(token: token, box: box, mode: mode, content: content).encode()}\n');
    await socket.flush();
    if (!await it.moveNext()) throw StateError('the link did not answer');
    final r = AiLinkResponse.decode(it.current)!;
    await it.cancel();
    return r;
  } finally {
    socket.destroy();
  }
}

/// Runs [_linkWrite] while the app keeps pumping, and rethrows its error at
/// once instead of leaving the test to time out.
Future<AiLinkResponse> _send(Session s, String token, String box, String content) async {
  var done = false;
  AiLinkResponse? response;
  Object? error;
  StackTrace? stack;
  Future<void>(() async {
    try {
      response = await _linkWrite(s.env.appDir, token, box, content);
    } on Object catch (e, st) {
      error = e;
      stack = st;
    } finally {
      done = true;
    }
  });
  await s.until(() => done, what: 'the link answer');
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return response!;
}

/// The text the open note editor shows (dynamic: the app does not depend on
/// appflowy_editor).
String _editorText(WidgetTester t) => [
  for (final n in editorState(t).document.root.children as Iterable)
    ((n as dynamic).delta?.toPlainText() ?? '') as String,
].join('\n');

/// AI phase 2: AI connections, the AI box, and a write through the real link.
void aiSuite() {
  group('ai', () {
    testWidgets('AI1-AI5: add a connection, insert an AI box, pick the AI, write through the link, undo, revoke', (t) async {
      await withSession(t, 'ai', (s) async {
        final link = await startAiLink(s.nb, s.env.appDir);
        expect(link, isNotNull, reason: 'the app link starts');
        expect(s.env.contains(link!.file.path), isTrue, reason: 'ai-link.json is in the sandbox');
        try {
          final pageId = s.nb.currentId!;

          // AI1: gear menu -> AI connections -> add "Claude Code".
          await s.tapKey('settings-menu', settle: 500);
          await s.tapKey('settings-ai-connections', settle: 600);
          expect(find.text('AI connections'), findsOneWidget);
          expect(find.textContaining('No AI connections yet'), findsOneWidget);
          await s.tapKey('ai-add');
          await t.enterText(find.byKey(const ValueKey('ai-name')), 'Claude Code');
          await s.tapKey('ai-create', settle: 600);
          final token = (t.widget(find.byKey(const ValueKey('ai-token'))) as SelectableText).data!;
          expect(parseAiToken(token), isNotNull, reason: 'the token shown is a real token');
          expect(find.byKey(const ValueKey('ai-copy')), findsOneWidget, reason: 'copy is offered');
          expect(find.textContaining("won't show it again"), findsOneWidget);
          await s.tapKey('ai-token-done');
          expect(find.byKey(const ValueKey('ai-token')), findsNothing, reason: 'the token is gone after Done');
          expect(find.text('Claude Code'), findsOneWidget, reason: 'the connection is listed');
          final connId = s.settings.aiConnections.value.single.id;
          expect(s.settings.aiConnections.value.single.name, 'Claude Code');
          await t.tap(find.text('Close'));
          await s.pump(400);

          // AI2: Insert -> AI box appears with its editor open; type a line.
          await t.tap(await toolbarButton(t, 'noted.ai.insert'));
          await s.pump(600);
          final box = s.nb.current!.page.nodes.whereType<BoxRecord>().singleWhere((b) => b.typeId == aiBoxTypeId);
          expect(s.nb.current!.editingId, box.id, reason: 'the new box is open for editing');
          expect(find.byKey(const ValueKey('ai-box-label')), findsOneWidget);
          final editor = editorState(t);
          await insertTextAt(editor, editor.document.root.children.first, 0, 'My own line');
          await s.pump(500);
          expect(snapshotOf(s, box.id), contains('My own line'));
          const codec = AiCodec();
          AiBoxData data() => codec.decode((s.nb.current!.page.node(box.id)! as BoxRecord).data!.decode(), 1);
          List<Map<Object?, Object?>> blocks() =>
              ((data().json['document']! as Map)['children']! as List).cast<Map<Object?, Object?>>();
          expect(blocks().where(isAiWritten), isEmpty, reason: 'user text carries no AI marker');

          // AI3: pick "Claude Code" in the Connected AI menu.
          await s.tapKey('ai-box-picker', settle: 500);
          expect(find.text('Connected AI'), findsWidgets);
          await s.tapKey('ai-owner-$connId', settle: 500);
          expect(data().owner, connId);

          // AI4: page AI setting Box only, then a write over the real link.
          await s.pageMenu(pageId, 'Box only');
          expect(s.nb.ownAiSetting(pageId), AiSetting.boxOnly);
          await s.flush();
          final dataBeforeWrite = jsonEncode(codec.encode(data()));
          final response = await _send(s, token, box.id, 'Written by the AI');
          expect(response.ok, isTrue, reason: response.message ?? response.code?.name);
          expect(snapshotOf(s, box.id), contains('Written by the AI'));
          expect(blocks().where(isAiWritten), isNotEmpty, reason: 'the AI text is marked');
          expect(_editorText(t), contains('Written by the AI'), reason: 'the open editor shows it at once');
          expect(find.byKey(const ValueKey('ai-box-label')), findsOneWidget);
          // The box is still being edited: Escape leaves it, as in a note.
          expect(s.nb.current!.editingId, box.id);
          // (Ctrl+Z while the box is open goes to the note editor, as in a note.)
          await s.key(LogicalKeyboardKey.escape);
          expect(s.nb.current!.editingId, isNull);
          await s.pump(500);
          expect(snapshotOf(s, box.id), contains('Written by the AI'), reason: 'leaving the box does not commit over the write');
          // One Ctrl+Z removes the write, Ctrl+Shift+Z brings it back, and the
          // toolbar's Undo removes it again.
          await s.ctrl(LogicalKeyboardKey.keyZ);
          expect(snapshotOf(s, box.id), isNot(contains('Written by the AI')));
          expect(snapshotOf(s, box.id), contains('My own line'), reason: 'one step only');
          expect(jsonEncode(codec.encode(data())), dataBeforeWrite, reason: 'the data is as before the write');
          expect(data().owner, connId);
          await s.ctrl(LogicalKeyboardKey.keyZ, shift: true);
          expect(snapshotOf(s, box.id), contains('Written by the AI'));
          await t.tap(await toolbarButton(t, 'canvas.undo'));
          await s.pump(300);
          expect(snapshotOf(s, box.id), isNot(contains('Written by the AI')));
          expect(jsonEncode(codec.encode(data())), dataBeforeWrite);

          // AI5: revoke; a further write is rejected and the box is unchanged.
          await s.tapKey('settings-menu', settle: 500);
          await s.tapKey('settings-ai-connections', settle: 600);
          await s.tapKey('ai-revoke-$connId', settle: 500);
          await s.tapKey('ai-revoke-confirm', settle: 600);
          expect(s.settings.aiConnections.value, isEmpty);
          await t.tap(find.text('Close'));
          await s.pump(400);
          final before = snapshotOf(s, box.id);
          final beforeData = jsonEncode(codec.encode(data()));
          final refused = await _send(s, token, box.id, 'After revoke');
          expect(refused.ok, isFalse);
          expect(refused.code, AiLinkCode.badToken);
          expect(snapshotOf(s, box.id), before);
          expect(jsonEncode(codec.encode(data())), beforeData, reason: 'the box keeps its content');
        } finally {
          await link.dispose();
        }
      });
    });
  });
}
