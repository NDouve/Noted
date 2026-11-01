// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ai_test.dart' show tokenA, writeAiFixture;
import 'fixture.dart';

// The executable itself, over stdio, as Claude Code starts it.
void main() {
  test('a client initializes, lists the six tools and reads a page', () async {
    final root = Directory.systemTemp.createTempSync('noted_mcp_stdio');
    addTearDown(() => root.deleteSync(recursive: true));
    final data = writeFixture(root);
    final process = await Process.start('dart', ['run', 'bin/noted_mcp.dart', '--data-dir', data.path], runInShell: true);
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
    expect(init.capabilities.tools, isNotNull);
    server.notifyInitialized();

    final tools = await server.listTools(ListToolsRequest());
    expect(tools.tools.map((t) => t.name).toSet(), {'list_pages', 'read_page', 'read_box', 'search', 'list_my_boxes', 'write_box'});

    final read = await server.callTool(CallToolRequest(name: 'read_page', arguments: {'page_id': Ids.publicChild}));
    expect(read.isError, isNot(true));
    expect((read.content.single as TextContent).text, contains('zebra socks'));

    final off = await server.callTool(CallToolRequest(name: 'read_page', arguments: {'page_id': Ids.hidden}));
    expect(off.isError, isTrue);
    expect((off.content.single as TextContent).text, isNot(contains('Hidden')));

    await server.shutdown();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('NOTED_TOKEN in the environment gives list_my_boxes the AI\'s own boxes', () async {
    final root = Directory.systemTemp.createTempSync('noted_mcp_stdio_token');
    addTearDown(() => root.deleteSync(recursive: true));
    final data = writeAiFixture(root);
    final process = await Process.start(
      'dart',
      ['run', 'bin/noted_mcp.dart', '--data-dir', data.path],
      runInShell: true,
      environment: {'NOTED_TOKEN': tokenA},
    );
    addTearDown(process.kill);
    final client = MCPClient(Implementation(name: 'test client', version: '0.0.1'));
    final server = client.connectServer(stdioChannel(input: process.stdout, output: process.stdin));
    await server
        .initialize(
          InitializeRequest(
            protocolVersion: ProtocolVersion.latestSupported,
            capabilities: client.capabilities,
            clientInfo: client.implementation,
          ),
        )
        .timeout(const Duration(seconds: 90));
    server.notifyInitialized();
    final mine = await server.callTool(CallToolRequest(name: 'list_my_boxes'));
    expect(mine.isError, isNot(true));
    final text = (mine.content.single as TextContent).text;
    expect(text, contains('aiA2'));
    expect(text, isNot(contains('aiB')));
    expect(text, isNot(contains(tokenA)));
    await server.shutdown();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
