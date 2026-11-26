// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/src/storage/exclusive_move.dart'
    show
        MoveStrategy,
        debugMoveStrategy,
        debugNoReplaceErrno,
        publishByRename;
import 'package:noted_core/src/storage/exclusive_publish.dart'
    show
        debugLinkCalls,
        debugLinkErrno,
        debugPublishAsAndroid,
        nonLinkPublisher;
import 'support/coordination_support.dart';
import 'support/page_save.dart';

void suite() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('noted_excl'));
  tearDown(() async => dir.delete(recursive: true));

  String p(String n) => '${dir.path}${Platform.pathSeparator}$n';

  test(
    'publishes to a free name with the right bytes and consumes the temp',
    () async {
      final tmp = File(p('a.tmp'))..writeAsBytesSync([1, 2, 3, 250]);
      expect(await publishExclusive(tmp, p('a.bin')), isTrue);
      expect(File(p('a.bin')).readAsBytesSync(), [1, 2, 3, 250]);
      expect(tmp.existsSync(), isFalse);
    },
  );

  test('fails on an existing name and leaves it and the temp alone', () async {
    File(p('a.bin')).writeAsBytesSync([9, 9]);
    final tmp = File(p('a.tmp'))..writeAsBytesSync([1, 2, 3]);
    expect(await publishExclusive(tmp, p('a.bin')), isFalse);
    expect(File(p('a.bin')).readAsBytesSync(), [9, 9]);
    expect(tmp.readAsBytesSync(), [1, 2, 3]);
  });

  test('handles non-ASCII names', () async {
    final tmp = File(p('é.tmp'))..writeAsBytesSync([7]);
    expect(await publishExclusive(tmp, p('é ü.bin')), isTrue);
    expect(File(p('é ü.bin')).readAsBytesSync(), [7]);
  });

  test('saveNew publishes a new page and fails on an existing file', () async {
    final store = PageStore(dir);
    final page = NotedPage.create(
      PageMeta.create(id: 'p1', title: 'One', order: 0),
    );
    expect(await store.saveNew(page), isTrue);
    expect((await PageStore(dir).scan()).single, isA<ReadablePage>());
    final before = File(store.pathFor('p1')).readAsBytesSync();

    final other = page.withMeta(page.meta.withTitle('Other'));
    expect(await store.saveNew(other), isFalse);
    expect(File(store.pathFor('p1')).readAsBytesSync(), before);
    expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
  });

  test(
    'a file created between writing the temp and publishing is not replaced',
    () async {
      final store = PageStore(dir);
      final page = NotedPage.create(
        PageMeta.create(id: 'p1', title: 'Mine', order: 0),
      );
      final theirs = [1, 2, 3, 4];
      final ok = await store.saveNew(
        page,
        beforePublish: () async =>
            File(store.pathFor('p1')).writeAsBytesSync(theirs),
      );
      expect(ok, isFalse);
      expect(File(store.pathFor('p1')).readAsBytesSync(), theirs);
      expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    },
  );

  test('other failures throw FileSystemException', () async {
    final missingTmp = File(p('nope.tmp'));
    expect(
      () => publishExclusive(missingTmp, p('x.bin')),
      throwsA(isA<FileSystemException>()),
    );
    final tmp = File(p('a.tmp'))..writeAsBytesSync([1]);
    expect(
      () => publishExclusive(tmp, p('no_dir${Platform.pathSeparator}x.bin')),
      throwsA(isA<FileSystemException>()),
    );
    expect(tmp.existsSync(), isTrue);
  });

  test('a target created right before the OS call is not replaced', () async {
    final tmp = File(p('a.tmp'))..writeAsBytesSync([1, 2, 3]);
    final ok = await publishExclusive(
      tmp,
      p('a.bin'),
      beforeOsCall: () => File(p('a.bin')).writeAsBytesSync([9]),
    );
    expect(ok, isFalse);
    expect(File(p('a.bin')).readAsBytesSync(), [9]);
  });

  test('saveNew removes its temp file when publishing throws', () async {
    final store = PageStore(
      Directory('${dir.path}${Platform.pathSeparator}gone'),
    );
    final page = NotedPage.create(
      PageMeta.create(id: 'p1', title: '', order: 0),
    );
    // The folder doesn't exist, so even writing the temp file throws.
    await expectLater(store.saveNew(page), throwsA(isA<FileSystemException>()));
    expect(dir.listSync(recursive: true).whereType<File>(), isEmpty);
    // Publish throws after the temp is written: the target is a directory name
    // that can't be linked to because its parent is a file.
    final blocker = File(p('blocker'))..writeAsStringSync('x');
    final s2 = PageStore(Directory(blocker.path));
    await expectLater(s2.saveNew(page), throwsA(isA<FileSystemException>()));
    expect(dir.listSync().whereType<File>().map((f) => f.path), [blocker.path]);
  });

  test('saveNew removes its temp when publishing is interrupted', () async {
    final store = PageStore(dir);
    final page = NotedPage.create(
      PageMeta.create(id: 'p1', title: '', order: 0),
    );
    await expectLater(
      store.saveNew(page, beforePublish: () async => throw StateError('boom')),
      throwsA(isA<StateError>()),
    );
    expect(dir.listSync().whereType<File>(), isEmpty);
  });

  test('a path over 260 characters publishes', () async {
    var deep = dir.path;
    while (deep.length < 300) {
      deep = '$deep${Platform.pathSeparator}${'d' * 40}';
    }
    final long = await Directory(deep).create(recursive: true);
    final tmp = File('${long.path}${Platform.pathSeparator}a.tmp')
      ..writeAsBytesSync([5]);
    final target = '${long.path}${Platform.pathSeparator}a.bin';
    expect(await publishExclusive(tmp, target), isTrue);
    expect(File(target).readAsBytesSync(), [5]);
    final tmp2 = File('${long.path}${Platform.pathSeparator}b.tmp')
      ..writeAsBytesSync([6]);
    expect(await publishExclusive(tmp2, target), isFalse);
  });

  test('relative and forward-slash paths publish', () async {
    final tmp = File(p('r.tmp'))..writeAsBytesSync([1]);
    final fwd = p('f.bin').replaceAll(r'\', '/');
    expect(await publishExclusive(tmp, fwd), isTrue);
    expect(File(p('f.bin')).readAsBytesSync(), [1]);
    final old = Directory.current;
    Directory.current = dir;
    try {
      final tmp2 = File('s.tmp')..writeAsBytesSync([2]);
      // POSIX resolves `..` through the real folder, so it must exist.
      Directory('sub').createSync();
      expect(await publishExclusive(tmp2, 'sub/../s.bin'), isTrue);
    } finally {
      Directory.current = old;
    }
    expect(File(p('s.bin')).readAsBytesSync(), [2]);
  });

  test('Windows refuses trailing-dot and device names', () async {
    final tmp = File(p('a.tmp'))..writeAsBytesSync([1]);
    for (final bad in ['x.', 'x ', 'NUL', 'nul.txt', 'COM1', 'lpt9.x', 'CON']) {
      expect(
        () => publishExclusive(tmp, p(bad)),
        throwsA(isA<FileSystemException>()),
        reason: bad,
      );
    }
    expect(tmp.existsSync(), isTrue);
  }, skip: !Platform.isWindows);

  test('plain save still replaces', () async {
    final store = PageStore(dir);
    final page = NotedPage.create(
      PageMeta.create(id: 'p1', title: 'One', order: 0),
    );
    File(store.pathFor('p1')).writeAsStringSync('old');
    await store.save(page);
    expect((await store.load('p1')).meta.title, 'One');
  });

  // Android: `link` is refused by SELinux, so the publisher renames instead.
  // Every case forces the Android branch and registers the publisher.
  group('Android publish', () {
    setUp(() {
      debugPublishAsAndroid = true;
      useRenamePublishOnAndroid();
      debugLinkCalls = 0;
    });
    tearDown(() {
      debugPublishAsAndroid = null;
      nonLinkPublisher = null;
      debugLinkErrno = null;
      debugNoReplaceErrno = null;
      debugMoveStrategy = null;
      debugLinkCalls = 0;
    });

    test('where link works it publishes by link, once', () async {
      final tmp = File(p('a.tmp'))..writeAsBytesSync([1, 2, 3]);
      expect(await publishExclusive(tmp, p('a.bin')), isTrue);
      expect(File(p('a.bin')).readAsBytesSync(), [1, 2, 3]);
      expect(tmp.existsSync(), isFalse);
      expect(debugLinkCalls, 1);
    }, skip: Platform.isWindows);

    final strategies = <MoveStrategy>[
      MoveStrategy.lstatRename,
      if (Platform.isLinux) MoveStrategy.native,
    ];
    for (final strategy in strategies) {
      for (final errno in [13, 1]) {
        group('link refused with errno $errno, ${strategy.name}', () {
          setUp(() {
            debugLinkErrno = errno;
            debugMoveStrategy = strategy;
          });

          test('publishes to a free name and consumes the temp', () async {
            final tmp = File(p('a.tmp'))..writeAsBytesSync([4, 5, 6]);
            expect(await publishExclusive(tmp, p('a.bin')), isTrue);
            expect(File(p('a.bin')).readAsBytesSync(), [4, 5, 6]);
            expect(tmp.existsSync(), isFalse);
            expect(debugLinkCalls, 1);
          });

          test('a file at the target gives false, both untouched', () async {
            File(p('a.bin')).writeAsBytesSync([9, 9]);
            final tmp = File(p('a.tmp'))..writeAsBytesSync([1]);
            expect(await publishExclusive(tmp, p('a.bin')), isFalse);
            expect(File(p('a.bin')).readAsBytesSync(), [9, 9]);
            expect(tmp.readAsBytesSync(), [1]);
          });

          test('a folder at the target gives false, both untouched', () async {
            Directory(p('a.bin')).createSync();
            File(p('a.bin${Platform.pathSeparator}x')).writeAsBytesSync([7]);
            final tmp = File(p('a.tmp'))..writeAsBytesSync([1]);
            expect(await publishExclusive(tmp, p('a.bin')), isFalse);
            expect(
              File(p('a.bin${Platform.pathSeparator}x')).readAsBytesSync(),
              [7],
            );
            expect(tmp.readAsBytesSync(), [1]);
          });

          test('a dangling link at the target gives false', () async {
            Link(p('a.bin')).createSync(p('nowhere'));
            final tmp = File(p('a.tmp'))..writeAsBytesSync([1]);
            expect(await publishExclusive(tmp, p('a.bin')), isFalse);
            expect(Link(p('a.bin')).targetSync(), p('nowhere'));
            expect(tmp.readAsBytesSync(), [1]);
          }, skip: Platform.isWindows);

          test('a stub at the target gives false, both untouched', () async {
            File(p('.a.bin.icloud')).writeAsBytesSync([8]);
            final tmp = File(p('a.tmp'))..writeAsBytesSync([1]);
            expect(await publishExclusive(tmp, p('a.bin')), isFalse);
            expect(File(p('.a.bin.icloud')).readAsBytesSync(), [8]);
            expect(File(p('a.bin')).existsSync(), isFalse);
            expect(tmp.readAsBytesSync(), [1]);
          });

          test('a target created before the OS call is kept; the hook runs once', () async {
            final tmp = File(p('a.tmp'))..writeAsBytesSync([1, 2]);
            var hooked = 0;
            final ok = await publishExclusive(
              tmp,
              p('a.bin'),
              beforeOsCall: () {
                hooked++;
                File(p('a.bin')).writeAsBytesSync([9]);
              },
            );
            expect(ok, isFalse);
            expect(File(p('a.bin')).readAsBytesSync(), [9]);
            expect(tmp.readAsBytesSync(), [1, 2]);
            expect(hooked, 1);
          });

          test('a missing folder throws', () async {
            final tmp = File(p('a.tmp'))..writeAsBytesSync([1]);
            await expectLater(
              publishExclusive(tmp, p('no${Platform.pathSeparator}a.bin')),
              throwsA(isA<FileSystemException>()),
            );
            expect(tmp.readAsBytesSync(), [1]);
          });
        });
      }
    }

    test('another link errno throws, names the errno and renames nothing', () async {
      debugLinkErrno = 28;
      debugMoveStrategy = MoveStrategy.lstatRename;
      final tmp = File(p('a.tmp'))..writeAsBytesSync([1]);
      await expectLater(
        publishExclusive(tmp, p('a.bin')),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('errno 28'),
          ),
        ),
      );
      expect(File(p('a.bin')).existsSync(), isFalse);
      expect(tmp.readAsBytesSync(), [1]);
    });

    test('a renameat2 that is missing or refuses falls to the lstat path', () async {
      debugLinkErrno = 13;
      debugMoveStrategy = MoveStrategy.native;
      for (final errno in [38, 22]) {
        debugNoReplaceErrno = errno;
        final tmp = File(p('a$errno.tmp'))..writeAsBytesSync([errno]);
        expect(await publishExclusive(tmp, p('a$errno.bin')), isTrue);
        expect(File(p('a$errno.bin')).readAsBytesSync(), [errno]);
        expect(tmp.existsSync(), isFalse);
        // A taken target is still false.
        final tmp2 = File(p('b$errno.tmp'))..writeAsBytesSync([1]);
        expect(await publishExclusive(tmp2, p('a$errno.bin')), isFalse);
        expect(File(p('a$errno.bin')).readAsBytesSync(), [errno]);
        expect(tmp2.existsSync(), isTrue);
      }
    }, skip: !Platform.isLinux);

    test('a renameat2 refused as busy throws and moves nothing', () async {
      debugLinkErrno = 13;
      debugMoveStrategy = MoveStrategy.native;
      debugNoReplaceErrno = 13;
      final tmp = File(p('a.tmp'))..writeAsBytesSync([1]);
      await expectLater(
        publishExclusive(tmp, p('a.bin')),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            allOf(contains('busy'), contains('errno 13')),
          ),
        ),
      );
      expect(File(p('a.bin')).existsSync(), isFalse);
      expect(tmp.readAsBytesSync(), [1]);
    }, skip: !Platform.isLinux);

    test('with no publisher registered a refused link throws and nothing is replaced', () async {
      nonLinkPublisher = null;
      debugLinkErrno = 13;
      final tmp = File(p('a.tmp'))..writeAsBytesSync([1]);
      await expectLater(
        publishExclusive(tmp, p('a.bin')),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(p('a.bin')).existsSync(), isFalse);
      expect(tmp.readAsBytesSync(), [1]);
      // Over a taken name it is false, not a replace.
      File(p('a.bin')).writeAsBytesSync([9]);
      expect(await publishExclusive(tmp, p('a.bin')), isFalse);
      expect(File(p('a.bin')).readAsBytesSync(), [9]);
    });

    test('useRenamePublishOnAndroid registers the publisher only on Android', () {
      nonLinkPublisher = null;
      debugPublishAsAndroid = false;
      useRenamePublishOnAndroid();
      expect(nonLinkPublisher, isNull);
      debugPublishAsAndroid = true;
      useRenamePublishOnAndroid();
      expect(nonLinkPublisher, same(publishByRename));
    });
  });
}

void main() => runWithAndWithoutCoordinator(suite);
