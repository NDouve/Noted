// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

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
