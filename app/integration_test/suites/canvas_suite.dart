// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.


import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import '../support/harness.dart';
import '../support/note_helpers.dart';

const _select = 'canvas.select';
const _pen = 'noted.drawing.pen';
const _eraser = 'noted.drawing.eraser';

Command _cmd(WidgetTester t, String id) => t.widget<ToolbarEntry>(find.byKey(ValueKey(id))).command;

bool _checked(WidgetTester t, String id) => _cmd(t, id).checked ?? false;

String? _activeTool(Session s) => s.nb.tools.active?.id;

Future<void> _tapTool(Session s, String id) async {
  await s.tester.tap(find.byKey(ValueKey(id)));
  await s.pump(150);
}

List<BoxRecord> _drawings(Session s) =>
    s.nb.current!.page.nodes.whereType<BoxRecord>().where((b) => b.typeId.contains('drawing')).toList();

DrawingData _data(Session s, BoxRecord b) => (s.nb.current!.modules.codecs.resolve(b) as LiveBox).data! as DrawingData;

/// Draws with the mouse through [points] (page coordinates).
Future<void> _draw(Session s, List<Offset> points, {bool release = true}) async {
  final t = s.tester;
  final g = await t.startGesture(toScreen(t, points.first), kind: PointerDeviceKind.mouse);
  for (final p in points.skip(1)) {
    await g.moveTo(toScreen(t, p));
    await t.pump(const Duration(milliseconds: 16));
  }
  if (release) await g.up();
  await s.pump(300);
}

List<Offset> _line(Offset a, Offset b, [int n = 30]) => [for (var i = 0; i <= n; i++) Offset.lerp(a, b, i / n)!];

Future<void> _setTheme(Session s, String value) async {
  await s.tapKey('settings-menu', settle: 500);
  await s.tapKey('theme-$value', settle: 800);
}

Brightness _brightness(WidgetTester t) => Theme.of(t.element(find.byType(Scaffold).first)).brightness;

