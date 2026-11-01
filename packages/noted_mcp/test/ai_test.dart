// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core_read.dart';
import 'package:noted_mcp/noted_mcp.dart';

import 'fixture.dart';

const _idA = '1111111111111111';
const _idB = '2222222222222222';
const _idRevoked = '3333333333333333';
const _key = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ'; // 43 characters
const tokenA = 'noted_${_idA}_$_key';
const tokenB = 'noted_${_idB}_$_key';
const tokenRevoked = 'noted_${_idRevoked}_$_key';

const wholeAi = 'f000000000000001'; // Whole page: a note, A's box, B's box
const boxyAi = 'f000000000000002'; // Box only: a note, A's boxes, B's box
const offAi = 'f000000000000003'; // Off: A's box

Map<String, Object?> aiBoxData(String owner, String text) {
  final para = markAiWritten({
    'type': 'paragraph',
    'data': {
      'delta': [
        {'insert': text},
      ],
    },
  });
  return {
    'owner': owner,
    'document': {
      'type': 'page',
      'children': [para],
    },
  };
}

/// The base fixture plus pages with AI boxes of two connections, and a
/// settings.json that lists them.
Directory writeAiFixture(Directory root) {
  final data = writeFixture(root);
  final pages = Directory('${data.path}/pages');
  void save(NotedPage p) => File('${pages.path}/${p.id}.canvas').writeAsStringSync(writePage(p));
  const at = Bounds(0, 0, 100, 40);
  save(
    page(
      wholeAi,
      'Whole AI',
      ai: 'page',
      nodes: [
        box('note1', 'noted.note', simpleNote('okapi note'), at),
        box('aiA', aiBoxTypeId, aiBoxData(_idA, 'okapi from A'), const Bounds(0, 100, 100, 40)),
        box('aiB', aiBoxTypeId, aiBoxData(_idB, 'okapi from B'), const Bounds(0, 200, 100, 40)),
      ],
    ),
  );
  save(
    page(
      boxyAi,
      'Boxy AI',
      ai: 'box',
      nodes: [
        box('note2', 'noted.note', simpleNote('okapi private $secret'), at),
        box('aiA2', aiBoxTypeId, aiBoxData(_idA, 'okapi from A2'), const Bounds(0, 200, 100, 40)),
        box('aiA3', aiBoxTypeId, aiBoxData(_idA, 'okapi first A'), const Bounds(0, 100, 100, 40)),
        box('aiB2', aiBoxTypeId, aiBoxData(_idB, 'okapi from B2 $secret'), const Bounds(0, 300, 100, 40)),
      ],
    ),
  );
  save(page(offAi, 'Off AI', nodes: [box('aiA4', aiBoxTypeId, aiBoxData(_idA, 'okapi off'), at)]));
  File('${data.path}/settings.json').writeAsStringSync(
    jsonEncode({
      'format': 1,
      'aiConnections': [
        {'id': _idA, 'name': 'A', 'hash': 'x', 'created': 1},
        {'id': _idB, 'name': 'B', 'hash': 'x', 'created': 2},
      ],
    }),
  );
  return data;
}

