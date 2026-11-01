// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core_read.dart';

import 'ai_test.dart' show FakeNoted, codeR;
import 'fixture.dart';

// The executable itself, over stdio, as Claude Code starts it.
void main() {
  Future<ServerConnection> connect(Directory data, {Map<String, String>? environment}) async {
    final process = await Process.start(
      'dart',
      ['run', 'bin/noted_mcp.dart', '--data-dir', data.path],
      runInShell: true,
      environment: environment,
    );
    addTearDown(process.kill);
    final client = MCPClient(Implementation(name: 'test client', version: '0.0.1'));
    final server = client.connectServer(stdioChannel(input: process.stdout, output: process.stdin));
    final init = await server
        .initialize(
          InitializeRequest(
            protocolVersion: ProtocolVersion.latestSupported,
            capabilities: client.capabilities,
            clientInfo: client.implementation,
          ),
        )
        .timeout(const Duration(seconds: 90));
    expect(init.serverInfo.name, 'noted');
    expect(init.serverInfo.version, '0.4.0');
    expect(init.capabilities.tools, isNotNull);
    server.notifyInitialized();
    return server;
  }

  String textOf(CallToolResult r) => (r.content.single as TextContent).text;

  test('a client initializes, lists the six tools and reads an Open page', () async {
    final root = Directory.systemTemp.createTempSync('noted_mcp_stdio');
    addTearDown(() => root.deleteSync(recursive: true));
    final server = await connect(writeFixture(root));

    final tools = await server.listTools(ListToolsRequest());
    expect(tools.tools.map((t) => t.name).toSet(), {
      'list_pages',
      'read_page',
      'read_box',
      'search',
      'write_box',
      'describe_code',
    });

    final read = await server.callTool(CallToolRequest(name: 'read_page', arguments: {'page_id': Ids.publicChild}));
    expect(read.isError, isNot(true));
    expect(textOf(read), contains('zebra socks'));

    final off = await server.callTool(CallToolRequest(name: 'read_page', arguments: {'page_id': Ids.hidden}));
    expect(off.isError, isTrue);
    expect(textOf(off), isNot(contains('Hidden')));

    final noCode = await server.callTool(
      CallToolRequest(name: 'write_box', arguments: {'box_id': 'aiA', 'content': 'x', 'mode': 'append'}),
    );
    expect(noCode.isError, isTrue, reason: 'write_box needs a code');

    await server.shutdown();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('NOTED_TOKEN is ignored, and a code call without Noted running says so', () async {
    final root = Directory.systemTemp.createTempSync('noted_mcp_stdio_nolink');
    addTearDown(() => root.deleteSync(recursive: true));
    final server = await connect(writeFixture(root), environment: {'NOTED_TOKEN': codeR});
    final out = await server.callTool(CallToolRequest(name: 'describe_code', arguments: {'code': codeR}));
    expect(out.isError, isTrue);
    expect(textOf(out), startsWith('This needs Noted running'));
    expect(textOf(out), isNot(contains(codeR)));
    await server.shutdown();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('the process sends its own session id and the client name and version to the app', () async {
    final root = Directory.systemTemp.createTempSync('noted_mcp_stdio_link');
    addTearDown(() => root.deleteSync(recursive: true));
    final data = writeFixture(root);
    final fake = await FakeNoted.start(data);
    addTearDown(fake.close);
    fake.answer = (_) => const AiLinkResponse.described(kind: 'box', id: 'aiA', role: 'writer').encode();
    final server = await connect(data);
    final a = await server.callTool(CallToolRequest(name: 'describe_code', arguments: {'code': codeR}));
    expect(a.isError, isNot(true));
    await server.callTool(CallToolRequest(name: 'describe_code', arguments: {'code': codeR}));
    expect(fake.requests, hasLength(2));
    for (final r in fake.requests) {
      expect(r.app, 'test client 0.0.1');
      expect(r.session.length, greaterThanOrEqualTo(43), reason: '32 random bytes in base64url');
    }
    expect(fake.requests[0].session, fake.requests[1].session, reason: 'one session per process');
    await server.shutdown();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
