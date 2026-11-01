// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';

import 'toolbox.dart';
import 'tools.dart';

/// Noted's MCP server (invariant 4): eight tools. It reads the saved page
/// files in [dataDir] afresh on every call, so it never answers from
/// anything a running app has on screen or in memory. While Noted runs, a
/// call with a code is checked by the app ([NotedToolbox]) and a write is a
/// request to that app, which decides. While Noted is closed the server
/// checks the code against the saved store itself, and writes only its access
/// log and an AI box that allows closed-app writes.
///
/// Each process makes a random session id at start and sends it, with the
/// MCP client's name, on every request to the app: the app asks the user to
/// allow a code the first time it is used from a session.
base class NotedMcpServer extends MCPServer with ToolsSupport {
  NotedMcpServer(
    super.channel, {
    required Directory dataDir,
    String? session,
    Duration? connectTimeout,
    Duration? greetingTimeout,
    Duration? responseTimeout,
  }) : toolbox = NotedToolbox(
         dataDir,
         session: session,
         connectTimeout: connectTimeout,
         greetingTimeout: greetingTimeout,
         responseTimeout: responseTimeout,
       ),
       super.fromStreamChannel(
         implementation: Implementation(name: 'noted', version: '0.5.0'),
         instructions:
             'Access to the user\'s Noted pages. Without a code you see only '
             'pages the user set to Open, and boxes only by their id. If the '
             'user gave you a code (it starts with noted_), pass it as "code" '
             'on every call: a page or binder code also lets you read the '
             'Privileged pages it covers, and a box code lets you read (and, '
             'for a Writer code, write) one AI box. Start with list_pages or '
             'search, then read_page. While Noted runs it checks codes; while '
             'it is closed the server checks them against the saved codes, '
             'and the user must have approved the code in Noted once '
             '(otherwise it asks you to have them open Noted). Writes while '
             'Noted is closed work only for a box the user allowed that for. If the '
             'user asks you to help with a Noted sync conflict, call '
             'merge_requests with the page or binder code, merge the two '
             'versions, and send the result with propose_merge.',
       ) {
    registerTool(listPagesTool, (r) => _run(() => toolbox.listPages(code: _opt(r, 'code'))));
    registerTool(readPageTool, (r) => _run(() => toolbox.readPage(_arg(r, 'page_id'), code: _opt(r, 'code'))));
    registerTool(readBoxTool, (r) => _run(() => toolbox.readBox(_arg(r, 'box_id'), code: _opt(r, 'code'), pageId: _opt(r, 'page_id'))));
    registerTool(searchTool, (r) => _run(() => toolbox.search(_arg(r, 'query'), code: _opt(r, 'code'))));
    registerTool(writeBoxTool, _writeBox);
    registerTool(describeCodeTool, (r) => _run(() => toolbox.describeCode(_opt(r, 'code'))));
    registerTool(mergeRequestsTool, (r) => _run(() => toolbox.mergeRequests(_opt(r, 'code'))));
    registerTool(proposeMergeTool, _proposeMerge);
  }

  /// The tools' implementation, with this process's session id.
  final NotedToolbox toolbox;

  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) {
    toolbox.app = appLabel(request.clientInfo.name, request.clientInfo.version);
    return super.initialize(request);
  }

  static String _arg(CallToolRequest r, String name) => '${r.arguments?[name] ?? ''}';

  static String? _opt(CallToolRequest r, String name) {
    final v = r.arguments?[name];
    return v is String ? v : null;
  }

  Future<CallToolResult> _run(Future<ToolOutput> Function() tool) async {
    final out = await tool();
    return CallToolResult(content: [TextContent(text: out.text)], isError: out.isError);
  }

  Future<CallToolResult> _writeBox(CallToolRequest r) {
    final content = r.arguments?['content'];
    return _run(
      () async => content is! String
          ? (text: 'content is required (markdown).', isError: true)
          : toolbox.writeBox(
              boxId: _arg(r, 'box_id'),
              code: _opt(r, 'code'),
              mode: _arg(r, 'mode'),
              content: content,
            ),
    );
  }

  Future<CallToolResult> _proposeMerge(CallToolRequest r) {
    final content = r.arguments?['content'];
    return _run(
      () async => content is! String
          ? (text: 'content is required (the merged markdown).', isError: true)
          : toolbox.proposeMerge(code: _opt(r, 'code'), requestId: _arg(r, 'request_id'), content: content),
    );
  }

  static final Schema _codeProperty = Schema.string(
    description:
        'The code the user gave you (starts with noted_). Pass it on every call '
        'you were given one for.',
  );

  static final listPagesTool = Tool(
    name: 'list_pages',
    description:
        'Lists the Noted pages you may see, as JSON: id, title, parent page id, '
        'access (open or privileged) and folder or binder. Without a code that '
        'is the Open pages; with the code the user gave you for a page or '
        'binder, also the pages it covers. A box code does not list pages.',
    inputSchema: Schema.object(properties: {'code': _codeProperty}),
    annotations: ToolAnnotations(readOnlyHint: true),
  );

  static final readPageTool = Tool(
    name: 'read_page',
    description:
        'Reads a page as markdown: its title, then each box top to bottom and '
        'left to right, each with its type and box id. Notes are markdown; '
        'drawings, images and files are [drawing], [image: alt text], [file: '
        'name]. AI boxes are markdown too, and what an AI wrote is marked '
        '<ai-written>. Pass the code the user gave you for a Privileged page '
        'or its binder. You see boxes only by their id.',
    inputSchema: Schema.object(
      properties: {
        'page_id': Schema.string(description: 'The page id from list_pages or search.'),
        'code': _codeProperty,
      },
      required: ['page_id'],
    ),
    annotations: ToolAnnotations(readOnlyHint: true),
  );

  static final readBoxTool = Tool(
    name: 'read_box',
    description:
        'Reads one box by its id, as read_page shows it. With a box code the '
        'user gave you (a Reader or Writer code) this reads that AI box and '
        'tells you nothing about its page. Without a code it reads a box on '
        'an Open page.',
    inputSchema: Schema.object(
      properties: {
        'box_id': Schema.string(description: 'The box id.'),
        'page_id': Schema.string(
          description: 'The page the box is on (box ids are only unique per page). Optional; a box code ignores it.',
        ),
        'code': _codeProperty,
      },
      required: ['box_id'],
    ),
    annotations: ToolAnnotations(readOnlyHint: true),
  );

  static final searchTool = Tool(
    name: 'search',
    description:
        'Finds pages whose title or text holds every word (put a phrase in '
        'quotes). Returns JSON with page ids and a snippet of each match. It '
        'looks only at the pages you can read: the Open ones, and with a page '
        'or binder code the pages it covers.',
    inputSchema: Schema.object(
      properties: {'query': Schema.string(description: 'Words to find.'), 'code': _codeProperty},
      required: ['query'],
    ),
    annotations: ToolAnnotations(readOnlyHint: true),
  );

  static final writeBoxTool = Tool(
    name: 'write_box',
    description:
        'Writes markdown to an AI box with the Writer code the user gave you '
        'for it. While Noted runs it decides (the user may have to allow this '
        'code or each write); while Noted is closed the write goes through '
        'only if the user allowed closed-app writes for the box. The user '
        'sets what a Writer code may do per box (its Writer permission): '
        '"append" adds to the end and is always allowed; "replace_ai" '
        'replaces only the text you wrote earlier and needs Edit or Full '
        'permission; "replace" replaces the whole box (empty content empties '
        'it) and needs Full permission. A mode the box does not allow fails '
        'with not_permitted; do not retry it, ask the user to change the '
        'permission. Text the user wrote in the box is kept except with '
        '"replace". Fenced code blocks and raw HTML become plain paragraphs.',
    inputSchema: Schema.object(
      properties: {
        'box_id': Schema.string(description: 'The id of the AI box.'),
        'code': Schema.string(description: 'The Writer code the user gave you for this box.'),
        'content': Schema.string(description: 'The markdown to write.'),
        'mode': Schema.string(
          description:
              '"append" (add to the end), "replace_ai" (replace only your own earlier text; needs Edit or '
              'Full permission) or "replace" (replace the whole box; needs Full permission).',
          enumValues: ['append', 'replace_ai', 'replace'],
        ),
      },
      required: ['box_id', 'code', 'content', 'mode'],
    ),
    annotations: ToolAnnotations(readOnlyHint: false, destructiveHint: false),
  );

  static final mergeRequestsTool = Tool(
    name: 'merge_requests',
    description:
        'Call this when the user asks you to help with a Noted sync conflict '
        '(two computers changed the same box and Noted could not combine '
        'them). Lists the merges the user asked for that the page or binder '
        'code covers, as JSON: request id, page id, box id, box type and the '
        'two versions as markdown ("mine" is the version on the user\'s '
        'computer, "theirs" the other one), each with the computer name and '
        'time it was saved. An AI box keeps <ai-written> lines around what an '
        'AI wrote; keep those lines in your merge. Then merge the two '
        'versions yourself, keeping everything that either side added, and '
        'send the result with propose_merge. A request lasts 10 minutes. '
        'Needs Noted running and a page or binder code (a Reader code is '
        'enough). Nothing here changes any page.',
    inputSchema: Schema.object(
      properties: {
        'code': Schema.string(description: 'The page or binder code the user gave you.'),
      },
      required: ['code'],
    ),
    annotations: ToolAnnotations(readOnlyHint: true),
  );

  static final proposeMergeTool = Tool(
    name: 'propose_merge',
    description:
        'Sends the merged markdown for a request from merge_requests. It is '
        'only a proposal: the user sees it next to both versions in Noted and '
        'chooses whether to use it, so nothing changes until they accept. '
        'Write the whole merged box (not a diff); text that is the same in a '
        'version is kept as it was. <ai-written> lines are ignored: Noted decides what counts as AI-written. '
        'Needs Noted running and the same code as merge_requests (a Reader '
        'code is enough). One proposal answers a request; a request that has '
        'expired or was withdrawn fails with no_request.',
    inputSchema: Schema.object(
      properties: {
        'code': Schema.string(description: 'The page or binder code the user gave you.'),
        'request_id': Schema.string(description: 'The request id from merge_requests.'),
        'content': Schema.string(description: 'The merged box content, as markdown.'),
      },
      required: ['code', 'request_id', 'content'],
    ),
    annotations: ToolAnnotations(readOnlyHint: false, destructiveHint: false),
  );

  static final describeCodeTool = Tool(
    name: 'describe_code',
    description:
        'Asks Noted what a code the user gave you covers: a box, a page or a '
        'binder (by id), your role (reader or writer) and when it expires. '
        'Needs Noted running.',
    inputSchema: Schema.object(
      properties: {'code': Schema.string(description: 'The code the user gave you.')},
      required: ['code'],
    ),
    annotations: ToolAnnotations(readOnlyHint: true),
  );
}
