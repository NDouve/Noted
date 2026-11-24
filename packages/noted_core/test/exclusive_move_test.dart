// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/src/storage/dataless.dart' show debugDatalessAbi, debugResetDataless;
import 'support/coordination_support.dart';
import 'package:noted_core/src/storage/exclusive_move.dart'
    show MoveStrategy, debugMoveStrategy, moveExclusiveUncoordinated;

void suite() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('noted_move'));
  tearDown(() async {
    debugMoveStrategy = null;
    await dir.delete(recursive: true);
  });

  final sep = Platform.pathSeparator;
  String p(String n) => '${dir.path}$sep$n';

  group('moveExclusive', () {
    test('moves a file, keeping its bytes', () async {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3, 250]);
      expect(await moveExclusive(p('a.bin'), p('b.bin')), MoveOutcome.moved);
      expect(File(p('a.bin')).existsSync(), isFalse);
      expect(File(p('b.bin')).readAsBytesSync(), [1, 2, 3, 250]);
    });

    test('moves a folder with its files', () async {
      Directory(p('src/sub')).createSync(recursive: true);
      File(p('src/x.txt')).writeAsStringSync('x');
      File(p('src/sub/y.txt')).writeAsStringSync('y');
      expect(await moveExclusive(p('src'), p('dst')), MoveOutcome.moved);
      expect(Directory(p('src')).existsSync(), isFalse);
      expect(File(p('dst/x.txt')).readAsStringSync(), 'x');
      expect(File(p('dst/sub/y.txt')).readAsStringSync(), 'y');
    });

    test('handles non-ASCII names', () async {
      File(p('é.bin')).writeAsBytesSync([7]);
      expect(await moveExclusive(p('é.bin'), p('é ü.bin')), MoveOutcome.moved);
      expect(File(p('é ü.bin')).readAsBytesSync(), [7]);
    });

    test('a file at the target is targetExists, both untouched', () async {
      File(p('a.bin')).writeAsBytesSync([1]);
      File(p('b.bin')).writeAsBytesSync([2]);
      expect(await moveExclusive(p('a.bin'), p('b.bin')), MoveOutcome.targetExists);
      expect(File(p('a.bin')).readAsBytesSync(), [1]);
      expect(File(p('b.bin')).readAsBytesSync(), [2]);
    });

    test('an empty folder at the target is targetExists (never replaced)', () async {
      Directory(p('src')).createSync();
      File(p('src/x.txt')).writeAsStringSync('x');
      Directory(p('dst')).createSync();
      expect(await moveExclusive(p('src'), p('dst')), MoveOutcome.targetExists);
      expect(File(p('src/x.txt')).existsSync(), isTrue);
      expect(Directory(p('dst')).listSync(), isEmpty);
    });

    test('a full folder at the target is targetExists, both untouched', () async {
      Directory(p('src')).createSync();
      File(p('src/x.txt')).writeAsStringSync('x');
      Directory(p('dst')).createSync();
      File(p('dst/z.txt')).writeAsStringSync('z');
      expect(await moveExclusive(p('src'), p('dst')), MoveOutcome.targetExists);
      expect(File(p('src/x.txt')).readAsStringSync(), 'x');
      expect(File(p('dst/z.txt')).readAsStringSync(), 'z');
      expect(File(p('dst/x.txt')).existsSync(), isFalse);
    });

    test('a file at the target is not replaced by a folder move, and the other way', () async {
      Directory(p('src')).createSync();
      File(p('dst')).writeAsStringSync('f');
      expect(await moveExclusive(p('src'), p('dst')), MoveOutcome.targetExists);
      File(p('f.txt')).writeAsStringSync('f');
      Directory(p('d2')).createSync();
      expect(await moveExclusive(p('f.txt'), p('d2')), MoveOutcome.targetExists);
      expect(File(p('f.txt')).readAsStringSync(), 'f');
    });

    test('a target made between the check and the call is not replaced', () async {
      File(p('a.bin')).writeAsBytesSync([1]);
      var calls = 0;
      final outcome = await moveExclusive(
        p('a.bin'),
        p('b.bin'),
        beforeOsCall: () {
          calls++;
          File(p('b.bin')).writeAsBytesSync([9]);
        },
      );
      expect(calls, 1);
      expect(outcome, MoveOutcome.targetExists);
      expect(File(p('a.bin')).readAsBytesSync(), [1]);
      expect(File(p('b.bin')).readAsBytesSync(), [9]);
    });

    test(
      'a folder target made between the check and the call is not replaced',
      () async {
        Directory(p('src')).createSync();
        File(p('src/x.txt')).writeAsStringSync('x');
        final outcome = await moveExclusive(
          p('src'),
          p('dst'),
          beforeOsCall: () => Directory(p('dst')).createSync(),
        );
        expect(outcome, MoveOutcome.targetExists);
        expect(File(p('src/x.txt')).existsSync(), isTrue);
        expect(Directory(p('dst')).listSync(), isEmpty);
      },
    );

    test('a present target makes no OS call', () async {
      File(p('a.bin')).writeAsBytesSync([1]);
      File(p('b.bin')).writeAsBytesSync([2]);
      var calls = 0;
      await moveExclusive(p('a.bin'), p('b.bin'), beforeOsCall: () => calls++);
      expect(calls, 0);
    });

    test('a missing source throws', () async {
      await expectLater(
        () => moveExclusive(p('nope'), p('b')),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a source that vanishes before the call throws', () async {
      File(p('a.bin')).writeAsBytesSync([1]);
      await expectLater(
        () => moveExclusive(
          p('a.bin'),
          p('b.bin'),
          beforeOsCall: () => File(p('a.bin')).deleteSync(),
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a missing target folder throws', () async {
      File(p('a.bin')).writeAsBytesSync([1]);
      await expectLater(
        () => moveExclusive(p('a.bin'), p('nodir/b.bin')),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(p('a.bin')).existsSync(), isTrue);
    });

    test('a link is moved, not followed', () async {
      if (Platform.isWindows) return; // links need privileges on Windows
      File(p('real')).writeAsStringSync('r');
      Link(p('l')).createSync(p('real'));
      expect(await moveExclusive(p('l'), p('m')), MoveOutcome.moved);
      expect(Link(p('m')).targetSync(), p('real'));
      expect(File(p('real')).readAsStringSync(), 'r');
    });

    test('runs in a real isolate', () async {
      File(p('a.bin')).writeAsBytesSync([5]);
      final from = p('a.bin'), to = p('b.bin');
      final outcome = await Isolate.run(() => moveExclusiveUncoordinated(from, to));
      expect(outcome, MoveOutcome.moved);
      expect(File(to).readAsBytesSync(), [5]);
    });

    test('moveOutcomeForErrorCode follows the table', () async {
      MoveOutcome w(int c) => moveOutcomeForErrorCode(c, windows: true);
      MoveOutcome x(int c) => moveOutcomeForErrorCode(c, windows: false);
      for (final c in [5, 32, 33]) {
        expect(w(c), MoveOutcome.busy, reason: '$c');
      }
      expect(w(17), MoveOutcome.cannotRename);
      expect(w(358), MoveOutcome.cannotRename);
      expect(w(426), MoveOutcome.cannotRename);
      expect(w(9999), MoveOutcome.busy);
      for (final c in [1, 13, 16, 26]) {
        expect(x(c), MoveOutcome.busy, reason: '$c');
      }
      expect(x(18), MoveOutcome.cannotRename); // EXDEV
      expect(x(22), MoveOutcome.cannotRename); // EINVAL
      expect(x(9999), MoveOutcome.busy);
    });

    test('the Linux and Apple codes for no support map to cannotRename', () async {
      if (Platform.isMacOS || Platform.isIOS) {
        expect(moveOutcomeForErrorCode(78), MoveOutcome.cannotRename); // ENOSYS
        await expectLater(
          moveOutcomeForErrorCode(45),
          MoveOutcome.cannotRename,
        ); // ENOTSUP
      } else if (Platform.isLinux || Platform.isAndroid) {
        expect(moveOutcomeForErrorCode(38), MoveOutcome.cannotRename); // ENOSYS
        await expectLater(
          moveOutcomeForErrorCode(95),
          MoveOutcome.cannotRename,
        ); // ENOTSUP
      }
    });
  });

  group('the no-replace fallback (lstat, then rename)', () {
    setUp(() => debugMoveStrategy = MoveStrategy.lstatRename);

    test('moves a file and a folder', () async {
      File(p('a.bin')).writeAsBytesSync([1]);
      expect(await moveExclusive(p('a.bin'), p('b.bin')), MoveOutcome.moved);
      expect(File(p('b.bin')).readAsBytesSync(), [1]);
      Directory(p('src')).createSync();
      File(p('src/x')).writeAsStringSync('x');
      expect(await moveExclusive(p('src'), p('dst')), MoveOutcome.moved);
      expect(File(p('dst/x')).readAsStringSync(), 'x');
    });

    // These make the target in the hook, after moveExclusive's own check, so
    // only the fallback's lstat stands between the rename and a replace.
    test('a file target present at the call is not replaced', () async {
      File(p('a.bin')).writeAsBytesSync([1]);
      await expectLater(
        await moveExclusive(
          p('a.bin'),
          p('b.bin'),
          beforeOsCall: () => File(p('b.bin')).writeAsBytesSync([2]),
        ),
        MoveOutcome.targetExists,
      );
      expect(File(p('b.bin')).readAsBytesSync(), [2]);
      expect(File(p('a.bin')).readAsBytesSync(), [1]);
    });

    test('a folder target present at the call is not replaced', () async {
      Directory(p('src')).createSync();
      File(p('src/x')).writeAsStringSync('x');
      await expectLater(
        await moveExclusive(
          p('src'),
          p('dst'),
          beforeOsCall: () => Directory(p('dst')).createSync(),
        ),
        MoveOutcome.targetExists,
      );
      expect(File(p('src/x')).readAsStringSync(), 'x');
      expect(Directory(p('dst')).listSync(), isEmpty);
    });

    test(
      'a target made by the hook, after the first check, is not replaced',
      () async {
        File(p('a.bin')).writeAsBytesSync([1]);
        final outcome = await moveExclusive(
          p('a.bin'),
          p('b.bin'),
          beforeOsCall: () => File(p('b.bin')).writeAsBytesSync([9]),
        );
        expect(outcome, MoveOutcome.targetExists);
        expect(File(p('b.bin')).readAsBytesSync(), [9]);
        expect(File(p('a.bin')).readAsBytesSync(), [1]);
      },
    );
  });

  group('Linux', () {
    final linux = Platform.isLinux;

    test('the raw system call path moves and never replaces', () async {
      debugMoveStrategy = MoveStrategy.linuxSyscall;
      File(p('a.bin')).writeAsBytesSync([1]);
      expect(await moveExclusive(p('a.bin'), p('b.bin')), MoveOutcome.moved);
      File(p('c.bin')).writeAsBytesSync([3]);
      final outcome = await moveExclusive(
        p('c.bin'),
        p('d.bin'),
        beforeOsCall: () => File(p('d.bin')).writeAsBytesSync([4]),
      );
      expect(outcome, MoveOutcome.targetExists);
      expect(File(p('d.bin')).readAsBytesSync(), [4]);
    }, skip: linux ? false : 'Linux only');

    test(
      'another file system is cannotRename (/dev/shm)',
      () async {
        final shm = Directory('/dev/shm');
        File(p('a.bin')).writeAsBytesSync([1]);
        final to =
            '${shm.path}/noted_move_${DateTime.now().microsecondsSinceEpoch}';
        try {
          expect(await moveExclusive(p('a.bin'), to), MoveOutcome.cannotRename);
          expect(File(p('a.bin')).existsSync(), isTrue);
          expect(File(to).existsSync(), isFalse);
        } finally {
          if (File(to).existsSync()) File(to).deleteSync();
        }
      },
      skip: linux && Directory('/dev/shm').existsSync()
          ? false
          : 'needs /dev/shm',
    );
  });

  group('Windows', () {
    final win = Platform.isWindows;

    test('a file open in a folder makes the folder move busy', () async {
      Directory(p('src')).createSync();
      final f = File(p('src/x.txt'))..writeAsStringSync('x');
      final open = f.openSync();
      try {
        expect(await moveExclusive(p('src'), p('dst')), MoveOutcome.busy);
        expect(Directory(p('dst')).existsSync(), isFalse);
      } finally {
        open.closeSync();
      }
      expect(await moveExclusive(p('src'), p('dst')), MoveOutcome.moved);
    }, skip: win ? false : 'Windows only');

    test('an open file is busy to move', () async {
      final f = File(p('a.bin'))..writeAsBytesSync([1]);
      final open = f.openSync();
      try {
        expect(await moveExclusive(p('a.bin'), p('b.bin')), MoveOutcome.busy);
      } finally {
        open.closeSync();
      }
      expect(await moveExclusive(p('a.bin'), p('b.bin')), MoveOutcome.moved);
    }, skip: win ? false : 'Windows only');

    test('a reserved or trailing-dot name throws', () async {
      File(p('a.bin')).writeAsBytesSync([1]);
      await expectLater(
        () => moveExclusive(p('a.bin'), p('NUL.txt')),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        () => moveExclusive(p('a.bin'), p('b.')),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(p('a.bin')).existsSync(), isTrue);
    }, skip: win ? false : 'Windows only');

    test('a path over 260 characters moves', () async {
      var deep = '\\\\?\\${dir.path}';
      while (deep.length < 300) {
        deep = '$deep\\${'d' * 40}';
      }
      Directory(deep).createSync(recursive: true);
      File('$deep\\a.bin').writeAsBytesSync([8]);
      expect(await moveExclusive('$deep\\a.bin', '$deep\\b.bin'), MoveOutcome.moved);
      expect(File('$deep\\b.bin').readAsBytesSync(), [8]);
      // The same pair spelled without the prefix gets it added.
      final plain = deep.substring(4);
      await expectLater(
        await moveExclusive('$plain\\b.bin', '$plain\\c.bin'),
        MoveOutcome.moved,
      );
      expect(File('$deep\\c.bin').existsSync(), isTrue);
    }, skip: win ? false : 'Windows only');

    test('another drive is cannotRename', () async {
      final here = dir.path.substring(0, 1).toUpperCase();
      Directory? other;
      for (final letter in 'DEFGHIJKLMNOPQRSTUVWXYZ'.split('')) {
        if (letter == here) continue;
        final root = Directory('$letter:\\');
        try {
          if (!root.existsSync()) continue;
        } on FileSystemException {
          continue;
        }
        try {
          other = root.createTempSync('noted_move');
          break;
        } on FileSystemException {
          continue;
        }
      }
      if (other == null) {
        markTestSkipped('no second writable drive');
        return;
      }
      try {
        File(p('a.bin')).writeAsBytesSync([1]);
        Directory(p('src')).createSync();
        await expectLater(
          await moveExclusive(p('a.bin'), '${other.path}\\a.bin'),
          MoveOutcome.cannotRename,
        );
        await expectLater(
          await moveExclusive(p('src'), '${other.path}\\src'),
          MoveOutcome.cannotRename,
        );
        expect(File(p('a.bin')).existsSync(), isTrue);
      } finally {
        other.deleteSync(recursive: true);
      }
    }, skip: win ? false : 'Windows only');

    test('syncRootOf is null outside a sync root, and does not throw', () async {
      expect(syncRootOf(p('missing/deeper')), isNull);
      expect(syncRootOf(dir.path), isNull);
    }, skip: win ? false : 'Windows only');
  });

  group('import rules', () {
    // The import, export and part lines only (comments may name the files).
    String src(String path) =>
        File(path)
            .readAsLinesSync()
            .where((l) => RegExp(r'^\s*(import|export|part)\b').hasMatch(l))
            .join('\n');
    final dirPath = File('lib/src/storage/exclusive_publish.dart').existsSync()
        ? 'lib'
        : '../lib';

    test('exclusive_publish.dart does not import exclusive_move.dart', () async {
      await expectLater(
        src('$dirPath/src/storage/exclusive_publish.dart'),
        isNot(contains('exclusive_move')),
      );
    });

    test('noted_core_read does not export it, nor the file stamp', () async {
      final read = src('$dirPath/noted_core_read.dart');
      expect(read, isNot(contains('exclusive_move')));
      expect(read, isNot(contains('file_stamp')));
      expect(read, isNot(contains('page_store')));
    });

    test('file_stamp.dart does not import exclusive_move.dart (the page store imports it)', () async {
      await expectLater(
        src('$dirPath/src/storage/file_stamp.dart'),
        isNot(contains('exclusive_move')),
      );
    });

    test('the page store imports the stamp and the mover', () async {
      final store = src('$dirPath/src/storage/page_store.dart');
      expect(store, contains("import 'file_stamp.dart';"));
      expect(store, contains("import 'exclusive_move.dart';"));
    });
  });

  group('placeholderState', () {
    test('an ordinary file and folder are not placeholders', () async {
      File(p('a.bin')).writeAsBytesSync([1]);
      expect(placeholderState(p('a.bin')), PlaceholderState.notPlaceholder);
      expect(placeholderState(dir.path), PlaceholderState.notPlaceholder);
    });

    test('a missing path is unknown', () async {
      expect(placeholderState(p('nope')), PlaceholderState.unknown);
    });
  });

  group('files that are not downloaded', () {
    tearDown(() {
      debugDatalessAbi = null;
      debugResetDataless();
    });

    test('a stub-only source stays where it is: busy, never missing', () async {
      File(p('.a.bin.icloud')).writeAsStringSync('');
      expect(await moveExclusive(p('a.bin'), p('b.bin')), MoveOutcome.busy);
      expect(
        () => moveExclusiveUncoordinated(p('a.bin'), p('b.bin')),
        throwsA(isA<StorageBusy>().having((e) => e.reason, 'reason', StorageBusyReason.dataless)),
      );
      expect(File(p('.a.bin.icloud')).existsSync(), isTrue);
      expect(File(p('b.bin')).existsSync(), isFalse);
    });

    test('a stubbed name is taken: the move reports targetExists and moves nothing', () async {
      File(p('a.bin')).writeAsBytesSync([1]);
      File(p('.b.bin.icloud')).writeAsStringSync('');
      expect(await moveExclusive(p('a.bin'), p('b.bin')), MoveOutcome.targetExists);
      expect(File(p('a.bin')).readAsBytesSync(), [1]);
      debugMoveStrategy = MoveStrategy.lstatRename;
      expect(await moveExclusive(p('a.bin'), p('b.bin')), MoveOutcome.targetExists);
      expect(File(p('a.bin')).existsSync(), isTrue);
    });

    test('a dataless source stays where it is', () async {
      File(p('a.bin')).writeAsBytesSync([1]);
      debugDatalessAbi = Abi.macosArm64;
      debugResetDataless();
      expect(await moveExclusive(p('a.bin'), p('b.bin')), MoveOutcome.busy);
      debugDatalessAbi = null;
      expect(File(p('a.bin')).existsSync(), isTrue);
      expect(File(p('b.bin')).existsSync(), isFalse);
    }, skip: (Platform.isMacOS || Platform.isIOS) ? 'a real lstat exists: nothing fails closed' : null);
  });
}

void main() => runWithAndWithoutCoordinator(suite);