void main() {
  late Directory root;
  late Directory data;
  late NotedLibrary library;

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('noted_mcp_ai');
    data = writeAiFixture(root);
    library = await NotedLibrary.load(data);
  });
  tearDownAll(() => root.deleteSync(recursive: true));

  NotedTools withToken(String? token) => NotedTools(library, token: token);

  String generic(String s) => s.replaceAll(RegExp(r'"[^"]*" on page'), 'X on page');

  group('AI boxes in reads', () {
    test('a Whole page shows AI boxes as markdown, marking the AI\'s own', () {
      final text = withToken(tokenA).readPage(wholeAi).text;
      expect(text, contains('**ai** · box `aiA` · your box'));
      expect(text, contains('**ai** · box `aiB`\n'));
      expect(text, contains('okapi from A'));
      expect(text, contains('okapi from B'));
    });

    test('without a token nothing is "your box"', () {
      expect(withToken(null).readPage(wholeAi).text, isNot(contains('your box')));
    });

    test('Box only: the title and the AI\'s own boxes in reading order, nothing else', () {
      final text = withToken(tokenA).readPage(boxyAi).text;
      expect(text, startsWith('# Boxy AI'));
      expect(text.indexOf('okapi first A'), lessThan(text.indexOf('okapi from A2')));
      expect(text, isNot(contains('from B2')));
      expect(text, isNot(contains('private')));
      expect(text, isNot(contains(secret)));
    });

    test('Box only with no own box gives the explanation', () {
      final text = withToken(null).readPage(boxyAi).text;
      expect(text, contains('Box only'));
      expect(text, isNot(contains('okapi')));
      expect(withToken(tokenB).readPage(boxyAi).text, contains('from B2'));
    });

    test('read_box: an own box reads; another AI\'s or a note looks missing', () {
      expect(withToken(tokenA).readBox(boxyAi, 'aiA2').text, contains('okapi from A2'));
      final missing = withToken(tokenA).readBox(boxyAi, 'nothing');
      for (final id in ['aiB2', 'note2']) {
        final r = withToken(tokenA).readBox(boxyAi, id);
        expect(r.isError, isTrue);
        expect(generic(r.text), generic(missing.text));
        expect(r.text, isNot(contains(secret)));
      }
    });

    test('Off pages stay invisible, even for the owner', () {
      expect(withToken(tokenA).readPage(offAi).isError, isTrue);
      expect(withToken(tokenA).readBox(offAi, 'aiA4').isError, isTrue);
      expect(withToken(tokenA).search('okapi').text, isNot(contains('Off AI')));
      expect(withToken(tokenA).listMyBoxes().text, isNot(contains(offAi)));
    });

    test('search on a Box only page matches the AI\'s own boxes only', () {
      final a = (jsonDecode(withToken(tokenA).search('okapi').text)['results'] as List).cast<Map<String, Object?>>();
      final matches = (a.firstWhere((r) => r['id'] == boxyAi)['matches']! as List).join('\n');
      expect(matches, contains('aiA2'));
      expect(matches, isNot(contains('aiB2')));
      expect(matches, isNot(contains('note2')));
      final none = (jsonDecode(withToken(null).search('okapi').text)['results'] as List).cast<Map<String, Object?>>();
      expect(none.where((r) => r['id'] == boxyAi), isEmpty);
    });

    test('an unlisted (revoked) or malformed token sees no own boxes', () {
      for (final t in [tokenRevoked, 'garbage', '']) {
        final tools = withToken(t);
        expect(tools.connectionId, isNull);
        expect(tools.readPage(boxyAi).text, isNot(contains('okapi')));
        expect(tools.readPage(wholeAi).text, isNot(contains('your box')));
        expect(tools.readBox(boxyAi, 'aiA2').isError, isTrue);
        expect(tools.listMyBoxes().isError, isTrue);
      }
    });

    test('the listing is read afresh: a connection removed from settings.json is gone', () async {
      final r = Directory.systemTemp.createTempSync('noted_mcp_ai2');
      addTearDown(() => r.deleteSync(recursive: true));
      final d = writeAiFixture(r);
      expect(NotedTools(await NotedLibrary.load(d), token: tokenA).connectionId, _idA);
      File('${d.path}/settings.json').writeAsStringSync(jsonEncode({'format': 1, 'aiConnections': []}));
      expect(NotedTools(await NotedLibrary.load(d), token: tokenA).connectionId, isNull);
    });
  });

  group('list_my_boxes', () {
    test('lists the own boxes on pages that aren\'t Off', () {
      final out = withToken(tokenA).listMyBoxes();
      expect(out.isError, isFalse);
      final boxes = (jsonDecode(out.text)['boxes'] as List).cast<Map<String, Object?>>();
      expect({for (final b in boxes) b['box_id']}, {'aiA', 'aiA2', 'aiA3'});
      final one = boxes.firstWhere((b) => b['box_id'] == 'aiA2');
      expect(one, {'page_id': boxyAi, 'page_title': 'Boxy AI', 'box_id': 'aiA2', 'ai': 'box'});
    });

    test('without a valid token it explains NOTED_TOKEN', () {
      final out = withToken(null).listMyBoxes();
      expect(out.isError, isTrue);
      expect(out.text, contains('NOTED_TOKEN'));
      expect(out.text, contains('AI connections'));
    });
  });

  group('write_box over the link', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('noted_mcp_link'));
    tearDown(() => dir.deleteSync(recursive: true));

    /// A fake Noted: greets with [greetNonce] (default [nonce]), records what
    /// it receives, and answers with [answer] when it has a request line.
    Future<List<String>> fake({String nonce = 'N0NCE', String? greetNonce, String? answer, String? rawGreeting, bool greet = true}) async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final received = <String>[];
      server.listen((s) {
        if (greet) s.write(rawGreeting ?? '${aiLinkGreeting(greetNonce ?? nonce)}\n');
        utf8.decoder
            .bind(s)
            .listen(
              (chunk) {
                received.add(chunk);
                if (chunk.endsWith('\n') && answer != null) {
                  s.write('$answer\n');
                  s.close();
                }
              },
              onError: (_) {},
              cancelOnError: true,
            );
      });
      File('${dir.path}/$aiLinkFileName').writeAsStringSync(
        jsonEncode({'format': 1, 'port': server.port, 'pid': 1, 'nonce': nonce}),
      );
      return received;
    }

    Future<ToolOutput> write({String? token = tokenA, String mode = 'append'}) =>
        AiLinkClient(dir, responseTimeout: const Duration(seconds: 3))
            .writeBox(token: token, boxId: 'aiA', mode: mode, content: 'hello');

    test('success sends the token and request, and returns the app\'s result', () async {
      final received = await fake(answer: AiLinkResponse.ok(page: wholeAi, box: 'aiA').encode());
      final out = await write();
      expect(out.isError, isFalse);
      expect(out.text, contains('aiA'));
      final req = AiLinkRequest.decode(received.join())!;
      expect(req.token, tokenA);
      expect(req.box, 'aiA');
      expect(req.mode, AiLinkMode.append);
      expect(req.content, 'hello');
    });

    test('an error code from the app is an error result with its message, without the token', () async {
      await fake(answer: AiLinkResponse.error(AiLinkCode.notOwner).encode());
      final out = await write(mode: 'replace');
      expect(out.isError, isTrue);
      expect(out.text, AiLinkCode.notOwner.defaultMessage);
      expect(out.text, isNot(contains(tokenA)));
    });

    test('a nonce mismatch is not_running and the fake received no token', () async {
      final received = await fake(greetNonce: 'OTHER', answer: AiLinkResponse.ok(page: 'p', box: 'b').encode());
      final out = await write();
      expect(out.isError, isTrue);
      expect(out.text, AiLinkClient.notRunning);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(received, isEmpty);
    });

    test('no ai-link.json is not_running, and reads still work', () async {
      final out = await write();
      expect(out.isError, isTrue);
      expect(out.text, "Noted isn't running. Open Noted and try again; reads still work.");
      expect(withToken(tokenA).readPage(wholeAi).isError, isFalse);
    });

    test('nothing listening on the port is not_running', () async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      File('${dir.path}/$aiLinkFileName').writeAsStringSync(
        jsonEncode({'format': 1, 'port': port, 'pid': 1, 'nonce': 'n'}),
      );
      expect((await write()).text, AiLinkClient.notRunning);
    });

    test('without a token, or a bad mode, nothing is sent', () async {
      final received = await fake(answer: AiLinkResponse.ok(page: 'p', box: 'b').encode());
      final none = await write(token: null);
      expect(none.isError, isTrue);
      expect(none.text, contains('NOTED_TOKEN'));
      expect((await write(token: 'junk')).isError, isTrue);
      expect((await write(mode: 'delete')).isError, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(received, isEmpty);
    });

    test('a server that accepts but never greets times out as not_running, nothing sent', () async {
      final received = await fake(greet: false);
      final out = await AiLinkClient(
        dir,
        greetingTimeout: const Duration(milliseconds: 300),
      ).writeBox(token: tokenA, boxId: 'aiA', mode: 'append', content: 'x');
      expect(out.text, AiLinkClient.notRunning);
      expect(received, isEmpty);
    });

    test('an oversized greeting without a newline is not_running, nothing sent', () async {
      final received = await fake(rawGreeting: 'x' * 100000);
      expect((await write()).text, AiLinkClient.notRunning);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(received, isEmpty);
    });

    test('an oversized greeting line is not_running, nothing sent', () async {
      final received = await fake(rawGreeting: '${'x' * 100000}\n');
      expect((await write()).text, AiLinkClient.notRunning);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(received, isEmpty);
    });

    test('a malformed response is an error', () async {
      await fake(answer: 'not json');
      final out = await write();
      expect(out.isError, isTrue);
      expect(out.text, contains('understood'));
    });

    test('a request over the size limit is refused and nothing is sent', () async {
      final received = await fake(answer: AiLinkResponse.ok(page: 'p', box: 'b').encode());
      final out = await AiLinkClient(dir).writeBox(
        token: tokenA,
        boxId: 'aiA',
        mode: 'append',
        content: 'y' * (aiLinkMaxRequestBytes + 1),
      );
      expect(out.isError, isTrue);
      expect(out.text, contains('too long'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(received, isEmpty);
    });

    test('a silent app times out with an error', () async {
      await fake();
      final out = await AiLinkClient(
        dir,
        responseTimeout: const Duration(milliseconds: 300),
      ).writeBox(token: tokenA, boxId: 'aiA', mode: 'append', content: 'x');
      expect(out.isError, isTrue);
      expect(out.text, isNot(contains(tokenA)));
    });
  });
}
