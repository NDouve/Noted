// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_commands.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

/// Records which UI actions the commands asked for.
class _Actions implements PageTreeActions {
  final List<String> calls = [];
  @override
  Future<void> newStandalonePage() async => calls.add('newPage');
  @override
  Future<void> newPageFromTemplate() async => calls.add('newPageFromTemplate');
  @override
  Future<void> newBinder() async => calls.add('newBinder');
  @override
  Future<void> newBinderInFolder() async => calls.add('newBinderInFolder');
  @override
  Future<void> openBinder() async => calls.add('openBinder');
  @override
  Future<void> moveToFolder(PageMeta page) async => calls.add('moveToFolder ${page.id}');
  @override
  Future<void> newBinderFromTemplate() async => calls.add('newBinderFromTemplate');
  @override
  Future<void> newSubpage(PageMeta page) async => calls.add('newSubpage ${page.id}');
  @override
  Future<void> newSubpageFromTemplate(PageMeta page) async =>
      calls.add('newSubpageFromTemplate ${page.id}');
  @override
  Future<void> saveAsTemplate(PageMeta page) async => calls.add('saveAsTemplate ${page.id}');
  @override
  Future<void> rename(PageMeta page) async => calls.add('rename ${page.id}');
  @override
  Future<void> indent(PageMeta page) async => calls.add('indent ${page.id}');
  @override
  Future<void> delete(PageMeta page) async => calls.add('delete ${page.id}');
  @override
  Future<void> binderNewPage(BinderSection binder) async {}
  @override
  Future<void> binderNewPageFromTemplate(BinderSection binder) async {}
  @override
  Future<void> binderSaveAsTemplate(BinderSection binder) async {}
  @override
  Future<void> binderRemove(BinderSection binder) async {}
}

