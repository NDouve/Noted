// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/io_trace.dart';

void main() {
  late Directory dir;
  late IoTrace trace;
  late List<String> lines;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('noted_io_trace');
    trace = IoTrace()..sink = (l) => lines.add(l);
    lines = [];
  });
  tearDown(() => dir.delete(recursive: true));

  Future<T> traced<T>(Future<T> Function() body) =>
      IOOverrides.runWithIOOverrides(body, TracingIoOverrides(trace));

  test('operations are noted with their path, and no content', () async {
    await traced(() async {
      final f = File('${dir.path}/page.canvas');
      await f.writeAsString('secret words');
      await f.readAsString();
      await f.rename('${dir.path}/other.canvas');
    });
    final text = trace.describe('probe', '${dir.path}/page.canvas', 32);
    expect(text, contains('write'));
    expect(text, contains('read'));
    expect(text, contains('rename'));
    expect(text, contains('page.canvas'));
    expect(text, isNot(contains('secret')));
    expect(text.split('\n').every((l) => l.startsWith('[io-trace]')), isTrue);
  });

  test('a rename refused because another read holds the file names that read', () async {
    final f = File('${dir.path}/big.canvas');
    // Larger than one read chunk, so a paused stream keeps the file open.
    await f.writeAsBytes(List.filled(1 << 20, 65));
    await traced(() async {
      final held = Completer<void>();
      final release = Completer<void>();
      late StreamSubscription<List<int>> sub;
      sub = File(f.path).openRead().listen((_) {
        if (!held.isCompleted) {
          sub.pause(release.future);
          held.complete();
        }
      });
      await held.future;
      Object? error;
      try {
        await File(f.path).rename('${dir.path}/moved.canvas');
      } on FileSystemException catch (e) {
        error = e;
      }
      release.complete();
      await sub.asFuture<void>();
      if (Platform.isWindows) {
        expect(error, isA<FileSystemException>(), reason: 'Windows refuses to rename a file being read');
        expect(lines.first, contains('rename failed with errno 32'));
        expect(lines.join('\n'), contains('STILL RUNNING'));
        expect(lines.join('\n'), contains('openRead'));
      } else {
        expect(error, isNull);
        expect(lines, isEmpty, reason: 'no sharing error, so nothing is reported');
      }
    });
  });

  test('a report that finds nothing says so', () {
    final text = trace.describe('rename', '${dir.path}/x.canvas', 32);
    expect(text, contains('nothing else in this process touched it'));
  });
  test('access denied is reported for a rename only', () {
    final denied = FileSystemException('x', 'a', const OSError('denied', 5));
    final id = trace.begin('rename', '${dir.path}/a', to: '${dir.path}/b');
    trace.failed(id, 'rename', '${dir.path}/a', denied, to: '${dir.path}/b');
    expect(lines, isNotEmpty);
    lines.clear();
    final id2 = trace.begin('read', '${dir.path}/a');
    trace.failed(id2, 'read', '${dir.path}/a', denied);
    expect(lines, isEmpty);
  });
}
