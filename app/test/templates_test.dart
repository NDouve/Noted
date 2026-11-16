// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A test that hangs fails after 3 minutes instead of holding the run.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';
import 'support/real_io.dart';
import 'support/settle_saves.dart';

Map<String, Object?> doc(String text) => {
  'document': {
    'type': 'page',
    'children': [
      {
        'type': 'paragraph',
        'data': {
          'delta': [
            {'insert': text},
          ],
        },
      },
    ],
  },
};

List<String> tplFiles(Directory d) => d.existsSync()
    ? [
        for (final f in d.listSync())
          if (f.path.endsWith('.notedtemplate')) f.path,
      ]
    : [];

/// A store that runs [onSaveNew] (with the count so far and the page) before
/// each new page file it is asked to publish, and may throw there.
class _FailingStore extends PageStore {
  _FailingStore(super.directory);

  int count = 0;
  void Function(int n, NotedPage page)? onSaveNew;

  @override
  Future<bool> saveNew(NotedPage page, {Future<void> Function()? beforePublish}) {
    onSaveNew?.call(count++, page);
    return super.saveNew(page, beforePublish: beforePublish);
  }
}

void main() {
  late Directory root;
  late Directory pages;
  late Directory binderDir;
  late File settings;
  late List<Notebook> opened;
  String? pickAnswer;
  var picks = 0;

  Future<void> setUpDirs() async {
    root = await Directory.systemTemp.createTemp('noted_templates');
    pages = await Directory('${root.path}/pages').create();
    binderDir = await Directory('${root.path}/Work').create();
    settings = File('${root.path}/app/binders.json');
    opened = [];
    pickAnswer = null;
    picks = 0;
  }

  Notebook make({List<String>? roots}) {
    final nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: settings,
      readOnlyRoots: roots ?? const [],
      pickFolder: () async {
        picks++;
        return pickAnswer;
      },
    );
    opened.add(nb);
    return nb;
  }

  Future<void> tearDownDirs() async {
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    await root.delete(recursive: true);
  }

  Directory appTemplates() => Directory('${root.path}/app/templates');

  /// Puts a note box with [text] on the open page.
  void addNote(Notebook nb, String text, {Bounds at = const Bounds(10, 10, 0, 0)}) {
    final c = nb.current!;
    final box = c.createBoxAt(at);
    c.commit(box.id, c.modules.codecs.codecFor(box.typeId)!.decode(doc(text), 1));
  }

  Future<NotedPage> loadPage(Notebook nb, String id) async {
    await nb.flush();
    final dirs = [pages, binderDir];
    for (final d in dirs) {
      final f = File('${d.path}/$id.canvas');
      if (f.existsSync()) return readPage(f.readAsStringSync());
    }
    throw StateError('no file for $id');
  }

  List<BoxRecord> boxes(NotedPage p) => p.nodes.whereType<BoxRecord>().toList();

  void expectSameContent(NotedPage a, NotedPage b) {
    final x = boxes(a), y = boxes(b);
    expect(x, hasLength(y.length));
    for (var i = 0; i < x.length; i++) {
      expect(x[i].id, isNot(y[i].id));
      expect(x[i].rev, isNot(y[i].rev));
      expect(x[i].typeId, y[i].typeId);
      expect(x[i].data!.text, y[i].data!.text);
      expect(x[i].snapshotText, y[i].snapshotText);
      expect(x[i].bounds, y[i].bounds);
    }
  }

  group('model', () {
    setUp(setUpDirs);
    tearDown(tearDownDirs);

    test('save a page as an app-wide template, then make pages from it', () async {
      final nb = make();
      await nb.load();
      final src = nb.currentId!;
      addNote(nb, 'Agenda');
      addNote(nb, 'Notes', at: const Bounds(10, 200, 0, 0));
      await nb.rename(src, 'Meeting');
      final sub = await nb.createPage(parentId: src);
      await nb.open(src);

      final t = await nb.savePageAsTemplate(src, name: '');
      expect(t.name, 'Meeting'); // the page title by default
      final file = File('${appTemplates().path}/${t.id}.notedtemplate');
      expect(file.existsSync(), isTrue);
      // Subpages are not part of it.
      expect(t.page.nodes, hasLength(2));
      expect(file.readAsStringSync(), isNot(contains(sub)));

      final listing = await nb.listTemplates(TemplateKind.page);
      expect(listing.items.single.template.id, t.id);
      expect(listing.items.single.binderPath, isNull);

      final made = await nb.createPageFromTemplate(listing.items.single.template);
      expect(made, isNot(src));
      expect(nb.currentId, made);
      final a = await loadPage(nb, src);
      final b = await loadPage(nb, made);
      expect(b.meta.title, 'Meeting');
      expect(b.meta.parentId, isNull);
      expectSameContent(b, a);
      expect(boxes(b).map((e) => e.id).toSet().intersection(boxes(a).map((e) => e.id).toSet()), isEmpty);
      // The template is untouched by using it.
      expect(File(file.path).readAsStringSync(), t.write());
      // Using it twice gives different ids again.
      final again = await nb.createPageFromTemplate(t);
      final c = await loadPage(nb, again);
      expect(boxes(c).first.id, isNot(boxes(b).first.id));
    });

    test('a template can go to a binder, or be used for a subpage', () async {
      final nb = make();
      await nb.load();
      final binder = await nb.addBinder(binderDir.path);
      final inB = await nb.createPage(binderPath: binder.path);
      addNote(nb, 'In binder');
      await nb.rename(inB, 'Plan');

      final mine = await nb.savePageAsTemplate(inB, name: 'Binder plan', inBinder: true);
      expect(File('${binderDir.path}/templates/${mine.id}.notedtemplate').existsSync(), isTrue);
      final global = await nb.savePageAsTemplate(inB, name: 'Global plan');
      expect(File('${appTemplates().path}/${global.id}.notedtemplate').existsSync(), isTrue);

      final inside = await nb.listTemplates(TemplateKind.page, binderPath: binder.path);
      expect(inside.items.map((e) => e.template.name).toSet(), {'Binder plan', 'Global plan'});
      final outside = await nb.listTemplates(TemplateKind.page);
      expect(outside.items.single.template.name, 'Global plan');

      // The templates folder in a binder is not mistaken for pages.
      final again = make();
      await again.load();
      expect(again.binders.single.unreadable, isEmpty);

      // A page that isn't in a binder can't be saved to one.
      final plain = await nb.createPage();
      await expectLater(
        nb.savePageAsTemplate(plain, name: 'x', inBinder: true),
        throwsA(isA<NotebookException>()),
      );

      // New page in the binder, and a subpage of it, from the template.
      final newPage = await nb.createPageFromTemplate(mine, binderPath: binder.path);
      expect(File('${binderDir.path}/$newPage.canvas').existsSync(), isTrue);
      expect(nb.binderOfPage(newPage), binder.path);
      final sub = await nb.createPageFromTemplate(global, parentId: newPage);
      expect(File('${binderDir.path}/$sub.canvas').existsSync(), isTrue);
      expect(nb.treeOfPage(sub).parentIdOf(sub), newPage);
      expectSameContent(await loadPage(nb, sub), await loadPage(nb, inB));
      expect(nb.treeOfPage(newPage).isDivider(newPage), isTrue);
    });

    test('a page from a template in a standalone folder goes to that folder', () async {
      final nb = make();
      await nb.load();
      final other = await Directory('${root.path}/Elsewhere').create();
      addNote(nb, 'x');
      final t = await nb.savePageAsTemplate(nb.currentId!, name: 'X');
      final id = await nb.createPageFromTemplate(t, folderPath: other.path);
      expect(File('${other.path}/$id.canvas').existsSync(), isTrue);
      expect(nb.standaloneFolders, hasLength(1));
    });

    test('R-1: a binder that fails to be created keeps what changed since it was written, in plain words', () async {
      void Function(int n, NotedPage page)? hook;
      final freshDir = await Directory('${root.path}/Copy').create();
      final nb = Notebook(
        PageStore(pages),
        buildModules(),
        saveDelay: Duration.zero,
        bindersFile: settings,
        storeFactory: (d) {
          return _FailingStore(d)..onSaveNew = (n, page) => hook?.call(n, page);
        },
      );
      opened.add(nb);
      await nb.load();
      final binder = await nb.addBinder(binderDir.path);
      final root1 = await nb.createPage(binderPath: binder.path);
      await nb.createPage(parentId: root1);
      final t = await nb.saveBinderAsTemplate(binder.path, name: 'T');

      late String firstPath;
      hook = (n, page) {
        if (n == 0) {
          firstPath = '${freshDir.path}/${page.id}.canvas';
          return;
        }
        // The first page was written; a sync client changes it, then the second fails.
        File(firstPath).writeAsStringSync(File(firstPath).readAsStringSync().replaceFirst('"title":"', '"title":"Synced '));
        throw FileSystemException('disk full', freshDir.path);
      };

      await expectLater(
        nb.createBinderFromTemplate(t, freshDir.path),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            allOf(startsWith('Could not create the binder'), isNot(contains(freshDir.path)), isNot(contains('Exception'))),
          ),
        ),
      );
      expect(File(firstPath).readAsStringSync(), contains('Synced '), reason: 'the changed page is kept');
      expect(File('${freshDir.path}/$binderFileName').existsSync(), isFalse, reason: 'the binder file we wrote goes');
    });

    test('save a binder as a template and make a binder from it', () async {
      final nb = make();
      await nb.load();
      final binder = await nb.addBinder(binderDir.path);
      await nb.updateBinder(
        binder.path,
        title: 'Project',
        description: 'About it',
        owner: 'Sam',
        color: binderPalette[4],
      );
      final root1 = await nb.createPage(binderPath: binder.path);
      addNote(nb, 'Root text');
      await nb.rename(root1, 'Overview');
      final kid = await nb.createPage(parentId: root1);
      addNote(nb, 'Kid text');
      await nb.rename(kid, 'Details');

      final t = await nb.saveBinderAsTemplate(binder.path, name: '');
      expect(t.name, 'Project');
      expect(File('${appTemplates().path}/${t.id}.notedtemplate').existsSync(), isTrue);
      expect(binderDir.listSync().whereType<Directory>(), isEmpty); // not stored inside it
      expect(t.pages, hasLength(2));
      expect(t.pages.first.id, root1); // parents first

      final listing = await nb.listTemplates(TemplateKind.binder);
      expect(listing.items.single.template.id, t.id);
      expect((await nb.listTemplates(TemplateKind.page)).items, isEmpty);

      // A folder that already has a binder is refused.
      await expectLater(
        nb.createBinderFromTemplate(t, binderDir.path),
        throwsA(isA<NotebookException>()),
      );
      final fresh = await Directory('${root.path}/Copy').create();
      final made = await nb.createBinderFromTemplate(t, fresh.path);
      expect(made.available, isTrue);
      expect(nb.coverPath, made.path);
      final b = made.binder!;
      expect([b.title, b.description, b.owner, b.color], ['Project', 'About it', 'Sam', binderPalette[4]]);
      expect(b.id, isNot(binder.binder!.id));
      expect(File('${fresh.path}/$binderFileName').existsSync(), isTrue);

      expect(made.tree.roots, hasLength(1));
      final newRoot = made.tree.roots.single;
      expect(newRoot.id, isNot(root1));
      expect(newRoot.title, 'Overview');
      final newKid = made.tree.childrenOf(newRoot.id).single;
      expect(newKid.id, isNot(kid));
      expect(newKid.title, 'Details');
      final copy = readPage(File('${fresh.path}/${newKid.id}.canvas').readAsStringSync());
      expectSameContent(copy, await loadPage(nb, kid));

      // From the menu's path: no folder picker, a folder named after the
      // template in the default binder folder, numbered when taken.
      final picksBefore = picks;
      final first = await nb.createBinderFromTemplateInDefault(t);
      final second = await nb.createBinderFromTemplateInDefault(t);
      expect(picks, picksBefore);
      final sep = Platform.pathSeparator;
      expect(first.path, endsWith('${sep}Project'));
      expect(second.path, endsWith('${sep}Project 2'));
      for (final b in [first, second]) {
        expect(
          Directory(b.path).parent.absolute.path.toLowerCase(),
          Directory(nb.defaultBinderFolderPath).absolute.path.toLowerCase(),
        );
        expect(File('${b.path}$sep$binderFileName').existsSync(), isTrue);
        expect(b.tree.roots.single.title, 'Overview');
      }
      expect(nb.coverPath, second.path);

      // It survives a restart.
      await nb.flush();
      final again = make();
      await again.load();
      expect(again.binders.map((e) => e.title), containsAll(['Project']));
      expect(again.binders, hasLength(4)); // the original, Copy, Project, Project 2
    });

    test('a provider copy of a template is not merged or deleted (known limit)', () async {
      final nb = make();
      await nb.load();
      final t = await nb.savePageAsTemplate(nb.currentId!, name: 'Fine');
      final orig = File('${appTemplates().path}/${t.id}.notedtemplate');
      final text = orig.readAsStringSync();
      final copy = File('${appTemplates().path}/${t.id} (1).notedtemplate')..writeAsStringSync(text);
      await nb.listTemplates(TemplateKind.page);
      await nb.checkFolders();
      expect(copy.existsSync(), isTrue);
      expect(copy.readAsStringSync(), text);
      expect(orig.readAsStringSync(), text);
    });
    test('an unreadable template is listed and left alone', () async {
      final nb = make();
      await nb.load();
      appTemplates().createSync(recursive: true);
      const newer = '{"format":99,"templateId":"future","kind":"page","name":"From the future"}';
      final f = File('${appTemplates().path}/future.notedtemplate')..writeAsStringSync(newer);
      final junk = File('${appTemplates().path}/junk.notedtemplate')..writeAsStringSync('nope');

      var listing = await nb.listTemplates(TemplateKind.page);
      expect(listing.items, isEmpty);
      expect(listing.unreadable, hasLength(2));
      expect(listing.unreadable.map((u) => u.reason).join(), contains('newer'));

      final t = await nb.savePageAsTemplate(nb.currentId!, name: 'Fine');
      listing = await nb.listTemplates(TemplateKind.page);
      expect(listing.items.single.template.id, t.id);
      await nb.deleteTemplate(listing.items.single);
      expect((await nb.listTemplates(TemplateKind.page)).items, isEmpty);
      expect(f.readAsStringSync(), newer);
      expect(junk.readAsStringSync(), 'nope');
    });
  });

  group('checked deletes', () {
    setUp(setUpDirs);
    tearDown(tearDownDirs);

    final good1 = Uint8List.fromList([1, 2, 3, 4]);
    final good2 = Uint8List.fromList([5, 6, 7, 8]);
    final name1 = attachmentFileName(contentHash(good1), 'txt');
    final name2 = attachmentFileName(contentHash(good2), 'txt');

    String base(String path) => path.split(RegExp(r'[\\/]')).last;

    // Every file and folder under [d], with the file bytes.
    Map<String, String> snapshot(Directory d) => {
      for (final e in d.existsSync() ? d.listSync(recursive: true) : <FileSystemEntity>[])
        e.path.substring(d.path.length): e is File ? base64Encode(e.readAsBytesSync()) : '<dir>',
    };

    Directory tAssets(Directory dir, NotedTemplate t) => Directory('${dir.path}/${t.id}.assets/${t.page.id}');

    File put(Directory d, String name, List<int> bytes) {
      d.createSync(recursive: true);
      return File('${d.path}/$name')..writeAsBytesSync(bytes);
    }

    // An app-wide template of the open page with two verified attachments.
    Future<(NotedTemplate, Directory)> appTemplate(Notebook nb, {bool files = true}) async {
      final t = await nb.savePageAsTemplate(nb.currentId!, name: 'T');
      final a = tAssets(appTemplates(), t);
      if (files) {
        put(a, name1, good1);
        put(a, name2, good2);
      }
      return (t, a);
    }

    List<String> collect(Notebook nb) {
      final notices = <String>[];
      nb.attachmentNotices.listen(notices.add);
      return notices;
    }

    Future<void> tick() => Future<void>.delayed(Duration.zero);

    Matcher refusal(String text) => throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains(text)));

    test('a template that changed since it was listed is not deleted, and its assets stay', () async {
      final nb = make();
      await nb.load();
      final (t, a) = await appTemplate(nb);
      final item = (await nb.listTemplates(TemplateKind.page)).items.single;
      final file = File(item.path);
      final changed = '${file.readAsStringSync()} ';
      file.writeAsStringSync(changed);
      await expectLater(nb.deleteTemplate(item), refusal('changed since it was listed'));
      expect(file.readAsStringSync(), changed);
      expect(File('${a.path}/$name1').existsSync(), isTrue);
      expect(File('${a.path}/$name2').existsSync(), isTrue);
      expect(Directory(appTemplates().path).listSync().whereType<File>().map((f) => base(f.path)), ['${t.id}.notedtemplate']);
    });

    test('the assets cleanup removes verified files and emptied folders and keeps everything else', () async {
      final nb = make();
      await nb.load();
      final notices = collect(nb);
      final (_, a) = await appTemplate(nb);
      put(a, 'note.txt', [1]);
      final damagedName = attachmentFileName(contentHash([9, 9]), 'txt');
      put(a, damagedName, [1]);
      put(Directory('${a.path}/sub'), attachmentFileName(contentHash([3, 3]), 'txt'), [4]);
      put(Directory('${a.path}/gone'), name2, good2);
      final item = (await nb.listTemplates(TemplateKind.page)).items.single;
      await nb.deleteTemplate(item);
      await tick();

      expect(File(item.path).existsSync(), isFalse);
      expect(File('${a.path}/$name1').existsSync(), isFalse);
      expect(File('${a.path}/$name2').existsSync(), isFalse);
      expect(Directory('${a.path}/gone').existsSync(), isFalse, reason: 'emptied folder');
      expect(File('${a.path}/note.txt').existsSync(), isTrue);
      expect(File('${a.path}/$damagedName').existsSync(), isTrue);
      expect(Directory('${a.path}/sub').listSync(), hasLength(1));
      expect(notices.single, allOf(contains('some of its files were kept'), contains('note.txt'), contains(damagedName)));
    });

    test('a second template file with the same id keeps the assets', () async {
      final nb = make();
      await nb.load();
      final notices = collect(nb);
      final (t, a) = await appTemplate(nb);
      final text = File('${appTemplates().path}/${t.id}.notedtemplate').readAsStringSync();
      File('${appTemplates().path}/Copy of T.notedtemplate').writeAsStringSync(text);
      final items = (await nb.listTemplates(TemplateKind.page)).items;
      expect(items, hasLength(2));
      await nb.deleteTemplate(items.firstWhere((i) => !i.path.contains('Copy of')));
      await tick();
      expect(File('${a.path}/$name1').existsSync(), isTrue);
      expect(File('${a.path}/$name2').existsSync(), isTrue);
      expect(notices.single, contains('another copy of the template may need them'));
      // The last copy's delete cleans them.
      final rest = (await nb.listTemplates(TemplateKind.page)).items.single;
      await nb.deleteTemplate(rest);
      expect(Directory('${appTemplates().path}/${t.id}.assets').existsSync(), isFalse);
    });

    group('Codex R-1: a copy that can not be read keeps the assets', () {
      Future<void> keptThenUsable(Notebook nb, NotedTemplate t, Directory a, void Function() makeReadable) async {
        expect(File('${a.path}/$name1').existsSync(), isTrue);
        expect(File('${a.path}/$name2').existsSync(), isTrue);
        makeReadable();
        final again = make();
        await again.load();
        final listing = await again.listTemplates(TemplateKind.page);
        expect(listing.items.single.template.id, t.id);
        expect(listing.unreadable, isEmpty);
        final page = await again.createPageFromTemplate(listing.items.single.template);
        expect(File('${pages.path}/$page.assets/$name1').readAsBytesSync(), good1);
        expect(File('${pages.path}/$page.assets/$name2').readAsBytesSync(), good2);
      }

      test('a copy written as invalid text during the delete, named unrelated to the id', () async {
        final nb = make();
        await nb.load();
        final (t, a) = await appTemplate(nb);
        final text = File('${appTemplates().path}/${t.id}.notedtemplate').readAsStringSync();
        final copy = File('${appTemplates().path}/Copy of T.notedtemplate');
        final item = (await nb.listTemplates(TemplateKind.page)).items.single;
        nb.templateStepHook = (step) async {
          if (step == 'delete') copy.writeAsStringSync('{ half written');
        };
        await nb.deleteTemplate(item);
        await keptThenUsable(nb, t, a, () => copy.writeAsStringSync(text));
      });

      test('a leftover of another delete, named unrelated to the id', () async {
        final nb = make();
        await nb.load();
        final (t, a) = await appTemplate(nb);
        final text = File('${appTemplates().path}/${t.id}.notedtemplate').readAsStringSync();
        final item = (await nb.listTemplates(TemplateKind.page)).items.single;
        final left = File('${appTemplates().path}/Other.notedtemplate.4242-a-b.cas-old');
        nb.templateStepHook = (step) async {
          if (step == 'delete') left.writeAsStringSync(text);
        };
        await nb.deleteTemplate(item);
        expect(left.existsSync(), isTrue);
        // A new Notebook's listing sweeps it back into the template.
        await keptThenUsable(nb, t, a, () {});
        expect(left.existsSync(), isFalse);
        expect(File('${appTemplates().path}/Other.notedtemplate').readAsStringSync(), text);
      });

      test('a file named from the id, not a template (the save temp)', () async {
        final nb = make();
        await nb.load();
        final notices = collect(nb);
        final (t, a) = await appTemplate(nb);
        final item = (await nb.listTemplates(TemplateKind.page)).items.single;
        File('${appTemplates().path}/${t.id}.notedtemplate.tmp').writeAsStringSync('half');
        await nb.deleteTemplate(item);
        await tick();
        expect(File('${a.path}/$name1').existsSync(), isTrue);
        expect(File('${a.path}/$name2').existsSync(), isTrue);
        expect(notices.single, contains('another copy of the template may need them'));
      });
    });

    group('Codex R-2: a binder that changed is not written into', () {
      late Notebook nb;
      late BinderSection binder;
      late String inB;
      late Directory templates;
      Map<String, String>? atReplace;

      setUp(() async {
        nb = make();
        await nb.load();
        binder = await nb.addBinder(binderDir.path);
        inB = await nb.createPage(binderPath: binder.path);
        addNote(nb, 'In binder');
        templates = Directory('${binderDir.path}/templates');
        atReplace = null;
      });

      Future<void> replaceBinder() async {
        final file = File('${binderDir.path}/$binderFileName');
        file.writeAsStringSync(Binder.create(title: 'Other', id: newId(), color: binderPalette.first).write());
        await nb.checkBinderFile(file.path);
        await nb.useThisBinder(binderDir.path);
        atReplace = snapshot(templates);
      }

      // Replaces the binder the [nth] time [step] is reached.
      void crossAt(String step, {int nth = 1}) {
        var n = 0;
        nb.templateStepHook = (s) async {
          if (s == step && ++n == nth) await replaceBinder();
        };
      }

      Future<void> expectUnchanged() async {
        expect(atReplace, isNotNull, reason: 'the hook was reached');
        expect(snapshot(templates), atReplace);
        final again = make();
        await again.load();
        expect(snapshot(templates), atReplace, reason: 'after a restart');
      }

      Future<(NotedTemplate, Directory)> binderTemplate({bool files = true}) async {
        final t = await nb.savePageAsTemplate(inB, name: 'B', inBinder: true);
        final a = tAssets(templates, t);
        if (files) {
          put(a, name1, good1);
          put(a, name2, good2);
        }
        return (t, a);
      }

      test('a queued Save as template into the binder, crossing the replacement after the page was read', () async {
        crossAt('saveTemplate');
        await expectLater(nb.savePageAsTemplate(inB, name: 'B', inBinder: true), refusal('The binder changed; nothing was written.'));
        await expectUnchanged();
        expect(templates.existsSync() ? tplFiles(templates) : <String>[], isEmpty);
      });

      test('a Save as template stopped after its file says the assets are missing', () async {
        final (_, a) = await binderTemplate(); // a template exists, so the folder does
        a.parent.deleteSync(recursive: true);
        put(Directory('${binderDir.path}/$inB.assets'), name1, good1);
        crossAt('saveAssets');
        await expectLater(
          nb.savePageAsTemplate(inB, name: 'B2', inBinder: true),
          refusal('saved without its images and files'),
        );
        expect(tplFiles(templates), hasLength(2), reason: 'the file was written before the replacement');
      });

      test('a sweeping listing with a leftover present lists it and moves nothing', () async {
        final (t, _) = await binderTemplate(files: false);
        final file = File('${templates.path}/${t.id}.notedtemplate');
        final left = file.renameSync('${file.path}.4242-a-b.cas-old');
        crossAt('sweep');
        final listing = await nb.listTemplates(TemplateKind.page, binderPath: binder.path);
        expect(listing.unreadable.map((u) => base(u.path)), contains(base(left.path)));
        expect(left.existsSync(), isTrue);
        expect(file.existsSync(), isFalse);
        await expectUnchanged();
      });

      test('a delete crossing the replacement before the file delete', () async {
        await binderTemplate();
        final item = (await nb.listTemplates(TemplateKind.page, binderPath: binder.path)).items.firstWhere((i) => i.binderPath != null);
        crossAt('delete');
        await expectLater(nb.deleteTemplate(item), refusal('The binder changed; nothing was written.'));
        expect(File(item.path).existsSync(), isTrue);
        await expectUnchanged();
      });

      test('a delete crossing the replacement between two asset deletes', () async {
        final (_, a) = await binderTemplate();
        final item = (await nb.listTemplates(TemplateKind.page, binderPath: binder.path)).items.firstWhere((i) => i.binderPath != null);
        crossAt('assetDelete', nth: 2);
        final notices = collect(nb);
        await nb.deleteTemplate(item); // the file is gone: the picker drops it, and the notice says the rest
        await tick();
        expect(File(item.path).existsSync(), isFalse);
        expect(notices.single, 'The template was deleted; the binder changed, so its files were kept.');
        expect(a.listSync().whereType<File>(), hasLength(1), reason: 'one went before the replacement, one stays');
        await expectUnchanged();
      });

      test('a template listed before the binder was replaced is not deleted', () async {
        await binderTemplate();
        final item = (await nb.listTemplates(TemplateKind.page, binderPath: binder.path)).items.firstWhere((i) => i.binderPath != null);
        expect(item.binderId, isNotNull);
        await replaceBinder();
        await expectLater(nb.deleteTemplate(item), refusal('The binder changed; nothing was written.'));
        expect(File(item.path).existsSync(), isTrue);
        await expectUnchanged();
      });

      test('a page made from a binder template reads its assets without sweeping after the replacement', () async {
        final (t, a) = await binderTemplate(files: false);
        put(a, name1, good1);
        final left = put(a, '$name2.4242-a-b.cas-old', good2);
        crossAt('copyAssets');
        final made = await nb.createPageFromTemplate(t, binderPath: binder.path);
        expect(made, isNotEmpty);
        expect(left.existsSync(), isTrue, reason: 'the leftover was not put back');
        expect(File('${a.path}/$name2').existsSync(), isFalse);
        await expectUnchanged();
      });

      test('a same-id copy landing between two asset deletes stops the cleanup and keeps the rest', () async {
        final nb2 = nb;
        final notices = collect(nb2);
        final (t, a) = await appTemplate(nb2);
        final item = (await nb2.listTemplates(TemplateKind.page)).items.single;
        final text = File(item.path).readAsStringSync();
        var n = 0;
        nb2.templateStepHook = (step) async {
          if (step == 'assetDelete' && ++n == 2) {
            File('${appTemplates().path}/Copy of T.notedtemplate').writeAsStringSync(text);
          }
        };
        await nb2.deleteTemplate(item);
        await tick();
        expect(a.listSync().whereType<File>(), hasLength(1), reason: 'the first went, the rest stays');
        expect(notices.single, contains('another copy of the template may need them'));
      });

      test('the same template synced back to the deleted path between two asset deletes stops the cleanup', () async {
        final notices = collect(nb);
        final (t, a) = await appTemplate(nb);
        final item = (await nb.listTemplates(TemplateKind.page)).items.single;
        final text = File(item.path).readAsStringSync();
        var n = 0;
        nb.templateStepHook = (step) async {
          if (step == 'assetDelete' && ++n == 2) File(item.path).writeAsStringSync(text);
        };
        await nb.deleteTemplate(item);
        await tick();
        expect(File(item.path).readAsStringSync(), text, reason: 'the copy is untouched');
        expect(a.listSync().whereType<File>(), hasLength(1), reason: 'the first went, the rest stays');
        expect(notices.single, contains('another copy of the template may need them'));
        expect(t.id, isNotEmpty);
      });
    });

    for (final bad in ['../victim', 'a/b', r'..\victim', '.', '..']) {
      test('a template id that is not a plain name ("$bad") is unreadable and touches nothing outside templates/', () async {
        final nb = make();
        await nb.load();
        final (t, _) = await appTemplate(nb, files: false);
        final text = File('${appTemplates().path}/${t.id}.notedtemplate').readAsStringSync();
        final victim = put(Directory('${appTemplates().parent.path}/victim.assets/${t.page.id}'), name1, good1);
        final evil = File('${appTemplates().path}/evil.notedtemplate')..writeAsStringSync(text.replaceFirst(RegExp(r'"templateId"\s*:\s*"[^"]*"'), '"templateId": ${jsonEncode(bad)}'));
        expect(evil.readAsStringSync(), contains('"templateId": ${jsonEncode(bad)}'));
        final listing = await nb.listTemplates(TemplateKind.page);
        expect(listing.items.map((i) => i.template.id), [t.id]);
        expect(listing.unreadable.map((u) => base(u.path)), ['evil.notedtemplate']);
        expect(victim.existsSync(), isTrue);
      });
    }

    test('a template whose page id is a path copies nothing from outside its assets folder', () async {
      final nb = make();
      await nb.load();
      final page = NotedPage.create(PageMeta.create(id: '../x', title: 'P', order: 0));
      final t = NotedTemplate.forPage(name: 'E', page: page);
      Directory('${appTemplates().path}/${t.id}.assets').createSync(recursive: true);
      // `<templates>/<id>.assets/../x` is `<templates>/x`.
      final victim = put(Directory('${appTemplates().path}/x'), name1, good1);
      File('${appTemplates().path}/${t.id}.notedtemplate').writeAsStringSync(t.write());
      final made = await nb.createPageFromTemplate(t);
      expect(Directory('${pages.path}/$made.assets').existsSync(), isFalse, reason: 'nothing was copied from outside');
      expect(victim.readAsBytesSync(), good1);
    });

    test('a pull-only binder lists a leftover as unreadable and does not move it', () async {
      final first = make();
      await first.load();
      final binder = await first.addBinder(binderDir.path);
      final inB = await first.createPage(binderPath: binder.path);
      final t = await first.savePageAsTemplate(inB, name: 'B', inBinder: true);
      await first.flush();
      final templates = Directory('${binderDir.path}/templates');
      final file = File('${templates.path}/${t.id}.notedtemplate');
      final left = file.renameSync('${file.path}.4242-a-b.cas-old');
      final before = snapshot(templates);

      final nb = make(roots: [binderDir.path]);
      await nb.load();
      final listing = await nb.listTemplates(TemplateKind.page, binderPath: binderDir.path);
      expect(listing.unreadable.map((u) => base(u.path)), contains(base(left.path)));
      expect(listing.unreadable.firstWhere((u) => base(u.path) == base(left.path)).reason, contains('left over from a delete'));
      expect(snapshot(templates), before);
    });

    test('a binder that can not be read is listed without a sweep', () async {
      final nb = make();
      await nb.load();
      final binder = await nb.addBinder(binderDir.path);
      final inB = await nb.createPage(binderPath: binder.path);
      final t = await nb.savePageAsTemplate(inB, name: 'B', inBinder: true);
      final templates = Directory('${binderDir.path}/templates');
      final file = File('${templates.path}/${t.id}.notedtemplate');
      file.renameSync('${file.path}.4242-a-b.cas-old');
      final before = snapshot(templates);
      File('${binderDir.path}/$binderFileName').writeAsStringSync('{ not json');
      await nb.checkBinderFile('${binderDir.path}/$binderFileName');
      final listing = await nb.listTemplates(TemplateKind.page, binderPath: binder.path);
      expect(listing.unreadable.map((u) => u.reason), contains(contains('left over from a delete')));
      expect(snapshot(templates), before);
    });

    test('reload equivalence: a delete stopped after the move aside is put back by the next listing', () async {
      final nb = make();
      await nb.load();
      final (t, a) = await appTemplate(nb);
      await nb.flush();
      final file = File('${appTemplates().path}/${t.id}.notedtemplate');
      final text = file.readAsStringSync();
      // The crash state: the template is set aside, nothing else happened.
      final left = file.renameSync('${file.path}.$pid-a-b.cas-old');

      final again = make();
      await again.load();
      final listing = await again.listTemplates(TemplateKind.page);
      expect(listing.unreadable, isEmpty);
      expect(listing.items.single.template.id, t.id);
      expect(left.existsSync(), isFalse);
      expect(file.readAsStringSync(), text);
      expect(File('${a.path}/$name1').readAsBytesSync(), good1);
      final page = await again.createPageFromTemplate(listing.items.single.template);
      expect(File('${pages.path}/$page.assets/$name1').readAsBytesSync(), good1);
      expect(File('${pages.path}/$page.assets/$name2').readAsBytesSync(), good2);

      await again.deleteTemplate(listing.items.single);
      expect(file.existsSync(), isFalse);
      expect(Directory('${appTemplates().path}/${t.id}.assets').existsSync(), isFalse);
    });
  });

  group('menus', () {
    late Notebook nb;

    // A step that needs real time (files), bounded: one stuck on a timer of the
    // fake clock fails here, with its stack, instead of holding the run until
    // the job's limit.
    Future<T?> real<T>(WidgetTester tester, Future<T> Function() step) => tester.runAsync(
      () => step().timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TestFailure('A real-time step did not finish within 60 s.'),
      ),
    );

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => realIoPause(50));
      }
      await tester.pumpAndSettle();
    }

    Future<void> untilCount(WidgetTester tester, Directory d, int n) async {
      for (var i = 0; i < 60 && tplFiles(d).length != n; i++) {
        await tester.runAsync(() => realIoPause(50));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tplFiles(d), hasLength(n));
    }

    Future<void> untilFound(WidgetTester tester, Finder f) async {
      for (var i = 0; i < 40 && f.evaluate().isEmpty; i++) {
        await tester.runAsync(() => realIoPause(50));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(f, findsOneWidget);
    }

    Future<void> start(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await real(tester, () async {
        await setUpDirs();
        nb = make();
        await nb.load();
        await nb.rename(nb.currentId!, 'Alpha');
        addNote(nb, 'Alpha text');
      });
      await tester.pumpWidget(MaterialApp(home: Home(notebook: nb)));
      await tester.pump();
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => realIoPause(30));
      }
      for (final nb in [...opened]) {
        await settleSaves(tester, nb);
      }
      await tester.runAsync(tearDownDirs);
    }

    Future<void> tapWhenFound(WidgetTester tester, Finder f) async {
      for (var i = 0; i < 60 && f.evaluate().isEmpty; i++) {
        await tester.runAsync(() => realIoPause(50));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(() => tester.tap(f));
      await settle(tester);
    }

    Future<void> tapAsync(WidgetTester tester, Finder f) async {
      await tester.runAsync(() => tester.tap(f));
      await settle(tester);
    }

    Future<void> pageMenu(WidgetTester tester, String item) async {
      await tester.tap(find.byTooltip('Page options').first);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tapAsync(tester, find.text(item));
    }

    testWidgets('page menu: Save as template asks for a name and a place', (tester) async {
      await start(tester);
      await real(tester, () => nb.addBinder(binderDir.path));
      late String inB;
      await real(tester, () async {
        inB = await nb.createPage(binderPath: nb.binders.single.path);
        await nb.rename(inB, 'Bound');
        addNote(nb, 'Bound text');
      });
      await tester.pump();

      // A standalone page: no choice of place; Enter saves under the title.
      await pageMenu(tester, 'Save as template…');
      expect(find.text('Save as template'), findsOneWidget);
      expect(find.byKey(const ValueKey('template-where-binder')), findsNothing);
      expect(find.widgetWithText(TextField, 'Alpha'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      await untilCount(tester, appTemplates(), 1);
      await untilFound(tester, find.text('Saved template "Alpha"'));

      // A page in a binder: "This binder" is offered and preselected.
      await tester.tap(find.byTooltip('Page options').last);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tapAsync(tester, find.text('Save as template…'));
      expect(find.byKey(const ValueKey('template-where-binder')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('template-name')), 'Bound plan');
      await tapAsync(tester, find.text('Save'));
      await untilCount(tester, Directory('${binderDir.path}/templates'), 1);
      expect(tplFiles(appTemplates()), hasLength(1));

      await tester.tap(find.byTooltip('Page options').last);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tapAsync(tester, find.text('Save as template…'));
      await tester.tap(find.byKey(const ValueKey('template-where-app')));
      await tester.pump();
      await tapAsync(tester, find.text('Save'));
      for (var i = 0; i < 40 && tplFiles(appTemplates()).length < 2; i++) {
        await tester.runAsync(() => realIoPause(50));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tplFiles(appTemplates()), hasLength(2));
      await finish(tester);
    });

    testWidgets('Pages menu: New page from template picks, then creates it in the default folder', (tester) async {
      await start(tester);
      await real(tester, () => nb.savePageAsTemplate(nb.currentId!, name: 'Alpha template'));
      final before = pages.listSync().where((f) => f.path.endsWith('.canvas')).length;

      await tester.tap(find.byKey(const ValueKey('pages-menu')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tapAsync(tester, find.text('New page from template…'));
      await untilFound(tester, find.text('Alpha template'));
      await tapAsync(tester, find.text('Alpha template'));
      // No question about where to store it: the default folder is used.
      expect(find.text('Where should this page be stored?'), findsNothing);
      await settle(tester);
      expect(pages.listSync().where((f) => f.path.endsWith('.canvas')), hasLength(before + 1));
      final page = await tester.runAsync(() => loadPage(nb, nb.currentId!));
      expect(page!.meta.title, 'Alpha');
      expect(boxes(page).single.snapshotText, 'Alpha text');
      await finish(tester);
    });

    testWidgets('New subpage from template; delete a template from the picker', (tester) async {
      await start(tester);
      await real(tester, () => nb.savePageAsTemplate(nb.currentId!, name: 'Alpha template'));
      final parent = nb.currentId!;
      await tester.pumpAndSettle();
      await pageMenu(tester, 'New subpage from template…');
      final delete = find.byTooltip('Delete template');
      await untilFound(tester, delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tapAsync(tester, find.text('Delete').last);
      await untilFound(tester, find.text('There are no templates yet.'));
      expect(tplFiles(appTemplates()), isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await real(tester, () => nb.savePageAsTemplate(parent, name: 'Again'));
      await pageMenu(tester, 'New subpage from template…');
      await untilFound(tester, find.text('Again'));
      await tapAsync(tester, find.text('Again'));
      // Making the page reads and writes files: wait for it.
      for (var i = 0; i < 60 && nb.tree.childrenOf(parent).isEmpty; i++) {
        await tester.runAsync(() => realIoPause(50));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(nb.tree.childrenOf(parent), hasLength(1));
      await finish(tester);
    });

    testWidgets('binder menu: save as template, then New binder from template', (tester) async {
      await start(tester);
      await real(tester, () => nb.addBinder(binderDir.path));
      await real(tester, () async {
        final p = await nb.createPage(binderPath: nb.binders.single.path);
        await nb.rename(p, 'Inside');
        await nb.open(nb.tree.roots.first.id);
      });
      await tester.pump();
      final path = nb.binders.single.path;

      await tester.tap(find.byKey(ValueKey('binder-menu-$path')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tapAsync(tester, find.text('Save as template…'));
      expect(find.text('Save binder as template'), findsOneWidget);
      expect(find.byKey(const ValueKey('template-where-binder')), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      await untilCount(tester, appTemplates(), 1);

      // New binder from template: no folder picker. The binder is created at
      // once in the default binder folder, in a folder named after the
      // template, and its cover opens.
      pickAnswer = binderDir.path;
      final picksBefore = picks;
      Future<void> fromTemplate(int expected) async {
        await tester.tap(find.byKey(const ValueKey('pages-menu')));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        await tapAsync(tester, find.text('New binder from template…'));
        await tapWhenFound(tester, find.descendant(of: find.byType(AlertDialog), matching: find.text('Work')));
        // The binder is listed before its cover is shown (the add still checks the folder once more).
        for (var i = 0; i < 400 && (nb.binders.length < expected || nb.cover?.path != nb.binders.last.path); i++) {
          await tester.runAsync(() => realIoPause(50));
          await tester.pump(const Duration(milliseconds: 50));
        }
        await settle(tester);
      }

      await fromTemplate(2);
      expect(picks, picksBefore);
      expect(nb.binders, hasLength(2));
      final made = nb.binders.last;
      expect(made.path, endsWith('${Platform.pathSeparator}Work'));
      expect(
        Directory(made.path).parent.absolute.path.toLowerCase(),
        Directory(nb.defaultBinderFolderPath).absolute.path.toLowerCase(),
      );
      expect(nb.cover?.path, made.path);
      expect(made.tree.roots.single.title, 'Inside');

      // The same template again: the name is taken, so a number is added.
      await fromTemplate(3);
      expect(picks, picksBefore);
      expect(nb.binders.last.path, endsWith('${Platform.pathSeparator}Work 2'));
      expect(nb.cover?.path, nb.binders.last.path);
      await finish(tester);
    });
  });
}
