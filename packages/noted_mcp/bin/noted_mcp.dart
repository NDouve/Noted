// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Noted's read-only MCP server, over stdio. See docs/mcp.md.
//
//   noted_mcp [--data-dir <folder with settings.json and binders.json>]

import 'dart:io';

import 'package:dart_mcp/stdio.dart';
import 'package:noted_mcp/noted_mcp.dart';

void main(List<String> args) {
  final i = args.indexOf('--data-dir');
  final dataDir = i >= 0 && i + 1 < args.length ? Directory(args[i + 1]) : defaultDataDirectory();
  NotedMcpServer(stdioChannel(input: stdin, output: stdout), dataDir: dataDir);
}
