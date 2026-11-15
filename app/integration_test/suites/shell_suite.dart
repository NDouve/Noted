// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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

    testWidgets('M6: a read-only page keeps zoom and find on and edits off', (t) async {
      await withSession(t, 'shellreadonly', (s) async {
        final id = await putNote(s, 'ro');
        s.nb.current!.select(id);
        s.nb.current!.readOnly = true;
        await s.pump(300);
        await _top(s, 'Edit');
        expect(_on(t, 'canvas.delete'), isFalse);
        expect(_on(t, 'canvas.undo'), isFalse);
        expect(_on(t, 'canvas.find'), isTrue);
        await s.key(LogicalKeyboardKey.escape);
        await _top(s, 'View');
        expect(_on(t, 'canvas.zoomIn'), isTrue);
        await s.key(LogicalKeyboardKey.escape);
      });
    });

    testWidgets('M7: Edit opened by pointer while editing, Escape, then typing lands in the note', (t) async {
      await withSession(t, 'shelltyping', (s) async {
        final id = await putNote(s, 'abc');
        await editNote(s, id);
        await _top(s, 'Edit');
        expect(s.nb.current!.editingId, id, reason: 'the bar took no focus');
        await s.key(LogicalKeyboardKey.escape);
        expect(s.nb.current!.editingId, id);
        t.testTextInput.enterText('abcxyz');
        await s.pump(500);
        expect(snapshotOf(s, id), contains('xyz'));
      });
    });
  });
}
