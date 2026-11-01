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

/// Sends one request over the app's real loopback link, the way the MCP
/// server does (the greeting's nonce is checked against ai-link.json before
/// the code is sent).
Future<AiLinkResponse> _linkRequest(Directory dataDir, AiLinkRequest request) async {
  final link = readAiLink(await File('${dataDir.path}${Platform.pathSeparator}$aiLinkFileName').readAsString())!;
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, link.port);
  try {
    final lines = socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());
    final it = StreamIterator(lines);
    // Plain checks, not expect(): this future is not awaited inside the test
    // body, where expect() would break the live binding.
    if (!await it.moveNext() || readAiLinkGreeting(it.current) != link.nonce) {
      throw StateError('the link did not greet with the nonce of ai-link.json');
    }
    socket.write('${request.encode()}\n');
    await socket.flush();
    if (!await it.moveNext()) throw StateError('the link did not answer');
    final r = AiLinkResponse.decode(it.current)!;
    await it.cancel();
    return r;
  } finally {
    socket.destroy();
  }
}

/// A request in flight while the app keeps pumping, so the test can answer
/// the app's question meanwhile.
class _Sent {
  _Sent(this.s, AiLinkRequest request) {
    Future<void>(() async {
      try {
        _response = await _linkRequest(s.env.appDir, request);
      } on Object catch (e, st) {
        _error = e;
        _stack = st;
      } finally {
        done = true;
      }
    });
  }

  final Session s;
  bool done = false;
  AiLinkResponse? _response;
  Object? _error;
  StackTrace? _stack;

  /// Pumps until the answer is in; rethrows the link's error at once.
  Future<AiLinkResponse> answer() async {
    await s.until(() => done, what: 'the link answer');
    if (_error != null) Error.throwWithStackTrace(_error!, _stack!);
    return _response!;
  }
}

AiLinkWriteBox _write(String code, String box, String content, {String session = 'it-session', AiLinkMode mode = AiLinkMode.replace}) =>
    AiLinkWriteBox(code: code, session: session, app: 'Integration test', box: box, mode: mode, content: content);

/// The text the open note editor shows (dynamic: the app does not depend on
/// appflowy_editor).
String _editorText(WidgetTester t) => [
  for (final n in editorState(t).document.root.children as Iterable)
    ((n as dynamic).delta?.toPlainText() ?? '') as String,
].join('\n');

