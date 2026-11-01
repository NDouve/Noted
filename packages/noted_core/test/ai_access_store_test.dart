// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory dir;
  late File file;
  late AiAccessStore store;
  final now = DateTime.utc(2026, 11, 1, 12);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('noted_ai_access_');
    file = File('${dir.path}/$aiAccessFileName');
    store = AiAccessStore(file);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, Object?> onDisk() => jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

  test('a missing file means no codes, and every code is bad', () {
    expect(store.codes(), isEmpty);
    expect(store.read().askBeforeWrite('b'), isFalse);
    expect(store.verify('noted_0123456789abcdef_${'A' * 43}').failure, AiCodeFailure.badCode);
    expect(file.existsSync(), isFalse);
  });

  test('issue, verify, use, sessions and revoke round trip through the file', () {
    final issued = store.issue(
      target: const AiCodeTarget.box('b1', page: 'p1'),
      role: AiCodeRole.writer,
      label: 'Feedback',
      now: now,
    );
    expect(store.verify(issued.code, now: now).code!.label, 'Feedback');
    expect(file.readAsStringSync(), isNot(contains(parseAiToken(issued.code)!.key)));
    expect(onDisk()['format'], 1);
    expect((onDisk()['codes'] as List).single['target'], {'kind': 'box', 'id': 'b1', 'page': 'p1'});

    store.recordUse(issued.record.id, now: now.add(const Duration(minutes: 5)));
    store.addSession(issued.record.id, AiCodeSession(id: 's1', app: 'Claude Code', approved: now));
    store.addSession(issued.record.id, AiCodeSession(id: 's2', app: 'Other', approved: now));
    store.addSession(issued.record.id, AiCodeSession(id: 's1', app: 'Claude Code 2', approved: now));
    final c = store.codes().single;
    expect(c.lastUsed, now.add(const Duration(minutes: 5)));
    expect(c.sessions.map((s) => (s.id, s.app)), [('s2', 'Other'), ('s1', 'Claude Code 2')]);
    expect(c.session('s1'), isNotNull);
    expect(c.session('nope'), isNull);

    store.removeSession(issued.record.id, 's2');
    expect(store.codes().single.sessions.map((s) => s.id), ['s1']);

    expect(store.revoke(issued.record.id), isTrue);
    // Revoking keeps the code, marked, so its history stays.
    final revokedAt = store.codes().single.revoked;
    expect(revokedAt, isNotNull);
    expect(store.revoke(issued.record.id), isFalse, reason: 'already revoked');
    expect(store.codes().single.revoked, revokedAt, reason: 'the first time is kept');
    expect(store.revoke('0000000000000000'), isFalse);
    expect(store.verify(issued.code).failure, AiCodeFailure.badCode);
    expect((onDisk()['codes'] as List).single['revoked'], isA<String>());
  });

  test('a new Writer retires the old one in the file', () {
    final a = store.issue(target: const AiCodeTarget.box('b'), role: AiCodeRole.writer, label: 'a');
    final r = store.issue(target: const AiCodeTarget.box('b'), role: AiCodeRole.reader, label: 'r');
    final b = store.issue(target: const AiCodeTarget.box('b'), role: AiCodeRole.writer, label: 'b');
    expect(store.codes().map((c) => c.id), [a.record.id, r.record.id, b.record.id]);
    expect(store.codes().first.isRevoked, isTrue);
    expect(store.verify(a.code).ok, isFalse);
    expect(store.verify(b.code).ok, isTrue);
    expect(store.verify(r.code).ok, isTrue);
  });

  test('expiry is checked at verify time', () {
    final c = store.issue(
      target: const AiCodeTarget.page('p'),
      role: AiCodeRole.reader,
      label: 'x',
      expires: now.add(const Duration(days: 1)),
      now: now,
    );
    expect(store.verify(c.code, now: now).ok, isTrue);
    expect(store.verify(c.code, now: now.add(const Duration(days: 2))).failure, AiCodeFailure.expired);
  });

  test('a change in the file is seen on the next check (another instance, a revoke)', () {
    final c = store.issue(target: const AiCodeTarget.box('b'), role: AiCodeRole.reader, label: 'x');
    expect(store.verify(c.code).ok, isTrue);
    final json = onDisk()..['codes'] = <Object?>[];
    file.writeAsStringSync(jsonEncode(json));
    expect(store.verify(c.code).failure, AiCodeFailure.badCode);
  });

  test('unknown fields, unreadable code entries and unknown roles survive a rewrite', () {
    final keep = {
      'id': 'fedcba9876543210',
      'target': {'kind': 'page', 'id': 'p', 'future': true},
      'role': 'organize',
      'label': 'Later',
      'hash': 'abc',
      'created': '2026-01-01T00:00:00.000Z',
      'lastUsed': null,
      'expires': null,
      'sessions': [
        {'id': 's', 'app': 'A', 'approved': '2026-01-01T00:00:00.000Z', 'ip': 'x'},
      ],
      'colour': 'red',
    };
    file.writeAsStringSync(
      jsonEncode({
        'format': 1,
        'top': {'a': 1},
        'codes': [keep, 'not a code', 5],
        'boxes': {
          'b9': {'askBeforeWrite': true, 'note': 'kept'},
        },
      }),
    );
    final c = store.issue(target: const AiCodeTarget.box('b'), role: AiCodeRole.writer, label: 'new', now: now);
    store.setAskBeforeWrite('b', true);
    store.setAskBeforeWrite('b9', false);
    store.recordUse(c.record.id, now: now);
    store.addSession('fedcba9876543210', AiCodeSession(id: 's3', app: 'B', approved: now));

    final json = onDisk();
    expect(json['top'], {'a': 1});
    final codes = json['codes'] as List;
    expect(codes.length, 4);
    final kept = codes.first as Map;
    expect(kept['colour'], 'red');
    expect(kept['role'], 'organize');
    expect((kept['target'] as Map)['future'], true);
    expect((kept['sessions'] as List).first['ip'], 'x');
    expect((kept['sessions'] as List).length, 2);
    expect(codes[1], 'not a code');
    expect(codes[2], 5);
    expect((json['boxes'] as Map)['b9'], {'note': 'kept'});
    expect((json['boxes'] as Map)['b'], {'askBeforeWrite': true});
    expect(store.read().askBeforeWrite('b'), isTrue);
    expect(store.read().askBeforeWrite('b9'), isFalse);
  });

  test('askBeforeWrite is per box and off removes an otherwise empty entry', () {
    store.setAskBeforeWrite('b', true);
    expect(store.askBeforeWrite('b'), isTrue);
    expect(store.askBeforeWrite('other'), isFalse);
    store.setAskBeforeWrite('b', false);
    expect(onDisk().containsKey('boxes'), isFalse);
  });

  group('unreadable file', () {
    for (final (name, text) in [
      ('not json', 'nope'),
      ('empty', ''),
      ('array', '[]'),
      ('newer format', '{"format":2,"codes":[]}'),
      ('no format', '{"codes":[]}'),
      ('codes not a list', '{"format":1,"codes":{}}'),
    ]) {
      test(name, () {
        file.writeAsStringSync(text);
        expect(() => store.read(), throwsA(isA<AiAccessUnreadable>()));
        expect(store.verify('noted_0123456789abcdef_${'A' * 43}').failure, AiCodeFailure.unreadable);
        expect(
          () => store.issue(target: const AiCodeTarget.box('b'), role: AiCodeRole.reader, label: 'x'),
          throwsA(isA<AiAccessUnreadable>()),
        );
        expect(() => store.setAskBeforeWrite('b', true), throwsA(isA<AiAccessUnreadable>()));
        expect(store.askBeforeWrite('b'), isTrue, reason: 'the safe side');
        expect(file.readAsStringSync(), text, reason: 'never overwritten');
      });
    }

    test('a valid code in an unreadable file is refused', () {
      final c = store.issue(target: const AiCodeTarget.box('b'), role: AiCodeRole.reader, label: 'x');
      file.writeAsStringSync('{ damaged');
      expect(store.verify(c.code).failure, AiCodeFailure.unreadable);
    });
  });

  test('writes leave no temporary files behind', () {
    store.issue(target: const AiCodeTarget.box('b'), role: AiCodeRole.reader, label: 'x');
    store.setAskBeforeWrite('b', true);
    final names = dir.listSync().whereType<File>().map((f) => f.path.split(RegExp(r'[\\/]')).last);
    expect(names.where((n) => n.endsWith('.tmp')), isEmpty);
    expect(names, contains(aiAccessFileName));
  });

  test('an update waits for the lock, then reports FileLockTimeout; nothing is lost', () {
    final c = store.issue(target: const AiCodeTarget.box('b'), role: AiCodeRole.reader, label: 'x');
    final lock = File('${file.path}.lock').openSync(mode: FileMode.append)..lockSync(FileLock.exclusive);
    try {
      expect(() => store.revoke(c.record.id), throwsA(isA<FileLockTimeout>()));
      expect(store.verify(c.code).ok, isTrue, reason: 'reads do not need the lock');
    } finally {
      lock.unlockSync();
      lock.closeSync();
    }
    expect(store.revoke(c.record.id), isTrue);
  }, skip: !Platform.isWindows ? 'file locks are per process on POSIX' : false);

  test('a BOM at the start is tolerated', () {
    file.writeAsStringSync('﻿{"format":1,"codes":[]}');
    expect(store.codes(), isEmpty);
  });
}
