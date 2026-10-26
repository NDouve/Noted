// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

import '../support/harness.dart';
import '../support/note_helpers.dart';

List<File> _tpl(Directory d) =>
    d.existsSync() ? [for (final f in d.listSync()) if (f is File) f] : <File>[];

/// Checklist steps 74-81 and 178 (templates).
void templatesSuite() {
  group('templates', () {
    testWidgets('step 074, 076-078, 081, 178: save a page as a template, create pages and subpages from it, delete it', (t) async {
      await withSession(t, 'templates', (s) async {
        final a = s.nb.currentId!;
        await s.nb.rename(a, 'Plan');
        await putNote(s, 'Template text');
        s.nb.current!.setBackground(PageBackground.ruled);
        await s.flush();
        // 074: Save as template, name it.
        await s.pageMenu(a, 'Save as template…');
        expect(find.text('Save as template'), findsOneWidget);
        await t.enterText(find.byKey(const ValueKey('template-name')), 'My plan');
        await t.tap(find.text('Save'));
        await s.pump(800);
        expect(find.text('Saved template "My plan"'), findsOneWidget);
        expect(_tpl(s.env.templates), hasLength(1));
        // 076-077: New page from template: picker lists it; no storage dialog.
        final before = s.rootIds.length;
        await s.tapKey('pages-menu', settle: 500);
        await s.tapText('New page from template…', settle: 600);
        expect(find.text('My plan'), findsOneWidget);
        await s.tapText('My plan', settle: 900);
        await s.until(() => s.rootIds.length == before + 1, what: 'page from template');
        expect(find.text('Where should this page be stored?'), findsNothing);
        final c = s.nb.current!;
        expect(c.page.meta.title, 'Plan');
        expect(c.page.nodes.whereType<BoxRecord>().single.snapshotText, 'Template text');
        // 178: the background came with it.
        expect(c.page.meta.background, PageBackground.ruled);
        // 078: New subpage from template.
        await s.pageMenu(a, 'New subpage from template…');
        await s.tapText('My plan', settle: 900);
        await s.until(() => s.kids(a).length == 1, what: 'subpage from template');
        // 081: delete from the picker.
        await s.pageMenu(a, 'New subpage from template…');
        await t.tap(find.byTooltip('Delete template'));
        await s.pump(500);
        await t.tap(find.text('Delete').last);
        await s.pump(800);
        expect(find.text('There are no templates yet.'), findsOneWidget);
        expect(_tpl(s.env.templates), isEmpty);
        await t.tap(find.text('Cancel'));
        await s.pump(400);
      });
    });

    testWidgets('step 075, 079, 080: a binder page saves "This binder"; a binder saves app-wide and creates a binder from the template', (t) async {
      await withSession(t, 'bindertemplates', (s) async {
        final folder = s.env.folder('Work');
        final binder = await s.nb.addBinder(folder.path);
        final inB = await s.newPage('Bound', binderPath: binder.path);
        await s.nb.open(inB);
        await s.pump(300);
        await putNote(s, 'Bound text');
        await s.flush();
        // 075: "This binder" is offered and preselected.
        await s.pageMenu(inB, 'Save as template…');
        expect(find.byKey(const ValueKey('template-where-binder')), findsOneWidget);
        await t.enterText(find.byKey(const ValueKey('template-name')), 'Bound plan');
        await t.tap(find.text('Save'));
        await s.pump(900);
        expect(_tpl(Directory('${folder.path}${Platform.pathSeparator}templates')), hasLength(1));
        expect(_tpl(s.env.templates), isEmpty);
        // 079: binder menu: Save as template… is app-wide.
        await s.tapKey('binder-menu-${binder.path}', settle: 500);
        await s.tapText('Save as template…', settle: 600);
        expect(find.text('Save binder as template'), findsOneWidget);
        expect(find.byKey(const ValueKey('template-where-binder')), findsNothing);
        await t.testTextInput.receiveAction(TextInputAction.done);
        await s.pump(900);
        expect(_tpl(s.env.templates), hasLength(1));
        // 080 (model level: the menu item is being changed): a binder from the
        // template in an empty folder has the same color, cover and page tree.
        final listing = await s.nb.listTemplates(TemplateKind.binder);
        final tpl = listing.items.single.template;
        final target = s.env.folder('FromTemplate');
        final made = await s.nb.createBinderFromTemplate(tpl, target.path);
        await s.pump(500);
        expect(made.binder!.color, binder.binder!.color);
        expect(made.tree.roots.map((p) => p.title), ['Bound']);
      });
    });
  });
}
