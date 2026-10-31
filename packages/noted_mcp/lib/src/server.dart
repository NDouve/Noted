// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';

import 'library.dart';
import 'tools.dart';

/// Noted's read-only MCP server (invariant 4): four tools over the saved
/// page files in [dataDir]. Every call reads the files afresh, so it never
/// answers from anything a running app has on screen or in memory.
base class NotedMcpServer extends MCPServer with ToolsSupport {
  NotedMcpServer(super.channel, {required this.dataDir})
    : super.fromStreamChannel(
        implementation: Implementation(name: 'noted', version: '0.1.0'),
        instructions:
            'Read-only access to the user\'s Noted pages. Only pages whose AI '
            'setting allows it are visible. Start with list_pages or search, '
            'then read_page.',
      ) {
    registerTool(listPagesTool, (_) => _run((t) => t.listPages()));
    registerTool(readPageTool, (r) => _run((t) => t.readPage(_arg(r, 'page_id'))));
    registerTool(readBoxTool, (r) => _run((t) => t.readBox(_arg(r, 'page_id'), _arg(r, 'box_id'))));
    registerTool(searchTool, (r) => _run((t) => t.search(_arg(r, 'query'))));
  }

  /// The folder with `settings.json`, `binders.json` and `pages`.
  final Directory dataDir;

  static String _arg(CallToolRequest r, String name) => '${r.arguments?[name] ?? ''}';

  Future<CallToolResult> _run(ToolOutput Function(NotedTools tools) tool) async {
    final out = tool(NotedTools(await NotedLibrary.load(dataDir)));
    return CallToolResult(content: [TextContent(text: out.text)], isError: out.isError);
  }

  static final listPagesTool = Tool(
    name: 'list_pages',
    description:
        'Lists the Noted pages AI may see, as JSON: id, title, parent page id, '
        'AI setting ("box" or "page") and folder or binder.',
    inputSchema: Schema.object(),
    annotations: ToolAnnotations(readOnlyHint: true),
  );

  static final readPageTool = Tool(
    name: 'read_page',
    description:
        'Reads a page as markdown: its title, then each box top to bottom and '
        'left to right with its type. Notes are markdown; drawings, images and '
        'files are [drawing], [image: alt text], [file: name].',
    inputSchema: Schema.object(
      properties: {'page_id': Schema.string(description: 'The page id from list_pages or search.')},
      required: ['page_id'],
    ),
    annotations: ToolAnnotations(readOnlyHint: true),
  );

  static final readBoxTool = Tool(
    name: 'read_box',
    description: 'Reads one box of a page, as read_page shows it.',
    inputSchema: Schema.object(
      properties: {
        'page_id': Schema.string(description: 'The page id.'),
        'box_id': Schema.string(description: 'The box id from read_page.'),
      },
      required: ['page_id', 'box_id'],
    ),
    annotations: ToolAnnotations(readOnlyHint: true),
  );

  static final searchTool = Tool(
    name: 'search',
    description:
        'Finds pages whose title or text holds every word (put a phrase in '
        'quotes). Returns JSON with page ids and a snippet of each match.',
    inputSchema: Schema.object(
      properties: {'query': Schema.string(description: 'Words to find.')},
      required: ['query'],
    ),
    annotations: ToolAnnotations(readOnlyHint: true),
  );
}
