// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

import '../support/harness.dart';
import '../support/note_helpers.dart';

/// Checklist steps 1-17, 200-201 (page tree, new page flow).
void pageTreeSuite() {
  group('page tree', () {
    testWidgets('step 001-002: the app starts, and a restart shows the same pages', (t) async {
      await withSession(t, 'start', (s) async {
        expect(find.byKey(const ValueKey('pages-header')), findsOneWidget);
        final id = s.nb.currentId!;
        await s.nb.rename(id, 'Persisted');
        await s.restart();
        expect(s.nb.tree[id]!.title, 'Persisted');
        expect(s.nb.currentId, isNotNull);
      });
    });

    testWidgets('step 003-004, 201: + makes a page at once (no storage dialog), title focused', (t) async {
      await withSession(t, 'newpage', (s) async {
        final before = s.rootIds.length;
        await t.tap(find.byTooltip('New page'));
        await s.until(() => s.rootIds.length == before + 1, what: 'new page');
        expect(find.byType(AlertDialog), findsNothing);
        expect(s.nb.tree[s.nb.currentId!]!.title, 'Untitled page');
        expect(s.canvasFiles(s.env.pages), hasLength(before + 1));
        expect(find.text('Untitled page'), findsWidgets);
        final title = t.widget<TextField>(find.byKey(const ValueKey('page-title-field')));
        expect(title.focusNode!.hasFocus, isTrue);
      });
    });

    testWidgets('step 005: Rename from the menu changes the name shown in the sidebar', (t) async {
      await withSession(t, 'rename', (s) async {
        final id = s.nb.currentId!;
        await s.pageMenu(id, 'Rename');
        expect(find.text('Rename page'), findsOneWidget);
        await t.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'Renamed one');
        await t.testTextInput.receiveAction(TextInputAction.done);
        await s.pump(500);
        expect(s.nb.tree[id]!.title, 'Renamed one');
        expect(find.text('Renamed one'), findsWidgets);
      });
    });

    testWidgets('step 006-007: New subpage makes a divider; the chevron collapses and expands', (t) async {
      await withSession(t, 'subpage', (s) async {
        final a = s.nb.currentId!;
        await s.nb.rename(a, 'Parent');
        await s.pump();
        await s.pageMenu(a, 'New subpage');
        await s.until(() => s.kids(a).length == 1, what: 'subpage');
        final sub = s.kids(a).single;
        expect(s.nb.tree.isDivider(a), isTrue);
        expect(s.hasPageFile(s.env.pages, sub), isTrue);
        expect(find.byTooltip('Collapse'), findsOneWidget);
        expect(s.row(sub), findsOneWidget);
        await t.tap(find.byTooltip('Collapse'));
        await s.pump(400);
        expect(s.row(sub), findsNothing);
        await t.tap(find.byTooltip('Expand'));
        await s.pump(400);
        expect(s.row(sub), findsOneWidget);
      });
    });

    testWidgets('step 008-012: drag a page onto middle, top edge, bottom edge, the empty area, and itself', (t) async {
      await withSession(t, 'drag', (s) async {
        final a = s.nb.currentId!;
        await s.nb.rename(a, 'Alpha');
        final b = await s.newPage('Beta');
        final c = await s.newPage('Gamma');
        final d = await s.newPage('Delta');
        await s.pump(300);
        expect(s.rootIds, [a, b, c, d]);

        Offset at(String id, double f) {
          final r = t.getRect(s.row(id));
          return Offset(r.left + 80, r.top + r.height * f);
        }

        Future<void> dragTo(String from, Offset target) async {
          final start = t.getTopLeft(s.row(from)) + const Offset(60, 18);
          final g = await t.startGesture(start);
          await t.pump(kLongPressTimeout + const Duration(milliseconds: 150));
          await g.moveTo(start + const Offset(0, 4));
          await t.pump(const Duration(milliseconds: 50));
          await g.moveTo(target);
          await t.pump(const Duration(milliseconds: 50));
          await g.moveTo(target + const Offset(0, 0.5));
          await t.pump(const Duration(milliseconds: 50));
          await g.up();
          await s.pump(500);
        }

        // 008: middle of a row: last subpage.
        await dragTo(d, at(a, 0.5));
        expect(s.kids(a), [d]);
        expect(s.rootIds, [a, b, c]);
        // 009: top edge: just above.
        await dragTo(c, at(a, 0.08));
        expect(s.rootIds, [c, a, b]);
        // 010: bottom edge: just below.
        await dragTo(c, at(b, 0.92));
        expect(s.rootIds, [a, b, c]);
        // 011: empty area: end of the top level.
        await dragTo(d, const Offset(100, 800));
        expect(s.rootIds, [a, b, c, d]);
        expect(s.nb.tree.isDivider(a), isFalse);
        // 012: onto its own subpage: nothing changes.
        await dragTo(b, at(a, 0.5));
        expect(s.kids(a), [b]);
        await dragTo(a, at(b, 0.5));
        expect(s.kids(a), [b]);
        expect(s.rootIds, [a, c, d]);
        await s.flush();
        final disk = await PageStore(s.env.pages).scan();
        final tree = PageTree.build(disk.whereType<ReadablePage>().map((e) => e.meta));
        expect(tree.parentIdOf(b), a);
      });
    });

    testWidgets('step 013-015: Move up/down, Indent and Outdent from the menu', (t) async {
      await withSession(t, 'menu', (s) async {
        final a = s.nb.currentId!;
        await s.nb.rename(a, 'Alpha');
        final b = await s.newPage('Beta');
        final c = await s.newPage('Gamma');
        await s.pump(300);
        await s.pageMenu(b, 'Move up');
        expect(s.rootIds, [b, a, c]);
        await s.pageMenu(b, 'Move down');
        expect(s.rootIds, [a, b, c]);
        await s.pageMenu(b, 'Indent');
        expect(s.kids(a), [b]);
        expect(s.rootIds, [a, c]);
        await s.pageMenu(b, 'Outdent');
        expect(s.rootIds, [a, b, c]);
        await s.flush();
      });
    });

    testWidgets('step 016-017: Delete asks first, shows Undo, and Undo brings back pages with content', (t) async {
      await withSession(t, 'delete', (s) async {
        t.view.physicalSize = const Size(1400, 1400);
        final a = s.nb.currentId!;
        await s.nb.rename(a, 'Keep');
        final b = await s.newPage('Doomed');
        final b1 = await s.newPage('Doomed child', parentId: b);
        await s.nb.open(b1);
        await s.pump(300);
        await putNote(s, 'precious');
        await s.flush();
        final before = await readCanvas(s.env.pages, b1);
        await s.pageMenu(b, 'Delete');
        expect(find.text('Delete page?'), findsOneWidget);
        await t.tap(find.widgetWithText(OutlinedButton, 'Delete'));
        await s.pump(800);
        expect(s.rootIds, [a]);
        expect(s.hasPageFile(s.env.pages, b), isFalse);
        expect(s.hasPageFile(s.env.pages, b1), isFalse);
        expect(find.text('Undo'), findsOneWidget);
        await t.tap(find.text('Undo'));
        await s.pump(800);
        expect(s.rootIds, [a, b]);
        expect(s.kids(b), [b1]);
        expect(await readCanvas(s.env.pages, b1), before);
        expect(s.nb.currentId, b1);
        await s.pump(300);
        final box = s.nb.current!.page.nodes.whereType<BoxRecord>().single;
        expect(box.snapshotText, 'precious');
      });
    });

    testWidgets('step 200: Ctrl+N then typing goes into the new page title', (t) async {
      await withSession(t, 'ctrln', (s) async {
        final before = s.rootIds.length;
        await s.ctrl(LogicalKeyboardKey.keyN);
        await s.until(() => s.rootIds.length == before + 1, what: 'Ctrl+N page');
        final field = find.byKey(const ValueKey('page-title-field'));
        expect(t.widget<TextField>(field).focusNode!.hasFocus, isTrue);
        await t.enterText(field, 'Typed straight away');
        await s.pump(400);
        await t.testTextInput.receiveAction(TextInputAction.done);
        await s.pump(400);
        expect(s.nb.tree[s.nb.currentId!]!.title, 'Typed straight away');
        // Also works while a note editor has focus.
        await clickNewNote(s);
        expect(s.nb.current!.editingId, isNotNull);
        final n = s.rootIds.length;
        await s.ctrl(LogicalKeyboardKey.keyN);
        await s.until(() => s.rootIds.length == n + 1, what: 'Ctrl+N from a note');
      });
    });
  });
}
