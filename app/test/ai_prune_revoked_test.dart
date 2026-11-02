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
  const target = AiCodeTarget.box('b1', page: 'p1');

  setUp(() {
    data = Directory.systemTemp.createTempSync('noted_prune');
    service = AiAccessService(dataFolder: data);
  });

  tearDown(() {
    service.dispose();
    data.deleteSync(recursive: true);
  });

  String issue(String label) =>
      service.store.issue(target: target, role: AiCodeRole.reader, label: label).record.id;

  void inAppLog(String code) => service.log.append(
    AiActivityEntry(
      time: DateTime.utc(2026, 11, 1, 10),
      code: code,
      target: target,
      op: 'read_box',
      app: 'App',
      label: 'Chat',
      result: 'ok',
    ),
  );

  void inMcpLog(String code) => service.mcpLog.writeAsStringSync(
    '${AiMcpLogEntry(time: DateTime.utc(2026, 11, 1, 10), code: code, target: target, op: 'read_box', app: 'App', label: 'Chat', result: 'ok').encode()}\n',
    mode: FileMode.append,
  );

  List<String> ids() => [for (final c in service.store.codes()) c.id];

  test('a revoked code with no activity in either log is pruned', () {
    final id = issue('A');
    service.store.revoke(id);
    expect(service.pruneRevokedCodes(), 1);
    expect(ids(), isEmpty);
  });

  test('a revoked code with activity only in the MCP log is kept', () {
    final id = issue('A');
    service.store.revoke(id);
    inMcpLog(id);
    expect(service.pruneRevokedCodes(), 0);
    expect(ids(), [id]);
  });

  test('a revoked code with activity only in the app log is kept', () {
    final id = issue('A');
    service.store.revoke(id);
    inAppLog(id);
    expect(service.pruneRevokedCodes(), 0);
    expect(ids(), [id]);
  });

  test('an unrevoked code with no activity is kept', () {
    final id = issue('A');
    expect(service.pruneRevokedCodes(), 0);
    expect(ids(), [id]);
  });

  test('only the aged-out revoked code goes; a live one and one with activity stay', () {
    final gone = issue('gone');
    final busy = issue('busy');
    final live = issue('live');
    service.store.revoke(gone);
    service.store.revoke(busy);
    inMcpLog(busy);
    expect(service.pruneRevokedCodes(), 1);
    expect(ids(), unorderedEquals([busy, live]));
  });

  test('nothing is pruned while a log can not be read', () {
    final id = issue('A');
    service.store.revoke(id);
    Directory(service.mcpLog.path).createSync();
    expect(service.pruneRevokedCodes(), 0);
    expect(ids(), [id]);
  });

  test('nothing is pruned while the app log can not be read', () {
    final id = issue('A');
    service.store.revoke(id);
    Directory(service.log.file.path).createSync();
    expect(service.pruneRevokedCodes(), 0);
    expect(ids(), [id]);
  });

  test('with polling on, a change to a log that removes the last activity prunes on the next poll', () async {
    final id = issue('A');
    service.store.revoke(id);
    inMcpLog(id);
    final polled = AiAccessService(dataFolder: data, pollInterval: const Duration(milliseconds: 50));
    addTearDown(polled.dispose);
    expect(ids(), [id], reason: 'kept at start: the log still holds activity');
    service.mcpLog.writeAsStringSync('');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(ids(), isEmpty);
  });

  test('pruning is idempotent, and holds after a restart', () {
    final gone = issue('gone');
    final live = issue('live');
    service.store.revoke(gone);
    expect(service.pruneRevokedCodes(), 1);
    expect(service.pruneRevokedCodes(), 0);
    service.dispose();
    service = AiAccessService(dataFolder: data);
    expect(service.pruneRevokedCodes(), 0);
    expect(ids(), [live]);
  });

  group('app-side changes with polling on', () {
    late AiAccessService polled;
    setUp(() {
      polled = AiAccessService(dataFolder: data, pollInterval: const Duration(milliseconds: 50));
      addTearDown(polled.dispose);
    });

    test('revoking a never-used code prunes it without waiting for an outside change', () async {
      final id = issue('A');
      await polled.revoke(id);
      expect(ids(), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(ids(), isEmpty);
    });

    test('revoking a code that is still in the MCP log keeps it', () async {
      final id = issue('A');
      inMcpLog(id);
      await polled.revoke(id);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(ids(), [id]);
    });

    test('an app-side log trim that drops a revoked code last entry prunes it', () async {
      final id = issue('A');
      inAppLog(id);
      await polled.revoke(id);
      expect(ids(), [id]);
      // Fill the log so the first entry is trimmed away.
      for (var i = 0; i < aiActivityMaxEntries + 1; i++) {
        polled.log.append(
          AiActivityEntry(
            time: DateTime.utc(2026, 11, 1, 11),
            code: 'other',
            target: target,
            op: 'read_box',
            app: 'App',
            label: 'Chat',
            result: 'ok',
          ),
        );
      }
      polled.changed();
      expect(ids(), isEmpty);
    });
  });

  test('with polling on, the service prunes when it starts', () {
    final id = issue('A');
    service.store.revoke(id);
    final polled = AiAccessService(dataFolder: data, pollInterval: const Duration(milliseconds: 50));
    addTearDown(polled.dispose);
    expect(ids(), isEmpty);
  });
}
