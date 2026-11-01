// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core_read.dart';
import 'package:noted_mcp/noted_mcp.dart';

import 'fixture.dart';
import 'running_lock.dart';

const _key = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ'; // 43 characters
const codeW = 'noted_1111111111111111_$_key';
const codeR = 'noted_2222222222222222_$_key';

/// A fake Noted: greets with the nonce in `ai-link.json`, records each
/// request line it receives, and answers with what [answer] returns for the
/// parsed request (null: no answer).
final class FakeNoted {
  FakeNoted._(this.dir, this._server, this.nonce);

  final Directory dir;
  final ServerSocket _server;
  final String nonce;
  final List<String> lines = [];
  FutureOr<String?> Function(AiLinkRequest request) answer = (_) => null;

  /// The requests received, parsed.
  List<AiLinkRequest> get requests => [for (final l in lines) AiLinkRequest.parse(l)!];

  static Future<FakeNoted> start(
    Directory dir, {
    String nonce = 'N0NCE',
    String? greetNonce,
    bool greet = true,
    bool holdLock = true,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeNoted._(dir, server, nonce);
    server.listen((s) {
      if (greet) s.write('${aiLinkGreeting(greetNonce ?? nonce)}\n');
      final buf = StringBuffer();
      utf8.decoder
          .bind(s)
          .listen(
            (chunk) async {
              buf.write(chunk);
              if (!chunk.endsWith('\n')) return;
              final line = buf.toString().trim();
              fake.lines.add(line);
              final request = AiLinkRequest.parse(line);
              final reply = request == null ? null : await fake.answer(request);
              if (reply != null) s.write('$reply\n');
              await s.close();
            },
            onError: (_) {},
            cancelOnError: true,
          );
    });
    File('${dir.path}/$aiLinkFileName').writeAsStringSync(
      jsonEncode({'format': 1, 'port': server.port, 'pid': 1, 'nonce': nonce}),
    );
    if (holdLock) fake._lock = await RunningLock.hold(dir);
    return fake;
  }

  /// Like the running app: a separate process holds the exclusive lock on the
  /// running-lock file.
  RunningLock? _lock;

  Future<void> close() async {
    final l = _lock;
    _lock = null;
    await l?.release();
    await _server.close();
  }
}

void main() {
  late Directory root;
  late Directory data;

  setUpAll(() {
    root = Directory.systemTemp.createTempSync('noted_mcp_ai');
    data = writeFixture(root);
  });
  tearDownAll(() => root.deleteSync(recursive: true));

  NotedToolbox toolbox({String? app = 'Test App 1.2', String session = 'SESSION-1', Duration? responseTimeout}) =>
      NotedToolbox(
        data,
        session: session,
        app: app,
        greetingTimeout: const Duration(milliseconds: 500),
        responseTimeout: responseTimeout ?? const Duration(seconds: 5),
      );

  Future<FakeNoted> fake({String nonce = 'N0NCE', String? greetNonce, bool greet = true}) async {
    final f = await FakeNoted.start(data, nonce: nonce, greetNonce: greetNonce, greet: greet);
    addTearDown(() async {
      await f.close();
      final file = File('${data.path}/$aiLinkFileName');
      if (file.existsSync()) file.deleteSync();
    });
    return f;
  }

  String pagesGrant(Iterable<String> ids) => AiLinkResponse.granted(AiLinkPagesGrant(pages: ids.toList())).encode();
  String boxGrant(String box, String page) => AiLinkResponse.granted(AiLinkBoxGrant(box: box, page: page)).encode();
  String err(AiLinkCode c, [String? message]) => AiLinkResponse.error(c, message).encode();

  const notRunningText = 'This needs Noted running: codes are checked by the app. Open Noted and try again.';

  group('without a code', () {
    test('reads Open pages from saved files with Noted closed, and never contacts the app', () async {
      final out = await toolbox().readPage(Ids.public);
      expect(out.isError, isFalse);
      expect(out.text, contains('Trip plan'));
      final list = await toolbox().listPages();
      final ids = {for (final p in (jsonDecode(list.text)['pages'] as List).cast<Map<String, Object?>>()) p['id']};
      expect(ids, openIds);
      expect((await toolbox().search('zebra')).isError, isFalse);
      expect((await toolbox().readBox('note')).isError, isFalse);
    });

    test('a blank code counts as no code', () async {
      final f = await fake();
      final out = await toolbox().readPage(Ids.public, code: '  ');
      expect(out.isError, isFalse);
      expect(f.lines, isEmpty);
    });

    test('Privileged and Guarded pages answer like missing pages', () async {
      final t = toolbox();
      for (final id in [...privilegedIds, ...guardedIds]) {
        expect((await t.readPage(id)).text, noSuchPage(id));
      }
      expect((await t.readPage('ffffffffffffffff')).text, noSuchPage('ffffffffffffffff'));
    });

    test('an AI box on an Open page reads, with its marker', () async {
      final out = await toolbox().readBox('aiA');
      expect(out.text, contains('okapi from A'));
      expect(out.text, contains('<ai-written>'));
    });
  });

  group('code-based reads', () {
    test('a page grant adds Privileged pages to list, read, read_box and search', () async {
      final f = await fake();
      f.answer = (_) => pagesGrant([Ids.priv, Ids.privBinderPage]);
      final t = toolbox();
      final list = await t.listPages(code: codeR);
      final ids = {for (final p in (jsonDecode(list.text)['pages'] as List).cast<Map<String, Object?>>()) p['id']};
      expect(ids, {...openIds, Ids.priv, Ids.privBinderPage});
      expect((await t.readPage(Ids.priv, code: codeR)).text, contains('giraffe privileged text'));
      expect((await t.readPage(Ids.privChild, code: codeR)).text, noSuchPage(Ids.privChild));
      expect((await t.readPage(Ids.public, code: codeR)).isError, isFalse, reason: 'Open pages stay readable');
      expect((await t.readBox('n8', code: codeR)).text, contains('giraffe'));
      final hits = jsonDecode((await t.search('giraffe', code: codeR)).text)['results'] as List;
      expect(hits.map((r) => (r as Map)['id']), [Ids.priv]);
      // What it asked for.
      final actions = [for (final r in f.requests) (r as AiLinkAccess).action];
      expect(actions, [
        AiLinkAction.listPages,
        AiLinkAction.readPage,
        AiLinkAction.readPage,
        AiLinkAction.readPage,
        AiLinkAction.readBox,
        AiLinkAction.search,
      ]);
      expect((f.requests[1] as AiLinkAccess).target, Ids.priv);
      expect((f.requests[5] as AiLinkAccess).target, 'giraffe');
    });

    test('a grant never opens a Guarded page or a locked binder, even if it names one', () async {
      final f = await fake();
      f.answer = (_) => pagesGrant([...guardedIds, ...privilegedIds]);
      final t = toolbox();
      for (final id in guardedIds) {
        expect((await t.readPage(id, code: codeR)).text, noSuchPage(id), reason: id);
      }
    });

    test('a box grant reads only that box: no title, page id or page list in the output', () async {
      final f = await fake();
      f.answer = (_) => boxGrant('aiG', Ids.aiGuarded);
      final out = await toolbox().readBox('aiG', code: codeR);
      expect(out.isError, isFalse);
      expect(out.text, startsWith('**ai** · box `aiG`'));
      expect(out.text, contains('okapi guarded box'));
      expect(out.text, contains('<ai-written>'));
      expect(out.text, isNot(contains('Guarded AI')), reason: 'the page title');
      expect(out.text, isNot(contains(Ids.aiGuarded)));
      expect(out.text, isNot(contains('okapi private')), reason: 'a sibling box');
      expect(out.text, isNot(contains(secret)));
    });

    test('a page link inside an AI box read by box code is plain text: no noted: address, no page id', () async {
      final r = Directory.systemTemp.createTempSync('noted_mcp_boxlink');
      addTearDown(() => r.deleteSync(recursive: true));
      final d = writeFixture(r);
      final linked = markAiWritten({
        'type': 'paragraph',
        'data': {
          'delta': [
            {'insert': 'see '},
            {
              'insert': 'the plans',
              'attributes': {'href': 'noted:page/${Ids.public}'},
            },
          ],
        },
      });
      final p = page(
        'f000000000000009',
        'Linker',
        ai: 'guarded',
        nodes: [
          box('aiL', aiBoxTypeId, {
            'document': {
              'type': 'page',
              'children': [linked],
            },
          }, const Bounds(0, 0, 100, 40)),
        ],
      );
      File('${d.path}/pages/${p.id}.canvas').writeAsStringSync(writePage(p));
      final f = await FakeNoted.start(d);
      addTearDown(f.close);
      f.answer = (_) => boxGrant('aiL', p.id);
      final out = await NotedToolbox(d, session: 's', responseTimeout: const Duration(seconds: 5)).readBox('aiL', code: codeR);
      expect(out.isError, isFalse);
      expect(out.text, contains('the plans'));
      expect(out.text, isNot(contains('noted:')));
      expect(out.text, isNot(contains(Ids.public)));
      expect(out.text, isNot(contains(p.id)));
    });

    test('a box in a locked binder is reachable by its box code', () async {
      final f = await fake();
      f.answer = (_) => boxGrant('aiV', Ids.aiLocked);
      expect((await toolbox().readBox('aiV', code: codeR)).text, contains('okapi vault box'));
    });

    test('a box grant for another box than the one asked for is a missing box', () async {
      final f = await fake();
      f.answer = (_) => boxGrant('aiG', Ids.aiGuarded);
      final out = await toolbox().readBox('aiA', code: codeR);
      expect(out.isError, isTrue);
      expect(out.text, noSuchBox('aiA'));
    });

    test('a grant for a box that is a note, or missing, is a missing box', () async {
      final f = await fake();
      f.answer = (_) => boxGrant('note2', Ids.aiGuarded);
      expect((await toolbox().readBox('note2', code: codeR)).text, noSuchBox('note2'));
      f.answer = (_) => boxGrant('gone', Ids.aiGuarded);
      expect((await toolbox().readBox('gone', code: codeR)).text, noSuchBox('gone'));
    });

    test('a box code on list_pages, read_page and search is a clear wrong_role message, nothing of the page', () async {
      final f = await fake();
      f.answer = (_) => boxGrant('aiG', Ids.aiGuarded);
      final t = toolbox();
      for (final out in [
        await t.listPages(code: codeR),
        await t.readPage(Ids.public, code: codeR),
        await t.search('okapi', code: codeR),
      ]) {
        expect(out.isError, isTrue);
        expect(out.text, contains('box code'));
        expect(out.text, contains('read_box'));
        expect(out.text, isNot(contains('Guarded AI')));
        expect(out.text, isNot(contains(Ids.aiGuarded)));
      }
    });

    test('a pages grant on read_box with a box id on a granted page reads it', () async {
      final f = await fake();
      f.answer = (_) => pagesGrant([Ids.aiOpen]);
      expect((await toolbox().readBox('aiB', code: codeR)).text, contains('okapi from B'));
    });

    test('the session id and app name are sent on every request', () async {
      final f = await fake();
      f.answer = (_) => pagesGrant([]);
      final t = toolbox(app: 'Test App 1.2', session: 'SESSION-XYZ');
      await t.listPages(code: codeR);
      await t.readPage(Ids.public, code: codeR);
      expect(f.requests, hasLength(2));
      for (final r in f.requests) {
        expect(r.session, 'SESSION-XYZ');
        expect(r.app, 'Test App 1.2');
        expect(r.code, codeR);
      }
    });

    test('without an app name none is sent', () async {
      final f = await fake();
      f.answer = (_) => pagesGrant([]);
      await toolbox(app: null).listPages(code: codeR);
      expect(f.requests.single.app, isNull);
    });
  });

  group('errors', () {
    // Every code the app can answer, mapped to a clear tool error.
    final cases = <AiLinkCode, String>{
      AiLinkCode.badCode: 'not valid',
      AiLinkCode.expired: 'expired',
      AiLinkCode.notApproved: "The user hasn't allowed this connection in Noted.",
      AiLinkCode.wrongRole: 'does not allow that',
      AiLinkCode.noBox: 'No such box',
      AiLinkCode.conflict: 'sync conflict',
      AiLinkCode.locked: 'cannot be edited',
      AiLinkCode.notWritable: 'does not take writes',
      AiLinkCode.notPermitted: "Writer permission doesn't allow that",
      AiLinkCode.saveFailed: 'could not save',
      AiLinkCode.busy: 'busy',
      AiLinkCode.badRequest: 'bad thing',
    };
    for (final e in cases.entries) {
      test('${e.key.wire} on a write and on a read is an error that says what happened', () async {
        final f = await fake();
        f.answer = (_) => err(e.key, 'bad thing');
        final w = await toolbox().writeBox(boxId: 'aiA', code: codeW, mode: 'append', content: 'hello');
        expect(w.isError, isTrue);
        expect(w.text, contains(e.value));
        expect(w.text, isNot(contains(codeW)));
        final r = await toolbox().readPage(Ids.priv, code: codeR);
        expect(r.isError, isTrue);
        expect(r.text, contains(e.value));
        expect(r.text, isNot(contains(codeR)));
      });
    }

    test('an unknown code from a newer app keeps its message and wire code', () async {
      final f = await fake();
      f.answer = (_) => jsonEncode({'ok': false, 'code': 'quota', 'message': 'Too many writes today.'});
      final out = await toolbox().writeBox(boxId: 'aiA', code: codeW, mode: 'append', content: 'x');
      expect(out.isError, isTrue);
      expect(out.text, contains('Too many writes today.'));
      expect(out.text, contains('quota'));
    });

    test('Noted not running: describe_code says so; other code calls are checked against the saved store', () async {
      // No ai-link.json and no ai-access.json in this folder: no code is known.
      final dir = Directory.systemTemp.createTempSync('noted_mcp_nolink');
      addTearDown(() => dir.deleteSync(recursive: true));
      final t = NotedToolbox(dir, session: 's');
      expect((await t.describeCode(codeR)).text, notRunningText);
      for (final out in [
        await t.listPages(code: codeR),
        await t.readPage(Ids.public, code: codeR),
        await t.readBox('aiG', code: codeR),
        await t.search('x', code: codeR),
        await t.writeBox(boxId: 'aiA', code: codeW, mode: 'append', content: 'x'),
      ]) {
        expect(out.isError, isTrue);
        expect(out.text, 'Approve this code in Noted first. Open Noted: it will ask you.');
      }
      expect((await toolbox().readPage(Ids.public)).isError, isFalse);
    });

    test('nothing listening on the port is not running', () async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      final dir = Directory.systemTemp.createTempSync('noted_mcp_stale');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/$aiLinkFileName').writeAsStringSync(jsonEncode({'format': 1, 'port': port, 'pid': 1, 'nonce': 'n'}));
      expect((await NotedToolbox(dir, session: 's').describeCode(codeR)).text, notRunningText);
    });

    test('a nonce mismatch is not running and the fake received no code', () async {
      final f = await fake(greetNonce: 'OTHER');
      f.answer = (_) => pagesGrant([]);
      expect((await toolbox().describeCode(codeR)).text, notedBusyText);
      // Noted holds its lock, so it is running: no fallback to the closed way,
      // and no code is sent to a peer that failed the nonce check.
      expect((await toolbox().listPages(code: codeR)).text, notedBusyText);
      expect((await toolbox().writeBox(boxId: 'aiA', code: codeW, mode: 'append', content: 'x')).text, notedBusyText);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(f.lines, isEmpty);
    });

    test('a peer that never greets is not running, nothing sent', () async {
      final f = await fake(greet: false);
      expect((await toolbox().describeCode(codeR)).text, notedBusyText);
      expect(f.lines, isEmpty);
    });

    test('a silent app times out with an error that does not hold the code', () async {
      await fake();
      final out = await toolbox(responseTimeout: const Duration(milliseconds: 300)).describeCode(codeR);
      expect(out.isError, isTrue);
      expect(out.text, isNot(contains(codeR)));
    });

    test('a malformed answer is an error', () async {
      final f = await fake();
      f.answer = (_) => 'not json';
      final out = await toolbox().describeCode(codeR);
      expect(out.isError, isTrue);
      expect(out.text, contains("didn't answer"));
    });

    test('a malformed code never reaches the app', () async {
      final f = await fake();
      f.answer = (_) => pagesGrant([]);
      final t = toolbox();
      for (final out in [
        await t.listPages(code: 'junk'),
        await t.readBox('aiG', code: 'noted_short'),
        await t.writeBox(boxId: 'aiA', code: 'junk', mode: 'append', content: 'x'),
        await t.describeCode('junk'),
        await t.describeCode(null),
      ]) {
        expect(out.isError, isTrue);
        expect(out.text, contains('not valid'));
      }
      expect(f.lines, isEmpty);
    });
  });

