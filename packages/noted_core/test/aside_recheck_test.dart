// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The aside re-check of replaceIfUnchanged and deleteFileIfMatches (steps V1 to
// V5 of the 2026-11-15 design): a fake sync swaps the verified aside, in the
// seams, between the verify and the delete.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';
import 'support/coordination_support.dart';
import 'support/page_save.dart';

/// A file whose next [stat] throws when [fail] says so (a sync client holding
/// it for a moment); everything the library calls is forwarded.
class _StatFile implements File {
  _StatFile(this._f, this.fail);

  final File _f;
  final bool Function() fail;

  @override
  String get path => _f.path;

  @override
  File get absolute => _f.absolute;

  @override
  Future<FileStat> stat() {
    if (fail()) throw const FileSystemException('injected hold');
    return _f.stat();
  }

  @override
  Future<Uint8List> readAsBytes() => _f.readAsBytes();

  @override
  Future<int> length() => _f.length();

  @override
  Stream<List<int>> openRead([int? start, int? end]) => _f.openRead(start, end);

  @override
  Future<File> rename(String newPath) => _f.rename(newPath);

  @override
  void deleteSync({bool recursive = false}) =>
      _f.deleteSync(recursive: recursive);

  @override
  Future<bool> exists() => _f.exists();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void suite() {
  late Directory dir;

  setUp(
    () async => dir = await Directory.systemTemp.createTemp('noted_recheck'),
  );
  tearDown(() async => dir.delete(recursive: true));

  String p(String n) => '${dir.path}${Platform.pathSeparator}$n';
  List<String> names() =>
      dir.listSync().map((f) => f.path.split(RegExp(r'[\\/]')).last).toList()
        ..sort();
  List<String> recovered() =>
      names().where((n) => n.contains('-recovered-')).toList();
  File tmpFile() => File(p('a.tmp'))..writeAsBytesSync([7, 8]);
  void seed() => File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
  bool redundant() {
    try {
      final b = File(p('b.bin')).readAsBytesSync();
      return b.length == 3 && b[0] == 1 && b[1] == 2 && b[2] == 3;
    } on FileSystemException {
      return false;
    }
  }

  group('save (replaceIfUnchanged)', () {
    test('7. no swap: the aside is gone and nothing is left over', () async {
      seed();
      final r = await replaceIfUnchanged(tmpFile(), p('a.bin'), [1, 2, 3]);
      expect(r.outcome, ReplaceOutcome.replaced);
      expect(r.keptPath, isNull);
      expect(names(), ['a.bin']);
    });

    test(
      '1. aside rewritten at beforeAsideDelete: kept as a -recovered- copy',
      () async {
        seed();
        final r = await replaceIfUnchanged(
          tmpFile(),
          p('a.bin'),
          [1, 2, 3],
          beforeAsideDelete: (path) async =>
              File(path).writeAsBytesSync([9, 9, 9, 9]),
        );
        expect(r.outcome, ReplaceOutcome.replaced);
        expect(File(p('a.bin')).readAsBytesSync(), [7, 8]);
        expect(File(r.keptPath!).readAsBytesSync(), [9, 9, 9, 9]);
        expect(r.keptPath, contains('-recovered-'));
        expect(names(), hasLength(2));
      },
    );

    test(
      '1. aside rewritten at the .cas-old name in afterRead: kept',
      () async {
        seed();
        final r = await replaceIfUnchanged(
          tmpFile(),
          p('a.bin'),
          [1, 2, 3],
          afterRead: () {
            final aside = dir
                .listSync()
                .map((f) => f.path)
                .singleWhere((s) => s.endsWith(asideSuffix));
            File(aside).writeAsBytesSync([9, 9, 9, 9]);
          },
        );
        expect(r.outcome, ReplaceOutcome.replaced);
        expect(File(r.keptPath!).readAsBytesSync(), [9, 9, 9, 9]);
        expect(File(p('a.bin')).readAsBytesSync(), [7, 8]);
      },
    );

    test('2. drop file rewritten at beforeFinalCheck: kept', () async {
      seed();
      final r = await replaceIfUnchanged(tmpFile(), p('a.bin'), [
        1,
        2,
        3,
      ], beforeFinalCheck: (path) async => File(path).writeAsBytesSync([9, 9]));
      expect(r.outcome, ReplaceOutcome.replaced);
      expect(r.keptPath, contains('-recovered-'));
      expect(File(r.keptPath!).readAsBytesSync(), [9, 9]);
      expect(names(), hasLength(2));
    });

    test(
      '2. a late file at the old name (V5): kept, and the drop file deleted',
      () async {
        seed();
        late String old;
        final r = await replaceIfUnchanged(
          tmpFile(),
          p('a.bin'),
          [1, 2, 3],
          beforeAsideDelete: (path) async => old = path,
          beforeFinalCheck: (_) async => File(old).writeAsBytesSync([5, 5]),
        );
        expect(r.outcome, ReplaceOutcome.replaced);
        expect(r.keptPath, contains('-recovered-'));
        expect(File(r.keptPath!).readAsBytesSync(), [5, 5]);
        expect(r.alsoKept, isEmpty);
        expect(File(old).existsSync(), isFalse);
        expect(names(), hasLength(2));
      },
    );

    test('2. both a swapped drop file and a late file: first is keptPath, second alsoKept', () async {
      seed();
      late String old;
      final r = await replaceIfUnchanged(
        tmpFile(),
        p('a.bin'),
        [1, 2, 3],
        beforeAsideDelete: (path) async => old = path,
        beforeFinalCheck: (drop) async {
          File(drop).writeAsBytesSync([9, 9]);
          File(old).writeAsBytesSync([5, 5]);
        },
      );
      expect(File(r.keptPath!).readAsBytesSync(), [9, 9]);
      expect(r.alsoKept, hasLength(1));
      expect(File(r.alsoKept.single).readAsBytesSync(), [5, 5]);
      expect(recovered(), hasLength(2));
    });

    test('3. drop file replaced after the read (second stat): kept', () async {
      seed();
      final r = await replaceIfUnchanged(
        tmpFile(),
        p('a.bin'),
        [1, 2, 3],
        afterFinalRead: (path) async =>
            File(path).writeAsBytesSync([9, 9, 9, 9, 9]),
      );
      expect(r.outcome, ReplaceOutcome.replaced);
      expect(File(r.keptPath!).readAsBytesSync(), [9, 9, 9, 9, 9]);
    });

    test('3. the same by identity', () async {
      seed();
      final r = await replaceIfUnchanged(
        tmpFile(),
        p('a.bin'),
        null,
        identity: ContentIdentity.ofBytes([1, 2, 3]),
        afterFinalRead: (path) async =>
            File(path).writeAsBytesSync([9, 9, 9, 9, 9]),
      );
      expect(File(r.keptPath!).readAsBytesSync(), [9, 9, 9, 9, 9]);
    });

    test('6. the aside gone at V1: nothing kept, replaced', () async {
      seed();
      final r = await replaceIfUnchanged(tmpFile(), p('a.bin'), [
        1,
        2,
        3,
      ], beforeAsideDelete: (path) async => File(path).deleteSync());
      expect(r.outcome, ReplaceOutcome.replaced);
      expect(r.keptPath, isNull);
      expect(names(), ['a.bin']);
    });

    test('6. the drop file turned into a directory: nothing deleted', () async {
      seed();
      final r = await replaceIfUnchanged(
        tmpFile(),
        p('a.bin'),
        [1, 2, 3],
        beforeFinalCheck: (path) async {
          File(path).deleteSync();
          Directory(path).createSync();
          File('$path${Platform.pathSeparator}x').writeAsBytesSync([1]);
        },
      );
      expect(r.outcome, ReplaceOutcome.replaced);
      expect(r.keptPath, isNotNull);
      final dirs = dir.listSync().whereType<Directory>().toList();
      expect(dirs, hasLength(1));
      expect(
        File('${dirs.single.path}${Platform.pathSeparator}x').existsSync(),
        isTrue,
      );
    });
  });

  group('delete (deleteFileIfMatches)', () {
    for (final byIdentity in [false, true]) {
      final how = byIdentity ? 'identity' : 'bytes';
      Future<DeleteResult> del({
        Future<void> Function(String)? beforeAsideDelete,
        Future<void> Function(String)? beforeFinalCheck,
        Future<void> Function(String)? afterFinalRead,
        bool Function()? stillRedundant,
      }) => deleteFileIfMatches(
        p('a.bin'),
        bytes: byIdentity ? null : [1, 2, 3],
        identity: byIdentity ? ContentIdentity.ofBytes([1, 2, 3]) : null,
        beforeAsideDelete: beforeAsideDelete,
        beforeFinalCheck: beforeFinalCheck,
        afterFinalRead: afterFinalRead,
        stillRedundant: stillRedundant,
      );

      test('7. no swap deletes and leaves nothing ($how)', () async {
        seed();
        expect((await del()).deleted, isTrue);
        expect(names(), isEmpty);
      });

      test(
        '4. a swap at beforeAsideDelete is put back at the target ($how)',
        () async {
          seed();
          final r = await del(
            beforeAsideDelete: (path) async =>
                File(path).writeAsBytesSync([9, 9, 9, 9]),
          );
          expect(r.outcome, DeleteOutcome.changed);
          expect(File(p('a.bin')).readAsBytesSync(), [9, 9, 9, 9]);
          expect(names(), ['a.bin']);
        },
      );

      test('4. a swap at beforeFinalCheck is put back ($how)', () async {
        seed();
        final r = await del(
          beforeFinalCheck: (path) async =>
              File(path).writeAsBytesSync([9, 9, 9, 9]),
        );
        expect(r.outcome, DeleteOutcome.changed);
        expect(File(p('a.bin')).readAsBytesSync(), [9, 9, 9, 9]);
        expect(names(), ['a.bin']);
      });

      test(
        '4. a swap after the read (second stat) is put back ($how)',
        () async {
          seed();
          final r = await del(
            afterFinalRead: (path) async =>
                File(path).writeAsBytesSync([9, 9, 9, 9, 9]),
          );
          expect(r.outcome, DeleteOutcome.changed);
          expect(File(p('a.bin')).readAsBytesSync(), [9, 9, 9, 9, 9]);
        },
      );

      test(
        '4. a swap with the target taken meanwhile: changedKept ($how)',
        () async {
          seed();
          final r = await del(
            beforeFinalCheck: (path) async {
              File(path).writeAsBytesSync([9, 9, 9, 9]);
              File(p('a.bin')).writeAsBytesSync([4]);
            },
          );
          expect(r.outcome, DeleteOutcome.changedKept);
          expect(r.keptPath, contains('-recovered-'));
          expect(File(r.keptPath!).readAsBytesSync(), [9, 9, 9, 9]);
          expect(File(p('a.bin')).readAsBytesSync(), [4]);
        },
      );

      test(
        '6. the aside gone at V1: absent, or changed if the target is occupied ($how)',
        () async {
          seed();
          var r = await del(
            beforeAsideDelete: (path) async => File(path).deleteSync(),
          );
          expect(r.outcome, DeleteOutcome.absent);
          expect(names(), isEmpty);
          seed();
          r = await del(
            beforeAsideDelete: (path) async {
              File(path).deleteSync();
              File(p('a.bin')).writeAsBytesSync([4]);
            },
          );
          expect(r.outcome, DeleteOutcome.changed);
          expect(File(p('a.bin')).readAsBytesSync(), [4]);
        },
      );
    }

    test(
      '4. a late file at the old name is put back at the free target',
      () async {
        seed();
        late String old;
        final r = await deleteFileIfMatches(
          p('a.bin'),
          bytes: [1, 2, 3],
          beforeAsideDelete: (path) async => old = path,
          beforeFinalCheck: (_) async => File(old).writeAsBytesSync([5, 5]),
        );
        expect(r.outcome, DeleteOutcome.changed);
        expect(File(p('a.bin')).readAsBytesSync(), [5, 5]);
        expect(names(), ['a.bin']);
      },
    );

    test('6. the drop file is a directory: kept, never deleted', () async {
      seed();
      final r = await deleteFileIfMatches(
        p('a.bin'),
        bytes: [1, 2, 3],
        beforeFinalCheck: (path) async {
          File(path).deleteSync();
          Directory(path).createSync();
        },
      );
      expect(r.deleted, isFalse);
      expect(dir.listSync().whereType<Directory>(), hasLength(1));
    });

    test('5. the redundant copy replaced at beforeFinalCheck: aside put back, changed', () async {
      seed();
      File(p('b.bin')).writeAsBytesSync([1, 2, 3]);
      final r = await deleteFileIfMatches(
        p('a.bin'),
        bytes: [1, 2, 3],
        stillRedundant: redundant,
        beforeFinalCheck: (_) async => File(p('b.bin')).writeAsBytesSync([0]),
      );
      expect(r.outcome, DeleteOutcome.changed);
      expect(File(p('a.bin')).readAsBytesSync(), [1, 2, 3]);
      expect(names(), ['a.bin', 'b.bin']);
    });

    test('5. the redundant copy replaced at afterFinalRead: aside put back, changed', () async {
      seed();
      File(p('b.bin')).writeAsBytesSync([1, 2, 3]);
      final r = await deleteFileIfMatches(
        p('a.bin'),
        bytes: [1, 2, 3],
        stillRedundant: redundant,
        afterFinalRead: (_) async => File(p('b.bin')).deleteSync(),
      );
      // The sync check above throws on a missing file; it must not delete.
      expect(r.deleted, isFalse);
      expect(File(p('a.bin')).readAsBytesSync(), [1, 2, 3]);
    });
  });

  group('a late file with the drop file vanished or stuck (V5 on every way out)', () {
    test(
      'replace: the drop file vanished at the re-check: the late file is kept',
      () async {
        seed();
        late String old;
        final r = await replaceIfUnchanged(
          tmpFile(),
          p('a.bin'),
          [1, 2, 3],
          beforeAsideDelete: (path) async => old = path,
          beforeFinalCheck: (drop) async {
            File(drop).deleteSync();
            File(old).writeAsBytesSync([5, 5]);
          },
        );
        expect(r.outcome, ReplaceOutcome.replaced);
        expect(r.keptPath, contains('-recovered-'));
        expect(File(r.keptPath!).readAsBytesSync(), [5, 5]);
        expect(File(old).existsSync(), isFalse);
        expect(names(), hasLength(2));
      },
    );

    test('delete: the drop file vanished at the re-check: the late file goes back to the target', () async {
      seed();
      late String old;
      final r = await deleteFileIfMatches(
        p('a.bin'),
        bytes: [1, 2, 3],
        beforeAsideDelete: (path) async => old = path,
        beforeFinalCheck: (drop) async {
          File(drop).deleteSync();
          File(old).writeAsBytesSync([5, 5]);
        },
      );
      expect(r.outcome, DeleteOutcome.changed);
      expect(File(p('a.bin')).readAsBytesSync(), [5, 5]);
      expect(names(), ['a.bin']);
    });

    // An open handle stops the unlink on Windows only.
    final windows = Platform.isWindows;

    test(
      'replace: the delete fails with a late file: both are kept',
      () async {
        seed();
        late String old;
        RandomAccessFile? hold;
        final r = await replaceIfUnchanged(
          tmpFile(),
          p('a.bin'),
          [1, 2, 3],
          beforeAsideDelete: (path) async => old = path,
          beforeFinalCheck: (drop) async {
            hold = File(drop).openSync();
            File(old).writeAsBytesSync([5, 5]);
          },
        );
        hold!.closeSync();
        expect(r.outcome, ReplaceOutcome.replaced);
        expect(File(r.keptPath!).readAsBytesSync(), [
          1,
          2,
          3,
        ], reason: 'the stuck verified file');
        expect(r.alsoKept, hasLength(1));
        expect(r.alsoKept.single, contains('-recovered-'));
        expect(File(r.alsoKept.single).readAsBytesSync(), [5, 5]);
      },
      skip: windows
          ? false
          : 'needs a delete that fails (open handle, Windows)',
    );

    test(
      'delete: the delete fails with a late file: the late file is back at the target, the error names the other',
      () async {
        seed();
        late String old;
        RandomAccessFile? hold;
        await expectLater(
          deleteFileIfMatches(
            p('a.bin'),
            bytes: [1, 2, 3],
            beforeAsideDelete: (path) async => old = path,
            beforeFinalCheck: (drop) async {
              hold = File(drop).openSync();
              File(old).writeAsBytesSync([5, 5]);
            },
          ),
          throwsA(isA<FileSystemException>()),
        );
        hold!.closeSync();
        expect(File(p('a.bin')).readAsBytesSync(), [5, 5]);
        expect(File(old).existsSync(), isFalse);
      },
      skip: windows
          ? false
          : 'needs a delete that fails (open handle, Windows)',
    );

    test(
      'delete: the delete fails with a late file and the target taken: the error carries both kept paths',
      () async {
        seed();
        late String old;
        late String dropPath;
        RandomAccessFile? hold;
        Object? error;
        try {
          await deleteFileIfMatches(
            p('a.bin'),
            bytes: [1, 2, 3],
            beforeAsideDelete: (path) async => old = path,
            beforeFinalCheck: (drop) async {
              dropPath = drop;
              hold = File(drop).openSync();
              File(old).writeAsBytesSync([5, 5]);
              File(p('a.bin')).writeAsBytesSync([4]);
            },
          );
        } on Object catch (e) {
          error = e;
        }
        hold!.closeSync();
        expect(error, isA<KeptFileSystemException>());
        final kept = (error as KeptFileSystemException).keptPaths;
        expect(kept, contains(dropPath));
        final recovered = kept.singleWhere((k) => k.contains('-recovered-'));
        expect(File(recovered).readAsBytesSync(), [5, 5]);
        expect(File(p('a.bin')).readAsBytesSync(), [4]);
        expect(error.message, contains(recovered));
      },
      skip: windows
          ? false
          : 'needs a delete that fails (open handle, Windows)',
    );
  });

  group('V2 retries a brief I/O error before keeping the file', () {
    test(
      'a stat that fails once, then succeeds: replace deletes normally',
      () async {
        seed();
        final tmp = tmpFile();
        var failed = false;
        final r = await IOOverrides.runZoned(
          () => replaceIfUnchanged(tmp, p('a.bin'), [1, 2, 3]),
          createFile: (path) => _StatFile(Zone.root.run(() => File(path)), () {
            if (failed || !path.endsWith(verifiedSuffix)) return false;
            return failed = true;
          }),
        );
        expect(failed, isTrue);
        expect(r.outcome, ReplaceOutcome.replaced);
        expect(r.keptPath, isNull);
        expect(names(), ['a.bin']);
      },
    );

    test(
      'a stat that fails once, then succeeds: delete deletes normally',
      () async {
        seed();
        var failed = false;
        final r = await IOOverrides.runZoned(
          () => deleteFileIfMatches(p('a.bin'), bytes: [1, 2, 3]),
          createFile: (path) => _StatFile(Zone.root.run(() => File(path)), () {
            if (failed || !path.endsWith(verifiedSuffix)) return false;
            return failed = true;
          }),
        );
        expect(failed, isTrue);
        expect(r.deleted, isTrue);
        expect(names(), isEmpty);
      },
    );
  });

  group('PageStore', () {
    test('saveIfUnchanged passes the seams through', () async {
      final store = PageStore(dir);
      final page = NotedPage.create(
        PageMeta.create(id: 'p1', title: 'Old', order: 0),
      );
      await store.save(page);
      final text = await store.readText('p1');
      var seen = false;
      final r = await store.saveIfUnchanged(
        NotedPage.create(PageMeta.create(id: 'p1', title: 'New', order: 0)),
        text,
        beforeFinalCheck: (path) async {
          seen = true;
          File(path).writeAsStringSync('swapped');
        },
      );
      expect(seen, isTrue);
      expect(r.outcome, ReplaceOutcome.replaced);
      expect(File(r.keptPath!).readAsStringSync(), 'swapped');
    });
  });
}

void main() => runWithAndWithoutCoordinator(suite);
