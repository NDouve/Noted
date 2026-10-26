// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

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

  Notebook make() {
    final nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: settings,
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

  group('menus', () {
    late Notebook nb;

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      await tester.pumpAndSettle();
    }

    Future<void> untilCount(WidgetTester tester, Directory d, int n) async {
      for (var i = 0; i < 60 && tplFiles(d).length != n; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tplFiles(d), hasLength(n));
    }

    Future<void> untilFound(WidgetTester tester, Finder f) async {
      for (var i = 0; i < 40 && f.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(f, findsOneWidget);
    }

    Future<void> start(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
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
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      }
      await tester.runAsync(tearDownDirs);
    }

    Future<void> tapWhenFound(WidgetTester tester, Finder f) async {
      for (var i = 0; i < 60 && f.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
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
      await tester.runAsync(() => nb.addBinder(binderDir.path));
      late String inB;
      await tester.runAsync(() async {
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
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tplFiles(appTemplates()), hasLength(2));
      await finish(tester);
    });

    testWidgets('Pages menu: New page from template picks, then creates it in the default folder', (tester) async {
      await start(tester);
      await tester.runAsync(() => nb.savePageAsTemplate(nb.currentId!, name: 'Alpha template'));
      final before = pages.listSync().where((f) => f.path.endsWith('.canvas')).length;

      await tester.tap(find.byKey(const ValueKey('pages-menu')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tapAsync(tester, find.text('New page from template…'));
      expect(find.text('Alpha template'), findsOneWidget);
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
      await tester.runAsync(() => nb.savePageAsTemplate(nb.currentId!, name: 'Alpha template'));
      final parent = nb.currentId!;
      await tester.pumpAndSettle();
      await pageMenu(tester, 'New subpage from template…');
      final delete = find.byTooltip('Delete template');
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tapAsync(tester, find.text('Delete').last);
      expect(find.text('There are no templates yet.'), findsOneWidget);
      expect(tplFiles(appTemplates()), isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.runAsync(() => nb.savePageAsTemplate(parent, name: 'Again'));
      await pageMenu(tester, 'New subpage from template…');
      await tapAsync(tester, find.text('Again'));
      expect(nb.tree.childrenOf(parent), hasLength(1));
      await finish(tester);
    });

    testWidgets('binder menu: save as template, then New binder from template', (tester) async {
      await start(tester);
      await tester.runAsync(() => nb.addBinder(binderDir.path));
      await tester.runAsync(() async {
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
        for (var i = 0; i < 60 && nb.binders.length < expected; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
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
