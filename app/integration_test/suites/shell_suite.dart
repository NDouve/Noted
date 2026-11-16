// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:noted/main.dart' show buildModules;
import 'package:noted/src/notebook.dart';
import 'package:noted_canvas/noted_canvas.dart'
    show CanvasCommands, CanvasController, ContextMenuStyle, PageCanvas;
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
          await s.tapKey('menu-sub-Appearance', settle: 400);
          await s.tapKey('menu-app.theme.$id', settle: 800);
          expect(_brightness(t), brightness);
        }
      });
    });

    testWidgets('M4: the panel follows no box, one box, no box', (t) async {
      await withSession(t, 'shellpanel', (s) async {
        final id = await putNote(s, 'panel');
        final c = s.nb.current!;
        // A new box opens in its editor, and the panel follows the box being edited.
        // This stands in for focus leaving the editor, which ends editing for a user.
        c.setEditing(id, false);
        c.select(null);
        await s.pump(200);
        expect(find.byKey(const ValueKey('panel-page-title')), findsOneWidget);
        c.select(id);
        await s.pump(200);
        expect(find.byKey(const ValueKey('panel-box-type')), findsOneWidget);
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

    testWidgets('C1: right-click a note, Bring to front, then Undo', (t) async {
      await withSession(t, 'contextfront', (s) async {
        final a = await putNote(s, 'first', x: 100, y: 100);
        final b = await putNote(s, 'second', x: 100, y: 124);
        final c = s.nb.current!;
        c.select(null);
        await s.pump(200);
        expect(_order(c), [a, b]);
        // Above the second note's grip, over the first note alone.
        await _rightClick(s, toScreen(t, const Offset(300, 103)));
        expect(find.byKey(const ValueKey('context-menu')), findsOneWidget);
        expect(c.selectedId, isNull, reason: 'opening a menu selects nothing');
        await s.tapKey('context-${CanvasCommands.bringToFront}', settle: 600);
        expect(c.selectedId, a, reason: 'choosing the entry selected the box');
        expect(_order(c), [b, a]);
        await _top(s, 'Edit');
        await s.tapKey('menu-canvas.undo', settle: 600);
        expect(_order(c), [a, b]);
      });
    });

    testWidgets('C2: right-click empty canvas, Select and type, click, type', (t) async {
      await withSession(t, 'contextnew', (s) async {
        final c = s.nb.current!;
        final before = c.page.nodes.length;
        await _rightClick(s, toScreen(t, const Offset(600, 300)));
        // Select and type makes no box; the next normal click does.
        await s.tapKey('context-canvas.select', settle: 600);
        await t.tapAt(toScreen(t, const Offset(600, 300)));
        await s.pump(600);
        expect(c.page.nodes.length, before + 1);
        final id = c.page.nodes.last.id;
        await s.until(() => c.editingId == id, what: 'the new note takes focus');
        final editor = editorState(t);
        final node = editor.getNodeAtPath(editor.selection.end.path);
        await insertTextAt(editor, node, 0, 'typed');
        await s.pump(500);
        expect(snapshotOf(s, id), contains('typed'));
      });
    });

    testWidgets('C3: Radial on, the same through the ring; the page is there after a restart', (t) async {
      await withSession(t, 'contextradial', (s) async {
        s.settings.contextMenu = ContextMenuStyle.radial;
        await s.pump(300);
        final c = s.nb.current!;
        final before = c.page.nodes.length;
        await _rightClick(s, toScreen(t, const Offset(600, 300)));
        expect(find.byKey(const ValueKey('radial-menu')), findsOneWidget);
        await s.tapKey('radial-canvas.select', settle: 600);
        await t.tapAt(toScreen(t, const Offset(600, 300)));
        await s.pump(600);
        expect(c.page.nodes.length, before + 1);
        final id = c.page.nodes.last.id;
        await s.until(() => c.editingId == id, what: 'the new note takes focus');
        final editor = editorState(t);
        final node = editor.getNodeAtPath(editor.selection.end.path);
        await insertTextAt(editor, node, 0, 'ringed');
        await s.pump(500);
        await s.flush();
        await s.restart();
        expect(snapshotOf(s, id), contains('ringed'));
      });
    });
  });
}

/// A right click (the secondary mouse button) at the screen point [at].
Future<void> _rightClick(Session s, Offset at) async {
  final g = await s.tester.startGesture(at, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
  await g.up();
  await g.removePointer();
  await s.pump(300);
}

List<String> _order(CanvasController c) => [for (final n in c.page.nodes) n.id];