void main() {
  late Directory dir;
  late Notebook nb;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('noted_cmds');
    nb = Notebook(PageStore(dir), buildModules(), saveDelay: Duration.zero);
    await nb.load();
  });

  tearDown(() async {
    nb.dispose();
    await dir.delete(recursive: true);
  });

  group('page commands', () {
    test('the page menu is made of commands with the menu labels', () async {
      final a = nb.currentId!;
      await nb.createPage();
      final r = pageCommands(nb, nb.tree[a]!, _Actions());
      expect(
        [for (final c in r.commands) (c.id, c.label)],
        [
          ('app.page.newSubpage', 'New subpage'),
          ('app.page.newSubpageFromTemplate', 'New subpage from template…'),
          ('app.page.saveAsTemplate', 'Save as template…'),
          ('app.page.rename', 'Rename'),
          ('app.page.moveUp', 'Move up'),
          ('app.page.moveDown', 'Move down'),
          ('app.page.indent', 'Indent'),
          ('app.page.outdent', 'Outdent'),
          ('app.page.moveToFolder', 'Move to folder…'),
          ('app.page.delete', 'Delete'),
          ('app.page.background.plain', 'Page background: Plain'),
          ('app.page.background.dots', 'Page background: Dots'),
          ('app.page.background.graph', 'Page background: Graph'),
          ('app.page.background.ruled', 'Page background: Ruled'),
        ],
      );
    });

    test('enabled follows the page\'s place in the tree', () async {
      final a = nb.currentId!;
      final b = await nb.createPage();
      final c = await nb.createPage();
      var r = pageCommands(nb, nb.tree[a]!, _Actions());
      expect(r[AppCommands.moveUp]!.enabled, isFalse, reason: 'first');
      expect(r[AppCommands.indent]!.enabled, isFalse, reason: 'first');
      expect(r[AppCommands.moveDown]!.enabled, isTrue);
      expect(r[AppCommands.outdent]!.enabled, isFalse, reason: 'top level');
      r = pageCommands(nb, nb.tree[c]!, _Actions());
      expect(r[AppCommands.moveUp]!.enabled, isTrue);
      expect(r[AppCommands.moveDown]!.enabled, isFalse, reason: 'last');
      expect(r[AppCommands.indent]!.enabled, isTrue);
      await nb.indent(b);
      r = pageCommands(nb, nb.tree[b]!, _Actions());
      expect(r[AppCommands.outdent]!.enabled, isTrue, reason: 'now a subpage');
    });

    test('invoking runs the action or the notebook change; a disabled one does nothing', () async {
      final a = nb.currentId!;
      final b = await nb.createPage();
      final actions = _Actions();
      var r = pageCommands(nb, nb.tree[b]!, actions);
      expect(await r.invoke(AppCommands.rename), isTrue);
      expect(await r.invoke(AppCommands.newSubpage), isTrue);
      expect(await r.invoke(AppCommands.delete), isTrue);
      expect(await r.invoke(AppCommands.indent), isTrue);
      expect(actions.calls, [
        'rename $b',
        'newSubpage $b',
        'delete $b',
        'indent $b',
      ]);
      expect(await r.invoke(AppCommands.moveUp), isTrue);
      expect(nb.tree.roots.map((p) => p.id), [b, a]);

      r = pageCommands(nb, nb.tree[b]!, actions);
      expect(await r.invoke(AppCommands.moveUp), isFalse, reason: 'already first');
      expect(actions.calls, hasLength(4));
    });

    test('the Pages header commands', () async {
      final actions = _Actions();
      final r = pagesHeaderCommands(nb, actions);
      expect(r[AppCommands.newPage]!.label, 'New page');
      expect(r[AppCommands.newPageFromTemplate]!.label, 'New page from template…');
      expect(r[AppCommands.newBinder]!.label, 'New binder');
      expect(r[AppCommands.newBinderFromTemplate]!.label, 'New binder from template…');
      await r.invoke(AppCommands.newPage);
      await r.invoke(AppCommands.newPageFromTemplate);
      expect(actions.calls, ['newPage', 'newPageFromTemplate']);
      // Without a folder picker (no binders on this device) binders are off.
      // New binder needs no picker; the folder-picking items do.
      expect(r[AppCommands.newBinder]!.enabled, isTrue);
      expect(r[AppCommands.newBinderInFolder]!.enabled, nb.pickFolder != null);
      expect(r[AppCommands.openBinder]!.enabled, nb.pickFolder != null);
      expect(r[AppCommands.newPage]!.shortcut!.trigger, LogicalKeyboardKey.keyN);
      expect(r[AppCommands.newPage]!.whileEditing, isTrue);
    });
  });

  group('theme commands', () {
    test('one command per theme, the current one checked, invoking changes it', () async {
      final settings = AppSettings(null);
      addTearDown(settings.dispose);
      final r = themeCommands(settings);
      expect(
        [for (final c in r.commands) (c.id, c.label)],
        [
          ('app.theme.system', 'Follow system'),
          ('app.theme.light', 'Light'),
          ('app.theme.dark', 'Dark'),
        ],
      );
      expect(r[AppCommands.themeSystem]!.checked, isTrue);
      var notified = 0;
      r.addListener(() => notified++);
      await r.invoke(AppCommands.themeDark);
      expect(settings.theme, ThemeSetting.dark);
      expect(r[AppCommands.themeDark]!.checked, isTrue);
      expect(r[AppCommands.themeSystem]!.checked, isFalse);
      expect(notified, greaterThan(0), reason: 'the registry heard the change');
      await r.invoke(AppCommands.themeLight);
      expect(settings.theme, ThemeSetting.light);
    });
  });

  testWidgets('the open page has the toolbar of registry commands, in sync with the keys', (t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: Home(notebook: nb)));
    await t.pump();
    await t.pump();

    for (final tip in [
      'Select and type (V)',
      'Pen (P)',
      'Eraser (E)',
      'Undo (Ctrl+Z)',
      'Redo (Ctrl+Y)',
      'Insert table',
      'Insert equation',
      'Fit all',
      'Zoom to 100% (Ctrl+0)',
    ]) {
      expect(find.byTooltip(tip), findsOneWidget, reason: tip);
    }
    expect(find.text('100%'), findsOneWidget);

    bool checked(String tooltip) => t
        .widget<IconButton>(
          find.ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton)),
        )
        .isSelected ??
        false;

    // Undo and redo start disabled; so do the note commands (no editor).
    IconButton btn(String tooltip) => t.widget<IconButton>(
      find.ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton)),
    );
    // Table and Equation are ghost text buttons.
    TextButton textBtn(String tooltip) => t.widget<TextButton>(
      find.descendant(of: find.byTooltip(tooltip), matching: find.byType(TextButton)),
    );
    expect(btn('Undo (Ctrl+Z)').onPressed, isNull);
    expect(textBtn('Insert table').onPressed, isNull);
    expect(textBtn('Insert equation').onPressed, isNull);

    expect(checked('Select and type (V)'), isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.keyP);
    await t.pump();
    expect(checked('Pen (P)'), isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.keyE);
    await t.pump();
    expect(checked('Eraser (E)'), isTrue);
    expect(checked('Pen (P)'), isFalse);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(checked('Select and type (V)'), isTrue);
    await t.tap(find.byTooltip('Pen (P)'));
    await t.pump();
    expect(checked('Pen (P)'), isTrue);
    // Colors are enabled with the pen.
    expect(
      t.widget<InkResponse>(find.descendant(of: find.byTooltip('Ink color: Blue'), matching: find.byType(InkResponse))).onTap,
      isNotNull,
    );

    await t.pumpWidget(const SizedBox());
  });
}
