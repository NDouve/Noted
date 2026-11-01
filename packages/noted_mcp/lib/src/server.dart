// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';

import 'library.dart';
import 'link_client.dart';
import 'tools.dart';

/// Noted's MCP server (invariant 4): six tools. It reads the saved page
/// files in [dataDir] afresh on every call, so it never answers from
/// anything a running app has on screen or in memory. It writes no file; its
/// only way to change a box is a write request to the running Noted app
/// ([AiLinkClient]), which decides.
///
/// [token] is the AI connection token (`NOTED_TOKEN`). It is never put in any
/// output or error.
base class NotedMcpServer extends MCPServer with ToolsSupport {
  NotedMcpServer(super.channel, {required this.dataDir, this.token})
    : super.fromStreamChannel(
        implementation: Implementation(name: 'noted', version: '0.2.0'),
        instructions:
            'Access to the user\'s Noted pages. Only pages whose AI setting '
            'allows it are visible. Start with list_pages or search, then '
            'read_page. With an AI connection token you also have your own AI '
            'boxes: list_my_boxes lists them and write_box changes one (it '
            'works only while Noted is running). Reads work without Noted '
            'running.',
      ) {
    registerTool(listPagesTool, (_) => _run((t) => t.listPages()));
    registerTool(readPageTool, (r) => _run((t) => t.readPage(_arg(r, 'page_id'))));
    registerTool(readBoxTool, (r) => _run((t) => t.readBox(_arg(r, 'page_id'), _arg(r, 'box_id'))));
    registerTool(searchTool, (r) => _run((t) => t.search(_arg(r, 'query'))));
    registerTool(listMyBoxesTool, (_) => _run((t) => t.listMyBoxes()));
    registerTool(writeBoxTool, _writeBox);
  }

  /// The folder with `settings.json`, `binders.json` and `pages`.
  final Directory dataDir;

  /// The AI connection token, if the server was given one.
  final String? token;

  static String _arg(CallToolRequest r, String name) => '${r.arguments?[name] ?? ''}';

  Future<CallToolResult> _run(ToolOutput Function(NotedTools tools) tool) async {
    final out = tool(NotedTools(await NotedLibrary.load(dataDir), token: token));
    return CallToolResult(content: [TextContent(text: out.text)], isError: out.isError);
  }

  Future<CallToolResult> _writeBox(CallToolRequest r) async {
    final content = r.arguments?['content'];
    final out = content is! String
        ? (text: 'content is required (markdown).', isError: true)
        : await AiLinkClient(dataDir).writeBox(
            token: token,
            boxId: _arg(r, 'box_id'),
            mode: _arg(r, 'mode'),
            content: content,
          );
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
        'files are [drawing], [image: alt text], [file: name]. AI boxes are '
        'markdown too; yours says "your box". On a Box only page you get only '
        'your own boxes.',
    inputSchema: Schema.object(
      properties: {'page_id': Schema.string(description: 'The page id from list_pages or search.')},
      required: ['page_id'],
    ),
    annotations: ToolAnnotations(readOnlyHint: true),
  );

  static final readBoxTool = Tool(
    name: 'read_box',
    description: 'Reads one box of a page, as read_page shows it. On a Box only page only your own boxes can be read.',
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
        'quotes). Returns JSON with page ids and a snippet of each match. On '
        'Box only pages it looks at the title and your own boxes.',
    inputSchema: Schema.object(
      properties: {'query': Schema.string(description: 'Words to find.')},
      required: ['query'],
    ),
    annotations: ToolAnnotations(readOnlyHint: true),
  );

  static final listMyBoxesTool = Tool(
    name: 'list_my_boxes',
    description:
        'Lists your own AI boxes on pages that aren\'t Off, as JSON: page id, '
        'page title, box id and the page\'s AI setting. Needs the AI '
        'connection token (NOTED_TOKEN).',
    inputSchema: Schema.object(),
    annotations: ToolAnnotations(readOnlyHint: true),
  );

  static final writeBoxTool = Tool(
    name: 'write_box',
    description:
        'Writes markdown to one of your own AI boxes. Noted decides and must '
        'be running; if it is not, the write fails (reads still work). '
        '"replace" replaces what you wrote earlier in the box; "append" adds '
        'to the end. Text the user wrote in the box is kept.',
    inputSchema: Schema.object(
      properties: {
        'box_id': Schema.string(description: 'The box id from list_my_boxes.'),
        'content': Schema.string(description: 'The markdown to write.'),
        'mode': Schema.string(description: '"replace" or "append".', enumValues: ['replace', 'append']),
      },
      required: ['box_id', 'content', 'mode'],
    ),
    annotations: ToolAnnotations(readOnlyHint: false, destructiveHint: false),
  );
}
