// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

// The executable itself, over stdio, as Claude Code starts it.
void main() {
  test('a client initializes, lists the four tools and reads a page', () async {
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
    expect(tools.tools.map((t) => t.name).toSet(), {'list_pages', 'read_page', 'read_box', 'search'});

    final read = await server.callTool(CallToolRequest(name: 'read_page', arguments: {'page_id': Ids.publicChild}));
    expect(read.isError, isNot(true));
    expect((read.content.single as TextContent).text, contains('zebra socks'));

    final off = await server.callTool(CallToolRequest(name: 'read_page', arguments: {'page_id': Ids.hidden}));
    expect(off.isError, isTrue);
    expect((off.content.single as TextContent).text, isNot(contains('Hidden')));

    await server.shutdown();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