/// AI: the AI box, its codes, the approval questions, and writes through the
/// real link.
void aiSuite() {
  group('ai', () {
    testWidgets('AI1-AI6: insert an AI box, issue a code, approve a session, write through the link, undo, ask before a write, revoke', (t) async {
      await withSession(t, 'ai', (s) async {
        final link = await startAiLink(s.nb, s.env.appDir);
        expect(link, isNotNull, reason: 'the app link starts');
        expect(s.env.contains(link!.file.path), isTrue, reason: 'ai-link.json is in the sandbox');
        try {
          final pageId = s.nb.currentId!;

          // AI1: Insert -> AI box appears with its editor open; type a line.
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

          // AI2: a Writer code for the box (what "Connect a chat" does).
          final code = await s.aiAccess.connect(box.id, role: AiCodeRole.writer, label: 'Feedback chat');
          expect(parseAiToken(code), isNotNull);
          final codeId = parseAiToken(code)!.id;
          expect(s.aiAccess.connections(box.id).single.label, 'Feedback chat');
          expect(s.aiAccess.connections(box.id).single.target.page, pageId, reason: 'the page is noted');

          // AI3: the page is Guarded (the default), which does not matter to
          // its AI box; the page menu offers the three values.
          expect(s.nb.aiAccessFor(pageId).value, AiAccess.guarded);
          await s.tapKey('page-settings');
          await s.tapKey('settings-ai-privileged');
          expect(s.nb.ownAiAccess(pageId), AiAccess.privileged);
          await s.tapKey('settings-ai-guarded');
          expect(s.nb.ownAiAccess(pageId), AiAccess.guarded);
          await s.tapKey('settings-close');
          await s.flush();

          // AI4: the first write of a new session asks; Allow; the write shows
          // at once, marked, and is one undo step.
          final dataBeforeWrite = jsonEncode(codec.encode(data()));
          final first = _Sent(s, _write(code, box.id, 'Written by the AI'));
          await s.until(() => find.byKey(const ValueKey('ai-approval-dialog')).evaluate().isNotEmpty, what: 'the approval question');
          expect(
            (t.widget(find.byKey(const ValueKey('ai-approval-message'))) as Text).data,
            'Integration test wants to read and write Feedback chat. Allow?',
          );
          await s.tapKey('ai-approval-allow', settle: 600);
          final response = await first.answer();
          expect(response.ok, isTrue, reason: response is AiLinkError ? response.message : null);
          expect(snapshotOf(s, box.id), contains('Written by the AI'));
          expect(blocks().where(isAiWritten), isNotEmpty, reason: 'the AI text is marked');
          expect(_editorText(t), contains('Written by the AI'), reason: 'the open editor shows it at once');
          expect(s.aiAccess.connections(box.id).single.sessions.single.app, 'Integration test');
          await s.key(LogicalKeyboardKey.escape);
          expect(s.nb.current!.editingId, isNull);
          await s.pump(500);
          expect(snapshotOf(s, box.id), contains('Written by the AI'), reason: 'leaving the box does not commit over the write');
          await s.ctrl(LogicalKeyboardKey.keyZ);
          expect(snapshotOf(s, box.id), isNot(contains('Written by the AI')));
          expect(snapshotOf(s, box.id), contains('My own line'), reason: 'one step only');
          expect(jsonEncode(codec.encode(data())), dataBeforeWrite, reason: 'the data is as before the write');
          await s.ctrl(LogicalKeyboardKey.keyZ, shift: true);
          expect(snapshotOf(s, box.id), contains('Written by the AI'));

          // The same session is not asked again.
          final second = _Sent(s, _write(code, box.id, ' More.', mode: AiLinkMode.append));
          expect((await second.answer()).ok, isTrue);
          expect(find.byKey(const ValueKey('ai-approval-dialog')), findsNothing);
          expect(snapshotOf(s, box.id), contains('More.'));

          // AI5: ask before each write: the question shows what would be
          // written; Deny leaves the box as it was.
          await s.aiAccess.setAskBeforeWrite(box.id, true);
          final before = snapshotOf(s, box.id);
          final asked = _Sent(s, _write(code, box.id, 'Please do not'));
          await s.until(() => find.byKey(const ValueKey('ai-approval-dialog')).evaluate().isNotEmpty, what: 'the per-write question');
          expect((t.widget(find.byKey(const ValueKey('ai-approval-preview'))) as Text).data, contains('Please do not'));
          await s.tapKey('ai-approval-deny', settle: 600);
          final denied = await asked.answer();
          expect(denied, isA<AiLinkError>());
          expect((denied as AiLinkError).code, AiLinkCode.notApproved);
          expect(snapshotOf(s, box.id), before);
          await s.aiAccess.setAskBeforeWrite(box.id, false);

          // AI6: revoke; a further write is rejected and the box is unchanged.
          await s.aiAccess.revoke(codeId);
          final beforeData = jsonEncode(codec.encode(data()));
          final refused = await _Sent(s, _write(code, box.id, 'After revoke')).answer();
          expect(refused.ok, isFalse);
          expect((refused as AiLinkError).code, AiLinkCode.badCode);
          expect(jsonEncode(codec.encode(data())), beforeData, reason: 'the box keeps its content');
          expect(s.aiAccess.activity(box.id).where((e) => e.op == 'write_box'), isNotEmpty, reason: 'the activity is logged');
        } finally {
          await link.dispose();
        }
      });
    });
  });
}