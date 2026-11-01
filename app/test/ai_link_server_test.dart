// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/ai/ai_link_server.dart';
import 'package:noted/src/ai/ai_access_service.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory root;
  late File linkFile;
  late List<AiLinkRequest> seen;
  late List<AiLinkServer> servers;
  late List<Socket> sockets;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_ailink');
    linkFile = File('${root.path}/data/$aiLinkFileName');
    seen = [];
    servers = [];
    sockets = [];
  });

  tearDown(() async {
    for (final s in sockets) {
      s.destroy();
    }
    for (final s in servers) {
      await s.dispose();
    }
    await root.delete(recursive: true);
  });

  Future<AiLinkServer> start({
    AiLinkHandler? handler,
    Duration? readTimeout,
    int? maxRequestBytes,
    int? maxConnections,
  }) async {
    final s = AiLinkServer(
      file: linkFile,
      handler:
          handler ??
          (r, _) async {
            seen.add(r);
            return AiLinkResponse.written(box: (r as AiLinkWriteBox).box);
          },
      readTimeout: readTimeout ?? aiLinkReadTimeout,
      maxRequestBytes: maxRequestBytes ?? aiLinkMaxRequestBytes,
      maxConnections: maxConnections ?? aiLinkMaxConnections,
    );
    servers.add(s);
    await s.start();
    return s;
  }

  // Connects and collects everything the server says until it closes.
  Future<({Socket socket, Stream<String> lines})> connect(AiLinkServer s) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, s.port!);
    sockets.add(socket);
    final lines = socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());
    return (socket: socket, lines: lines);
  }

  Future<List<String>> exchange(AiLinkServer s, String? send, {bool sendRaw = false}) async {
    final c = await connect(s);
    final out = <String>[];
    final done = Completer<void>();
    c.lines.listen(out.add, onDone: done.complete, onError: (Object _) => done.complete());
    if (send != null) c.socket.add(utf8.encode(sendRaw ? send : '$send\n'));
    await done.future.timeout(const Duration(seconds: 10));
    return out;
  }

  AiLinkWriteBox request({String box = 'b1', String content = 'hi'}) => AiLinkWriteBox(
    code: 'noted_${'a' * 16}_${'B' * 43}',
    session: 'session-1',
    app: 'Test client',
    box: box,
    mode: AiLinkMode.append,
    content: content,
  );

  test('writes ai-link.json and deletes it on dispose', () async {
    final s = await start();
    final link = readAiLink(linkFile.readAsStringSync())!;
    expect(link.port, s.port);
    expect(link.nonce, s.nonce);
    final json = jsonDecode(linkFile.readAsStringSync()) as Map;
    expect(json['format'], 1);
    expect(json['pid'], pid);
    // 32 bytes, base64url.
    expect(link.nonce, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    await s.dispose();
    expect(linkFile.existsSync(), isFalse);
  });

  test('the nonce is new at every start', () async {
    final a = await start();
    final first = a.nonce;
    await a.dispose();
    final b = await start();
    expect(b.nonce, isNot(first));
  });

  test('listens on 127.0.0.1 only', () async {
    final s = await start();
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, s.port!);
    socket.destroy();
    expect(s.port, isNonZero);
  });

  test('the greeting with the nonce comes first, before any request', () async {
    final s = await start();
    final c = await connect(s);
    final first = await c.lines.first.timeout(const Duration(seconds: 5));
    expect(readAiLinkGreeting(first), s.nonce);
    expect(seen, isEmpty);
  });

  test('one request, one answer, then it closes', () async {
    final s = await start();
    final out = await exchange(s, request().encode());
    expect(readAiLinkGreeting(out.first), s.nonce);
    expect(out, hasLength(2));
    final r = AiLinkResponse.decode(out[1])!;
    expect(r.ok, isTrue);
    expect((r as AiLinkWritten).box, 'b1');
    final got = seen.single as AiLinkWriteBox;
    expect(got.content, 'hi');
    expect(got.mode, AiLinkMode.append);
    expect(got.session, 'session-1');
    expect(got.app, 'Test client');
  });

  test('a request of this protocol that is not understood gets bad_request', () async {
    final s = await start();
    final out = await exchange(
      s,
      '{"noted":"ai-link/2","op":"delete_everything","code":"x","session":"s"}',
    );
    expect(AiLinkResponse.decode(out[1])!.code, AiLinkCode.badRequest);
    expect(seen, isEmpty);
  });

  test('a first byte that is not { drops the connection without an answer', () async {
    final s = await start();
    final out = await exchange(s, 'GET / HTTP/1.1\r\n\r\n');
    expect(out, hasLength(1), reason: 'only the greeting');
    expect(seen, isEmpty);
  });

  test('a JSON line that is not ai-link/2 is dropped without an answer', () async {
    final s = await start();
    for (final line in [
      '{"noted":"ai-link/1","op":"write_box"}',
      '{"hello":"world"}',
      '{"jsonrpc":"2.0","id":1,"method":"tools/list"}',
      '{ not json',
    ]) {
      final out = await exchange(s, line);
      expect(out, hasLength(1), reason: '$line: only the greeting');
    }
    expect(seen, isEmpty);
  });

  test('an oversize request is stopped while it is read', () async {
    final s = await start(maxRequestBytes: 1000);
    final c = await connect(s);
    final out = <String>[];
    final done = Completer<void>();
    c.lines.listen(out.add, onDone: done.complete, onError: (Object _) => done.complete());
    c.socket.add(utf8.encode('{"x":"${'a' * 5000}'));
    await done.future.timeout(const Duration(seconds: 10));
    expect(out, hasLength(2));
    expect(AiLinkResponse.decode(out[1])!.code, AiLinkCode.badRequest);
    expect(seen, isEmpty);
  });

  test('a request of exactly the limit is accepted; one byte more is not', () async {
    final s = await start(maxRequestBytes: 400);
    final base = request().encode();
    final pad = 400 - 1 - utf8.encode(base).length;
    final okLine = request(content: 'x' * (2 + pad)).encode();
    expect(utf8.encode(okLine).length + 1, 400);
    expect(AiLinkResponse.decode((await exchange(s, okLine))[1])!.ok, isTrue);
    final tooBig = '$okLine ';
    expect(AiLinkResponse.decode((await exchange(s, tooBig))[1])!.code, AiLinkCode.badRequest);
  });

  test('a silent client is dropped after the read timeout', () async {
    final s = await start(readTimeout: const Duration(milliseconds: 200));
    final watch = Stopwatch()..start();
    final out = await exchange(s, null);
    expect(out, hasLength(1), reason: 'only the greeting');
    expect(watch.elapsedMilliseconds, lessThan(5000));
    // A partial request that never ends is dropped too.
    final partial = await exchange(s, '{"noted":', sendRaw: true);
    expect(partial, hasLength(1));
    expect(seen, isEmpty);
  });

  test('at most maxConnections at once', () async {
    final s = await start(maxConnections: 2);
    final a = await connect(s);
    final b = await connect(s);
    await a.lines.first;
    await b.lines.first;
    final out = await exchange(s, request().encode());
    expect(out, isEmpty, reason: 'no greeting, no answer for the third');
    expect(seen, isEmpty);
    // A place frees up when one goes.
    a.socket.destroy();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final again = await exchange(s, request().encode());
    expect(AiLinkResponse.decode(again[1])!.ok, isTrue);
  });

  test('a handler that throws gives save_failed and the app runs on', () async {
    final s = await start(handler: (_, _) async => throw StateError('secret content'));
    final out = await exchange(s, request().encode());
    final r = AiLinkResponse.decode(out[1])!;
    expect(r.code, AiLinkCode.saveFailed);
    expect(r.message, isNot(contains('secret')));
    expect(AiLinkResponse.decode((await exchange(s, request().encode()))[1])!.code, AiLinkCode.saveFailed);
  });

  test('a stale file is left alone by a dispose of another launch', () async {
    final s = await start();
    linkFile.writeAsStringSync(jsonEncode({'format': 1, 'port': 1234, 'pid': 1, 'nonce': 'other'}));
    await s.dispose();
    expect(linkFile.existsSync(), isTrue);
  });

  test('with the real notebook: a bad code gives bad_code; a good one is asked about, then answered', () async {
    final dir = await Directory('${root.path}/pages').create();
    final service = AiAccessService(dataFolder: Directory('${root.path}/data'));
    final nb = Notebook(
      PageStore(dir),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
      aiAccess: service,
    );
    addTearDown(() async {
      await nb.flush();
      nb.dispose();
      service.dispose();
    });
    await nb.load();
    final questions = <String>[];
    nb.aiApprover = (r) async {
      questions.add(r.message);
      return true;
    };
    final s = await start(handler: nb.handleAiLink);
    final out = await exchange(s, request(box: 'no-such-box').encode());
    expect(AiLinkResponse.decode(out[1])!.code, AiLinkCode.badCode);
    expect(questions, isEmpty);

    final code = await service.issue(AiCodeTarget.box('no-such-box'), role: AiCodeRole.writer, label: 'x');
    final good = AiLinkWriteBox(
      code: code,
      session: 'session-1',
      app: 'Test client',
      box: 'no-such-box',
      mode: AiLinkMode.append,
      content: '',
    );
    final out2 = await exchange(s, good.encode());
    expect(AiLinkResponse.decode(out2[1])!.code, AiLinkCode.noBox);
    expect(questions, ['Test client wants to read and write x. Allow?']);
  });

  test('ai-link.json is written again if it goes missing, but another file is never replaced', () async {
    final s = AiLinkServer(
      file: linkFile,
      handler: (r, _) async => AiLinkResponse.written(box: 'b'),
      recheckInterval: const Duration(milliseconds: 50),
    );
    servers.add(s);
    await s.start();
    linkFile.deleteSync();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(linkFile.existsSync(), isTrue);
    final link = readAiLink(linkFile.readAsStringSync())!;
    expect(link.port, s.port);
    expect(link.nonce, s.nonce);

    const other = '{"format":1,"port":1234,"pid":1,"nonce":"other"}';
    linkFile.writeAsStringSync(other);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(linkFile.readAsStringSync(), other);
    // After dispose it does not come back.
    await s.dispose();
    linkFile.deleteSync();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(linkFile.existsSync(), isFalse);
  });

  test('startAiLink returns null instead of throwing when it cannot start', () async {
    final dir = await Directory('${root.path}/pages').create();
    final nb = Notebook(PageStore(dir), buildModules(), saveDelay: Duration.zero);
    addTearDown(nb.dispose);
    // The data "folder" is a file, so ai-link.json can't be written.
    final blocker = File('${root.path}/blocker')..writeAsStringSync('x');
    final server = await startAiLink(nb, Directory(blocker.path));
    expect(server, isNull);
  });
}

extension on AiLinkResponse {
  AiLinkCode? get code => this is AiLinkError ? (this as AiLinkError).code : null;
  String? get message => this is AiLinkError ? (this as AiLinkError).message : null;
}
