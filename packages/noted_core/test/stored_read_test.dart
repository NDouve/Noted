// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/src/storage/dataless.dart'
    show debugDatalessPaths, debugMarkDataless, debugUnmarkDataless;

void main() {
  late Directory dir;
  late List<String> reads;
  late List<String> asked;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('noted_stored');
    reads = [];
    asked = [];
    storedReadObserver = reads.add;
  });
  tearDown(() async {
    storedReadObserver = null;
    debugDatalessPaths = null;
    await dir.delete(recursive: true);
  });

  Future<String?> ask(String path) async {
    asked.add(path);
    return null;
  }

  String p(String name) => '${dir.path}${Platform.pathSeparator}$name';

  test('a downloaded file is read', () async {
    File(p('a.canvas')).writeAsStringSync('hello');
    final r = await readStored(p('a.canvas'), ask: ask);
    expect(r, isA<StoredBytes>());
    expect((r as StoredBytes).text, 'hello');
    expect(reads, [p('a.canvas')]);
    expect(asked, isEmpty);
    expect((readStoredSync(p('a.canvas')) as StoredBytes).text, 'hello');
  });

  test('a file with no file and no stub is missing', () async {
    expect(await readStored(p('none.canvas'), ask: ask), isA<StoredMissing>());
    expect(readStoredSync(p('none.canvas')), isA<StoredMissing>());
    expect(await readStored('${p('nofolder')}${Platform.pathSeparator}x', ask: ask), isA<StoredMissing>());
    expect(asked, isEmpty);
  });

  test('a stub only is not downloaded: nothing is read, the ask is called once', () async {
    File(p('.a.canvas.icloud')).writeAsStringSync('');
    final r = await readStored(p('a.canvas'), ask: ask);
    expect(r, isA<StoredNotDownloaded>());
    expect(reads, isEmpty, reason: 'no open');
    expect(asked, [p('a.canvas')]);
    expect(readStoredSync(p('a.canvas'), ask: ask), isA<StoredNotDownloaded>());
    expect(asked, hasLength(2));
  });

  test('a present dataless file is not read, the ask is called once', () async {
    File(p('a.canvas')).writeAsStringSync('hello');
    debugMarkDataless(p('a.canvas'));
    final r = await readStored(p('a.canvas'), ask: ask);
    expect(r, isA<StoredNotDownloaded>());
    expect(reads, isEmpty, reason: 'no open');
    expect(asked, [p('a.canvas')]);
    debugUnmarkDataless(p('a.canvas'));
    expect((await readStored(p('a.canvas'), ask: ask) as StoredBytes).text, 'hello');
    expect(asked, hasLength(1));
  });

  test('with no ask, nothing is asked and the result is the same', () async {
    File(p('.a.canvas.icloud')).writeAsStringSync('');
    expect(await readStored(p('a.canvas')), isA<StoredNotDownloaded>());
  });

  test('a downloaded file with a stale stub beside it is read, while the checked primitives stay busy', () async {
    File(p('a.canvas')).writeAsStringSync('hello');
    File(p('.a.canvas.icloud')).writeAsStringSync('');
    expect((await readStored(p('a.canvas')) as StoredBytes).text, 'hello');
    await expectLater(ContentIdentity.ofFile(p('a.canvas')), throwsA(isA<StorageBusy>()));
  });

  test('an eviction between the gate and the read is not downloaded', () async {
    File(p('a.canvas')).writeAsStringSync('hello');
    storedReadObserver = (path) {
      File(path).deleteSync();
      File(p('.a.canvas.icloud')).writeAsStringSync('');
    };
    expect(await readStored(p('a.canvas'), ask: ask), isA<StoredNotDownloaded>());
    expect(asked, [p('a.canvas')]);
  });

  test('a file that goes between the gate and the read is missing', () async {
    File(p('a.canvas')).writeAsStringSync('hello');
    storedReadObserver = (path) => File(path).deleteSync();
    expect(await readStored(p('a.canvas'), ask: ask), isA<StoredMissing>());
    expect(asked, isEmpty);
  });

  test('an ask that throws, synchronously or later, never reaches the caller', () async {
    File(p('.a.canvas.icloud')).writeAsStringSync('');
    final uncaught = <Object>[];
    final logged = <String>[];
    storedReadLog = logged.add;
    addTearDown(() => storedReadLog = print);
    await runZonedGuarded(() async {
      final sync = await readStored(p('a.canvas'), ask: (_) => throw StateError('now'));
      final later = await readStored(p('a.canvas'), ask: (_) async => throw StateError('later'));
      expect(sync, isA<StoredNotDownloaded>());
      expect(later, isA<StoredNotDownloaded>());
      expect(readStoredSync(p('a.canvas'), ask: (_) => throw StateError('now')), isA<StoredNotDownloaded>());
      await readStored(p('a.canvas'), ask: (_) async => 'no channel');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }, (e, s) => uncaught.add(e));
    expect(uncaught, isEmpty);
    expect(logged.where((m) => m.contains('now')), hasLength(2));
    expect(logged.where((m) => m.contains('later')), hasLength(1));
    expect(logged.where((m) => m.contains('no channel')), hasLength(1));
  });

  test('bad UTF-8 makes text throw the FileSystemException readAsString throws', () async {
    final f = File(p('bad.canvas'))..writeAsBytesSync([0x7b, 0xff, 0xfe, 0x7d]);
    Object? expected;
    try {
      f.readAsStringSync();
    } on Object catch (e) {
      expected = e;
    }
    expect(expected, isA<FileSystemException>());
    final r = await readStored(f.path) as StoredBytes;
    expect(
      () => r.text,
      throwsA(
        isA<FileSystemException>().having((e) => e.message, 'message', (expected as FileSystemException).message),
      ),
    );
    expect(utf8.decode(r.bytes, allowMalformed: true), isNotEmpty);
  });

  test('openStoredRead refuses a file that is not downloaded and streams one that is', () async {
    File(p('a.bin')).writeAsBytesSync(List.generate(200000, (i) => i % 251));
    final ok = await openStoredRead(p('a.bin'), ask: ask);
    final bytes = <int>[];
    await (ok as StoredOpened<Stream<List<int>>>).value.forEach(bytes.addAll);
    expect(bytes, hasLength(200000));
    final part = await openStoredRead(p('a.bin'), start: 10, end: 20);
    final sub = <int>[];
    await (part as StoredOpened<Stream<List<int>>>).value.forEach(sub.addAll);
    expect(sub, bytes.sublist(10, 20));

    debugMarkDataless(p('a.bin'));
    final no = await openStoredRead(p('a.bin'), ask: ask);
    expect((no as StoredRefused).result, isA<StoredNotDownloaded>());
    expect(asked, [p('a.bin')]);
    expect((openStoredFileSync(p('a.bin')) as StoredRefused).result, isA<StoredNotDownloaded>());
    expect(((await openStoredFile(p('a.bin'))) as StoredRefused).result, isA<StoredNotDownloaded>());
    debugUnmarkDataless(p('a.bin'));
    final raf = (openStoredFileSync(p('a.bin')) as StoredOpened<RandomAccessFile>).value;
    raf.closeSync();
    expect(((await openStoredRead(p('nope'))) as StoredRefused).result, isA<StoredMissing>());
  });

  test('ContentIdentity.ofFile closes its handle when the length fails', () async {
    final f = File(p('a.bin'))..writeAsBytesSync(List.filled(1000, 7));
    await IOOverrides.runZoned(
      () => expectLater(ContentIdentity.ofFile(f.path), throwsA(isA<FileSystemException>())),
      createFile: (path) => _LengthFails(Zone.root.run(() => File(path))),
    );
    // A handle left open would hold the file (on Windows it blocks the rename).
    final moved = f.renameSync(p('b.bin'));
    moved.deleteSync();
    expect(File(p('b.bin')).existsSync(), isFalse);
  });

  test('debugDatalessPaths matches a path given by its 8.3 short form', () async {
    Directory(p('a long folder name')).createSync();
    final f = File(p('a long folder name${Platform.pathSeparator}a long file name.canvas'))..writeAsStringSync('x');
    final r = Process.runSync('powershell', [
      '-NoProfile',
      '-Command',
      "(New-Object -ComObject Scripting.FileSystemObject).GetFile('${f.path}').ShortPath",
    ]);
    final short = (r.stdout as String).trim();
    if (short.isEmpty || short.toLowerCase() == f.path.toLowerCase()) {
      markTestSkipped('this volume makes no short names');
      return;
    }
    debugMarkDataless(short);
    expect(await readStored(f.path), isA<StoredNotDownloaded>());
    debugUnmarkDataless(f.path);
    expect(await readStored(short), isA<StoredBytes>());
  }, skip: Platform.isWindows ? null : 'Windows only');
}

/// A file whose length fails (a file that went between the open and the length).
class _LengthFails implements File {
  _LengthFails(this._f);

  final File _f;

  @override
  String get path => _f.path;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) => _f.open(mode: mode);

  @override
  Future<int> length() => throw FileSystemException('gone', _f.path);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}
