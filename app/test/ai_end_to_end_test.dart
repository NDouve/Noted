// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/ai/ai_access_service.dart';
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
    _transcribe(tool, args, result['isError'] == true, text);
    return (result['isError'] == true, text);
  }

  // With NOTED_E2E_TRANSCRIPT set to a file path, each call and answer is
  // appended there, with codes replaced by a placeholder (for run reports).
  void _transcribe(String tool, Map<String, Object?> args, bool isError, String text) {
    final path = Platform.environment['NOTED_E2E_TRANSCRIPT'];
    if (path == null || path.isEmpty) return;
    String hide(String s) => s.replaceAll(RegExp(r'noted_[0-9a-f]{16}_[A-Za-z0-9_-]+'), '<code>');
    final answer = text.split('\n').map((l) => '<< ${hide(l)}').join('\n');
    File(path).writeAsStringSync(
      '>> $tool ${hide(jsonEncode(args))}\n${isError ? '<< (error)\n' : ''}$answer\n',
      mode: FileMode.append,
    );
  }
}

void main() {
  test('the real app link and the real noted_mcp over stdio: codes, approval, a write, reads', () async {
    final root = await Directory.systemTemp.createTemp('noted_ai_e2e');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final data = await Directory('${root.path}/data').create();
    final service = AiAccessService(dataFolder: data);
    addTearDown(service.dispose);

    final nb = Notebook(
      PageStore(Directory('${data.path}/pages')),
      buildModules(aiAccess: service),
      saveDelay: Duration.zero,
      bindersFile: File('${data.path}/binders.json'),
      aiAccess: service,
    );
    final approvals = <String>[];
    nb.aiApprover = (r) async {
      approvals.add(r.message);
      return true;
    };
    await nb.load();
    final pageId = nb.currentId!;
    const codec = AiCodec();
    nb.current!.insertBox(
      BoxRecord.create(
        id: 'aibox',
        typeId: aiBoxTypeId,
        dataVersion: codec.dataVersion,
        bounds: const Bounds(40, 40, 400, 120),
        data: RawJson.encode(codec.encode(codec.create())),
        snapshotText: '',
        rev: 'r0',
      ),
    );
    await nb.flush();
    final writer = await service.connect('aibox', role: AiCodeRole.writer, label: 'Feedback chat');
    await service.setWriterPermission('aibox', AiWriterPermission.full); // the writes below replace the box
    final reader = await service.connect('aibox', role: AiCodeRole.reader, label: 'Review chat');

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

    // What a code is.
    final (describeError, described) = await mcp.call('describe_code', {'code': writer});
    expect(describeError, isFalse, reason: described);
    expect(described, allOf(contains('aibox'), contains('writer')));
    expect(described, isNot(contains(pageId)), reason: 'a box code names no page');

    // The write goes through the app after the user allows the new session:
    // it shows in the open page at once, marked AI-written, as one undo step.
    final (writeError, written) = await mcp.call('write_box', {
      'box_id': 'aibox',
      'code': writer,
      'content': '# Plan\n\nShip the **AI box**.',
      'mode': 'replace',
    });
    expect(writeError, isFalse, reason: written);
    expect(written, isNot(contains(writer)));
    expect(approvals, ['noted end-to-end test 0 wants to read and write the AI box (code "Feedback chat"). Allow?']);
    String shown() => (nb.current!.page.node('aibox')! as BoxRecord).snapshotText;
    expect(shown(), contains('Ship the **AI box**.'));
    final open = codec.decode((nb.current!.page.node('aibox')! as BoxRecord).data!.decode(), 1);
    final blocks = ((open.json['document']! as Map)['children']! as List).cast<Map<Object?, Object?>>();
    expect(blocks.where(isAiWritten), hasLength(2), reason: 'the heading and the paragraph');

    // A Reader code reads the box from the saved file; it can't write.
    final (readError, read) = await mcp.call('read_box', {'box_id': 'aibox', 'code': reader});
    expect(readError, isFalse, reason: read);
    expect(read, contains('Ship the **AI box**.'));
    final (readerWriteError, _) = await mcp.call('write_box', {
      'box_id': 'aibox',
      'code': reader,
      'content': 'x',
      'mode': 'replace',
    });
    expect(readerWriteError, isTrue);

    // The page is Guarded: invisible to an AI without a code, and to a box code.
    final (guardedError, _) = await mcp.call('read_page', {'page_id': pageId});
    expect(guardedError, isTrue);
    final (boxCodePageError, _) = await mcp.call('read_page', {'page_id': pageId, 'code': reader});
    expect(boxCodePageError, isTrue);

    // Privileged: a page code reads it, nothing else does.
    await nb.setAiAccess(pageId, AiAccess.privileged);
    await nb.flush();
    final pageCode = await service.issue(AiCodeTarget.page(pageId), role: AiCodeRole.reader, label: 'Notes chat');
    final (withCodeError, withCode) = await mcp.call('read_page', {'page_id': pageId, 'code': pageCode});
    expect(withCodeError, isFalse, reason: withCode);
    expect(withCode, contains('<ai-written>'));
    final (privNoCodeError, _) = await mcp.call('read_page', {'page_id': pageId});
    expect(privNoCodeError, isTrue);

    // Open: anyone reads it without a code.
    await nb.setAiAccess(pageId, AiAccess.open);
    await nb.flush();
    final (openError, openText) = await mcp.call('read_page', {'page_id': pageId});
    expect(openError, isFalse, reason: openText);
    expect(openText, contains('Ship the **AI box**.'));

    // Revoked: the write is refused and nothing changes.
    final beforeRevoke = shown();
    await service.revoke(parseAiToken(writer)!.id);
    final (revokedError, _) = await mcp.call('write_box', {
      'box_id': 'aibox',
      'code': writer,
      'content': 'x',
      'mode': 'replace',
    });
    expect(revokedError, isTrue);
    expect(shown(), beforeRevoke);

    // Noted closes (its link stops, and this test holds no running lock):
    // noted_mcp checks approved codes itself against the saved store.
    // The app leaves its lock file in the data folder; without it a closed write is refused.
    File('${data.path}/noted-running.lock').writeAsStringSync('');
    await nb.flush();
    await link.dispose();
    linkStopped = true;
    // A Reader read from the saved page.
    final (closedReadError, closedRead) = await mcp.call('read_box', {'box_id': 'aibox', 'code': reader});
    expect(closedReadError, isFalse, reason: closedRead);
    expect(closedRead, contains('Ship the **AI box**.'));
    // A new Writer, approved in Noted beforehand; the box doesn't allow
    // writes while Noted is closed yet, so the write is refused.
    final writer2 = await service.connect('aibox', role: AiCodeRole.writer, label: 'Feedback chat 2');
    service.store.approveCode(parseAiToken(writer2)!.id);
    final pageFile = File('${data.path}/pages/$pageId.canvas');
    final beforeClosed = pageFile.readAsStringSync();
    final (offError, off) = await mcp.call('write_box', {
      'box_id': 'aibox',
      'code': writer2,
      'content': 'Written while Noted was closed.',
      'mode': 'append',
    });
    expect(offError, isTrue, reason: off);
    expect(pageFile.readAsStringSync(), beforeClosed, reason: 'nothing written');
    // With the switch on, an Append-only write lands in the page file.
    await service.setWriterPermission('aibox', AiWriterPermission.append);
    await service.setClosedWrites('aibox', true);
    final (onError, on) = await mcp.call('write_box', {
      'box_id': 'aibox',
      'code': writer2,
      'content': 'Written while Noted was closed.',
      'mode': 'append',
    });
    expect(onError, isFalse, reason: on);
    expect(pageFile.readAsStringSync(), contains('Written while Noted was closed.'));
    // Append only: replacing is refused.
    final (replaceError, replaced) = await mcp.call('write_box', {
      'box_id': 'aibox',
      'code': writer2,
      'content': 'x',
      'mode': 'replace',
    });
    expect(replaceError, isTrue, reason: replaced);
    final (listError, _) = await mcp.call('list_pages');
    expect(listError, isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));
}