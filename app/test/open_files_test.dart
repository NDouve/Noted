// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/open_files.dart';
import 'package:noted/src/save_trouble.dart';
import 'package:noted_core/noted_core.dart';

typedef _S = ({Notebook nb, String id, String orig, String copy});

/// A page store whose compare-and-delete of [failDelete] fails, like a source
/// drive that went away.
class _FailDeleteStore extends PageStore {
  _FailDeleteStore(super.directory);

  final Set<String> failDelete = {};

  @override
  Future<DeleteResult> deleteIfUnchanged(
    String pageId,
    String expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    Future<void> Function()? beforeDelete,
    void Function()? beforeRestore,
  }) {
    if (failDelete.contains(pageId)) throw const FileSystemException('drive gone');
    return super.deleteIfUnchanged(
      pageId,
      expectedText,
      beforeMoveAside: beforeMoveAside,
      afterRead: afterRead,
      beforeDelete: beforeDelete,
      beforeRestore: beforeRestore,
    );
  }
}

void main() {
  late Directory root;
  late Directory pages;
  late List<Notebook> opened;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_openfiles');
    pages = await Directory('${root.path}/pages').create();
    opened = [];
  });

  tearDown(() async {
    for (final nb in opened) {
      await nb.flush();
      // Checks a release queued (twice: a check can queue the next) are done
      // before the folder goes.
      await nb.checkFile('settled.txt');
      await nb.checkFile('settled.txt');
      nb.dispose();
    }
    await root.delete(recursive: true);
  });

  // A notebook of its own (own pages folder and binders.json).
  Notebook make(
    String name, [
    Directory? pagesDir,
    bool recovery = false,
    PageStore Function(Directory)? storeFactory,
  ]) {
    final nb = Notebook(
      PageStore(pagesDir ?? Directory('${root.path}/$name-pages')),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/$name/binders.json'),
      watchFiles: false,
      storeFactory: storeFactory ?? PageStore.new,
      // A short window, so a locked open page is blocked at once.
      busyReadWindow: const Duration(milliseconds: 200),
      recoveryDirectory: recovery ? Directory('${root.path}/$name-recovery') : null,
    );
    opened.add(nb);
    return nb;
  }

  group('arguments', () {
    test('flags and empty arguments are skipped', () {
      expect(openArgs(['--flag', '', 'a.canvas', 'b']), ['a.canvas', 'b']);
      expect(openArgs([]), isEmpty);
    });
  });

  group('resolveOpenPath', () {
    test(
      'accepts an existing page file or binder file, as an absolute path',
      () {
        final page = File('${root.path}/x.canvas')..writeAsStringSync('{}');
        final binder = File('${root.path}/noted-binder.json')
          ..writeAsStringSync('{}');
        String n(String p) => p.replaceAll(r'\', '/');
        expect(n(resolveOpenPath(page.path)), n(page.absolute.path));
        expect(n(resolveOpenPath(binder.path)), n(binder.absolute.path));
        // ".." segments are resolved.
        final sub = Directory('${root.path}/sub')..createSync();
        expect(
          n(resolveOpenPath('${sub.path}/../x.canvas')),
          n(page.absolute.path),
        );
      },
    );

    test('anything else is refused', () {
      File('${root.path}/notes.txt').writeAsStringSync('x');
      File('${root.path}/other.json').writeAsStringSync('{}');
      File('${root.path}/x-noted-binder.json').writeAsStringSync('{}');
      Directory('${root.path}/dir.canvas').createSync();
      for (final bad in [
        '',
        '${root.path}/notes.txt',
        '${root.path}/other.json',
        '${root.path}/x-noted-binder.json',
        '${root.path}/missing.canvas',
        '${root.path}/dir.canvas',
        '${root.path}/a\u0000.canvas',
      ]) {
        expect(
          () => resolveOpenPath(bad),
          throwsA(isA<NotebookException>()),
          reason: bad,
        );
      }
    });
  });

  group('channel', () {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    const codec = StandardMethodCodec();

    tearDown(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        OpenFileService.channel,
        null,
      );
      OpenFileService.channel.setMethodCallHandler(null);
    });

    test(
      'start asks "ready", opens what was held, then opens "open" calls',
      () async {
        final elsewhere = await Directory('${root.path}/Elsewhere').create();
        final later = await Directory('${root.path}/Later').create();
        final other = make('other');
        await other.load();
        final held = await other.createPage(folderPath: elsewhere.path);
        final sent = await other.createPage(folderPath: later.path);
        await other.flush();

        final calls = <String>[];
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          OpenFileService.channel,
          (call) async {
            calls.add(call.method);
            return call.method == 'ready'
                ? ['${elsewhere.path}/$held.canvas']
                : null;
          },
        );
        final nb = make('main', pages);
        await nb.load();
        final service = OpenFileService(nb);
        await service.start([]);
        expect(calls, ['ready']);
        expect(nb.currentId, held);

        // The runner hands over a second launch's file.
        await binding.defaultBinaryMessenger.handlePlatformMessage(
          'noted/open_files',
          codec.encodeMethodCall(
            MethodCall('open', '${later.path}/$sent.canvas'),
          ),
          (_) {},
        );
        expect(nb.currentId, sent);
      },
    );

    test('an "open" call with a bad path is a notice, not an error', () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        OpenFileService.channel,
        (call) async => <Object?>[],
      );
      final nb = make('main', pages);
      await nb.load();
      final notices = <String>[];
      final service = OpenFileService(nb)..notify = notices.add;
      await service.start([]);
      final before = nb.currentId;
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        'noted/open_files',
        codec.encodeMethodCall(MethodCall('open', '${root.path}/x.txt')),
        (_) {},
      );
      expect(notices, hasLength(1));
      expect(nb.currentId, before);
    });
  });

  group('openExistingFile', () {
    test(
      'a standalone page joins its folder as a standalone folder and opens',
      () async {
        final elsewhere = await Directory('${root.path}/Elsewhere').create();
        final other = make('other');
        await other.load();
        final id = await other.createPage(folderPath: elsewhere.path);
        await other.flush();

        final nb = make('main', pages);
        await nb.load();
        expect(nb.pageTitleOf(id), isNull);
        await openExistingFile(nb, '${elsewhere.path}/$id.canvas');
        expect(nb.currentId, id);
        expect(
          nb.standaloneFolders.single.path.replaceAll(r'\', '/'),
          Directory(elsewhere.path).absolute.path.replaceAll(r'\', '/'),
        );
        // Opening again changes nothing.
        await openExistingFile(nb, '${elsewhere.path}/$id.canvas');
        expect(nb.standaloneFolders, hasLength(1));
        expect(nb.currentId, id);
      },
    );

    test('a page inside a binder folder joins that binder', () async {
      final dir = await Directory('${root.path}/Work').create();
      final other = make('other');
      await other.load();
      final section = await other.addBinder(dir.path);
      final id = await other.createPage(binderPath: section.path);
      await other.flush();

      final nb = make('main', pages);
      await nb.load();
      await openExistingFile(nb, '${dir.path}/$id.canvas');
      expect(nb.currentId, id);
      expect(nb.binders.single.available, isTrue);
      expect(nb.binderOfPage(id), isNotNull);
      expect(nb.standaloneFolders, isEmpty);
    });

    test('a copy in a folder not joined yet is refused, also while the original '
        'is open; its folder is not left joined', () async {
      final elsewhere = await Directory('${root.path}/Elsewhere').create();
      final backup = await Directory('${root.path}/Backup').create();
      final other = make('other');
      await other.load();
      final id = await other.createPage(folderPath: elsewhere.path);
      await other.flush();
      File('${elsewhere.path}/$id.canvas')
          .copySync('${backup.path}/$id.canvas');

      final nb = make('main', pages);
      await nb.load();
      await openExistingFile(nb, '${elsewhere.path}/$id.canvas');
      expect(nb.currentId, id); // the page is the open one
      for (var i = 0; i < 2; i++) {
        final before = nb.currentId;
        await expectLater(
          openExistingFile(nb, '${backup.path}/$id.canvas'),
          throwsA(isA<NotebookException>()),
        );
        expect(nb.currentId, before);
        expect(nb.standaloneFolders, hasLength(1));
        expect(nb.unreadable, isEmpty);
        // Another page open: still refused.
        if (i == 0) await nb.open(await nb.createPage());
      }
      expect(nb.pageTitleOf(id), isNotNull);
    });

    test('a copy in a folder already joined is opened, the other file '
        'listed as the duplicate', () async {
      final elsewhere = await Directory('${root.path}/Elsewhere').create();
      final other = make('other');
      await other.load();
      final id = await other.createPage(folderPath: elsewhere.path);
      await other.flush();
      File('${elsewhere.path}/$id.canvas')
          .copySync('${elsewhere.path}/backup.canvas');
      final nb = make('main', pages);
      await nb.load();
      await nb.addStandaloneFolder(elsewhere.path);
      // Which of the two files the scan keeps depends on the listing order;
      // the one it lists as a duplicate is the one asked for.
      final dup = nb.unreadable.singleWhere(
        (u) => u.reason.startsWith('duplicate page id'),
      );
      await openExistingFile(nb, dup.path);
      expect(nb.currentId, id);
      expect(nb.standaloneFolders, hasLength(1));
      expect(nb.unreadable, hasLength(1));
      expect(nb.unreadable.single.path, isNot(dup.path));
    });

    test('a file damaged or from a newer version is still refused', () async {
      final dir = await Directory('${root.path}/Elsewhere').create();
      final other = make('other');
      await other.load();
      final id = await other.createPage(folderPath: dir.path);
      await other.flush();
      final nb = make('main', pages);
      await nb.load();
      await nb.addStandaloneFolder(dir.path);
      File('${dir.path}/damaged.canvas').writeAsStringSync('not a page');
      await expectLater(
        openExistingFile(nb, '${dir.path}/damaged.canvas'),
        throwsA(isA<NotebookException>()),
      );
      expect(nb.pageTitleOf(id), isNotNull);
    });

    group('a copy that arrives after its folder was joined', () {
      // Closing a page queues a look at its chosen file (R7); this waits for
      // it, so a test that then changes that file isn't racing a read of it.
      Future<void> settled(Notebook nb) => nb.checkFile('settled.txt');

      // A page called Original in [dir] (a binder when [binder]); the notebook
      // joins the folder, then a copy called Copy appears beside it.
      Future<({Notebook nb, String id, String orig, String copy})> setup(
        Directory dir,
        Directory copyDir, {
        bool binder = false,
        bool recovery = false,
      }) async {
        final other = make('other');
        await other.load();
        late String id;
        if (binder) {
          final s = await other.addBinder(dir.path);
          id = await other.createPage(binderPath: s.path);
        } else {
          id = await other.createPage(folderPath: dir.path);
        }
        await other.rename(id, 'Original');
        await other.flush();
        final nb = make('main', pages, recovery);
        await nb.load();
        if (binder) {
          await nb.addBinder(dir.path);
        } else {
          await nb.addStandaloneFolder(dir.path);
        }
        if (copyDir.path != dir.path) {
          if (binder) {
            await nb.addBinder(copyDir.path);
          } else {
            await nb.addStandaloneFolder(copyDir.path);
          }
        }
        final orig = '${dir.path}/$id.canvas';
        final copy = '${copyDir.path}/copy-of-$id.canvas';
        File(copy).writeAsStringSync(
          File(orig).readAsStringSync().replaceAll('Original', 'Copy'),
        );
        return (nb: nb, id: id, orig: orig, copy: copy);
      }

      test('in one standalone folder: the copy opens, the original is the '
          'duplicate', () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        expect(s.nb.pageTitleOf(s.id), 'Original');
        await openExistingFile(s.nb, s.copy);
        expect(s.nb.currentId, s.id);
        expect(s.nb.pageTitleOf(s.id), 'Copy');
        expect(
          s.nb.unreadable.map((u) => u.path.replaceAll(r'\', '/')),
          [s.orig.replaceAll(r'\', '/')],
        );
        expect(File(s.orig).readAsStringSync(), contains('Original'));
        expect(File(s.copy).readAsStringSync(), contains('Copy'));
      });

      test('between two standalone folders', () async {
        final a = await Directory('${root.path}/A').create();
        final b = await Directory('${root.path}/B').create();
        final s = await setup(a, b);
        await openExistingFile(s.nb, s.copy);
        expect(s.nb.currentId, s.id);
        expect(s.nb.pageTitleOf(s.id), 'Copy');
        expect(s.nb.unreadable, hasLength(1));
        expect(File(s.orig).readAsStringSync(), contains('Original'));
      });

      test('in one binder', () async {
        final dir = await Directory('${root.path}/Work').create();
        final s = await setup(dir, dir, binder: true);
        await openExistingFile(s.nb, s.copy);
        expect(s.nb.currentId, s.id);
        expect(s.nb.pageTitleOf(s.id), 'Copy');
        expect(s.nb.binders.single.unreadable, hasLength(1));
        expect(File(s.orig).readAsStringSync(), contains('Original'));
      });

      test('the choice survives a later scan; edits land in the copy', () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        final origBytes = File(s.orig).readAsBytesSync();
        await openExistingFile(s.nb, s.copy);
        final loc = s.nb.standaloneFolders.single.path;
        final entries = await s.nb.scanLocationForTest(loc);
        expect(
          entries.whereType<ReadablePage>().single.path.replaceAll(r'\', '/'),
          s.copy.replaceAll(r'\', '/'),
        );
        await s.nb.rename(s.id, 'Edited');
        await s.nb.flush();
        expect(File(s.copy).readAsStringSync(), contains('Edited'));
        expect(File(s.orig).readAsBytesSync(), origBytes);
      });

      test('after a restart, opening the copy again chooses it again', () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        await openExistingFile(s.nb, s.copy);
        await s.nb.flush();
        s.nb.dispose();
        opened.remove(s.nb);
        final again = make('main', pages);
        await again.load();
        await openExistingFile(again, s.copy);
        expect(again.currentId, s.id);
        expect(again.pageTitleOf(s.id), 'Copy');
        expect(File(s.orig).readAsStringSync(), contains('Original'));
      });

      test('the open page whose own file was deleted does not overwrite the '
          'copy', () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        await s.nb.open(s.id);
        File(s.orig).deleteSync();
        await s.nb.checkFile(s.orig);
        final copyBytes = File(s.copy).readAsBytesSync();
        await openExistingFile(s.nb, s.copy);
        expect(s.nb.pageTitleOf(s.id), 'Copy');
        await s.nb.flush();
        expect(File(s.copy).readAsBytesSync(), copyBytes);
        await s.nb.rename(s.id, 'Edited');
        await s.nb.flush();
        expect(File(s.copy).readAsStringSync(), contains('Edited'));
      });

      test('unsaved edits on the open original are saved to it first', () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        await s.nb.open(s.id);
        await s.nb.rename(s.id, 'Edited');
        final copyBytes = File(s.copy).readAsBytesSync();
        await openExistingFile(s.nb, s.copy);
        expect(s.nb.pageTitleOf(s.id), 'Copy');
        expect(File(s.orig).readAsStringSync(), contains('Edited'));
        expect(File(s.copy).readAsBytesSync(), copyBytes);
      });

      test('when the adopted file goes (page closed) the original is the page '
          'again; if it comes back, registration, store and tree agree', () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        await openExistingFile(s.nb, s.copy);
        await s.nb.open(await s.nb.createPage());
        await settled(s.nb);
        final copyText = File(s.copy).readAsStringSync();
        File(s.copy).deleteSync();
        await s.nb.checkFile(s.copy);
        // Seen missing once: nothing is promoted until a later check agrees.
        expect(s.nb.pageTitleOf(s.id), isNull);
        await s.nb.checkFolders();
        expect(s.nb.unreadable, isEmpty);
        expect(s.nb.pageTitleOf(s.id), 'Original');
        expect(s.nb.tree.roots.map((r) => r.id), contains(s.id));
        final loc = s.nb.standaloneFolders.single.path;

        File(s.copy).writeAsStringSync(copyText);
        final entries = await s.nb.scanLocationForTest(loc);
        await s.nb.checkFile(s.copy);
        String n(String p) => p.replaceAll(r'\', '/').toLowerCase();
        expect(
          entries.whereType<ReadablePage>().single.path.endsWith(
            s.orig.split(RegExp(r'[\/]')).last,
          ),
          isTrue,
        );
        expect(s.nb.unreadable.map((u) => n(u.path)), [n(s.copy)]);
        expect(s.nb.pageTitleOf(s.id), 'Original');
        expect(s.nb.tree.roots.map((r) => r.id), contains(s.id));
        await s.nb.open(s.id);
        expect(s.nb.pageTitleOf(s.id), 'Original');
        await s.nb.rename(s.id, 'Edited');
        await s.nb.flush();
        expect(File(s.orig).readAsStringSync(), contains('Edited'));
        expect(File(s.copy).readAsStringSync(), copyText);
      });

      test('a chosen file that is back before the next check is kept', () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        await openExistingFile(s.nb, s.copy);
        await s.nb.open(await s.nb.createPage());
        await settled(s.nb);
        final copyText = File(s.copy).readAsStringSync();
        File(s.copy).deleteSync();
        await s.nb.checkFile(s.copy);
        File(s.copy).writeAsStringSync(copyText);
        await s.nb.checkFile(s.copy);
        await s.nb.checkFolders();
        expect(s.nb.pageTitleOf(s.id), 'Copy');
        expect(s.nb.unreadable, hasLength(1));
        expect(s.nb.unreadable.single.path, isNot(endsWith('copy-of-${s.id}.canvas')));
      });

      test('a chosen file that is back but refuses reads at the confirming '
          'check keeps the choice; once readable, edits go to it', () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        await openExistingFile(s.nb, s.copy);
        await s.nb.open(await s.nb.createPage());
        await settled(s.nb);
        final copyText = File(s.copy).readAsStringSync();
        File(s.copy).deleteSync();
        await s.nb.checkFile(s.copy);
        File(s.copy).writeAsStringSync(copyText);
        final raf = File(s.copy).openSync(mode: FileMode.append)
          ..lockSync(FileLock.exclusive);
        try {
          await s.nb.checkFolders(); // the confirming tick: the file can't be read
        } finally {
          raf.unlockSync();
          raf.closeSync();
        }
        await s.nb.checkFolders();
        expect(s.nb.pageTitleOf(s.id), 'Copy');
        await s.nb.open(s.id);
        await s.nb.rename(s.id, 'Edited');
        await s.nb.flush();
        expect(File(s.copy).readAsStringSync(), contains('Edited'));
        expect(File(s.orig).readAsStringSync(), isNot(contains('Edited')));
      }, skip: Platform.isWindows ? null : 'byte-range locks only block reads on Windows');

      for (final (what, damage) in <(String, List<int> Function(String))>[
        ('truncated JSON', (t) => t.substring(0, t.length ~/ 2).codeUnits),
        ('invalid UTF-8', (t) => [0xff, 0xfe, 0xfd, 0x80]),
      ]) {
        test('a chosen file back as $what at the confirming check keeps the '
            'choice; once complete, edits go to it', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          await openExistingFile(s.nb, s.copy);
          await s.nb.open(await s.nb.createPage());
          await settled(s.nb);
          final copyText = File(s.copy).readAsStringSync();
          File(s.copy).deleteSync();
          await s.nb.checkFile(s.copy);
          File(s.copy).writeAsBytesSync(damage(copyText));
          await s.nb.checkFolders(); // the confirming tick
          File(s.copy).writeAsStringSync(copyText);
          await s.nb.checkFolders();
          expect(s.nb.pageTitleOf(s.id), 'Copy');
          await s.nb.open(s.id);
          await s.nb.rename(s.id, 'Edited');
          await s.nb.flush();
          expect(File(s.copy).readAsStringSync(), contains('Edited'));
          expect(File(s.orig).readAsStringSync(), isNot(contains('Edited')));
        });
      }

      test('the promoted duplicate prefers <id>.canvas and skips '
          'conflict-copy names', () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        await openExistingFile(s.nb, s.copy);
        final shaped = '${dir.path}/aa-bb.canvas';
        File(shaped).writeAsBytesSync(File(s.orig).readAsBytesSync());
        await s.nb.checkFile(shaped);
        await s.nb.open(await s.nb.createPage());
        await settled(s.nb);
        File(s.copy).deleteSync();
        await s.nb.checkFile(s.copy);
        await s.nb.checkFolders();
        expect(s.nb.pageTitleOf(s.id), 'Original');
        expect(s.nb.unreadable.map((u) => u.path), [
          predicate<String>((p) => p.endsWith('aa-bb.canvas')),
        ]);
      });

      test('closing a page whose chosen file is gone settles it at the next '
          'check', () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        await openExistingFile(s.nb, s.copy);
        File(s.copy).deleteSync();
        await s.nb.checkFile(s.copy);
        expect(s.nb.currentId, s.id);
        await s.nb.open(await s.nb.createPage());
        await s.nb.checkFolders();
        expect(s.nb.pageTitleOf(s.id), 'Original');
        expect(s.nb.unreadable, isEmpty);
        expect(s.nb.tree.roots.map((r) => r.id), contains(s.id));
      });

      test('a file that changes while the open page is closed for the swap '
          'is not adopted', () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        await s.nb.open(s.id);
        s.nb.syncHook = (point, path) async {
          if (point == 'adopt-closed') {
            File(s.copy).writeAsStringSync(
              File(s.copy).readAsStringSync().replaceAll('Copy', 'Other'),
            );
          }
        };
        await expectLater(
          openExistingFile(s.nb, s.copy),
          throwsA(isA<NotebookException>()),
        );
        s.nb.syncHook = null;
        expect(s.nb.currentId, s.id); // the closed page is shown again
        expect(s.nb.pageTitleOf(s.id), 'Original');
        expect(s.nb.unreadable, isEmpty);
      });

      test('a folder that goes and comes back while the adopted page is open '
          'and its file is gone keeps the page', () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        await openExistingFile(s.nb, s.copy);
        final away = '${dir.path}-away';
        dir.renameSync(away);
        await s.nb.checkFolders();
        File('$away/copy-of-${s.id}.canvas').deleteSync();
        Directory(away).renameSync(dir.path);
        await s.nb.checkFolders();
        await s.nb.rename(s.id, 'Edited');
        await s.nb.flush();
        await s.nb.open(await s.nb.createPage());
        await s.nb.checkFile(s.copy);
        await s.nb.checkFolders();
        expect(s.nb.tree.roots.map((r) => r.id), contains(s.id));
        expect(s.nb.pageTitleOf(s.id), 'Edited');
        expect(File(s.copy).readAsStringSync(), contains('Edited'));
        expect(
          s.nb.unreadable.map((u) => u.path),
          isNot(contains(predicate<String>((p) => p.endsWith('copy-of-${s.id}.canvas')))),
        );
        expect(s.nb.unreadable, hasLength(1));
      });

      test('removing the folder of the chosen file makes the duplicate in the '
          'other folder the page', () async {
        final a = await Directory('${root.path}/A').create();
        final b = await Directory('${root.path}/B').create();
        final s = await setup(a, b);
        await openExistingFile(s.nb, s.copy);
        await s.nb.open(await s.nb.createPage());
        final bPath = s.nb.standaloneFolders
            .firstWhere((f) => f.path.replaceAll(r'\', '/').endsWith('/B'))
            .path;
        await s.nb.removeStandaloneFolder(bPath);
        expect(s.nb.pageTitleOf(s.id), 'Original');
        expect(s.nb.unreadable, isEmpty);
        expect(s.nb.tree.roots.map((r) => r.id), contains(s.id));
      });

      test('removing the binder of the chosen file makes the duplicate in the '
          'other binder the page', () async {
        final a = await Directory('${root.path}/WorkA').create();
        final b = await Directory('${root.path}/WorkB').create();
        final other = make('other');
        await other.load();
        final sec = await other.addBinder(a.path);
        final id = await other.createPage(binderPath: sec.path);
        await other.rename(id, 'Original');
        await other.flush();
        await BinderStore(b).create(Binder.create(title: 'B', color: binderPalette.first));
        final nb = make('main', pages);
        await nb.load();
        await nb.addBinder(a.path);
        await nb.addBinder(b.path);
        final copy = '${b.path}/copy-of-$id.canvas';
        File(copy).writeAsStringSync(
          File('${a.path}/$id.canvas').readAsStringSync().replaceAll('Original', 'Copy'),
        );
        await openExistingFile(nb, copy);
        expect(nb.pageTitleOf(id), 'Copy');
        await nb.open(await nb.createPage());
        final bPath = nb.binders.firstWhere((x) => x.title == 'B').path;
        await nb.removeBinder(bPath);
        expect(nb.pageTitleOf(id), 'Original');
        expect(nb.tree.roots.map((r) => r.id), isNot(contains(id)));
        expect(nb.binderOfPage(id), isNotNull);
      });

      test('the open adopted page whose file went stays open; the original is '
          'not merged into it', () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        await openExistingFile(s.nb, s.copy);
        final origBytes = File(s.orig).readAsBytesSync();
        File(s.copy).deleteSync();
        await s.nb.checkFile(s.copy);
        final loc = s.nb.standaloneFolders.single.path;
        await s.nb.scanLocationForTest(loc);
        await s.nb.checkFile(s.orig);
        expect(s.nb.currentId, s.id);
        expect(s.nb.pageTitleOf(s.id), 'Copy');
        await s.nb.rename(s.id, 'Edited');
        await s.nb.flush();
        expect(File(s.copy).readAsStringSync(), contains('Edited'));
        expect(File(s.orig).readAsBytesSync(), origBytes);
      });

      test('a conflict copy of the duplicate file is listed, not merged',
          () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        await openExistingFile(s.nb, s.copy);
        final origBytes = File(s.orig).readAsBytesSync();
        final cc = '${dir.path}/${s.id}-DESKTOP-1.canvas';
        File(cc).writeAsBytesSync(origBytes);
        await s.nb.checkFile(cc);
        expect(
          s.nb.unreadable.where((u) => u.path.endsWith('DESKTOP-1.canvas')),
          hasLength(1),
        );
        expect(
          s.nb.unreadable
              .firstWhere((u) => u.path.endsWith('DESKTOP-1.canvas'))
              .reason,
          'conflict copy of a duplicate file; not merged',
        );
        expect(File(cc).existsSync(), isTrue);
        expect(File(s.orig).readAsBytesSync(), origBytes);
      });

      test('an open original blocked as unreadable keeps that reason when '
          'swapped, and the block is cleared', () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        await s.nb.open(s.id);
        File(s.orig).writeAsStringSync('not a page');
        await s.nb.checkFile(s.orig);
        expect(s.nb.readOnlyReason, isNotNull);
        await openExistingFile(s.nb, s.copy);
        expect(s.nb.readOnlyReason, isNull);
        expect(s.nb.pageTitleOf(s.id), 'Copy');
        final reasons = s.nb.unreadable.map((u) => u.reason).toList();
        expect(reasons, hasLength(1));
        expect(reasons.single, isNot(startsWith('duplicate page id')));
        await s.nb.rename(s.id, 'Edited');
        await s.nb.flush();
        expect(File(s.copy).readAsStringSync(), contains('Edited'));
        expect(File(s.orig).readAsStringSync(), 'not a page');
      });

      test('a binder away and back still uses the chosen file',
          () async {
        final dir = await Directory('${root.path}/Work').create();
        final s = await setup(dir, dir, binder: true);
        await openExistingFile(s.nb, s.copy);
        final origBytes = File(s.orig).readAsBytesSync();
        final path = s.nb.binders.single.path;
        // The binder's folder goes away and comes back: its store is made again.
        await s.nb.open(await s.nb.createPage());
        await settled(s.nb);
        dir.renameSync('${dir.path}-away');
        await s.nb.checkFolders();
        Directory('${dir.path}-away').renameSync(dir.path);
        await s.nb.checkFolders();
        expect(path, isNotEmpty);
        expect(s.nb.pageTitleOf(s.id), 'Copy');
        await s.nb.open(s.id);
        await s.nb.rename(s.id, 'Edited');
        await s.nb.flush();
        expect(File(s.copy).readAsStringSync(), contains('Edited'));
        expect(File(s.orig).readAsBytesSync(), origBytes);
      });

      test('the registered file itself still opens', () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        await openExistingFile(s.nb, s.orig);
        expect(s.nb.currentId, s.id);
        expect(s.nb.pageTitleOf(s.id), 'Original');
        expect(s.nb.unreadable, isEmpty);
      });

      group('a rescan never redirects a chosen page to its duplicate', () {
        Future<T> whileLocked<T>(String path, Future<T> Function() body) async {
          final raf = File(path).openSync(mode: FileMode.append)..lockSync(FileLock.exclusive);
          try {
            return await body();
          } finally {
            raf.unlockSync();
            raf.closeSync();
          }
        }

        // The copy is chosen, then the page is left for another one.
        Future<void> leave(_S s) async {
          await openExistingFile(s.nb, s.copy);
          await s.nb.open(await s.nb.createPage());
          await settled(s.nb);
        }

        String loc0(Notebook nb) => nb.standaloneFolders.first.path;
        List<int> bytes(String p) => File(p).readAsBytesSync();
        List<String> reasons(Notebook nb) => [for (final u in nb.unreadable) u.reason];

        // The text of a page of its own (another id), written by another notebook.
        Future<({String id, String text})> foreignPage() async {
          final o = make('foreign');
          await o.load();
          final yDir = await Directory('${root.path}/Y').create();
          final yid = await o.createPage(folderPath: yDir.path);
          await o.rename(yid, 'Why');
          await o.flush();
          return (id: yid, text: File('${yDir.path}/$yid.canvas').readAsStringSync());
        }

        void truncate(String path) {
          final t = File(path).readAsStringSync();
          File(path).writeAsStringSync(t.substring(0, t.length ~/ 2));
        }

        Future<void> editAndFlush(Notebook nb, String id, String title) async {
          await nb.rename(id, title);
          await nb.flush();
        }

        const winOnly = 'byte-range locks only block reads on Windows';

        test('1 locked during a rescan: opening fails, then the choice survives', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          final origBytes = bytes(s.orig);
          await leave(s);
          await whileLocked(s.copy, () async {
            await s.nb.scanLocationForTest(loc0(s.nb));
            await expectLater(s.nb.open(s.id), throwsA(anything));
          });
          await s.nb.scanLocationForTest(loc0(s.nb));
          await s.nb.open(s.id);
          expect(s.nb.pageTitleOf(s.id), 'Copy');
          await editAndFlush(s.nb, s.id, 'Edited');
          expect(File(s.copy).readAsStringSync(), contains('Edited'));
          expect(bytes(s.orig), origBytes);
        }, skip: Platform.isWindows ? null : winOnly);

        test('2 truncated during a rescan: opening fails, then the choice survives', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          final origBytes = bytes(s.orig);
          await leave(s);
          final whole = File(s.copy).readAsStringSync();
          truncate(s.copy);
          await s.nb.scanLocationForTest(loc0(s.nb));
          await expectLater(s.nb.open(s.id), throwsA(anything));
          File(s.copy).writeAsStringSync(whole);
          await s.nb.scanLocationForTest(loc0(s.nb));
          await s.nb.open(s.id);
          expect(s.nb.pageTitleOf(s.id), 'Copy');
          expect(bytes(s.orig), origBytes);
        });

        test('3 a damaged chosen file found by a check, then the other file changes', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          await leave(s);
          final whole = File(s.copy).readAsStringSync();
          truncate(s.copy);
          await s.nb.checkFile(s.copy);
          File(s.orig).writeAsStringSync(File(s.orig).readAsStringSync().replaceAll('Original', 'Retitled'));
          await s.nb.checkFile(s.orig);
          expect(s.nb.pageTitleOf(s.id), isNull, reason: 'the other file is a duplicate, not the page');
          expect(reasons(s.nb), contains('duplicate page id ${s.id}'));
          final retitled = bytes(s.orig);
          File(s.copy).writeAsStringSync(whole);
          await s.nb.checkFolders(); // no watcher event: the check looks at the chosen file again
          expect(s.nb.pageTitleOf(s.id), 'Copy');
          await s.nb.open(s.id);
          await editAndFlush(s.nb, s.id, 'Edited');
          expect(File(s.copy).readAsStringSync(), contains('Edited'));
          expect(bytes(s.orig), retitled);
        });

        for (final truncated in [false, true]) {
          test(
            '4${truncated ? 'b' : ''} the open page, its file ${truncated ? 'truncated' : 'locked'} at a rescan: '
            'the save is blocked and the other file is untouched',
            () async {
              final dir = await Directory('${root.path}/Elsewhere').create();
              final s = await setup(dir, dir);
              final origBytes = bytes(s.orig);
              await openExistingFile(s.nb, s.copy);
              final whole = File(s.copy).readAsStringSync();
              Future<void> damaged() async {
                await s.nb.scanLocationForTest(loc0(s.nb));
                await editAndFlush(s.nb, s.id, 'Edited');
                expect(s.nb.readOnlyReason, contains(truncated ? "isn't a valid page file" : "couldn't be read"));
                expect(bytes(s.orig), origBytes);
              }

              if (truncated) {
                truncate(s.copy);
                await damaged();
                File(s.copy).writeAsStringSync(whole);
              } else {
                await whileLocked(s.copy, damaged);
              }
              await s.nb.checkFolders();
              await s.nb.flush();
              expect(s.nb.readOnlyReason, isNull);
              expect(File(s.copy).readAsStringSync(), contains('Edited'));
              expect(bytes(s.orig), origBytes);
            },
            skip: !truncated && !Platform.isWindows ? winOnly : null,
          );
        }

        for (final truncated in [false, true]) {
          test(
            '5${truncated ? 'b' : ''} delete and move are refused while the chosen file is '
            '${truncated ? 'truncated' : 'locked'} after a rescan',
            () async {
              final dir = await Directory('${root.path}/Elsewhere').create();
              final s = await setup(dir, dir);
              final origBytes = bytes(s.orig);
              final bDir = await Directory('${root.path}/Bnd').create();
              final target = await s.nb.addBinder(bDir.path);
              await leave(s);
              Future<void> refused() async {
                await s.nb.scanLocationForTest(loc0(s.nb));
                await expectLater(s.nb.delete(s.id), throwsA(anything));
                await expectLater(s.nb.moveToLocation(s.id, binderPath: target.path), throwsA(anything));
              }

              if (truncated) {
                truncate(s.copy);
                await refused();
              } else {
                await whileLocked(s.copy, refused);
              }
              expect(File(s.orig).existsSync(), isTrue);
              expect(bytes(s.orig), origBytes);
              expect(File('${bDir.path}/${s.id}.canvas').existsSync(), isFalse);
            },
            skip: !truncated && !Platform.isWindows ? winOnly : null,
          );
        }

        test('6 a deleted chosen file falls back to the other one only after confirmation', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          await leave(s);
          File(s.copy).deleteSync();
          await s.nb.checkFile(s.copy);
          await s.nb.scanLocationForTest(loc0(s.nb));
          expect(s.nb.standaloneFolders.first.store!.pathFor(s.id), endsWith('copy-of-${s.id}.canvas'));
          expect(s.nb.pageTitleOf(s.id), isNull);
          await s.nb.checkFolders();
          expect(s.nb.pageTitleOf(s.id), 'Original');
          await s.nb.open(s.id);
          await editAndFlush(s.nb, s.id, 'Edited');
          expect(File(s.orig).readAsStringSync(), contains('Edited'));
        });

        test('6b the rescan runs before any check saw the chosen file go', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          await leave(s);
          File(s.copy).deleteSync();
          await s.nb.scanLocationForTest(loc0(s.nb));
          expect(s.nb.standaloneFolders.first.store!.pathFor(s.id), endsWith('copy-of-${s.id}.canvas'));
          expect(reasons(s.nb), contains('duplicate page id ${s.id}'));
          await s.nb.checkFolders();
          expect(s.nb.pageTitleOf(s.id), 'Original');
          await s.nb.open(s.id);
          await editAndFlush(s.nb, s.id, 'Edited');
          expect(File(s.orig).readAsStringSync(), contains('Edited'));
        });

        test('7 a page Noted moves keeps its choice: an outside change to the moved file is merged', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          final bDir = await Directory('${root.path}/Bnd').create();
          final target = await s.nb.addBinder(bDir.path);
          await leave(s);
          expect(await s.nb.moveToLocation(s.id, binderPath: target.path), isTrue);
          final moved = '${bDir.path}/${s.id}.canvas';
          expect(File(moved).readAsStringSync(), contains('Copy'));
          File(moved).writeAsStringSync(File(moved).readAsStringSync().replaceAll('Copy', 'Outside'));
          await s.nb.checkFile(moved);
          expect(s.nb.pageTitleOf(s.id), 'Outside');
          expect(s.nb.binders.firstWhere((b) => b.path == target.path).unreadable, isEmpty);
        });

        test('7b a move that rolls back puts the chosen file back under its own name', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final bDir = await Directory('${root.path}/Bnd').create();
          final other = make('other');
          await other.load();
          final id = await other.createPage(folderPath: dir.path);
          await other.rename(id, 'Original');
          final sub = await other.createPage(parentId: id);
          await other.flush();
          late _FailDeleteStore source;
          final nb = make('main', pages, false, (d) {
            final st = _FailDeleteStore(d);
            if (d.path == dir.path) source = st;
            return st;
          });
          await nb.load();
          await nb.addStandaloneFolder(dir.path);
          final target = await nb.addBinder(bDir.path);
          final orig = '${dir.path}/$id.canvas';
          final copy = '${dir.path}/copy-of-$id.canvas';
          File(copy).writeAsStringSync(File(orig).readAsStringSync().replaceAll('Original', 'Copy'));
          final origBytes = bytes(orig);
          final copyBytes = bytes(copy);
          await openExistingFile(nb, copy);
          await nb.open(await nb.createPage());
          await settled(nb);
          source.failDelete.add(sub);
          await expectLater(nb.moveToLocation(id, binderPath: target.path), throwsA(isA<NotebookException>()));
          expect(bytes(copy), copyBytes, reason: 'the chosen file is back under its own name');
          expect(bytes(orig), origBytes);
          expect(File('${bDir.path}/$id.canvas').existsSync(), isFalse);
          source.failDelete.clear();
          await nb.open(id);
          expect(nb.pageTitleOf(id), 'Copy');
        });

        test('9 the chosen file replaced by another page, then a rescan', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          final y = await foreignPage();
          await leave(s);
          File(s.copy).writeAsStringSync(y.text);
          await s.nb.scanLocationForTest(loc0(s.nb));
          await s.nb.open(s.id);
          expect(s.nb.pageTitleOf(s.id), 'Original');
          expect(File(s.copy).readAsStringSync(), y.text);
          await settled(s.nb); // the release queued a check of the file: no watcher event needed
          expect(s.nb.pageTitleOf(y.id), 'Why');
          expect(s.nb.tree.roots.map((r) => r.id), containsAll([s.id, y.id]));
          await s.nb.checkFile(s.copy);
          expect(s.nb.pageTitleOf(s.id), 'Original');
          expect(File(s.copy).readAsStringSync(), y.text);
        });

        test('10 the chosen file replaced by another page, a check, then the other file changes', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          final y = await foreignPage();
          await leave(s);
          File(s.copy).writeAsStringSync(y.text);
          await s.nb.checkFile(s.copy);
          expect(s.nb.pageTitleOf(s.id), 'Original');
          expect(s.nb.tree.roots.map((r) => r.id), contains(s.id));
          File(s.orig).writeAsStringSync(File(s.orig).readAsStringSync().replaceAll('Original', 'Newer'));
          await s.nb.checkFile(s.orig);
          expect(s.nb.pageTitleOf(s.id), 'Newer');
        });

        test('11 the open page whose file now holds another page: the save is blocked', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir, recovery: true);
          final y = await foreignPage();
          final origBytes = bytes(s.orig);
          await openExistingFile(s.nb, s.copy);
          File(s.copy).writeAsStringSync(y.text);
          await s.nb.scanLocationForTest(loc0(s.nb));
          await editAndFlush(s.nb, s.id, 'Edited');
          expect(s.nb.readOnlyReason, contains('holds a different page'));
          expect(bytes(s.orig), origBytes);
          expect(File(s.copy).readAsStringSync(), y.text);
          expect(s.nb.recoveryStoreForTest!.entriesOfPage(s.id), isNotEmpty);
        });

        test('12 the page file now holds another page: opening never shows it, and the choice is let go', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          final y = await foreignPage();
          await leave(s);
          File(s.copy).writeAsStringSync(y.text); // no watcher event, no check yet
          await expectLater(
            s.nb.open(s.id),
            throwsA(isA<PageFormatException>().having((e) => e.message, 'message', contains('holds a different page'))),
          );
          expect(File(s.copy).readAsStringSync(), y.text);
          // The failed open let go of the choice: the check it queued settles it.
          await settled(s.nb);
          await s.nb.open(s.id);
          expect(s.nb.pageTitleOf(s.id), 'Original');
          expect(File(s.copy).readAsStringSync(), y.text);
        });

        test('12b the page open on its file, the file replaced, the page closed and opened again', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          final y = await foreignPage();
          await openExistingFile(s.nb, s.copy);
          File(s.copy).writeAsStringSync(y.text);
          await s.nb.open(await s.nb.createPage());
          // Before or after the queued check, never Y's content under this page.
          try {
            await s.nb.open(s.id);
            expect(s.nb.pageTitleOf(s.id), 'Original');
          } on PageFormatException catch (e) {
            expect(e.message, contains('holds a different page'));
          }
          await settled(s.nb);
          await s.nb.open(s.id);
          expect(s.nb.pageTitleOf(s.id), 'Original');
          expect(File(s.copy).readAsStringSync(), y.text);
        });

        test('12c kept edits and a file that now holds another page: a preview, the other file untouched', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir, recovery: true);
          final y = await foreignPage();
          final origBytes = bytes(s.orig);
          await leave(s);
          final base = readPage(File(s.copy).readAsStringSync());
          final keep = await s.nb.keepClosedForTest(base.withMeta(base.meta.withTitle('Kept')), base, dir.path);
          expect(keep.safe, isTrue);
          File(s.copy).writeAsStringSync(y.text);
          await s.nb.open(s.id);
          expect(s.nb.trouble.kind, TroubleKind.preview);
          expect(s.nb.trouble.reason, contains('holds a different page'));
          expect(File(s.copy).readAsStringSync(), y.text);
          expect(bytes(s.orig), origBytes);
          // While the preview is open the other file stays unchosen.
          await settled(s.nb);
          expect(reasons(s.nb), contains('duplicate page id ${s.id}'));
          // Closing it rechecks the file, which lets go of the choice.
          await s.nb.open(await s.nb.createPage());
          await settled(s.nb);
          expect(s.nb.pageTitleOf(s.id), 'Original');
          expect(File(s.copy).readAsStringSync(), y.text);
        });

        for (final binder in [true, false]) {
          test('13${binder ? '' : 'b'} ${binder ? 'a binder' : 'a folder'} away and back without the chosen file', () async {
            final dir = await Directory('${root.path}/Work').create();
            final s = await setup(dir, dir, binder: binder);
            final origBytes = bytes(s.orig);
            await leave(s);
            final away = '${dir.path}-away';
            dir.renameSync(away);
            await s.nb.checkFolders();
            Directory(away).renameSync(dir.path);
            final aside = '${root.path}/aside.canvas';
            File(s.copy).renameSync(aside);
            await s.nb.checkFolders();
            expect(s.nb.pageTitleOf(s.id), isNull, reason: 'the other file does not take the page');
            File(aside).renameSync(s.copy);
            await s.nb.checkFolders();
            await s.nb.open(s.id);
            expect(s.nb.pageTitleOf(s.id), 'Copy');
            expect(bytes(s.orig), origBytes);
          });
        }

        test('14 the chosen file replaced by a copy of a page that has a file of its own', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          final yid = await s.nb.createPage(folderPath: dir.path);
          await s.nb.rename(yid, 'Why');
          await s.nb.flush();
          final yFile = '${dir.path}/$yid.canvas';
          final yBytes = bytes(yFile);
          await leave(s);
          File(s.copy).writeAsBytesSync(yBytes);
          await s.nb.checkFile(s.copy);
          expect(s.nb.pageTitleOf(s.id), 'Original');
          expect(s.nb.tree.roots.map((r) => r.id), contains(s.id));
          expect(reasons(s.nb), contains('duplicate page id $yid'));
          expect(bytes(yFile), yBytes);
        });

        test('15 a closed page header is never changed in a file that holds another page', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          final yid = await s.nb.createPage(folderPath: dir.path);
          await s.nb.flush();
          final yFile = '${dir.path}/$yid.canvas';
          final yBytes = bytes(yFile);
          await leave(s);
          File(s.copy).writeAsBytesSync(yBytes); // no check yet
          await expectLater(s.nb.setAiAccess(s.id, AiAccess.open), throwsA(isA<NotebookException>()));
          expect(bytes(yFile), yBytes);
          expect(bytes(s.copy), yBytes);
        });

        test('16 the AI read of a page refuses a file that holds another page, then the check settles it', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          final yid = await s.nb.createPage(folderPath: dir.path);
          await s.nb.flush();
          await s.nb.setAiAccess(s.id, AiAccess.open);
          await leave(s);
          File(s.copy).writeAsBytesSync(bytes('${dir.path}/$yid.canvas'));
          expect(await s.nb.aiSavedPage(s.id), isNull);
          await settled(s.nb); // the refusal queued a check of the file
          expect(s.nb.pageTitleOf(s.id), 'Original');
        });

        for (final binder in [true, false]) {
          test(
            '17${binder ? '' : 'b'} ${binder ? 'a binder' : 'a folder'} away and back with the open page\'s file holding another page',
            () async {
              final dir = await Directory('${root.path}/Work').create();
              final s = await setup(dir, dir, binder: binder, recovery: true);
              final y = await foreignPage();
              final origBytes = bytes(s.orig);
              await openExistingFile(s.nb, s.copy);
              s.nb.current!.updateMeta(s.nb.current!.page.meta.withTitle('Unsaved'));
              final away = '${dir.path}-away';
              dir.renameSync(away);
              await s.nb.checkFolders();
              Directory(away).renameSync(dir.path);
              File(s.copy).writeAsStringSync(y.text);
              await s.nb.checkFolders();
              expect(s.nb.readOnlyReason, contains('holds a different page'));
              expect(File(s.copy).readAsStringSync(), y.text);
              expect(bytes(s.orig), origBytes);
              expect(s.nb.recoveryStoreForTest!.entriesOfPage(s.id), isNotEmpty);
            },
          );
        }

        test('18 the chosen file replaced by the content of a page that has a chosen file of its own', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          // Q has a copy C chosen too.
          final q = await s.nb.createPage(folderPath: dir.path);
          await s.nb.rename(q, 'Why');
          await s.nb.flush();
          final c = '${dir.path}/copy-of-$q.canvas';
          File(c).writeAsStringSync(File('${dir.path}/$q.canvas').readAsStringSync().replaceAll('Why', 'QCopy'));
          await openExistingFile(s.nb, c);
          expect(s.nb.pageTitleOf(q), 'QCopy');
          await leave(s);
          final origBytes = bytes(s.orig);
          final qBytes = bytes(c);
          File(s.copy).writeAsBytesSync(qBytes);
          await s.nb.checkFile(s.copy);
          expect(s.nb.pageTitleOf(s.id), 'Original', reason: 'P returns through the other file');
          expect(s.nb.tree.roots.map((r) => r.id), contains(s.id));
          await s.nb.checkFolders();
          await s.nb.checkFolders();
          expect(s.nb.pageTitleOf(s.id), 'Original');
          expect(s.nb.pageTitleOf(q), 'QCopy');
          expect(bytes(s.orig), origBytes);
          expect(bytes(s.copy), qBytes);
        });

        test('12d the page closed with its file replaced: before the queued check, opening gives the error', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          final y = await foreignPage();
          await openExistingFile(s.nb, s.copy);
          File(s.copy).writeAsStringSync(y.text);
          final gate = Completer<void>();
          s.nb.syncHook = (point, path) async {
            if (point == 'check-start' && path.endsWith('copy-of-${s.id}.canvas')) await gate.future;
          };
          await s.nb.open(await s.nb.createPage()); // closing queues a check of the file, held at its start
          await expectLater(
            s.nb.open(s.id),
            throwsA(isA<PageFormatException>().having((e) => e.message, 'message', contains('holds a different page'))),
          );
          expect(File(s.copy).readAsStringSync(), y.text);
          gate.complete();
          await settled(s.nb);
          await s.nb.open(s.id);
          expect(s.nb.pageTitleOf(s.id), 'Original');
        });

        test('a check that straddles the removal of its folder applies nothing', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          expect(s.nb.pageTitleOf(s.id), 'Original');
          File(s.orig).writeAsStringSync(File(s.orig).readAsStringSync().replaceAll('Original', 'Retitled'));
          final gate = Completer<void>();
          final reached = Completer<void>();
          s.nb.syncHook = (point, path) async {
            if (point == 'check-start' && path == s.orig) {
              reached.complete();
              await gate.future;
            }
          };
          final check = s.nb.checkFile(s.orig);
          await reached.future; // the check is under way, before it reads the file
          await s.nb.removeStandaloneFolder(dir.path);
          expect(s.nb.pageTitleOf(s.id), isNull);
          gate.complete();
          await check;
          expect(s.nb.pageTitleOf(s.id), isNull, reason: 'the removed folder gets no page back');
          expect(s.nb.tree.roots.map((r) => r.id), isNot(contains(s.id)));
        });

        test('a move that frees the page rechecks its chosen file: the replaced file lets the other one in', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          final y = await foreignPage();
          final bDir = await Directory('${root.path}/Bnd').create();
          final target = await s.nb.addBinder(bDir.path);
          await leave(s);
          s.nb.syncHook = (point, path) async {
            if (point == 'move-rekeyed') File(s.copy).writeAsStringSync(y.text);
          };
          await expectLater(s.nb.moveToLocation(s.id, binderPath: target.path), throwsA(isA<NotebookException>()));
          s.nb.syncHook = null;
          await settled(s.nb); // no explicit check of the file: freeing the page queued it
          expect(s.nb.pageTitleOf(s.id), 'Original');
          expect(File(s.copy).readAsStringSync(), y.text);
        });

        test('a chosen file dropped as damaged and then gone is settled by its page, not forgotten', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          await leave(s);
          truncate(s.copy);
          await s.nb.checkFile(s.copy); // listed unreadable, no longer in the index
          File(s.copy).deleteSync();
          await s.nb.checkFile(s.copy); // seen gone once, found by the page's choice
          expect(s.nb.pageTitleOf(s.id), isNull);
          await s.nb.checkFolders();
          expect(s.nb.pageTitleOf(s.id), 'Original');
        });

        test('a chosen file whose last known text equals what is there is still looked at again', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir);
          final y = await foreignPage();
          await leave(s);
          truncate(s.copy);
          await s.nb.checkFile(s.copy); // listed unreadable
          File(s.copy).writeAsStringSync(y.text);
          s.nb.setKnownTextForTest(s.copy, y.text); // as a replay that found it holding another page leaves it
          await s.nb.checkFolders();
          expect(s.nb.pageTitleOf(s.id), 'Original');
          expect(s.nb.pageTitleOf(y.id), 'Why');
        });

        test('a chosen file that stays damaged changes nothing at later folder checks', () async {
          final dir = await Directory('${root.path}/Work').create();
          final s = await setup(dir, dir, binder: true);
          await leave(s);
          truncate(s.copy);
          await s.nb.checkFile(s.copy);
          final edited = s.nb.binders.single.lastEdited;
          final listed = s.nb.binders.single.unreadable.map((u) => '${u.path} ${u.reason}').toList();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await s.nb.checkFolders();
          await s.nb.checkFolders();
          expect(s.nb.binders.single.lastEdited, edited);
          expect(s.nb.binders.single.unreadable.map((u) => '${u.path} ${u.reason}').toList(), listed);
        });

        test('a page opened as a preview while the confirming read runs keeps its choice', () async {
          final dir = await Directory('${root.path}/Elsewhere').create();
          final s = await setup(dir, dir, recovery: true);
          await leave(s);
          final base = readPage(File(s.copy).readAsStringSync());
          final keep = await s.nb.keepClosedForTest(base.withMeta(base.meta.withTitle('Kept')), base, dir.path);
          expect(keep.safe, isTrue);
          File(s.copy).deleteSync();
          await s.nb.scanLocationForTest(loc0(s.nb)); // seen gone once, registered still
          s.nb.syncHook = (point, path) async {
            if (point == 'confirm-gone-read') {
              s.nb.syncHook = null;
              await s.nb.open(s.id);
            }
          };
          await s.nb.checkFolders();
          expect(s.nb.currentId, s.id);
          expect(s.nb.trouble.kind, TroubleKind.preview);
          expect(reasons(s.nb), contains('duplicate page id ${s.id}'), reason: 'the other file is still not the page');
        });
      });
    });

    test('a copy of a binder is refused and not joined', () async {
      final dir = await Directory('${root.path}/Work').create();
      final copy = await Directory('${root.path}/Work copy').create();
      final other = make('other');
      await other.load();
      final section = await other.addBinder(dir.path);
      final id = await other.createPage(binderPath: section.path);
      await other.flush();
      for (final f in dir.listSync().whereType<File>()) {
        f.copySync('${copy.path}/${f.uri.pathSegments.last}');
      }
      final nb = make('main', pages);
      await nb.load();
      await openExistingFile(nb, '${dir.path}/$id.canvas');
      expect(nb.currentId, id);
      await expectLater(
        openExistingFile(nb, '${copy.path}/$id.canvas'),
        throwsA(isA<NotebookException>()),
      );
      expect(nb.binders, hasLength(1));
      expect(nb.currentId, id);
    });

    test('noted-binder.json joins the binder and shows its cover', () async {
      final dir = await Directory('${root.path}/Work').create();
      await BinderStore(dir)
          .create(Binder.create(title: 'Work', color: binderPalette.first));
      final nb = make('main', pages);
      await nb.load();
      await openExistingFile(nb, '${dir.path}/$binderFileName');
      expect(nb.binders.single.title, 'Work');
      expect(nb.coverPath, nb.binders.single.path);
    });

    test('a refused file changes nothing', () async {
      final nb = make('main', pages);
      await nb.load();
      final before = nb.currentId;
      final bad = File('${root.path}/Elsewhere/bad.canvas')
        ..createSync(recursive: true);
      bad.writeAsStringSync('not a page');
      await expectLater(
        openExistingFile(nb, bad.path),
        throwsA(isA<NotebookException>()),
      );
      await expectLater(
        openExistingFile(nb, '${root.path}/nope.txt'),
        throwsA(isA<NotebookException>()),
      );
      expect(nb.currentId, before);
      expect(nb.standaloneFolders, isEmpty);
      expect(bad.readAsStringSync(), 'not a page');
    });

    test('the service reports a refusal as a notice and carries on', () async {
      final nb = make('main', pages);
      await nb.load();
      final notices = <String>[];
      final service = OpenFileService(nb)..notify = notices.add;
      await service.start(['--x', '${root.path}/nope.canvas'], listen: false);
      expect(notices, hasLength(1));
    });
  });
}
