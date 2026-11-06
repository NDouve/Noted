// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Test helper, run as its own process from the package folder (the app's
// reload-equivalence probe starts it, so the app doesn't depend on noted_mcp):
// a real `NotedToolbox` makes one closed `write_box`, with the hold limit at
// 60 s, and reports what happens on standard output, one line each:
//
//   at-hold      the write reached `beforeClosedHold` (before it takes the lock)
//   at-replace   it reached `beforeClosedReplace` (holding the lock)
//   send:N       it sent a write to the link (the Nth send)
//   result:JSON  {"error": bool, "text": "..."}, then the process exits
//
// With `pause-hold` or `pause-replace` the write waits at that point for a
// line on standard input.
//
//   closed_write_child.dart <data dir> <box id> <code> <mode> <content> [pause-hold] [pause-replace]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:noted_mcp/noted_mcp.dart';

Future<void> main(List<String> args) async {
  final data = Directory(args[0]);
  final pauseHold = args.contains('pause-hold');
  final pauseReplace = args.contains('pause-replace');
  final input = StreamIterator(stdin.transform(utf8.decoder).transform(const LineSplitter()));
  Future<void> say(String line) async {
    stdout.writeln(line);
    await stdout.flush();
  }

  Future<void> hook(String name, bool pause) async {
    await say(name);
    if (pause) await input.moveNext();
  }

  final toolbox = NotedToolbox(
    data,
    session: 'child',
    app: 'closed write child',
    closedHoldLimit: const Duration(seconds: 60),
    beforeClosedHold: (_) => hook('at-hold', pauseHold),
    beforeClosedReplace: (_) => hook('at-replace', pauseReplace),
    onLinkSend: (n) => stdout.writeln('send:$n'),
  );
  final out = await toolbox.writeBox(boxId: args[1], code: args[2], mode: args[3], content: args[4]);
  await say('result:${jsonEncode({'error': out.isError, 'text': out.text})}');
  exit(0);
}
