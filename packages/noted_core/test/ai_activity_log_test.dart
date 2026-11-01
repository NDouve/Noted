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
  final t0 = DateTime.utc(2026, 11, 1, 12);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('noted_ai_activity_');
    file = File('${dir.path}/$aiActivityFileName');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  AiActivityEntry entry(int i, {AiCodeTarget? target, String result = 'ok'}) => AiActivityEntry(
    time: t0.add(Duration(seconds: i)),
    code: '0123456789abcdef',
    target: target ?? const AiCodeTarget.box('b1', page: 'p1'),
    op: AiActivityOp.readBox,
    app: 'Claude Code',
    label: 'Feedback',
    result: result,
  );

  test('a missing file is an empty log; entries are appended, newest last', () {
    final log = AiActivityLog(file);
    expect(log.entries(), isEmpty);
    log.append(entry(1));
    log.append(entry(2, result: 'not_approved'));
    final e = log.entries();
    expect(e.map((x) => x.time), [t0.add(const Duration(seconds: 1)), t0.add(const Duration(seconds: 2))]);
    expect(e.first.ok, isTrue);
    expect(e.last.ok, isFalse);
    expect(e.last.result, 'not_approved');
    expect(e.first.target, const AiCodeTarget.box('b1', page: 'p1'));
    expect((jsonDecode(file.readAsStringSync()) as Map)['format'], 1);
  });

  test('the log is capped at 1000 entries overall, oldest dropped', () {
    expect(aiActivityMaxEntries, 1000);
    final log = AiActivityLog(file, maxEntries: 5);
    for (var i = 0; i < 8; i++) {
      log.append(entry(i));
    }
    expect(log.entries().map((x) => x.time.difference(t0).inSeconds), [3, 4, 5, 6, 7]);
  });

  test('the default cap is 1000', () {
    final log = AiActivityLog(file);
    // Seed 1000 entries directly, then add one.
    file.writeAsStringSync(jsonEncode({'format': 1, 'entries': [for (var i = 0; i < 1000; i++) entry(i).toJson()]}));
    expect(log.entries().length, 1000);
    log.append(entry(1000));
    final e = log.entries();
    expect(e.length, 1000);
    expect(e.first.time.difference(t0).inSeconds, 1);
    expect(e.last.time.difference(t0).inSeconds, 1000);
  });

  test('entries can be listed per box, page or binder', () {
    final log = AiActivityLog(file);
    log.append(entry(1));
    log.append(entry(2, target: const AiCodeTarget.page('p1')));
    log.append(entry(3, target: const AiCodeTarget.binder('bd')));
    log.append(entry(4, target: const AiCodeTarget.box('other')));
    expect(log.entriesFor(AiCodeTargetKind.box, 'b1').length, 1);
    expect(log.entriesFor(AiCodeTargetKind.page, 'p1').length, 1);
    expect(log.entriesFor(AiCodeTargetKind.binder, 'bd').length, 1);
    expect(log.entriesFor(AiCodeTargetKind.box, 'p1'), isEmpty);
  });

  test('unknown fields and entries are kept; a damaged file starts over', () {
    file.writeAsStringSync(
      jsonEncode({
        'format': 1,
        'extra': 7,
        'entries': [
          {...entry(1).toJson(), 'ip': 'x'},
          'junk',
        ],
      }),
    );
    final log = AiActivityLog(file);
    expect(log.entries().length, 1);
    expect(log.entries().single.extra, {'ip': 'x'});
    log.append(entry(2));
    final json = jsonDecode(file.readAsStringSync()) as Map;
    expect(json['extra'], 7);
    expect((json['entries'] as List).length, 3);
    expect((json['entries'] as List)[1], 'junk');

    file.writeAsStringSync('damaged');
    expect(log.entries(), isEmpty);
    log.append(entry(3));
    expect(log.entries().length, 1);
  });

  test('a file in another format is left alone and the entry is skipped', () {
    final log = AiActivityLog(file);
    for (final text in ['{"format":2,"entries":[]}', '{"format":1}', '[]', '{"format":1,"entries":{}}']) {
      file.writeAsStringSync(text);
      expect(log.append(entry(1)), isFalse, reason: text);
      expect(log.entries(), isEmpty);
      expect(file.readAsStringSync(), text);
    }
    expect(Directory(dir.path).listSync().whereType<File>().map((f) => f.path.split(RegExp(r'[\\/]')).last).where((n) => n.endsWith('.tmp')), isEmpty);
  });

  test('a missing file or invalid JSON starts a log, and append reports it', () {
    final log = AiActivityLog(file);
    expect(log.append(entry(1)), isTrue);
    file.writeAsStringSync('');
    expect(log.append(entry(2)), isTrue);
    expect(log.entries().length, 1);
  });

  test('a lock held by another handle makes append skip, not wait forever', () {
    final lock = File('${file.path}.lock').openSync(mode: FileMode.append)..lockSync(FileLock.exclusive);
    try {
      final started = DateTime.now();
      expect(AiActivityLog(file).append(entry(1)), isFalse);
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 10)));
    } finally {
      lock.unlockSync();
      lock.closeSync();
    }
    expect(AiActivityLog(file).append(entry(2)), isTrue);
  }, skip: !Platform.isWindows ? 'file locks are per process on POSIX' : false);
}
