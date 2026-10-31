// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart' show buildModules;
import 'package:noted/src/notebook.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import '../support/harness.dart';
import '../support/note_helpers.dart';

String _text(WidgetTester t, String key) => t.widget<Text>(find.byKey(ValueKey(key))).data!;

/// New entries S1.. (search) and T1.. (binder from template).
void searchSuite() {
  group('search and binder from template', () {
    testWidgets('S1: Find on page (Ctrl+F): count, stepping with Enter/Shift+Enter/F3, Esc closes', (t) async {
      await withSession(t, 'findonpage', (s) async {
        addNote(s, [para('needle one'), para('hay'), para('needle two needle three')]);
        await s.pump(400);
        await s.ctrl(LogicalKeyboardKey.keyF);
        expect(find.byKey(const ValueKey('find-bar')), findsOneWidget);
        await t.enterText(find.byKey(const ValueKey('find-field')), 'needle');
        await s.pump(500);
        expect(_text(t, 'find-count'), '1 of 3');
        await s.key(LogicalKeyboardKey.enter);
        expect(_text(t, 'find-count'), '2 of 3');
        await s.key(LogicalKeyboardKey.f3);
        expect(_text(t, 'find-count'), '3 of 3');
        await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await s.pump(200);
        expect(_text(t, 'find-count'), '2 of 3');
        await t.tap(find.byKey(const ValueKey('find-next')));
        await s.pump(200);
        expect(_text(t, 'find-count'), '3 of 3');
        await t.tap(find.byKey(const ValueKey('find-field')));
        await s.pump(150);
        await s.key(LogicalKeyboardKey.escape);
        await s.pump(300);
        expect(find.byKey(const ValueKey('find-bar')), findsNothing);
      });
    });

    testWidgets('S2: Find on page brings a far-away match into view', (t) async {
      await withSession(t, 'findview', (s) async {
        addNote(s, [para('here')], x: 0, y: 0);
        addNote(s, [para('distant needle')], x: 3000, y: 2500);
        await s.pump(400);
        await t.tap(await toolbarButton(t, 'canvas.zoomReset'));
        await s.pump(300);
        await s.ctrl(LogicalKeyboardKey.keyF);
        await t.enterText(find.byKey(const ValueKey('find-field')), 'needle');
        await s.pump(800);
        final size = t.getSize(find.byType(PageCanvas));
        final view = canvasState(t).view!;
        final visible = view.visible(Size(size.width, size.height - 52));
        expect(visible.contains(const Offset(3040, 2520)), isTrue, reason: 'the match box is in view');
      });
    });

    testWidgets('S3-S5: Search all pages: grouped results, clicking opens the page with find pre-filled, NOT SEARCHED for an unavailable binder', (t) async {
      late Directory folder;
      late String pageA;
      late String boxA;
      await withSession(
        t,
        'searchall',
        (s) async {
          pageA = s.nb.tree.roots.firstWhere((p) => p.title == 'Alpha').id;
          await s.nb.open(pageA);
          await s.pump(300);
          boxA = addNote(s, [para('first needle here')]);
          await s.flush();
          final pageB = await s.newPage('Beta');
          await s.nb.open(pageB);
          await s.pump(300);
          addNote(s, [para('a needle and another needle')]);
          await s.flush();
          await s.newPage('Gamma');
          await s.flush();
          await s.nb.open(pageB);
          await s.pump(300);

          // Ctrl+Shift+F focuses the sidebar search field.
          await s.ctrl(LogicalKeyboardKey.keyF, shift: true);
          await s.pump(300);
          final field = find.byKey(const ValueKey('search-field'));
          expect(field, findsOneWidget);
          await t.enterText(field, 'needle');
          await s.until(() => find.byKey(ValueKey('search-page-$pageA')).evaluate().isNotEmpty, what: 'results');
          expect(find.byKey(ValueKey('search-page-${s.nb.currentId}')), findsOneWidget);
          expect(find.textContaining('Gamma'), findsNothing);
          // S4: clicking a result opens its page with find pre-filled.
          await t.tap(find.byKey(ValueKey('search-result-$pageA-$boxA')));
          await s.pump(900);
          expect(s.nb.currentId, pageA);
          expect(find.byKey(const ValueKey('find-bar')), findsOneWidget);
          expect(t.widget<TextField>(find.byKey(const ValueKey('find-field'))).controller!.text, 'needle');
          expect(_text(t, 'find-count'), '1 of 1');

          // S5: a binder whose folder is away is listed under NOT SEARCHED.
          final away = Directory('${folder.path}-away');
          folder.renameSync(away.path);
          await s.until(() => s.nb.binders.single.status == BinderStatus.unavailable, what: 'unavailable');
          await t.enterText(field, 'needl');
          await s.pump(300);
          await t.enterText(field, 'needle');
          await s.until(() => find.byKey(const ValueKey('search-not-searched')).evaluate().isNotEmpty, what: 'not searched');
          expect(find.text('NOT SEARCHED'), findsOneWidget);
          expect(find.byKey(const ValueKey('not-searched-Work')), findsOneWidget);
          away.renameSync(folder.path);
          await s.until(() => s.nb.binders.single.status == BinderStatus.available, what: 'back');
        },
        prepare: (env) async {
          folder = env.folder('Work');
          final nb = Notebook(PageStore(env.pages), buildModules(), bindersFile: env.binders, recoveryDirectory: env.recovery);
          await nb.load();
          await nb.rename(nb.currentId!, 'Alpha');
          final sec = await nb.addBinder(folder.path);
          final p = await nb.createPage(binderPath: sec.path);
          await nb.rename(p, 'Inside');
          await nb.flush();
          nb.dispose();
        },
        watchFiles: true,
        folderCheckInterval: const Duration(milliseconds: 400),
      );
    });

    testWidgets('T1: New binder from template needs no folder picker; it makes "<template>" in the default binder folder (then "<template> 2") and opens the cover with the title focused', (t) async {
      await withSession(t, 'bindertemplate', (s) async {
        final folder = s.env.folder('Work');
        final binder = await s.nb.addBinder(folder.path);
        await s.nb.updateBinder(binder.path, title: 'Work');
        final p = await s.newPage('Inside', binderPath: binder.path);
        await s.nb.open(p);
        await s.flush();
        await s.nb.saveBinderAsTemplate(binder.path, name: 'Team');
        final picks = s.picks;
        for (final expected in ['Team', 'Team 2']) {
          await s.tapKey('pages-menu', settle: 500);
          await s.tapText('New binder from template…', settle: 700);
          await s.tapText('Team', settle: 1200);
          await s.until(() => s.nb.binders.any((b) => b.path.endsWith('${Platform.pathSeparator}$expected')), what: expected);
          expect(s.picks, picks, reason: 'no folder picker');
          final made = s.nb.binders.firstWhere((b) => b.path.endsWith('${Platform.pathSeparator}$expected'));
          expect(s.env.contains(made.path), isTrue);
          expect(made.tree.roots.map((x) => x.title), ['Inside']);
          expect(find.text('Binder cover'), findsOneWidget);
          final title = t.widget<TextField>(find.byKey(const ValueKey('cover-title')));
          expect(title.focusNode!.hasFocus, isTrue);
        }
      });
    });
  });
}

