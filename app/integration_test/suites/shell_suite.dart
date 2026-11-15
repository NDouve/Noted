// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:noted/main.dart' show buildModules;
import 'package:noted/src/notebook.dart';

import 'package:noted_canvas/noted_canvas.dart' show PageCanvas;
import 'package:noted_core/noted_core.dart';

import '../support/harness.dart';
import '../support/note_helpers.dart';

Future<void> _top(Session s, String title) => s.tapKey('menu-top-$title', settle: 400);

bool _on(WidgetTester t, String id) =>
    t.widget<MenuItemButton>(find.byKey(ValueKey('menu-$id'))).onPressed != null;

Brightness _brightness(WidgetTester t) => Theme.of(t.element(find.byType(Scaffold).first)).brightness;

/// The menu bar and the contextual panel (task 6): entries M1.. in step_map.json.
void shellSuite() {
  group('desktop shell', () {
    testWidgets('M1: File > New page makes a page and opens it', (t) async {
      await withSession(t, 'shellnew', (s) async {
        final before = s.nb.currentId;
        await _top(s, 'File');
        await s.tapKey('menu-app.page.new', settle: 800);
        await s.until(() => s.nb.currentId != before, what: 'the new page');
      });
    });

    testWidgets('M2: Edit > Undo takes back the last change on the page', (t) async {
      await withSession(t, 'shellundo', (s) async {
        final id = await putNote(s, 'undo me');
        expect(s.nb.current!.page.node(id), isNotNull);
        await _top(s, 'Edit');
        expect(_on(t, 'canvas.undo'), isTrue);
        await s.tapKey('menu-canvas.undo', settle: 600);
        expect(s.nb.current!.page.node(id), isNull);
      });
    });

    testWidgets('M3: View > Theme > Precision and back to Light', (t) async {
      await withSession(t, 'shelltheme', (s) async {
        expect(_brightness(t), Brightness.light, reason: 'a fresh profile starts in Light');
        for (final (id, brightness) in [('dark', Brightness.dark), ('light', Brightness.light)]) {
          await _top(s, 'View');
          await s.tapKey('menu-sub-Theme', settle: 400);
          await s.tapKey('menu-app.theme.$id', settle: 800);
          expect(_brightness(t), brightness);
        }
      });
    });

    testWidgets('M4: the panel follows no box, one box, no box', (t) async {
      await withSession(t, 'shellpanel', (s) async {
        final id = await putNote(s, 'panel');
        final c = s.nb.current!;
        c.setEditing(id, false);
        c.select(null);
        await s.pump(200);
        // A new box opens in its editor; the panel follows the box being edited.
        expect(find.byKey(const ValueKey('panel-page-title')), findsOneWidget);
        c.select(id);
        await s.pump(200);
        expect(find.byKey(const ValueKey('panel-box-type')), findsOneWidget);
        c.setEditing(id, false);
        c.select(null);
        await s.pump(200);
        expect(find.byKey(const ValueKey('panel-page-title')), findsOneWidget);
      });
    });

    testWidgets('M5: a change saved from the window is there after a restart, and the menus work', (t) async {
      await withSession(t, 'shellreopen', (s) async {
        final id = await putNote(s, 'kept');
        await s.flush();
        await s.restart();
        expect(s.nb.current!.page.node(id), isNotNull);
        await _top(s, 'File');
        expect(_on(t, 'app.page.new'), isTrue);
      });
    });

    testWidgets('M6: a read-only page (its binder file damaged) keeps zoom, find and File on and edits off', (t) async {
      late Directory folder;
      await withSession(
        t,
        'shellreadonly',
        (s) async {
          final binder = s.nb.binders.single;
          final inB = binder.tree.roots.first.id;
          final file = File('${folder.path}${Platform.pathSeparator}$binderFileName');
          file.writeAsStringSync(file.readAsStringSync().replaceFirst('{', ''));
          await s.until(() => binder.status == BinderStatus.unreadable, what: 'unreadable');
          await t.tap(find.byKey(ValueKey('page-row-$inB')));
          await s.pump(600);
          // The notebook's own read-only path: the banner and PageCanvas.readOnly show.
          expect(find.byKey(const ValueKey('read-only-banner')), findsOneWidget);
          expect(t.widget<PageCanvas>(find.byType(PageCanvas)).readOnly, isTrue);
          await _top(s, 'Edit');
          expect(_on(t, 'canvas.delete'), isFalse);
          expect(_on(t, 'canvas.undo'), isFalse);
          expect(_on(t, 'canvas.paste'), isFalse);
          expect(_on(t, 'canvas.find'), isTrue);
          await s.key(LogicalKeyboardKey.escape);
          await _top(s, 'View');
          expect(_on(t, 'canvas.zoomIn'), isTrue);
          await s.key(LogicalKeyboardKey.escape);
          await _top(s, 'File');
          expect(_on(t, 'app.page.new'), isTrue, reason: 'New page works on a read-only page');
          await s.key(LogicalKeyboardKey.escape);
        },
        prepare: (env) async {
          folder = env.folder('Work');
          final nb = Notebook(PageStore(env.pages), buildModules(), bindersFile: env.binders, recoveryDirectory: env.recovery);
          await nb.load();
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

    testWidgets('M7: Edit opened by pointer while editing, Escape, then typing lands in the note', (t) async {
      await withSession(t, 'shelltyping', (s) async {
        final id = await putNote(s, 'abc');
        final editor = await editNote(s, id);
        final before = editor.selection;
        expect(before, isNotNull);
        final offset = before.end.offset as int;
        await _top(s, 'Edit');
        expect(s.nb.current!.editingId, id, reason: 'the bar took no focus');
        await s.key(LogicalKeyboardKey.escape);
        expect(s.nb.current!.editingId, id);
        expect(editorState(t).selection, before, reason: 'the caret is where it was');
        // Typed at that caret, in the editor that still has the focus. (The
        // editor takes characters from the text input, which a key event in a
        // test does not drive, so the text goes in through its own transaction.)
        final node = editor.getNodeAtPath(before.end.path);
        await insertTextAt(editor, node, offset, 'xyz');
        await s.pump(500);
        final text = "${'abc'.substring(0, offset)}xyz${'abc'.substring(offset)}";
        expect(snapshotOf(s, id), contains(text));

      });
    });
  });
}
