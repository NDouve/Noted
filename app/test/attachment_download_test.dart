// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// t2a: attachments that are not downloaded are asked for, never read, copied or
// renamed in place of the file; a copy refuses while one is not here; on Apple a
// move or a delete never renames a folder that holds one.

@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/attachment_copy.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/src/storage/dataless.dart' show debugDatalessPaths, debugMarkDataless, debugUnmarkDataless;
import 'package:noted_core/src/storage/exclusive_move.dart' show debugMoveStrategy, debugRenameDelay;
import 'package:noted_core/src/storage/folder_walk.dart' show debugAppleMode, debugListDir;
import 'support/notebook_folder.dart';

void main() {
  late Directory root;
  late Directory pages;
  late Directory extra;
  late List<Notebook> opened;
  late List<String> asked;
  late List<String> notices;
  final sep = Platform.pathSeparator;

  final good = Uint8List.fromList(List.generate(64, (i) => (i * 7) % 251));
  final name = '${contentHash(good)}.bin';
  final good2 = Uint8List.fromList(List.generate(64, (i) => (i * 11 + 3) % 251));
  final name2 = '${contentHash(good2)}.bin';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_t2a');
    pages = await Directory('${root.path}/pages').create();
    extra = await Directory('${root.path}/Elsewhere').create();
    opened = [];
    asked = [];
    notices = [];
    Notebook.pairLockLimit = const Duration(milliseconds: 150);
    Notebook.pairRetryDelay = const Duration(milliseconds: 10);
  });
  tearDown(() async {
    debugAppleMode = null;
    debugListDir = null;
    debugDatalessPaths = null;
    debugRenameDelay = null;
    debugMoveStrategy = null;
    storedReadObserver = null;
    attachmentBeforePublishHook = null;
    Notebook.forceCopyMoveForTest = false;
    Notebook.placeholderMarksForTest = {};
    Notebook.pairLockLimit = const Duration(seconds: 5);
    Notebook.pairRetryDelay = const Duration(milliseconds: 500);
    Notebook.strayQuiet = const Duration(seconds: 30);
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    await deleteTestFolder(root);
  });

  Notebook make({bool requester = true}) {
    final nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
    );
    if (requester) {
      nb.askDownload = (path) async {
        asked.add(path);
        return null;
      };
    }
    final sub = nb.attachmentNotices.listen(notices.add);
    addTearDown(sub.cancel);
    opened.add(nb);
    return nb;
  }

  // A page `a` and a page `x` in the other folder, scanned by a fresh notebook.
  Future<(Notebook, String, String)> scanned({bool requester = true}) async {
    final first = make();
    await first.load();
    final a = first.currentId!;
    final x = await first.createPage(folderPath: extra.path);
    await first.open(a);
    await first.flush();
    first.dispose();
    opened.remove(first);
    final nb = make(requester: requester);
    await nb.load();
    return (nb, a, x);
  }

  File put(Directory dir, String n, List<int> bytes) =>
      File('${dir.path}$sep$n')..parent.createSync(recursive: true)..writeAsBytesSync(bytes);

  Directory assetsOf(Directory folder, String id) => Directory('${folder.path}$sep$id.assets');
  List<String> names(Directory d) => d.existsSync()
      ? (d.listSync().map((e) => e.path.split(RegExp(r'[\\/]')).last).toList()..sort())
      : <String>[];

  bool sameFile(String a, String b) => a.replaceAll(r'\', '/').toLowerCase() == b.replaceAll(r'\', '/').toLowerCase();
  bool askedFor(String path) => asked.any((a) => sameFile(a, path));

  group('copies refuse while a file is not downloaded', () {
    setUp(() => Notebook.forceCopyMoveForTest = true);

    test('a move that copies is refused up front, and nothing is made', () async {
      final (nb, a, x) = await scanned();
      final src = assetsOf(pages, a);
      put(src, name, good);
      put(src, name2, good2);
      debugMarkDataless('${src.path}$sep$name');
      var copying = 0; // a file that is on the device would be copied if the listing did not refuse first
      attachmentBeforePublishHook = (target) async => copying++;
      await expectLater(
        nb.move(a, parentId: x),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            contains('has files that are not downloaded yet, so it can not be copied to'),
          ),
        ),
      );
      expect(copying, 0, reason: 'refused up front, before any file was copied');
      await Future<void>.delayed(Duration.zero);
      expect(askedFor('${src.path}$sep$name'), isTrue);
      expect(File('${extra.path}$sep$a.canvas').existsSync(), isFalse, reason: 'no page was copied');
      expect(assetsOf(extra, a).existsSync(), isFalse);
      expect(File('${pages.path}$sep$a.canvas').existsSync(), isTrue);
      expect(names(src), [name, name2]..sort());
    });

    test('off Apple a folder that cannot be read refuses the move and says so', () async {
      final (nb, a, x) = await scanned();
      final src = assetsOf(pages, a);
      put(src, name, good);
      debugAppleMode = false;
      debugListDir = (d) =>
          sameFile(d, src.path) ? throw FileSystemException('io', d, const OSError('io', 5)) : Directory(d).listSync(followLinks: false);
      await expectLater(
        nb.move(a, parentId: x),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', "A folder can't be read, so it was not copied.")),
      );
      await Future<void>.delayed(Duration.zero);
      expect(File('${extra.path}$sep$a.canvas').existsSync(), isFalse);
      expect(names(src), [name]);
    });

    test('B1: a file evicted between the listing and the copy is refused, the copies removed, the original unchanged', () async {
      final (nb, a, x) = await scanned();
      final src = assetsOf(pages, a);
      put(src, name, good);
      put(src, name2, good2);
      final text = File('${pages.path}$sep$a.canvas').readAsStringSync();
      attachmentBeforePublishHook = (target) async {
        if (target.endsWith(name2)) debugMarkDataless('${src.path}$sep$name2'); // after its copy was made
      };
      await expectLater(
        nb.move(a, parentId: x),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('not downloaded yet'))),
      );
      attachmentBeforePublishHook = null;
      expect(File('${extra.path}$sep$a.canvas').existsSync(), isFalse, reason: 'the page copy was removed');
      expect(names(assetsOf(extra, a)), isEmpty, reason: 'the copied files were removed');
      expect(File('${pages.path}$sep$a.canvas').readAsStringSync(), text);
      expect(names(src), [name, name2]..sort());
    });

    test('Delete the original keeps an original that is only a stub now, asks for it, and does not call it gone', () async {
      final (nb, a, x) = await scanned();
      final src = assetsOf(pages, a);
      put(src, name, good);
      final work = await Directory('${root.path}/Work').create();
      final binder = await nb.addBinder(work.path);
      final kept = await (() async {
        try {
          await nb.moveToLocation(a, binderPath: binder.path);
        } on OriginalsKeptException catch (e) {
          return e.move;
        }
        fail('the move should have kept the originals');
      })();
      expect(File('${assetsOf(work, a).path}$sep$name').readAsBytesSync(), good);
      // The original's file is evicted: only its stub stands.
      File('${src.path}$sep$name').deleteSync();
      File('${src.path}$sep.$name.icloud').writeAsStringSync('');
      await expectLater(
        nb.deleteOriginals(kept),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('still downloading'))),
      );
      await Future<void>.delayed(Duration.zero);
      expect(File('${src.path}$sep.$name.icloud').existsSync(), isTrue, reason: 'the stub is not a missing file');
      expect(src.existsSync(), isTrue);
      expect(askedFor('${src.path}$sep$name') || askedFor('${src.path}$sep.$name.icloud'), isTrue);
      expect(File('${assetsOf(work, a).path}$sep$name').existsSync(), isTrue, reason: 'the copy stays');
    });

    test('a put-back across drives keeps its source folder and names the file it skipped', () async {
      Notebook.forceCopyMoveForTest = false; // the delete sets the folder aside by rename
      final (nb, a, _) = await scanned();
      final src = assetsOf(pages, a);
      put(src, name, good);
      put(src, name2, good2);
      final deleted = await nb.delete(a);
      final trashed = Directory('${root.path}/app/deleted-attachments')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith(name2))
          .toList();
      expect(trashed, hasLength(1), reason: 'set aside for Undo');
      debugMarkDataless(trashed.single.path);
      Notebook.forcePutBackCannotRenameForTest = true; // as across drives
      addTearDown(() => Notebook.forcePutBackCannotRenameForTest = false);
      notices.clear();
      try {
        await nb.undoDelete(deleted);
      } on NotebookException catch (e) {
        notices.add(e.message); // the put-back did not finish
      }
      await Future<void>.delayed(Duration.zero);
      expect(trashed.single.existsSync(), isTrue, reason: 'the source folder is kept');
      expect(askedFor(trashed.single.path), isTrue);
      expect(notices.any((n) => n.contains('Still downloading, left in') && n.contains(name2)), isTrue, reason: '$notices');
    });

    test('on Apple an Undo that renames back names the file it left, not the generic text', () async {
      Notebook.forceCopyMoveForTest = false;
      final (nb, a, _) = await scanned();
      final src = assetsOf(pages, a);
      put(src, name, good);
      put(src, name2, good2);
      final deleted = await nb.delete(a);
      final trashed = Directory('${root.path}/app/deleted-attachments')
          .listSync(recursive: true)
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith(name2));
      debugAppleMode = true;
      debugMarkDataless(trashed.path);
      notices.clear();
      try {
        await nb.undoDelete(deleted);
      } on NotebookException {
        // The put-back did not finish.
      }
      await Future<void>.delayed(Duration.zero);
      expect(trashed.existsSync(), isTrue, reason: 'left where it is');
      expect(askedFor(trashed.path), isTrue);
      expect(notices.any((n) => n.contains('Still downloading, left in') && n.contains(name2)), isTrue, reason: '$notices');
      expect(notices.any((n) => n.contains('could not be moved out of')), isFalse, reason: 'not the generic text');
    });

    test('with no requester the text says the file is a placeholder', () async {
      final (nb, a, x) = await scanned(requester: false);
      final src = assetsOf(pages, a);
      put(src, name, good);
      debugMarkDataless('${src.path}$sep$name');
      await expectLater(
        nb.move(a, parentId: x),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            contains('has a file that is only a placeholder from another device, so it can not be copied yet.'),
          ),
        ),
      );
    });

    test('Save a copy refuses up front and mid-copy, and writes no page', () async {
      final folder = await Directory('${root.path}/Copy').create();
      final nb = Notebook(
        PageStore(pages),
        buildModules(),
        saveDelay: Duration.zero,
        bindersFile: File('${root.path}/app/binders.json'),
        pickFolder: () async => folder.path,
      )..askDownload = (p) async {
          asked.add(p);
          return null;
        };
      opened.add(nb);
      await nb.load();
      final a = nb.currentId!;
      final src = assetsOf(pages, a);
      put(src, name, good);
      put(src, name2, good2);
      debugMarkDataless('${src.path}$sep$name');
      await expectLater(
        nb.saveCopyElsewhere(),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', 'Some files are still downloading. Try again in a moment.')),
      );
      expect(folder.listSync(), isEmpty, reason: 'nothing was made');
      debugUnmarkDataless('${src.path}$sep$name');
      // Mid-copy.
      attachmentBeforePublishHook = (target) async {
        if (target.endsWith(name2)) debugMarkDataless('${src.path}$sep$name2');
      };
      await expectLater(
        nb.saveCopyElsewhere(),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', 'Some files are still downloading. Try again in a moment.')),
      );
      attachmentBeforePublishHook = null;
      expect(folder.listSync().where((e) => e.path.endsWith('.canvas')), isEmpty, reason: 'no page was written');
      expect(
        folder.listSync(recursive: true).whereType<File>(),
        isEmpty,
        reason: 'what the copy made was removed',
      );
    });
  });

  group('template saves', () {
    late Notebook nb;
    late String pageId;
    late Directory pageAssets;
    late Directory templates;
    late Directory binderDir;
    late BinderSection binder;
    late String inB;

    // Every check under a timeout, so a deadlock fails.
    Future<T> within<T>(Future<T> f) => f.timeout(const Duration(seconds: 20));

    setUp(() async {
      nb = make();
      await nb.load();
      pageId = nb.currentId!;
      pageAssets = assetsOf(pages, pageId);
      put(pageAssets, name, good);
      put(pageAssets, name2, good2);
      templates = Directory('${root.path}/app/templates');
      binderDir = await Directory('${root.path}/Work').create();
      binder = await nb.addBinder(binderDir.path);
      inB = await nb.createPage(binderPath: binder.path);
      put(assetsOf(binderDir, inB), name, good);
      put(assetsOf(binderDir, inB), name2, good2);
    });

    // The three ways to save: in a binder, app-wide, and a whole binder.
    final modes = <String, ({Future<Object> Function() save, Directory Function() dir, String page})>{};
    late Directory binderTemplates;
    setUp(() {
      binderTemplates = Directory('${binderDir.path}/templates');
      modes
        ..clear()
        ..['in a binder'] = (
          save: () => nb.savePageAsTemplate(inB, name: 'T', inBinder: true),
          dir: () => binderTemplates,
          page: inB,
        )
        ..['app-wide'] = (
          save: () => nb.savePageAsTemplate(pageId, name: 'T'),
          dir: () => templates,
          page: pageId,
        )
        ..['a whole binder'] = (
          save: () => nb.saveBinderAsTemplate(binder.path, name: 'T'),
          dir: () => templates,
          page: inB,
        );
    });

    List<String> files(Directory d) => [
      if (d.existsSync())
        for (final e in d.listSync(recursive: true).whereType<File>()) e.path.replaceAll(r'\', '/'),
    ];
    List<String> templateFiles(Directory d) => files(d).where((f) => f.endsWith('.notedtemplate')).toList();

    for (final mode in ['in a binder', 'app-wide', 'a whole binder']) {
      group(mode, () {
        Directory srcAssets() => mode == 'app-wide' ? pageAssets : assetsOf(binderDir, inB);
        void evictOne() => debugMarkDataless('${srcAssets().path}$sep$name');

        test('refuses up front: no template, no copy, and the file is asked for', () async {
          evictOne();
          await expectLater(
            within(modes[mode]!.save()),
            throwsA(isA<NotebookException>().having((e) => e.message, 'message', 'Some files are still downloading. Try again in a moment.')),
          );
          await Future<void>.delayed(Duration.zero);
          expect(files(modes[mode]!.dir()), isEmpty);
          expect(askedFor('${srcAssets().path}$sep$name'), isTrue);
        });

        test('a mid-copy eviction ends with no template file and the copy removed; a listing then completes', () async {
          attachmentBeforePublishHook = (target) async {
            if (target.endsWith(name2)) debugMarkDataless('${srcAssets().path}$sep$name2');
          };
          await expectLater(within(modes[mode]!.save()), throwsA(isA<NotebookException>()));
          attachmentBeforePublishHook = null;
          expect(files(modes[mode]!.dir()), isEmpty, reason: 'no template file, and the copy was removed');
          final listing = await within(nb.listTemplates(TemplateKind.page, binderPath: binder.path));
          expect(listing.items, isEmpty);
        });

        test('a refusal at the saveAssets gate writes no file and copies nothing', () async {
          nb.templateStepHook = (s) async {
            if (s == 'saveAssets') throw const NotebookException('Refused at the gate.');
          };
          await expectLater(within(modes[mode]!.save()), throwsA(isA<NotebookException>()));
          expect(files(modes[mode]!.dir()), isEmpty);
        });

        test('a refusal at the saveTemplate gate leaves no template file and the copy removed', () async {
          var copied = false;
          nb.templateStepHook = (s) async {
            if (s == 'saveTemplate') {
              copied = files(modes[mode]!.dir()).isNotEmpty; // the assets are there before the file
              throw const NotebookException('Refused at the gate.');
            }
          };
          await expectLater(within(modes[mode]!.save()), throwsA(isA<NotebookException>()));
          expect(copied, isTrue, reason: 'copied first');
          expect(files(modes[mode]!.dir()), isEmpty);
          await within(nb.listTemplates(TemplateKind.page, binderPath: binder.path));
        });

        test('a publish that fails after writing rolls the file back by its identity, and the copy goes', () async {
          nb.templatePublishedHook = (path) async {
            expect(File(path).existsSync(), isTrue);
            throw FileSystemException('the folder went away', path);
          };
          await expectLater(within(modes[mode]!.save()), throwsA(isA<NotebookException>()));
          nb.templatePublishedHook = null;
          expect(files(modes[mode]!.dir()), isEmpty);
          await within(nb.listTemplates(TemplateKind.page, binderPath: binder.path));
        });

        test('the rollback refuses when the template changed since it was written', () async {
          nb.templatePublishedHook = (path) async {
            File(path).writeAsStringSync('{"changed": true}');
            throw FileSystemException('the folder went away', path);
          };
          await expectLater(within(modes[mode]!.save()), throwsA(isA<NotebookException>()));
          nb.templatePublishedHook = null;
          expect(templateFiles(modes[mode]!.dir()), hasLength(1), reason: 'a changed file is kept');
          expect(File(templateFiles(modes[mode]!.dir()).single).readAsStringSync(), '{"changed": true}');
          expect(
            files(modes[mode]!.dir()).where((f) => f.endsWith(name) && f.endsWith('.bin')),
            isNotEmpty,
            reason: 'a template that is still listed keeps its assets',
          );
          expect(files(modes[mode]!.dir()).where((f) => f.endsWith(name2)), isNotEmpty);
        });

        test('a copy of the template that survives keeps the assets when the rollback deletes the file (0172)', () async {
          nb.templatePublishedHook = (path) async {
            // Another device's copy of the same template, named from its id.
            File('$path.sync-copy').writeAsStringSync(File(path).readAsStringSync());
            throw FileSystemException('the folder went away', path);
          };
          await expectLater(within(modes[mode]!.save()), throwsA(isA<NotebookException>()));
          nb.templatePublishedHook = null;
          expect(templateFiles(modes[mode]!.dir()), isEmpty, reason: 'the rollback deleted the file');
          expect(files(modes[mode]!.dir()).where((f) => f.endsWith('.sync-copy')), hasLength(1));
          expect(
            files(modes[mode]!.dir()).where((f) => f.endsWith('.bin')),
            isNotEmpty,
            reason: 'the surviving copy may need the assets',
          );
        });

        test('with nothing evicted the save still works, template and assets together', () async {
          await within(modes[mode]!.save());
          expect(templateFiles(modes[mode]!.dir()), hasLength(1));
          expect(files(modes[mode]!.dir()).where((f) => f.endsWith(name)), isNotEmpty);
        });
      });
    }

    test('the rollback refuses when the binder changed', () async {
      nb.templatePublishedHook = (path) async => throw FileSystemException('the folder went away', path);
      nb.templateStepHook = (step) async {
        if (step != 'delete') return;
        // Another binder takes the folder before the rollback's turn.
        File('${binderDir.path}$sep$binderFileName')
            .writeAsStringSync(Binder.create(title: 'Other', id: newId(), color: binderPalette.first).write());
        await nb.checkBinderFile('${binderDir.path}$sep$binderFileName');
        await nb.afterHoldForTest(binderDir.path);
        await nb.useThisBinder(binderDir.path);
      };
      await expectLater(within(nb.savePageAsTemplate(inB, name: 'T', inBinder: true)), throwsA(isA<NotebookException>()));
      nb.templatePublishedHook = null;
      expect(templateFiles(binderTemplates), hasLength(1), reason: 'the binder changed, so the file was not deleted');
      expect(files(binderTemplates).where((f) => f.endsWith(name)), isNotEmpty, reason: 'and its assets stay');
      expect(files(binderTemplates).where((f) => f.endsWith(name2)), isNotEmpty);
    });

    test('assets that arrive with no template file survive a sweeping listing, and stay when the file comes', () async {
      final id = newId();
      final orphan = File('${templates.path}$sep$id.assets${sep}p$sep$name')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(good);
      orphan.setLastModifiedSync(DateTime(2001));
      for (var i = 0; i < 2; i++) {
        await within(nb.listTemplates(TemplateKind.page));
        expect(orphan.existsSync(), isTrue, reason: 'listing $i');
      }
      // Its template file comes (another device's save): the assets stay.
      final saved = await nb.savePageAsTemplate(pageId, name: 'T');
      expect(saved.id, isNot(id));
      await within(nb.listTemplates(TemplateKind.page));
      expect(orphan.existsSync(), isTrue);
    });

    test('a new page from a template whose assets are not downloaded is refused, and no page is made', () async {
      final t = await nb.savePageAsTemplate(pageId, name: 'T');
      final tAssets = Directory('${templates.path}$sep${t.id}.assets$sep$pageId');
      debugMarkDataless('${tAssets.path}$sep$name');
      final before = nb.tree.roots.length;
      await expectLater(
        within(nb.createPageFromTemplate(t)),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', 'Some files are still downloading. Try again in a moment.')),
      );
      expect(nb.tree.roots.length, before);
      expect(askedFor('${tAssets.path}$sep$name'), isTrue);
    });

    test('a new page from a template: a file evicted mid-copy refuses it, and its copies go', () async {
      final t = await nb.savePageAsTemplate(pageId, name: 'T');
      final tAssets = Directory('${templates.path}$sep${t.id}.assets$sep$pageId');
      final before = pages.listSync().map((e) => e.path).toSet();
      attachmentBeforePublishHook = (target) async {
        if (target.endsWith(name2)) debugMarkDataless('${tAssets.path}$sep$name2'); // after the first file was copied
      };
      await expectLater(
        within(nb.createPageFromTemplate(t)),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', 'Some files are still downloading. Try again in a moment.')),
      );
      attachmentBeforePublishHook = null;
      expect(pages.listSync().map((e) => e.path).toSet(), before, reason: 'no page, no assets folder left');
    });

    test('a binder from a template: a file evicted mid-copy refuses it, and no binder or copy is left', () async {
      final t = await nb.saveBinderAsTemplate(binder.path, name: 'T');
      final victim = Directory('${templates.path}$sep${t.id}.assets')
          .listSync(recursive: true)
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith(name2))
          .path;
      attachmentBeforePublishHook = (target) async {
        if (target.endsWith(name2)) debugMarkDataless(victim);
      };
      final target = await Directory('${root.path}/NewBinder2').create();
      await expectLater(within(nb.createBinderFromTemplate(t, target.path)), throwsA(isA<NotebookException>()));
      attachmentBeforePublishHook = null;
      expect(File('${target.path}$sep$binderFileName').existsSync(), isFalse);
      expect(files(target), isEmpty, reason: 'pages and copies were removed');
    });

    test('a binder from a template: a page that sync changed keeps its attachments when a later file is evicted', () async {
      final inB2 = await nb.createPage(binderPath: binder.path);
      put(assetsOf(binderDir, inB2), name, good);
      put(assetsOf(binderDir, inB2), name2, good2);
      final t = await nb.saveBinderAsTemplate(binder.path, name: 'T');
      final tDir = Directory('${templates.path}$sep${t.id}.assets');
      final target = await Directory('${root.path}/NewBinder3').create();
      String? first;
      var changed = false;
      attachmentBeforePublishHook = (to) async {
        final dirName = to.replaceAll(r'\', '/').split('/').reversed.skip(1).first; // <new id>.assets
        first ??= dirName;
        if (dirName == first || changed) return;
        changed = true;
        // Sync changes the page that was published first, then a file is evicted.
        final page = File('${target.path}$sep${first!.replaceAll('.assets', '')}.canvas');
        page.writeAsStringSync('${page.readAsStringSync()} ');
        for (final f in tDir.listSync(recursive: true).whereType<File>()) {
          debugMarkDataless(f.path);
        }
      };
      await expectLater(within(nb.createBinderFromTemplate(t, target.path)), throwsA(isA<NotebookException>()));
      attachmentBeforePublishHook = null;
      expect(changed, isTrue, reason: 'the second page was reached');
      final survivors = target.listSync().whereType<File>().where((f) => f.path.endsWith('.canvas')).toList();
      expect(survivors, hasLength(1), reason: 'only the page that sync changed stays; the others were deleted');
      final id = survivors.single.path.replaceAll(r'\', '/').split('/').last.replaceAll('.canvas', '');
      expect(names(assetsOf(target, id)), isNotEmpty, reason: 'and it keeps its attachments');
      expect(target.listSync().whereType<Directory>().where((d) => !d.path.endsWith('$id.assets') && d.path.endsWith('.assets')), isEmpty,
          reason: 'the deleted pages lost their copies');
    });

    test('a binder from a template whose assets are not downloaded is refused, and no binder is made', () async {
      final t = await nb.saveBinderAsTemplate(binder.path, name: 'T');
      final tDir = Directory('${templates.path}$sep${t.id}.assets');
      final victim = tDir.listSync(recursive: true).whereType<File>().first.path;
      debugMarkDataless(victim);
      final target = await Directory('${root.path}/NewBinder').create();
      await expectLater(
        within(nb.createBinderFromTemplate(t, target.path)),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', 'Some files are still downloading. Try again in a moment.')),
      );
      expect(File('${target.path}$sep$binderFileName').existsSync(), isFalse);
      expect(files(target), isEmpty);
      expect(askedFor(victim), isTrue);
    });
  });

  group('Apple mode: moves and deletes', () {
    late List<String> reads;
    setUp(() {
      debugAppleMode = true;
      reads = [];
      storedReadObserver = reads.add;
    });

    String lower(String p) => p.replaceAll(r'\', '/').toLowerCase();
    bool readOf(String path) => reads.any((r) => lower(r) == lower(path));

    // A page `a` with a downloaded file, a dataless one and a nested dataless one.
    Future<(Notebook, String, String, Directory)> world() async {
      final (nb, a, x) = await scanned();
      final src = assetsOf(pages, a);
      put(src, name, good);
      put(src, name2, good2);
      put(Directory('${src.path}${sep}sub'), name, good);
      debugMarkDataless('${src.path}$sep$name2');
      // Also marked for the old seam, which forgets a mark when its file is read (hydrated).
      Notebook.placeholderMarksForTest = {fileStamp('${src.path}$sep$name2')!};
      reads.clear();
      return (nb, a, x, src);
    }

    test('a move reads nothing of the evicted file, leaves it asked for, and moves the others one by one', () async {
      final (nb, a, x, src) = await world();
      await expectLater(
        nb.move(a, parentId: x),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('Still downloading, left in the old folder: "$name2"'))),
      );
      // The old placeholder seam forgets a mark when the file is read (hydrated): it is still there.
      expect(Notebook.placeholderMarksForTest, isNotEmpty, reason: 'no read of it, not even to download it');
      await Future<void>.delayed(Duration.zero);
      expect(File('${extra.path}$sep$a.canvas').existsSync(), isTrue, reason: 'the page moved');
      expect(names(src), [name2], reason: 'only the evicted file stayed');
      expect(File('${assetsOf(extra, a).path}$sep$name').readAsBytesSync(), good);
      expect(File('${assetsOf(extra, a).path}${sep}sub$sep$name').readAsBytesSync(), good, reason: 'the nested file moved');
      expect(askedFor('${src.path}$sep$name2'), isTrue);
      expect(readOf('${src.path}$sep$name2'), isFalse, reason: 'nothing was read to download it');
    });

    test('an evicted assets folder is asked for and never listed, moved or removed (move)', () async {
      final (nb, a, x) = await scanned();
      final src = assetsOf(pages, a);
      put(src, name, good);
      put(src, name2, good2);
      debugMarkDataless(src.path); // iCloud evicted the whole folder
      await expectLater(
        nb.move(a, parentId: x),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('Still downloading, left in the old folder'))),
      );
      await Future<void>.delayed(Duration.zero);
      expect(names(src), [name, name2]..sort(), reason: 'nothing was moved out of it, and it was not removed');
      expect(names(assetsOf(extra, a)), isEmpty);
      expect(askedFor(src.path), isTrue);
    });

    test('an evicted assets folder refuses a delete whole, and nothing is set aside', () async {
      final (nb, a, _) = await scanned();
      final src = assetsOf(pages, a);
      put(src, name, good);
      debugMarkDataless(src.path);
      await expectLater(
        nb.delete(a),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', 'Still downloading. Delete again once the files are here.')),
      );
      await Future<void>.delayed(Duration.zero);
      expect(File('${pages.path}$sep$a.canvas').existsSync(), isTrue);
      expect(names(src), [name]);
      expect(askedFor(src.path), isTrue);
    });

    test('B2: with the destination folder there, the evicted file is asked for and left with its note', () async {
      final (nb, a, x, src) = await world();
      assetsOf(extra, a).createSync(recursive: true);
      await expectLater(
        nb.move(a, parentId: x),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('Still downloading'))),
      );
      expect(names(src), [name2]);
      expect(askedFor('${src.path}$sep$name2'), isTrue);
    });

    test('a folder that cannot be read refuses a delete whole, with the can-not-be-read text', () async {
      final (nb, a, _) = await scanned();
      final src = assetsOf(pages, a);
      put(src, name, good);
      put(Directory('${src.path}${sep}sub'), name2, good2);
      debugListDir = (d) => sameFile(d, '${src.path}${sep}sub')
          ? throw FileSystemException('io', d, const OSError('io', 5))
          : Directory(d).listSync(followLinks: false);
      await expectLater(
        nb.delete(a),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', "A folder of this page can't be read.")),
      );
      await Future<void>.delayed(Duration.zero);
      expect(File('${pages.path}$sep$a.canvas').existsSync(), isTrue);
      expect(askedFor('${src.path}${sep}sub'), isFalse);
    });

    test('a stray folder with an unreadable subfolder stays, with no "could not be moved" notice', () async {
      final (nb, a, x) = await scanned();
      final src = assetsOf(pages, a);
      put(src, name, good);
      put(Directory('${src.path}${sep}sub'), name2, good2);
      debugListDir = (d) => sameFile(d, '${src.path}${sep}sub')
          ? throw FileSystemException('io', d, const OSError('io', 5))
          : Directory(d).listSync(followLinks: false);
      await expectLater(nb.move(a, parentId: x), throwsA(isA<NotebookException>()));
      notices.clear();
      Notebook.strayQuiet = Duration.zero;
      for (var i = 0; i < 2; i++) {
        await nb.checkFolders();
      }
      expect(Directory('${src.path}${sep}sub').existsSync(), isTrue, reason: 'left where it is');
      expect(notices.any((n) => n.contains('could not be moved')), isFalse, reason: '$notices');
    });

    test('after it is downloaded, the stray mover brings the file to its page', () async {
      final (nb, a, x, src) = await world();
      await expectLater(nb.move(a, parentId: x), throwsA(isA<NotebookException>()));
      expect(names(src), [name2]);
      // The daemon downloads it.
      debugUnmarkDataless('${src.path}$sep$name2');
      Notebook.strayQuiet = Duration.zero;
      for (var i = 0; i < 2; i++) {
        await nb.checkFolders();
      }
      expect(src.existsSync(), isFalse, reason: 'nothing is left at the old place');
      expect(File('${assetsOf(extra, a).path}$sep$name2').readAsBytesSync(), good2);
    });

    test('the stray mover asks for its not-downloaded file at each check, at most once per 30 s', () async {
      final (nb, a, x, src) = await world();
      await expectLater(nb.move(a, parentId: x), throwsA(isA<NotebookException>()));
      asked.clear();
      var t = DateTime(2031, 1, 1);
      nb.now = () => t;
      await nb.checkFolders();
      await Future<void>.delayed(Duration.zero);
      int count() => asked.where((p) => sameFile(p, '${src.path}$sep$name2')).length;
      final first = count();
      expect(first, 1, reason: 'before any decline or quiet wait');
      t = t.add(const Duration(seconds: 10));
      await nb.checkFolders();
      await Future<void>.delayed(Duration.zero);
      expect(count(), first, reason: 'not within 30 s');
      t = t.add(const Duration(seconds: 25));
      await nb.checkFolders();
      await Future<void>.delayed(Duration.zero);
      expect(count(), greaterThan(first), reason: 'after 30 s');
    });

    test('a stub entry is not moved and its target name is asked for; a dataless subfolder is asked for, not entered', () async {
      final (nb, a, x) = await scanned();
      final src = assetsOf(pages, a);
      put(src, name, good);
      put(src, '.$name2.icloud', const []);
      final sub = Directory('${src.path}${sep}held')..createSync();
      put(sub, name2, good2);
      debugMarkDataless(sub.path);
      await expectLater(nb.move(a, parentId: x), throwsA(isA<NotebookException>()));
      await Future<void>.delayed(Duration.zero);
      expect(names(src), ['.$name2.icloud', 'held']..sort());
      expect(names(sub), [name2], reason: 'not entered');
      expect(askedFor('${src.path}$sep$name2'), isTrue, reason: 'the stub stands for it');
      expect(askedFor(sub.path), isTrue);
      expect(File('${assetsOf(extra, a).path}$sep$name').readAsBytesSync(), good);
    });

    test('a folder with nothing evicted is renamed whole, in another isolate', () async {
      final (nb, a, x) = await scanned();
      final src = assetsOf(pages, a);
      put(src, name, good);
      put(Directory('${src.path}${sep}sub'), name2, good2);
      expect(await nb.move(a, parentId: x), isTrue);
      expect(src.existsSync(), isFalse);
      expect(File('${assetsOf(extra, a).path}${sep}sub$sep$name2').readAsBytesSync(), good2);
      expect(reads.where((r) => r.contains('.assets')), isEmpty);
    });

    test('a delete with an evicted attachment is refused whole; the first page is untouched; deleting again works', () async {
      final first = make();
      await first.load();
      final a = first.currentId!;
      final b = await first.createPage(parentId: a);
      await first.open(a);
      await first.flush();
      first.dispose();
      opened.remove(first);
      final nb = make();
      await nb.load();
      put(assetsOf(pages, a), name, good);
      put(assetsOf(pages, b), name2, good2);
      debugMarkDataless('${assetsOf(pages, b).path}$sep$name2');
      await expectLater(
        nb.delete(a),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', 'Still downloading. Delete again once the files are here.')),
      );
      await Future<void>.delayed(Duration.zero);
      expect(File('${pages.path}$sep$a.canvas').existsSync(), isTrue);
      expect(File('${pages.path}$sep$b.canvas').existsSync(), isTrue);
      expect(names(assetsOf(pages, a)), [name], reason: 'the first page was not set aside');
      expect(askedFor('${assetsOf(pages, b).path}$sep$name2'), isTrue);
      debugUnmarkDataless('${assetsOf(pages, b).path}$sep$name2');
      final deleted = await nb.delete(a);
      expect(File('${pages.path}$sep$a.canvas').existsSync(), isFalse);
      expect(deleted, isNotNull);
    });

    test('another page\'s save in the same folder waits for the slow rename and lands after it', () async {
      final (nb, a, x) = await scanned();
      put(assetsOf(pages, a), name, good);
      final b = await nb.createPage(); // open, in the folder the move leaves
      debugRenameDelay = const Duration(seconds: 3);
      final started = DateTime.now();
      DateTime? movedAt, savedAt;
      final move = nb.move(a, parentId: x).then((_) => movedAt = DateTime.now());
      await Future<void>.delayed(const Duration(milliseconds: 600)); // inside the rename
      final c = nb.current!;
      final box = c.createBoxAt(const Bounds(10, 10, 0, 0));
      c.commit(box.id, c.modules.codecs.codecFor(box.typeId)!.decode({
        'document': {
          'type': 'page',
          'children': [
            {
              'type': 'paragraph',
              'data': {
                'delta': [
                  {'insert': 'typed during the move'},
                ],
              },
            },
          ],
        },
      }, 1));
      final save = nb.flush().then((_) => savedAt = DateTime.now());
      await Future.wait([move, save]);
      expect(movedAt, isNotNull);
      expect(savedAt, isNotNull);
      expect(
        savedAt!.difference(started),
        greaterThan(const Duration(milliseconds: 2900)),
        reason: 'the save waited for the 3 s rename: it was asked at 0.6 s',
      );
      expect(File('${pages.path}$sep$b.canvas').readAsStringSync(), contains('typed during the move'));
    });

    test('leaving the page during the wait puts its edit in recovery, and a relaunch lands it', () async {
      final rec = Directory('${root.path}/recovery');
      Notebook mk() {
        final n = Notebook(
          PageStore(pages),
          buildModules(),
          saveDelay: Duration.zero,
          bindersFile: File('${root.path}/app/binders.json'),
          recoveryDirectory: rec,
          leaveSaveLimit: const Duration(milliseconds: 300),
        );
        opened.add(n);
        return n;
      }

      final first = mk();
      await first.load();
      final a = first.currentId!;
      final x = await first.createPage(folderPath: extra.path);
      final b = await first.createPage();
      await first.flush();
      first.dispose();
      opened.remove(first);
      final nb = mk();
      await nb.load();
      put(assetsOf(pages, a), name, good);
      await nb.open(b);
      debugRenameDelay = const Duration(seconds: 3);
      final move = nb.move(a, parentId: x);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final c = nb.current!;
      final box = c.createBoxAt(const Bounds(10, 10, 0, 0));
      c.commit(box.id, c.modules.codecs.codecFor(box.typeId)!.decode({
        'document': {
          'type': 'page',
          'children': [
            {
              'type': 'paragraph',
              'data': {
                'delta': [
                  {'insert': 'typed while waiting'},
                ],
              },
            },
          ],
        },
      }, 1));
      await nb.open(x); // leaves b: its save is still waiting for the folder
      final kept = await nb.pendingRecovery();
      expect(kept.entries.any((e) => e.pageId == b), isTrue, reason: 'the edit is in recovery while the rename runs');
      await move;
      await nb.flush();
      nb.dispose();
      opened.remove(nb);
      // A relaunch: the edit is in the page, from the save or from recovery.
      final again = mk();
      await again.load();
      await again.open(b);
      await again.flush();
      expect(File('${pages.path}$sep$b.canvas').readAsStringSync(), contains('typed while waiting'));
    });

    test('a kept file that is not downloaded stays in recovery, asked for, and lands once it is here', () async {
      final rec = Directory('${root.path}/recovery');
      Notebook mk() {
        final n = Notebook(
          PageStore(pages),
          buildModules(),
          saveDelay: Duration.zero,
          bindersFile: File('${root.path}/app/binders.json'),
          recoveryDirectory: rec,
        )..askDownload = (p) async {
            asked.add(p);
            return null;
          };
        opened.add(n);
        return n;
      }

      final first = mk();
      await first.load();
      final a = first.currentId!;
      await first.flush();
      first.dispose();
      opened.remove(first);
      final kept = put(Directory('${rec.path}$sep$a.assets'), name, good);
      debugMarkDataless(kept.path);
      final nb = mk();
      await nb.load();
      await nb.checkFolders();
      await Future<void>.delayed(Duration.zero);
      expect(kept.existsSync(), isTrue, reason: 'the kept file stays in recovery');
      expect(names(assetsOf(pages, a)), isEmpty, reason: 'nothing was copied or written in its place');
      expect(askedFor(kept.path), isTrue);
      expect(reads.where((r) => sameFile(r, kept.path)), isEmpty, reason: 'it was not read');
      debugUnmarkDataless(kept.path);
      await nb.checkFolders();
      await nb.checkFolders();
      expect(File('${assetsOf(pages, a).path}$sep$name').readAsBytesSync(), good);
      expect(kept.existsSync(), isFalse);
    });

    test('a slow rename names the move after 2 s, while this isolate keeps running', () async {
      final (nb, a, x) = await scanned();
      final src = assetsOf(pages, a);
      put(src, name, good);
      debugRenameDelay = const Duration(seconds: 3);
      var ticks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 100), (_) => ticks++);
      addTearDown(timer.cancel);
      final move = nb.move(a, parentId: x);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(notices.any((n) => n.contains('the folder is still being moved') && n.startsWith('Moving ')), isTrue, reason: '$notices');
      expect(ticks, greaterThan(15), reason: 'the UI isolate was not blocked');
      expect(await move, isTrue);
      timer.cancel();
      expect(File('${assetsOf(extra, a).path}$sep$name').readAsBytesSync(), good);
    });
  });
}