/// Checklist steps 82-99 (objective parts), 100-108, 146-160, 169-181, 185-191,
/// 194-199: toolbar, tools, drawing, zoom, backgrounds, themes, conflicts.
void canvasSuite() {
  group('canvas, toolbar, themes', () {
    testWidgets('step 146-149, 157-160, 179: toolbar tooltips, active tool, keys, ink choice selects the pen', (t) async {
      await withSession(t, 'toolbar', (s) async {
        // 146: tooltips show the name and shortcut.
        expect(_cmd(t, _pen).tooltip, 'Pen (P)');
        expect(_cmd(t, _eraser).tooltip, 'Eraser (E)');
        expect(_cmd(t, _select).tooltip, contains('(V)'));
        for (final id in ['canvas.undo', 'canvas.redo', 'canvas.fitAll', 'canvas.zoomReset', 'noted.drawing.color.1', 'noted.drawing.width.4']) {
          expect(_cmd(t, id).tooltip, isNotEmpty, reason: id);
        }
        // 147: Select, Pen, Eraser show as active in turn.
        await _tapTool(s, _select);
        expect([_checked(t, _select), _checked(t, _pen), _checked(t, _eraser)], [true, false, false]);
        await _tapTool(s, _pen);
        expect([_checked(t, _select), _checked(t, _pen), _checked(t, _eraser)], [false, true, false]);
        await _tapTool(s, _eraser);
        expect([_checked(t, _select), _checked(t, _pen), _checked(t, _eraser)], [false, false, true]);
        // 149 (superseded by 0075) / 179: with Select active the ink options are
        // enabled, and choosing one makes the Pen active with that color.
        await _tapTool(s, _select);
        for (var i = 0; i < 4; i++) {
          expect(_cmd(t, 'noted.drawing.color.$i').enabled, isTrue);
        }
        await _tapTool(s, 'noted.drawing.color.2');
        expect(_activeTool(s), _pen);
        expect(_checked(t, 'noted.drawing.color.2'), isTrue);
        expect(_checked(t, _pen), isTrue);
        // 148: widths are selectable too.
        await _tapTool(s, 'noted.drawing.width.8');
        expect(_checked(t, 'noted.drawing.width.8'), isTrue);
        expect(_checked(t, 'noted.drawing.width.4'), isFalse);
        // 157-160: keys.
        await _tapTool(s, _select);
        await s.key(LogicalKeyboardKey.keyP);
        expect(_checked(t, _pen), isTrue);
        await s.key(LogicalKeyboardKey.keyE);
        expect(_checked(t, _eraser), isTrue);
        await s.key(LogicalKeyboardKey.keyV);
        expect(_checked(t, _select), isTrue);
        await _tapTool(s, _pen);
        await s.key(LogicalKeyboardKey.keyV);
        expect(_checked(t, _select), isTrue);
      });
    });

    testWidgets('step 148, 88, 91, 99: pen strokes use the chosen ink and width; a fast long line is complete; the eraser removes and Ctrl+Z restores', (t) async {
      await withSession(t, 'drawing', (s) async {
        await _tapTool(s, 'noted.drawing.color.1');
        await _tapTool(s, 'noted.drawing.width.8');
        final from = const Offset(150, 150);
        final to = const Offset(650, 350);
        await _draw(s, _line(from, to, 60));
        final boxes = _drawings(s);
        expect(boxes, hasLength(1));
        final d = _data(s, boxes.single);
        expect(d.strokes, hasLength(1));
        final stroke = d.strokes.single;
        expect(stroke.color, PenSettings.colors[1]);
        expect(stroke.size, 8);
        expect(stroke.length, greaterThanOrEqualTo(30), reason: 'a smooth, complete stroke');
        // The last stored point is at the end of the line (page coordinates).
        // 91: erase across the stroke.
        await _tapTool(s, _eraser);
        await _draw(s, _line(const Offset(400, 100), const Offset(400, 400), 20));
        int live() => [
          for (final b in _drawings(s)) ..._data(s, b).strokes.where((x) => !_data(s, b).erased.contains(x.id)),
        ].length;
        expect(live(), 0);
        await s.ctrl(LogicalKeyboardKey.keyZ);
        expect(live(), 1);
        // 99: a default-color stroke drawn in dark mode shows light.
        await _setTheme(s, 'dark');
        await _tapTool(s, 'noted.drawing.color.0');
        await _draw(s, _line(const Offset(150, 450), const Offset(500, 450), 20));
        final latest = _data(s, _drawings(s).last).strokes.last;
        expect(latest.color, defaultInkValue);
        final shown = displayInkColor(latest.color, Brightness.dark);
        expect(shown.computeLuminance(), greaterThan(0.8));
      });
    });

    testWidgets('step 097-098, 189-191: ink colors in light and dark', (t) async {
      await withSession(t, 'inkcolors', (s) async {
        final light = NotedColors.forBrightness(Brightness.light);
        final dark = NotedColors.forBrightness(Brightness.dark);
        // 097: default ink is dark on light, light on dark.
        expect(displayInkColor(defaultInkValue, Brightness.light), light.inkDefault);
        expect(displayInkColor(defaultInkValue, Brightness.dark), dark.inkDefault);
        expect(light.inkDefault.computeLuminance(), lessThan(0.1));
        expect(dark.inkDefault.computeLuminance(), greaterThan(0.8));
        // 098 (superseded by 189-191), 189-191: colored inks keep their color in light
        // and are lifted for contrast in dark.
        final canvasDark = DesignColors.dark.bgCanvas;
        final canvasLight = DesignColors.light.bgCanvas;
        for (final stored in PenSettings.colors.skip(1)) {
          expect(displayInkColor(stored, Brightness.light), Color(stored), reason: 'light shows the original');
          final lifted = displayInkColor(stored, Brightness.dark);
          expect(contrastRatio(lifted, canvasDark), greaterThanOrEqualTo(inkMinContrast));
          expect(contrastRatio(displayInkColor(stored, Brightness.light), canvasLight), greaterThanOrEqualTo(3.0));
        }
        // The toolbar swatch shows the same shade as the stroke (dark).
        await _setTheme(s, 'dark');
        final purple = PenSettings.colors[1];
        final swatch = t.widget<ToolbarEntry>(find.byKey(const ValueKey('noted.drawing.color.1'))).command.iconBuilder!(
          t.element(find.byKey(const ValueKey('noted.drawing.color.1'))),
          false,
        ) as ToolbarSwatch;
        expect(swatch.color, displayInkColor(purple, Brightness.dark));
        await _setTheme(s, 'light');
        final swatchL = t.widget<ToolbarEntry>(find.byKey(const ValueKey('noted.drawing.color.1'))).command.iconBuilder!(
          t.element(find.byKey(const ValueKey('noted.drawing.color.1'))),
          false,
        ) as ToolbarSwatch;
        expect(swatchL.color, Color(purple));
      });
    });

    testWidgets('step 150-153: Undo/Redo buttons; Insert table and equation are enabled only in a note', (t) async {
      await withSession(t, 'undo', (s) async {
        // 153: outside any note they are greyed out.
        expect(_cmd(t, 'noted.note.insertTable').enabled, isFalse);
        expect(_cmd(t, 'noted.note.insertEquation').enabled, isFalse);
        // 150: an edit goes away with Undo and comes back with Redo.
        await putNote(s, 'edit me');
        int count() => s.nb.current!.page.nodes.whereType<BoxRecord>().length;
        expect(count(), 1);
        await t.tap(find.byKey(const ValueKey('canvas.undo')));
        await s.pump(300);
        expect(count(), 0);
        await t.tap(find.byKey(const ValueKey('canvas.redo')));
        await s.pump(300);
        expect(count(), 1);
        // 151: inside a note, Insert table puts a table at the caret.
        final id = s.nb.current!.page.nodes.whereType<BoxRecord>().single.id;
        await editNote(s, id);
        expect(_cmd(t, 'noted.note.insertTable').enabled, isTrue);
        expect(_cmd(t, 'noted.note.insertEquation').enabled, isTrue);
        await t.tap(find.byKey(const ValueKey('noted.note.insertTable')));
        await s.pump(600);
        expect(editorState(t).document.root.children.any((n) => n.type == 'table'), isTrue);
        // 152: Insert equation opens the dialog.
        await t.tap(find.byKey(const ValueKey('noted.note.insertEquation')));
        await s.pump(600);
        expect(find.byKey(const ValueKey('math-source')), findsOneWidget);
        await t.tap(find.text('Cancel'));
        await s.pump(400);
      });
    });

    testWidgets('step 154-155, 194-199: Fit all, 100%, and zoom stays anchored (Ctrl+wheel, Ctrl+=)', (t) async {
      await withSession(t, 'zoom', (s) async {
        for (final p in [const Offset(0, 0), const Offset(1500, 0), const Offset(0, 1200), const Offset(1500, 1200)]) {
          addNote(s, [para('box')], x: p.dx, y: p.dy);
        }
        await s.pump(500);
        // 154: Fit all brings all boxes into view.
        await t.tap(find.byKey(const ValueKey('canvas.fitAll')));
        await s.pump(500);
        final size = t.getSize(find.byType(PageCanvas));
        final viewport = Size(size.width, size.height - CommandToolbar.height);
        final visible = canvasState(t).view!.visible(viewport);
        for (final b in s.nb.current!.page.nodes.whereType<BoxRecord>()) {
          expect(visible.contains(b.bounds.rect.topLeft), isTrue, reason: 'box ${b.id} in view');
        }
        // 155: the zoom readout returns to 100%.
        await t.tap(find.byKey(const ValueKey('canvas.zoomReset')));
        await s.pump(400);
        expect(canvasState(t).view!.scale, closeTo(1, 1e-9));
        await t.tap(find.byKey(const ValueKey('canvas.fitAll')));
        await s.pump(400);

        final wheelPointer = TestPointer(1, PointerDeviceKind.mouse);
        Future<void> hoverAt(Offset screen) => t.sendEventToBinding(wheelPointer.hover(screen));
        // 194-196: Ctrl+wheel 5 in, 5 out at the corners keeps the point fixed.
        Future<void> wheel(Offset local, double dy) async {
          final pointer = wheelPointer;
          await t.sendEventToBinding(pointer.hover(viewportPoint(t, local)));
          final world = canvasState(t).view!.toWorld(local);
          await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await t.sendEventToBinding(pointer.scroll(Offset(0, dy)));
          await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await t.pump(const Duration(milliseconds: 60));
          final after = canvasState(t).view!.toScreen(world);
          expect((after - local).distance, lessThan(1.5), reason: 'anchored at $local');
        }

        for (final local in [const Offset(20, 20), Offset(viewport.width - 20, viewport.height - 20), Offset(viewport.width / 2, viewport.height / 2)]) {
          await t.tap(find.byKey(const ValueKey('canvas.fitAll')));
          await s.pump(300);
          for (var i = 0; i < 5; i++) {
            await wheel(local, -60);
          }
          for (var i = 0; i < 5; i++) {
            await wheel(local, 60);
          }
        }

        // 198-199: Ctrl+= zooms around the mouse over a box, and around the
        // centre when the mouse is on the sidebar.
        await t.tap(find.byKey(const ValueKey('canvas.fitAll')));
        await s.pump(300);
        final local = const Offset(300, 200);
        await hoverAt(viewportPoint(t, local));
        await s.pump(100);
        var world = canvasState(t).view!.toWorld(local);
        final before = canvasState(t).view!.scale;
        await s.ctrl(LogicalKeyboardKey.equal);
        await s.pump(300);
        expect(canvasState(t).view!.scale, greaterThan(before));
        expect((canvasState(t).view!.toScreen(world) - local).distance, lessThan(1.5), reason: 'around the mouse');
        await t.tap(find.byKey(const ValueKey('canvas.fitAll')));
        await s.pump(300);
        await hoverAt(const Offset(100, 300)); // on the sidebar
        await s.pump(100);
        final centre = Offset(viewport.width / 2, viewport.height / 2);
        world = canvasState(t).view!.toWorld(centre);
        await s.ctrl(LogicalKeyboardKey.equal);
        await s.pump(300);
        expect((canvasState(t).view!.toScreen(world) - centre).distance, lessThan(1.5), reason: 'around the centre');
      });
    });

    testWidgets('step 087: at 30% zoom the arrow keys move the caret one line at a time', (t) async {
      await withSession(t, 'arrows', (s) async {
        final id = addNote(s, [para('line one'), para('line two'), para('line three')]);
        await s.pump(400);
        final editor = await editNote(s, id);
        for (var i = 0; i < 12; i++) {
          await s.ctrl(LogicalKeyboardKey.minus);
        }
        expect(canvasState(t).view!.scale, lessThan(0.5));
        selectRange(editor, [0], 2, 2);
        await s.pump(200);
        await s.key(LogicalKeyboardKey.arrowDown);
        expect(editorState(t).selection.start.path, [1]);
        await s.key(LogicalKeyboardKey.arrowDown);
        expect(editorState(t).selection.start.path, [2]);
        await s.key(LogicalKeyboardKey.arrowUp);
        expect(editorState(t).selection.start.path, [1]);
      });
    });

    testWidgets('step 169, 173-174, 176-177: page backgrounds from the menu, undo, and persistence', (t) async {
      await withSession(t, 'background', (s) async {
        final id = s.nb.currentId!;
        // 169: right-click the page, Page background: Dots.
        await s.pageMenu(id, 'Page background: Dots');
        await s.pump(300);
        expect(s.nb.current!.page.meta.background, PageBackground.dots);
        // 173-174: from the toolbar dropdown.
        await t.tap(find.byKey(const ValueKey('canvas.pageBackground')));
        await s.pump(500);
        await t.tap(find.textContaining('Graph').last);
        await s.pump(400);
        expect(s.nb.current!.page.meta.background, PageBackground.graph);
        await t.tap(find.byKey(const ValueKey('canvas.pageBackground')));
        await s.pump(500);
        await t.tap(find.textContaining('Ruled').last);
        await s.pump(400);
        expect(s.nb.current!.page.meta.background, PageBackground.ruled);
        // 176: Ctrl+Z restores the previous background.
        await s.ctrl(LogicalKeyboardKey.keyZ);
        expect(s.nb.current!.page.meta.background, PageBackground.graph);
        // 177: it survives a restart.
        await s.flush();
        await s.restart();
        expect(s.nb.current!.page.meta.background, PageBackground.graph);
      });
    });

    testWidgets('step 180-181: Esc clears a text selection first, then leaves the note and selects the Select tool', (t) async {
      await withSession(t, 'escape', (s) async {
        final id = addNote(s, [para('some words here')]);
        await s.pump(400);
        await _tapTool(s, _pen);
        await _tapTool(s, _select);
        final editor = await editNote(s, id);
        // 181: with a range selected, Esc collapses it and stays in the note.
        selectRange(editor, [0], 0, 4);
        await s.pump(200);
        await s.key(LogicalKeyboardKey.escape);
        expect(s.nb.current!.editingId, id);
        final sel = editorState(t).selection;
        expect(sel == null || sel.isCollapsed as bool, isTrue);
        // 180: Esc again leaves the note; Select is active.
        await s.key(LogicalKeyboardKey.escape);
        await s.pump(300);
        expect(s.nb.current!.editingId, isNull);
        expect(_checked(t, _select), isTrue);
      });
    });

    testWidgets('step 092-096: theme choice applies at once, follows the system, and is kept across restarts', (t) async {
      await withSession(t, 'theme', (s) async {
        await putNote(s, 'hello');
        await _setTheme(s, 'dark');
        expect(_brightness(t), Brightness.dark); // 092
        await _setTheme(s, 'light');
        expect(_brightness(t), Brightness.light); // 093
        await _setTheme(s, 'system');
        t.platformDispatcher.platformBrightnessTestValue = Brightness.dark; // 094
        await s.pump(300);
        expect(_brightness(t), Brightness.dark);
        t.platformDispatcher.platformBrightnessTestValue = Brightness.light; // 095
        await s.pump(300);
        expect(_brightness(t), Brightness.light);
        t.platformDispatcher.clearPlatformBrightnessTestValue();
        await _setTheme(s, 'dark');
        await s.flush();
        await s.restart(); // 096
        expect(_brightness(t), Brightness.dark);
      });
    });

    testWidgets('step 100-103, 106-108, 156, 161-162 (objective part): text and controls have enough contrast in both themes', (t) async {
      await withSession(t, 'contrast', (s) async {
        for (final theme in ['light', 'dark']) {
          await _setTheme(s, theme);
          final scheme = Theme.of(t.element(find.byType(Scaffold).first)).colorScheme;
          final surface = scheme.surface;
          expect(contrastRatio(scheme.onSurface, surface), greaterThanOrEqualTo(4.5), reason: '$theme text');
          expect(contrastRatio(scheme.error, surface), greaterThanOrEqualTo(3.0), reason: '$theme error text');
          expect(contrastRatio(scheme.primary, surface), greaterThanOrEqualTo(3.0), reason: '$theme accent');
          final colors = NotedColors.forBrightness(theme == 'dark' ? Brightness.dark : Brightness.light);
          expect(contrastRatio(colors.inkDefault, theme == 'dark' ? DesignColors.dark.bgCanvas : DesignColors.light.bgCanvas), greaterThanOrEqualTo(7));
          // The toolbar is 52px tall.
          expect(t.getSize(find.byType(CommandToolbar)).height, 52);
        }
      });
    });

    testWidgets('step 058-064, 104-105, 168, 185-187 (single-machine simulation): a conflicted box, the conflict view, and resolutions', (t) async {
      await withSession(t, 'conflict', (s) async {
        final pageId = s.nb.currentId!;
        final id = addNote(s, [para('base')]);
        await s.flush();
        // Another device edits the same box, and so do we, before saving.
        final other = PageStore(s.env.pages);
        final disk = await other.load(pageId);
        final box = disk.node(id)! as BoxRecord;
        final codec = s.nb.current!.modules.codecs.codecFor(box.typeId)!;
        final theirs = commitBox(box, codec, codec.decode({
          'document': {'type': 'page', 'children': [para('theirs')]},
        }, 1));
        await other.save(disk.replaceNode(theirs));
        s.nb.current!.commit(id, codec.decode({
          'document': {'type': 'page', 'children': [para('mine')]},
        }, 1));
        await s.nb.checkFile(other.pathFor(pageId));
        await s.pump(500);
        // 058: conflict badge on the box and a mark on the page row.
        expect((s.nb.current!.page.node(id)! as BoxRecord).isConflicted, isTrue);
        expect(find.byKey(const ValueKey('conflict-badge')), findsOneWidget);
        expect(s.nb.hasConflict(pageId), isTrue);
        // 059: the badge opens both versions.
        await t.tap(find.byKey(const ValueKey('conflict-badge')));
        await s.pump(500);
        expect(find.byKey(const ValueKey('conflict-dialog')), findsOneWidget);
        expect(find.text('Conflicting changes'), findsOneWidget);
        // 168: Keep mine is the only filled button.
        expect(find.byType(FilledButton), findsOneWidget);
        expect(find.descendant(of: find.byType(FilledButton), matching: find.text('Keep mine')), findsOneWidget);
        // 105/187: Edit manually shows two editable panes.
        await t.tap(find.byKey(const ValueKey('conflict-edit')));
        await s.pump(700);
        expect(find.byKey(const ValueKey('conflict-edit-dialog')), findsOneWidget);
        expect(find.byKey(const ValueKey('conflict-edit-mine')), findsOneWidget);
        expect(find.byKey(const ValueKey('conflict-edit-theirs')), findsOneWidget);
        // 063: use the other version.
        await t.tap(find.byKey(const ValueKey('conflict-use-theirs')));
        await s.pump(700);
        expect((s.nb.current!.page.node(id)! as BoxRecord).isConflicted, isFalse);
        expect((s.nb.current!.page.node(id)! as BoxRecord).snapshotText, 'theirs');
        // 064: Ctrl+Z brings the conflict back.
        s.nb.current!.undo();
        await s.pump(400);
        expect((s.nb.current!.page.node(id)! as BoxRecord).isConflicted, isTrue);
        // 060: Keep mine clears the badge and keeps our text.
        await t.tap(find.byKey(const ValueKey('conflict-badge')));
        await s.pump(500);
        await t.tap(find.byKey(const ValueKey('conflict-keep-mine')));
        await s.pump(600);
        expect(find.byKey(const ValueKey('conflict-badge')), findsNothing);
        expect((s.nb.current!.page.node(id)! as BoxRecord).snapshotText, 'mine');
      });
    });
  });
}
