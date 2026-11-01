// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  final entry = AiMcpLogEntry(
    time: DateTime.utc(2026, 11, 1, 12, 30),
    code: '0123456789abcdef',
    target: const AiCodeTarget.box('b1', page: 'p1'),
    op: 'write_box',
    app: 'Claude Code',
    label: 'Notes helper',
    result: 'ok',
  );

  test('an entry is one JSON line with the documented fields', () {
    final line = entry.encode();
    expect(line, isNot(contains('\n')));
    expect(jsonDecode(line), {
      'time': '2026-11-01T12:30:00.000Z',
      'code': '0123456789abcdef',
      'target': {'kind': 'box', 'id': 'b1', 'page': 'p1'},
      'op': 'write_box',
      'app': 'Claude Code',
      'label': 'Notes helper',
      'result': 'ok',
    });
    expect(aiMcpLogFileName, 'ai-mcp-log.jsonl');
  });

  test('entries round-trip, with the result values ok, an error code and pending_approval', () {
    for (final result in [aiMcpResultOk, AiLinkCode.notPermitted.wire, AiLinkCode.expired.wire, aiMcpResultPendingApproval]) {
      final e = AiMcpLogEntry.fromJson(
        jsonDecode(
          AiMcpLogEntry(
            time: entry.time,
            code: entry.code,
            target: entry.target,
            op: 'read_page',
            result: result,
          ).encode(),
        ),
      )!;
      expect(e.result, result);
      expect(e.isOk, result == 'ok');
      expect(e.isPendingApproval, result == 'pending_approval');
      expect(e.op, 'read_page');
      expect(e.app, '');
      expect(e.label, '');
      expect(e.time, entry.time);
      expect(e.target, entry.target);
    }
    expect(aiMcpResultPendingApproval, 'pending_approval');
  });

  test('a target without a page, and other kinds, parse', () {
    final e = AiMcpLogEntry.fromJson({
      'time': '2026-11-01T00:00:00Z',
      'code': 'c',
      'target': {'kind': 'page', 'id': 'p'},
      'op': 'search',
      'result': 'ok',
    })!;
    expect(e.target.kindName, 'page');
    expect(e.target.page, isNull);
  });

  test('the parser skips bad lines and keeps the rest in order', () {
    final good1 = entry.encode();
    final good2 = AiMcpLogEntry(
      time: DateTime.utc(2026, 11, 2),
      code: 'fedcba9876543210',
      target: const AiCodeTarget.box('b2'),
      op: 'write_box',
      result: aiMcpResultPendingApproval,
    ).encode();
    final text = [
      good1,
      '',
      '   ',
      'not json',
      '[1,2]',
      '{"time":"bad","code":"c","target":{"kind":"box","id":"b"},"op":"x","result":"ok"}',
      '{"time":"2026-11-01T00:00:00Z","code":"c","target":{"kind":"box"},"op":"x","result":"ok"}',
      '{"time":"2026-11-01T00:00:00Z","code":"c","target":{"kind":"box","id":"b"},"op":"x"}',
      '{"time":"2026-11-01T00:00:00Z","code":"","target":{"kind":"box","id":"b"},"op":"x","result":"ok"}',
      good2,
      '{"time":"2026-11-01T00:00:00Z","code":"c","target":{"kind":"box","id":"b"},"op":"x","res',
    ].join('\r\n');
    final entries = parseAiMcpLog(text);
    expect(entries.map((e) => e.code), ['0123456789abcdef', 'fedcba9876543210']);
    expect(entries.last.isPendingApproval, isTrue);
    expect(parseAiMcpLog(''), isEmpty);
    expect(parseAiMcpLog('\n\n'), isEmpty);
    expect(parseAiMcpLog('﻿$good1\n').single.label, 'Notes helper');
  });

  test('extra fields on a line are ignored', () {
    final json = jsonDecode(entry.encode()) as Map<String, Object?>;
    json['future'] = {'x': 1};
    expect(parseAiMcpLog(jsonEncode(json)).single.code, entry.code);
  });
}