  group('write_box', () {
    test('success sends the code, box, mode and content with the session and app, and says so', () async {
      final f = await fake();
      f.answer = (_) => const AiLinkResponse.written(box: 'aiA').encode();
      final out = await toolbox().writeBox(boxId: 'aiA', code: codeW, mode: 'replace', content: 'hello');
      expect(out.isError, isFalse);
      expect(out.text, 'Written to box aiA.');
      final req = f.requests.single as AiLinkWriteBox;
      expect(req.code, codeW);
      expect(req.box, 'aiA');
      expect(req.mode, AiLinkMode.replace);
      expect(req.content, 'hello');
      expect(req.session, 'SESSION-1');
      expect(req.app, 'Test App 1.2');
    });

    test('the code is required, and a bad mode or empty box sends nothing', () async {
      final f = await fake();
      f.answer = (_) => const AiLinkResponse.written(box: 'aiA').encode();
      final t = toolbox();
      final none = await t.writeBox(boxId: 'aiA', code: null, mode: 'append', content: 'x');
      expect(none.isError, isTrue);
      expect(none.text, contains('code'));
      expect((await t.writeBox(boxId: 'aiA', code: codeW, mode: 'delete', content: 'x')).isError, isTrue);
      expect((await t.writeBox(boxId: '', code: codeW, mode: 'append', content: 'x')).isError, isTrue);
      expect(f.lines, isEmpty);
    });

    test('a request over the size limit is refused and nothing is sent', () async {
      final f = await fake();
      f.answer = (_) => const AiLinkResponse.written(box: 'aiA').encode();
      final out = await toolbox().writeBox(
        boxId: 'aiA',
        code: codeW,
        mode: 'append',
        content: 'y' * (aiLinkMaxRequestBytes + 1),
      );
      expect(out.isError, isTrue);
      expect(out.text, contains('too long'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(f.lines, isEmpty);
    });
  });

  group('describe_code', () {
    test('forwards to the app and shows what the code grants', () async {
      final f = await fake();
      f.answer = (_) => const AiLinkResponse.described(
        kind: 'box',
        id: 'aiA',
        role: 'writer',
        expires: '2027-01-01T00:00:00.000Z',
      ).encode();
      final out = await toolbox().describeCode(codeW);
      expect(out.isError, isFalse);
      expect(jsonDecode(out.text), {'kind': 'box', 'id': 'aiA', 'role': 'writer', 'expires': '2027-01-01T00:00:00.000Z'});
      final req = f.requests.single as AiLinkDescribeCode;
      expect(req.code, codeW);
      expect(req.session, 'SESSION-1');
      expect(req.app, 'Test App 1.2');
    });

    test('a code that does not expire says null, and the app\'s refusals are errors', () async {
      final f = await fake();
      f.answer = (_) => const AiLinkResponse.described(kind: 'page', id: Ids.priv, role: 'reader').encode();
      expect(jsonDecode((await toolbox().describeCode(codeR)).text)['expires'], isNull);
      f.answer = (_) => err(AiLinkCode.expired);
      expect((await toolbox().describeCode(codeR)).text, contains('expired'));
    });
  });

  group('session id and app name', () {
    test('a session id is 32 random bytes in base64url, new each time', () {
      final a = newSessionId();
      final b = newSessionId();
      expect(a, isNot(b));
      final padded = a + '=' * ((4 - a.length % 4) % 4);
      expect(base64Url.decode(padded), hasLength(32));
      expect(a.length, lessThanOrEqualTo(aiLinkMaxSessionLength));
      expect(a, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    });

    test('the toolbox makes its own session id when none is given', () {
      expect(NotedToolbox(data).session, isNot(NotedToolbox(data).session));
    });

    test('the app is the client name and version, cut to the longest allowed', () {
      expect(appLabel('Claude Code', '2.1.0'), 'Claude Code 2.1.0');
      expect(appLabel('Claude Code'), 'Claude Code');
      expect(appLabel('Claude Code', ''), 'Claude Code');
      expect(appLabel('Evil\nApp\r\u0000x', '1\t2'), 'Evil App  x 1 2');
      expect(appLabel('\n'), isNull);
      expect(appLabel('  '), isNull);
      expect(appLabel(null), isNull);
      expect(appLabel('x' * 500, '1')!.length, aiLinkMaxAppLength);
    });
  });

  group('merge_requests and propose_merge', () {
    const item = AiLinkMergeItem(
      id: 'req1',
      page: 'pg',
      box: 'bx',
      type: 'noted.note',
      mine: AiLinkMergeVersion(at: 1000, device: 'PC-A'),
      theirs: AiLinkMergeVersion(at: 2000, device: 'PC-B'),
    );

    test('merge_requests sends the code with the session and app and lists both versions', () async {
      final f = await fake();
      f.answer = (_) => const AiLinkResponse.merges([item]).encode();
      final out = await toolbox().mergeRequests(codeR);
      expect(out.isError, isFalse);
      final r = f.requests.single as AiLinkMergeRequests;
      expect(r.code, codeR);
      expect(r.session, 'SESSION-1');
      expect(r.app, 'Test App 1.2');
      final listed = (jsonDecode(out.text)['requests'] as List).single as Map;
      expect(listed['id'], 'req1');
      expect(listed['box'], 'bx');
      expect(out.text, isNot(contains(codeR)));
    });

    test('an empty list says nothing is waiting', () async {
      final f = await fake();
      f.answer = (_) => const AiLinkResponse.merges([]).encode();
      final out = await toolbox().mergeRequests(codeR);
      expect(out.isError, isFalse);
      expect(out.text, contains('No merge requests'));
    });

    test('propose_merge sends the request id and the markdown, and says the user decides', () async {
      final f = await fake();
      f.answer = (_) => const AiLinkResponse.proposed(request: 'req1').encode();
      final out = await toolbox().proposeMerge(code: codeR, requestId: 'req1', content: '# Merged\n\nboth');
      expect(out.isError, isFalse);
      expect(out.text, contains('user'));
      final r = f.requests.single as AiLinkProposeMerge;
      expect(r.request, 'req1');
      expect(r.content, '# Merged\n\nboth');
      expect(r.code, codeR);
    });

    test('the app\'s refusals reach the AI as clear errors', () async {
      final f = await fake();
      for (final c in [AiLinkCode.noRequest, AiLinkCode.wrongRole, AiLinkCode.badCode, AiLinkCode.expired]) {
        f.answer = (_) => err(c);
        final a = await toolbox().mergeRequests(codeR);
        final b = await toolbox().proposeMerge(code: codeR, requestId: 'req1', content: 'x');
        for (final out in [a, b]) {
          expect(out.isError, isTrue, reason: c.wire);
          expect(out.text, isNotEmpty);
          expect(out.text, isNot(contains(codeR)));
        }
      }
      f.answer = (_) => err(AiLinkCode.noRequest);
      expect((await toolbox().proposeMerge(code: codeR, requestId: 'req1', content: 'x')).text, contains('merge_requests'));
    });

    test('with Noted closed both say it needs Noted running', () async {
      final dir = Directory.systemTemp.createTempSync('noted_mcp_merge_closed');
      addTearDown(() => dir.deleteSync(recursive: true));
      final t = NotedToolbox(dir, session: 's');
      expect((await t.mergeRequests(codeR)).text, notRunningText);
      expect((await t.proposeMerge(code: codeR, requestId: 'r', content: 'x')).text, notRunningText);
    });

    test('a malformed code or an empty request id never reaches the app', () async {
      final f = await fake();
      f.answer = (_) => const AiLinkResponse.proposed(request: 'r').encode();
      final t = toolbox();
      expect((await t.mergeRequests('junk')).text, contains('not valid'));
      expect((await t.mergeRequests(null)).isError, isTrue);
      expect((await t.proposeMerge(code: 'junk', requestId: 'r', content: 'x')).text, contains('not valid'));
      expect((await t.proposeMerge(code: codeR, requestId: ' ', content: 'x')).isError, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(f.lines, isEmpty);
    });

    // A saved page with a conflicted note box: mine links to a Guarded page and
    // to an Open one; theirs is [other].
    Future<void> withConflictPage(String pageId, {String? ai = 'privileged', Object? other}) async {
      final mine = box(
        'cn',
        'noted.note',
        richNote(linkedOff: Ids.hidden, linkedOn: Ids.publicChild),
        const Bounds(0, 0, 100, 40),
      );
      final theirsBox = box('cn', 'noted.note', other ?? simpleNote('Theirs only line'), const Bounds(0, 0, 100, 40));
      final conflicted = mine.withConflict(BoxConflict.other(node: theirsBox.toRaw(), at: 2000, device: 'PC-B'));
      final file = File('${data.path}/pages/$pageId.canvas');
      file.writeAsStringSync(writePage(page(pageId, 'Conflict page', ai: ai, nodes: [conflicted])));
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
    }

    AiLinkMergeItem itemFor(String pageId) => AiLinkMergeItem(
      id: 'req2',
      page: pageId,
      box: 'cn',
      type: 'noted.note',
      mine: const AiLinkMergeVersion(at: 1000, device: 'PC-A'),
      theirs: const AiLinkMergeVersion(at: 2000, device: 'PC-B'),
    );

    test('the versions are rendered here from the saved conflict record, with page links filtered', () async {
      const pageId = 'c0000000000000f1';
      await withConflictPage(pageId);
      final f = await fake();
      f.answer = (_) => AiLinkResponse.merges([itemFor(pageId)]).encode();
      final out = await toolbox().mergeRequests(codeR);
      expect(out.isError, isFalse);
      final listed = (jsonDecode(out.text)['requests'] as List).single as Map;
      final mine = (listed['mine'] as Map)['markdown'] as String;
      final theirs = (listed['theirs'] as Map)['markdown'] as String;
      expect(mine, contains('Trip plan'));
      // The link to a Guarded page is only its text; the visible page's link stays.
      expect(mine, contains('hidden notes'));
      expect(mine, isNot(contains(Ids.hidden)));
      expect(mine, contains(Ids.publicChild));
      expect(theirs, 'Theirs only line');
      expect((listed['mine'] as Map)['device'], 'PC-A');
      expect((listed['theirs'] as Map)['at'], 2000);
      expect(out.text, isNot(contains(secret)));
    });

    test('an AI box version keeps its <ai-written> lines', () async {
      const pageId = 'c0000000000000f2';
      final mine = box('cn', aiBoxTypeId, aiBoxData('From the AI'), const Bounds(0, 0, 100, 40));
      final theirs = box('cn', aiBoxTypeId, aiBoxData('Other AI text'), const Bounds(0, 0, 100, 40));
      final file = File('${data.path}/pages/$pageId.canvas');
      file.writeAsStringSync(
        writePage(
          page(
            pageId,
            'AI conflict',
            ai: 'privileged',
            nodes: [mine.withConflict(BoxConflict.other(node: theirs.toRaw(), at: 5, device: 'PC-B'))],
          ),
        ),
      );
      addTearDown(() => file.deleteSync());
      final f = await fake();
      f.answer = (_) => AiLinkResponse.merges([
        AiLinkMergeItem(
          id: 'r',
          page: pageId,
          box: 'cn',
          type: aiBoxTypeId,
          mine: const AiLinkMergeVersion(at: 1),
          theirs: const AiLinkMergeVersion(at: 5),
        ),
      ]).encode();
      final out = await toolbox().mergeRequests(codeR);
      final listed = (jsonDecode(out.text)['requests'] as List).single as Map;
      expect((listed['mine'] as Map)['markdown'], contains('<ai-written>'));
      expect((listed['theirs'] as Map)['markdown'], contains('Other AI text'));
    });

    test('a Guarded page, a settled conflict or a missing page is listed as unavailable with no content', () async {
      const guarded = 'c0000000000000f3';
      await withConflictPage(guarded, ai: 'guarded');
      const settled = 'c0000000000000f4';
      final file = File('${data.path}/pages/$settled.canvas');
      file.writeAsStringSync(
        writePage(
          page(
            settled,
            'Settled',
            ai: 'privileged',
            nodes: [box('cn', 'noted.note', simpleNote('SETTLED-TEXT'), const Bounds(0, 0, 100, 40))],
          ),
        ),
      );
      addTearDown(() => file.deleteSync());
      final f = await fake();
      f.answer = (_) => AiLinkResponse.merges([itemFor(guarded), itemFor(settled), itemFor('c0000000000000f5')]).encode();
      final out = await toolbox().mergeRequests(codeR);
      expect(out.isError, isFalse);
      final list = (jsonDecode(out.text)['requests'] as List).cast<Map<String, Object?>>();
      expect(list, hasLength(3), reason: 'nothing is silently dropped');
      for (final l in list) {
        expect(l['unavailable'], isA<String>());
        expect(l.containsKey('mine'), isFalse);
      }
      expect(out.text, isNot(contains('Theirs only')));
      expect(out.text, isNot(contains('SETTLED-TEXT')));
    });

    test('an encrypted box is refused', () async {
      const pageId = 'c0000000000000f6';
      final mine = box('cn', 'noted.encrypted', {'ciphertext': secret}, const Bounds(0, 0, 100, 40), snapshot: secret);
      final theirs = box('cn', 'noted.encrypted', {'ciphertext': secret}, const Bounds(0, 0, 100, 40), snapshot: secret);
      final file = File('${data.path}/pages/$pageId.canvas');
      file.writeAsStringSync(
        writePage(
          page(pageId, 'Enc', ai: 'privileged', nodes: [mine.withConflict(BoxConflict.other(node: theirs.toRaw(), at: 5))]),
        ),
      );
      addTearDown(() => file.deleteSync());
      final f = await fake();
      f.answer = (_) => AiLinkResponse.merges([itemFor(pageId)]).encode();
      final out = await toolbox().mergeRequests(codeR);
      expect(out.text, contains('unavailable'));
      expect(out.text, isNot(contains(secret)));
    });

    test('a version over the size limit is unavailable', () async {
      const pageId = 'c0000000000000f7';
      await withConflictPage(pageId, other: simpleNote('word ' * 30000));
      final f = await fake();
      f.answer = (_) => AiLinkResponse.merges([itemFor(pageId)]).encode();
      final out = await toolbox().mergeRequests(codeR);
      expect(out.text, contains('unavailable'));
    });
  });
}
