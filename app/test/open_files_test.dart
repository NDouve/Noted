// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/open_files.dart';
import 'package:noted_core/noted_core.dart';

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
      nb.dispose();
    }
    await root.delete(recursive: true);
  });

  // A notebook of its own (own pages folder and binders.json).
  Notebook make(String name, [Directory? pagesDir]) {
    final nb = Notebook(
      PageStore(pagesDir ?? Directory('${root.path}/$name-pages')),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/$name/binders.json'),
      watchFiles: false,
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
      // A page called Original in [dir] (a binder when [binder]); the notebook
      // joins the folder, then a copy called Copy appears beside it.
      Future<({Notebook nb, String id, String orig, String copy})> setup(
        Directory dir,
        Directory copyDir, {
        bool binder = false,
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
        final nb = make('main', pages);
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

      test('the promoted duplicate prefers <id>.canvas and skips '
          'conflict-copy names', () async {
        final dir = await Directory('${root.path}/Elsewhere').create();
        final s = await setup(dir, dir);
        await openExistingFile(s.nb, s.copy);
        final shaped = '${dir.path}/aa-bb.canvas';
        File(shaped).writeAsBytesSync(File(s.orig).readAsBytesSync());
        await s.nb.checkFile(shaped);
        await s.nb.open(await s.nb.createPage());
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
