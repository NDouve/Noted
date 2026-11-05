// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

/// Marks [path] read-only (Windows attribute, or no write permission).
void makeReadOnly(String path, {required bool on}) {
  if (Platform.isWindows) {
    Process.runSync('attrib', [on ? '+R' : '-R', path]);
  } else {
    Process.runSync('chmod', [on ? '444' : '644', path]);
  }
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('noted_rbr'));
  tearDown(() async {
    for (final f in dir.listSync()) {
      if (f is File) makeReadOnly(f.path, on: false);
    }
    await dir.delete(recursive: true);
  });

  String p(String n) => '${dir.path}${Platform.pathSeparator}$n';
  List<String> names() =>
      dir.listSync().map((f) => f.uri.pathSegments.last).toList()..sort();

  test('equal bytes: replaces an existing file, with no leftovers', () {
    File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
    final tmp = File(p('a.tmp'))..writeAsBytesSync([7, 8]);
    final r = replaceByRenameIfUnchanged(tmp, p('a.bin'), [1, 2, 3]);
    expect(r, RenameOutcome.replaced);
    expect(File(p('a.bin')).readAsBytesSync(), [7, 8]);
    expect(names(), ['a.bin']);
  });

  test('other bytes: changed, nothing moved', () {
    File(p('a.bin')).writeAsBytesSync([9]);
    final tmp = File(p('a.tmp'))..writeAsBytesSync([7, 8]);
    expect(replaceByRenameIfUnchanged(tmp, p('a.bin'), [1, 2, 3]), RenameOutcome.changed);
    expect(File(p('a.bin')).readAsBytesSync(), [9]);
    expect(names(), ['a.bin', 'a.tmp']);
  });

  test('no target: missing, and the temp stays', () {
    final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
    expect(replaceByRenameIfUnchanged(tmp, p('a.bin'), [1]), RenameOutcome.missing);
    expect(names(), ['a.tmp']);
  });

  test('the file is never absent at either seam', () {
    File(p('a.bin')).writeAsBytesSync([1]);
    final tmp = File(p('a.tmp'))..writeAsBytesSync([2]);
    var seen = 0;
    replaceByRenameIfUnchanged(
      tmp,
      p('a.bin'),
      [1],
      beforeCompare: () {
        expect(File(p('a.bin')).existsSync(), isTrue);
        seen++;
      },
      beforeRename: () {
        expect(File(p('a.bin')).existsSync(), isTrue);
        seen++;
      },
    );
    expect(seen, 2);
  });

  test('a replacement before the compare is detected; one in the window is overwritten', () {
    File(p('a.bin')).writeAsBytesSync([1]);
    final tmp = File(p('a.tmp'))..writeAsBytesSync([2]);
    expect(
      replaceByRenameIfUnchanged(
        tmp,
        p('a.bin'),
        [1],
        beforeCompare: () => File(p('a.bin')).writeAsBytesSync([5]),
      ),
      RenameOutcome.changed,
    );
    expect(File(p('a.bin')).readAsBytesSync(), [5]);
    // Documents the window accepted for binder files.
    expect(
      replaceByRenameIfUnchanged(
        tmp,
        p('a.bin'),
        [5],
        beforeRename: () => File(p('a.bin')).writeAsBytesSync([6]),
      ),
      RenameOutcome.replaced,
    );
    expect(File(p('a.bin')).readAsBytesSync(), [2]);
  });

  test('a read-only target is refused before the rename on every platform', () {
    File(p('a.bin')).writeAsBytesSync([1]);
    final tmp = File(p('a.tmp'))..writeAsBytesSync([2]);
    makeReadOnly(p('a.bin'), on: true);
    expect(
      () => replaceByRenameIfUnchanged(tmp, p('a.bin'), [1]),
      throwsA(isA<FileSystemException>()),
    );
    makeReadOnly(p('a.bin'), on: false);
    expect(File(p('a.bin')).readAsBytesSync(), [1]);
    expect(tmp.existsSync(), isTrue);
  });
}
