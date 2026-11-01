// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_box_ai/noted_box_ai.dart';
import 'package:noted_core/noted_core.dart';

/// The real noted_mcp executable over stdio, spoken to with plain JSON-RPC
/// lines, as Claude Code does.
class _Mcp {
  _Mcp(this.process) {
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final Object? msg;
      try {
        msg = jsonDecode(line);
      } on FormatException {
        return;
      }
      if (msg is! Map || msg['id'] is! int) return;
      _pending.remove(msg['id'])?.complete(msg.cast<String, Object?>());
    });
    process.stderr.drain<void>();
  }

  final Process process;
  final _pending = <int, Completer<Map<String, Object?>>>{};
  var _next = 1;

  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> params, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    final id = _next++;
    final c = _pending[id] = Completer();
    process.stdin.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
    return c.future.timeout(timeout);
  }

  // The first answer waits for `dart run` to compile the server.
  Future<void> start() async {
    final init = await request('initialize', {
      'protocolVersion': '2025-06-18',
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'noted end-to-end test', 'version': '0'},
    }, timeout: const Duration(seconds: 60));
    expect(init['result'], isA<Map<String, Object?>>());
    process.stdin.writeln(jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
  }

  /// Calls [tool]; returns (isError, text).
  Future<(bool, String)> call(String tool, [Map<String, Object?> args = const {}]) async {
    final r = await request('tools/call', {'name': tool, 'arguments': args});
    final result = r['result']! as Map;
    final text = [for (final c in result['content']! as List) (c as Map)['text']].join('\n');
    return (result['isError'] == true, text);
  }
}

void main() {
  test('the real app link and the real noted_mcp over stdio write into an AI box', () async {
    final root = await Directory.systemTemp.createTemp('noted_ai_e2e');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final data = await Directory('${root.path}/data').create();
    final settings = AppSettings(File('${data.path}/settings.json'));
    final token = await settings.addAiConnection('Claude Code');
    final connId = parseAiToken(token)!.id;

    final nb = Notebook(
      PageStore(Directory('${data.path}/pages')),
      buildModules(aiConnections: settings.aiConnections),
      saveDelay: Duration.zero,
      bindersFile: File('${data.path}/binders.json'),
      settings: settings,
    );
    await nb.load();
    final pageId = nb.currentId!;
    await nb.setAiSetting(pageId, AiSetting.boxOnly);
    const codec = AiCodec();
    nb.current!.insertBox(
      BoxRecord.create(
        id: 'aibox',
        typeId: aiBoxTypeId,
        dataVersion: codec.dataVersion,
        bounds: const Bounds(40, 40, 400, 120),
        data: RawJson.encode(codec.encode(codec.create().withOwner(connId))),
        snapshotText: '',
        rev: 'r0',
      ),
    );
    await nb.flush();

    final link = (await startAiLink(nb, data))!;
    var linkStopped = false;
    addTearDown(() async {
      if (!linkStopped) await link.dispose();
      await nb.flush();
      nb.dispose();
    });

    final process = await Process.start(
      'dart',
      ['run', 'bin/noted_mcp.dart', '--data-dir', data.path],
      workingDirectory: '../packages/noted_mcp',
      runInShell: true,
      environment: {'NOTED_TOKEN': token},
    );
    // With runInShell, kill() would end only the shell: close stdin so the
    // server exits and lets go of the data folder, and kill it if it hangs.
    addTearDown(() async {
      await process.stdin.close();
      await process.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
    });
    final mcp = _Mcp(process);
    await mcp.start();

    final (mineError, mine) = await mcp.call('list_my_boxes');
    expect(mineError, isFalse, reason: mine);
    expect(mine, contains('aibox'));

    // The write goes through the app: it shows in the open page at once,
    // marked AI-written, and is one undo step.
    final (writeError, written) = await mcp.call('write_box', {
      'box_id': 'aibox',
      'content': '# Plan\n\nShip the **AI box**.',
      'mode': 'replace',
    });
    expect(writeError, isFalse, reason: written);
    expect(written, isNot(contains(token)));
    String shown() => (nb.current!.page.node('aibox')! as BoxRecord).snapshotText;
    expect(shown(), contains('Ship the **AI box**.'));
    final open = codec.decode((nb.current!.page.node('aibox')! as BoxRecord).data!.decode(), 1);
    expect(open.json[aiOwnerKey], connId);
    final blocks = ((open.json['document']! as Map)['children']! as List).cast<Map<Object?, Object?>>();
    expect(blocks.where(isAiWritten), hasLength(2), reason: 'the heading and the paragraph');

    // The saved file is what the server reads back: Box only shows the AI's
    // own box, with its AI-written text marked.
    final (readError, read) = await mcp.call('read_page', {'page_id': pageId});
    expect(readError, isFalse, reason: read);
    expect(read, contains('<ai-written>'));
    expect(read, contains('Ship the **AI box**.'));

    final (appendError, appended) = await mcp.call('write_box', {
      'box_id': 'aibox',
      'content': 'And test it.',
      'mode': 'append',
    });
    expect(appendError, isFalse, reason: appended);
    expect(shown(), allOf(contains('Ship the **AI box**.'), contains('And test it.')));
    nb.current!.undo();
    expect(shown(), contains('Ship the **AI box**.'));
    expect(shown(), isNot(contains('And test it.')));

    // Rejected: a box that doesn't exist, a box another connection owns, and
    // any write after revocation.
    final (noBoxError, noBox) = await mcp.call('write_box', {'box_id': 'nope', 'content': 'x', 'mode': 'replace'});
    expect(noBoxError, isTrue, reason: noBox);
    final other = parseAiToken(await settings.addAiConnection('Other'))!.id;
    nb.current!.insertBox(
      BoxRecord.create(
        id: 'otherbox',
        typeId: aiBoxTypeId,
        dataVersion: codec.dataVersion,
        bounds: const Bounds(40, 300, 400, 120),
        data: RawJson.encode(codec.encode(codec.create().withOwner(other))),
        snapshotText: '',
        rev: 'r1',
      ),
    );
    await nb.flush();
    final (notMineError, notMine) = await mcp.call('write_box', {
      'box_id': 'otherbox',
      'content': 'x',
      'mode': 'replace',
    });
    expect(notMineError, isTrue, reason: notMine);
    expect((nb.current!.page.node('otherbox')! as BoxRecord).snapshotText, '');
    final beforeRevoke = shown();
    settings.revokeAiConnection(connId);
    final (revokedError, revoked) = await mcp.call('write_box', {'box_id': 'aibox', 'content': 'x', 'mode': 'replace'});
    expect(revokedError, isTrue, reason: revoked);
    expect(revoked, contains('revoked'));
    expect(shown(), beforeRevoke, reason: 'nothing written');

    // The app stops: writes fail cleanly, reads still work.
    await link.dispose();
    linkStopped = true;
    final (downError, down) = await mcp.call('write_box', {'box_id': 'aibox', 'content': 'x', 'mode': 'replace'});
    expect(downError, isTrue);
    expect(down, contains("isn't running"));
    final (listError, _) = await mcp.call('list_pages');
    expect(listError, isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
