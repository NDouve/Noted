// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// t2a: the metadata walk, and the Apple-mode folder move (never a rename over
// something that is not downloaded; the rename in another isolate).

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/src/storage/dataless.dart' show debugDatalessPaths, debugMarkDataless;
import 'package:noted_core/src/storage/exclusive_move.dart'
    show debugMoveVolumeOf, debugNoReplaceErrno, debugRenameDelay;
import 'package:noted_core/src/storage/folder_walk.dart' show debugAppleMode;

import 'support/coordination_support.dart';

DownloadAsk record(List<String> into) => (path) async {
  into.add(path);
  return null;
};

void suite() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('noted_walk'));
  tearDown(() async {
    debugAppleMode = null;
    debugDatalessPaths = null;
    debugRenameDelay = null;
    debugMoveVolumeOf = null;
    debugNoReplaceErrno = null;
    storedReadObserver = null;
    await dir.delete(recursive: true);
  });

  final sep = Platform.pathSeparator;
  String p(String n) => '${dir.path}$sep${n.replaceAll('/', sep)}';

  void makeFolder() {
    Directory(p('src/sub')).createSync(recursive: true);
    File(p('src/a.bin')).writeAsBytesSync([1]);
    File(p('src/sub/b.bin')).writeAsBytesSync([2]);
  }

  group('folderWalk', () {
    test('lists files by name, reading none of them', () {
      makeFolder();
      final reads = <String>[];
      storedReadObserver = reads.add;
      final w = folderWalk(p('src'));
      expect(w.files.map((f) => f.split(RegExp(r'[\\/]')).last).toSet(), {'a.bin', 'b.bin'});
      expect(w.notDownloaded, isEmpty);
      expect(w.hasNotDownloaded, isFalse);
      expect(reads, isEmpty);
    });

    test('a dataless file, nested too, and the target of a stub are listed to be asked for', () {
      makeFolder();
      debugMarkDataless(p('src/sub/b.bin'));
      File(p('src/.c.bin.icloud')).writeAsStringSync('');
      final w = folderWalk(p('src'));
      expect(w.notDownloaded, unorderedEquals([p('src/sub/b.bin'), p('src/c.bin')]));
      expect(w.stubs, [p('src/.c.bin.icloud')]);
      expect(w.files.map((f) => f.split(RegExp(r'[\\/]')).last), ['a.bin']);
    });

    test('a dataless folder is asked for and not entered', () {
      makeFolder();
      debugMarkDataless(p('src/sub'));
      final w = folderWalk(p('src'));
      expect(w.notDownloaded, [p('src/sub')]);
      expect(w.files.map((f) => f.split(RegExp(r'[\\/]')).last), ['a.bin']);
    });

    test('a stub whose target is . or .. is not a stub', () {
      Directory(p('src')).createSync();
      File(p('src/...icloud')).writeAsStringSync('');
      expect(folderWalk(p('src')).stubs, isEmpty);
    });
  });

  group('moveExclusive in Apple mode', () {
    test('a folder with a dataless file anywhere is not renamed: busy, and the files are asked for', () async {
      makeFolder();
      debugAppleMode = true;
      debugMarkDataless(p('src/sub/b.bin'));
      final asked = <String>[];
      var called = false;
      final r = await moveExclusive(
        p('src'),
        p('dst'),
        beforeOsCall: () => called = true,
        ask: (path) async {
          asked.add(path);
          return null;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(r, MoveOutcome.busy);
      expect(called, isFalse, reason: 'no OS call was made');
      expect(asked, [p('src/sub/b.bin')]);
      expect(Directory(p('src')).existsSync(), isTrue);
      expect(Directory(p('dst')).existsSync(), isFalse);
    });

    test('with no walk passed, the folder is walked by the call itself (no unguarded rename by omission)', () async {
      makeFolder();
      debugAppleMode = true;
      File(p('src/.c.bin.icloud')).writeAsStringSync('');
      final asked = <String>[];
      expect(
        await moveExclusive(p('src'), p('dst'), ask: record(asked)),
        MoveOutcome.busy,
      );
      await Future<void>.delayed(Duration.zero);
      expect(asked, [p('src/c.bin')]);
    });

    test('a walk that was passed in is used', () async {
      makeFolder();
      debugAppleMode = true;
      final asked = <String>[];
      final walk = FolderWalk([], [p('src/x.bin')], []);
      expect(
        await moveExclusive(p('src'), p('dst'), walk: walk, ask: record(asked)),
        MoveOutcome.busy,
      );
      await Future<void>.delayed(Duration.zero);
      expect(asked, [p('src/x.bin')]);
      expect(Directory(p('dst')).existsSync(), isFalse);
    });

    test('a clean folder is renamed in another isolate, and the hook runs in this one', () async {
      makeFolder();
      debugAppleMode = true;
      final here = Isolate.current.debugName;
      String? hookIsolate;
      expect(
        await moveExclusive(p('src'), p('dst'), beforeOsCall: () => hookIsolate = Isolate.current.debugName),
        MoveOutcome.moved,
      );
      expect(hookIsolate, here);
      expect(File(p('dst/sub/b.bin')).readAsBytesSync(), [2]);
      expect(Directory(p('src')).existsSync(), isFalse);
    });

    test('a slow rename does not block this isolate', () async {
      makeFolder();
      debugAppleMode = true;
      debugRenameDelay = const Duration(milliseconds: 600);
      var ticks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 50), (_) => ticks++);
      final r = await moveExclusive(p('src'), p('dst'));
      timer.cancel();
      expect(r, MoveOutcome.moved);
      expect(ticks, greaterThan(3));
    });

    test('another volume is cannotRename before the call', () async {
      makeFolder();
      debugAppleMode = true;
      debugMoveVolumeOf = (path) => path.contains('src') ? 1 : 2;
      var called = false;
      expect(
        await moveExclusive(p('src'), p('dst'), beforeOsCall: () => called = true),
        MoveOutcome.cannotRename,
      );
      expect(called, isFalse);
      expect(Directory(p('src')).existsSync(), isTrue);
    });

    test('an EXDEV from the call is cannotRename', () async {
      makeFolder();
      debugAppleMode = true;
      debugNoReplaceErrno = Platform.isWindows ? 17 : 18; // ERROR_NOT_SAME_DEVICE; EXDEV
      final r = await moveExclusive(p('src'), p('dst'));
      expect(r, MoveOutcome.cannotRename);
    });

    test('a taken target is targetExists, and nothing moves', () async {
      makeFolder();
      Directory(p('dst')).createSync();
      debugAppleMode = true;
      expect(await moveExclusive(p('src'), p('dst')), MoveOutcome.targetExists);
      expect(Directory(p('src')).existsSync(), isTrue);
    });

    test('outside Apple mode a folder with a dataless file is not walked (the file rules stay)', () async {
      makeFolder();
      debugMarkDataless(p('src/sub/b.bin'));
      // Not Apple: the folder is renamed as before.
      expect(await moveExclusive(p('src'), p('dst')), MoveOutcome.moved);
    });

    test('a dataless file is busy and asked for, in any mode', () async {
      makeFolder();
      debugMarkDataless(p('src/a.bin'));
      final asked = <String>[];
      expect(
        await moveExclusive(p('src/a.bin'), p('dst.bin'), ask: record(asked)),
        MoveOutcome.busy,
      );
      await Future<void>.delayed(Duration.zero);
      expect(asked, [p('src/a.bin')]);
    });
  });
}

void main() => runWithAndWithoutCoordinator(suite);
