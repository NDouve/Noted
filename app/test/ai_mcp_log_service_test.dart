// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/ai/ai_access_service.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory data;
  late AiAccessService service;

  setUp(() {
    data = Directory.systemTemp.createTempSync('noted_mcplog');
    service = AiAccessService(dataFolder: data);
  });

  tearDown(() {
    service.dispose();
    data.deleteSync(recursive: true);
  });

  AiMcpLogEntry entry(
    int second, {
    AiCodeTarget? target,
    String result = 'ok',
    String op = 'write_box',
  }) => AiMcpLogEntry(
    time: DateTime.utc(2026, 11, 1, 10, 0, second),
    code: 'c1',
    target: target ?? const AiCodeTarget.box('b1', page: 'p1'),
    op: op,
    app: 'Claude Code',
    label: 'Chat',
    result: result,
  );

  void append(Iterable<AiMcpLogEntry> entries) {
    service.mcpLog.writeAsStringSync(
      [for (final e in entries) '${e.encode()}\n'].join(),
      mode: FileMode.append,
    );
  }

  group('activity', () {
    test('merges the server log into a box\'s activity, marked closed, sorted by time', () {
      service.log.append(
        AiActivityEntry(
          time: DateTime.utc(2026, 11, 1, 10, 0, 5),
          code: 'c1',
          target: const AiCodeTarget.box('b1'),
          op: 'read_box',
          app: 'App',
          label: 'Chat',
          result: 'ok',
        ),
      );
      append([entry(9), entry(1), entry(3, target: const AiCodeTarget.box('other'))]);
      final merged = service.activity('b1');
      expect(merged.map((e) => (e.time.second, e.op)), [(1, 'write_box'), (5, 'read_box'), (9, 'write_box')]);
      expect(merged.map((e) => e.extra['closed']), [true, null, true]);
      expect(merged.first.app, 'Claude Code');
      expect(merged.first.target.page, 'p1');
    });

    test('a page or binder gets the entries about it, a refusal and a pending approval included', () {
      append([
        entry(1, target: const AiCodeTarget.page('pg'), op: 'read_page'),
        entry(2, target: const AiCodeTarget.page('pg'), op: 'search', result: 'pending_approval'),
        entry(3, target: const AiCodeTarget.binder('bd'), op: 'list_pages', result: 'expired'),
      ]);
      expect(service.activityFor(AiCodeTargetKind.page, 'pg').map((e) => e.result), ['ok', 'pending_approval']);
      expect(service.activityFor(AiCodeTargetKind.binder, 'bd').single.op, 'list_pages');
      expect(service.activityFor(AiCodeTargetKind.binder, 'pg'), isEmpty);
    });

    test('skips lines that are not entries, and a missing or unreadable log is empty', () {
      expect(service.activity('b1'), isEmpty);
      service.mcpLog.writeAsStringSync('junk\n${entry(1).encode()}\n{"time":"x"}\n');
      expect(service.activity('b1'), hasLength(1));
      service.mcpLog.deleteSync();
      service.mcpLog.createSync();
      service.mcpLog.writeAsBytesSync([0xFF, 0xFE, 0x00]);
      expect(service.activity('b1'), isEmpty);
    });

    test('listeners are told when the log file changes', () async {
      final polled = AiAccessService(dataFolder: data, pollInterval: const Duration(milliseconds: 50));
      addTearDown(polled.dispose);
      var told = 0;
      polled.addListener(() => told++);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(told, 0);
      append([entry(1)]);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(told, greaterThan(0));
      expect(polled.activity('b1'), hasLength(1));
    });
  });

  group('trimming the server log', () {
    List<String> lines() => service.mcpLog.readAsStringSync().split('\n').where((l) => l.isNotEmpty).toList();

    test('keeps the last 1000 lines once it holds more, in place', () {
      append([for (var i = 0; i < 1200; i++) entry(i % 60, op: 'op$i')]);
      expect(service.trimMcpLog(), isTrue);
      final kept = lines();
      expect(kept, hasLength(1000));
      expect(parseAiMcpLog(kept.first).single.op, 'op200');
      expect(parseAiMcpLog(kept.last).single.op, 'op1199');
      expect(service.mcpLog.readAsStringSync(), endsWith('\n'));
    });

    test('leaves a log of 1000 lines or fewer alone', () {
      append([for (var i = 0; i < 1000; i++) entry(1, op: 'op$i')]);
      final before = service.mcpLog.readAsBytesSync();
      expect(service.trimMcpLog(), isFalse);
      expect(service.mcpLog.readAsBytesSync(), before);
      expect(service.trimMcpLog(), isFalse);
    });

    test('a missing file is not created', () {
      expect(service.trimMcpLog(), isFalse);
      expect(service.mcpLog.existsSync(), isFalse);
    });

    test('a line being written (no newline yet) is kept, and a later append still lands after it', () {
      append([for (var i = 0; i < 12; i++) entry(1, op: 'op$i')]);
      service.mcpLog.writeAsStringSync('{"time":"2026-11-01T10:00:00Z","co', mode: FileMode.append);
      expect(service.trimMcpLog(keep: 5), isTrue);
      final text = service.mcpLog.readAsStringSync();
      expect(text.split('\n').length, 5, reason: '4 whole lines and the partial one');
      expect(text, endsWith('{"time":"2026-11-01T10:00:00Z","co'));
      expect(text, contains('op11'));
      expect(text, isNot(contains('op6"')), reason: 'only the 4 newest whole lines');
      // The appender finishes its line and appends the next after trimming.
      service.mcpLog.writeAsStringSync('de":"x"}\n${entry(2, op: 'after').encode()}\n', mode: FileMode.append);
      expect(parseAiMcpLog(service.mcpLog.readAsStringSync()).last.op, 'after');
    });

    test('a log that cannot be opened is not touched', () {
      // A directory where the file should be: nothing to read or write.
      service.mcpLog.createSync();
      final dirService = AiAccessService(dataFolder: Directory('${data.path}/sub')..createSync());
      addTearDown(dirService.dispose);
      Directory(dirService.mcpLog.path).createSync();
      expect(dirService.trimMcpLog(), isFalse);
      expect(Directory(dirService.mcpLog.path).existsSync(), isTrue);
    });

    test('with polling on, the service trims when the log has grown too long', () async {
      append([for (var i = 0; i < 1100; i++) entry(1, op: 'op$i')]);
      final polled = AiAccessService(dataFolder: data, pollInterval: const Duration(milliseconds: 50));
      addTearDown(polled.dispose);
      expect(lines(), hasLength(1000), reason: 'trimmed when the service started');
      append([for (var i = 0; i < 50; i++) entry(1, op: 'more$i')]);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(lines(), hasLength(1000), reason: 'and when it changed');
      expect(parseAiMcpLog(lines().last).single.op, 'more49');
    });
  });
}
