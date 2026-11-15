// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The canvas's context menus (conventional presentation): targets, the
// revalidation before any change, keys, notes being edited, touch.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'context_menu_world.dart';

void main() {
  late World w;
  late WidgetTester tt;

  Future<void> setUpWorld(WidgetTester t, {
    List<CanvasNode>? nodes,
    bool pen = false,
    bool withStore = false,
    Set<String> disallowed = const {},
    bool readOnly = false,
    ContextMenuStyle style = ContextMenuStyle.list,
    Size size = const Size(1200, 800),
  }) async {
    tt = t;
    w = World(t)..size = size;
    await w.pump(
      nodes: nodes,
      pen: pen,
      withStore: withStore,
      disallowed: disallowed,
      readOnly: readOnly,
      style: style,
    );
  }

  group('targets', () {
    testWidgets('a right click on empty canvas shows the canvas entries and selects nothing', (t) async {
      await setUpWorld(t, withStore: true);
      await w.rightClick(w.at(const Offset(900, 600)));
      expect(w.menu, findsOneWidget);
      expect(w.entries(), [
        'canvas.context.newNote',
        'canvas.context.paste',
        'noted.image.insert',
        'noted.file.insert',
      ]);
      expect(w.enabled('canvas.context.newNote'), isTrue);
      expect(w.enabled('canvas.context.paste'), isTrue);
      expect(w.enabled('noted.image.insert'), isTrue);
      expect(w.c.selectedId, isNull);
      expect(find.text('Boxes here…'), findsNothing);
      // No placeholder is shown.
      expect(find.textContaining('coming later'), findsNothing);
      expect(find.text('AI box'), findsNothing);
    });

    testWidgets('a right click on a box shows the box entries and selects the box', (t) async {
      await setUpWorld(t, nodes: [tbox('a', 'test.text', ba, 'alpha')]);
      await w.rightClick(w.at(const Offset(200, 200)));
      expect(w.menu, findsOneWidget);
      expect(w.c.selectedId, 'a');
      expect(w.entries(), [
        CanvasCommands.bringToFront,
        CanvasCommands.bringForward,
        CanvasCommands.sendBackward,
        CanvasCommands.sendToBack,
        'canvas.context.boxesHere',
        CanvasCommands.delete,
      ]);
      // One box: nothing to restack, nothing to pick among.
      expect(w.enabled(CanvasCommands.bringToFront), isFalse);
      expect(w.enabled('canvas.context.boxesHere'), isFalse);
      expect(w.enabled(CanvasCommands.delete), isTrue);
      expect(find.text('Delete box'), findsOneWidget);
      // Shortcuts are shown from the commands.
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('on a box\'s grip and on a resize handle the target is the box', (t) async {
      await setUpWorld(t, nodes: [tbox('a', 'test.text', ba, 'alpha')]);
      await w.rightClick(w.at(const Offset(250, 100 - boxGripHeight / 2)));
      expect(w.entries(), contains(CanvasCommands.delete));
      expect(w.c.selectedId, 'a');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(w.open, isFalse);
      w.c.select(null);
      await t.pump();
      await w.rightClick(w.at(const Offset(100 + 300 + 3, 200)));
      expect(w.entries(), contains(CanvasCommands.delete));
      expect(w.c.selectedId, 'a');
    });

    testWidgets('overlapping boxes: the topmost is the target; Boxes here opens the list; Send to back reorders and Undo restores', (t) async {
      await setUpWorld(t);
      await w.rightClick(w.at(overlapPoint));
      expect(w.c.selectedId, 'c');
      expect(w.enabled('canvas.context.boxesHere'), isTrue);
      await w.choose('canvas.context.boxesHere');
      expect(find.byKey(const ValueKey('box-pick-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('pick-row-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('pick-row-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('pick-row-c')), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await w.rightClick(w.at(overlapPoint));
      await w.choose(CanvasCommands.sendToBack);
      expect(w.order, ['c', 'a', 'b']);
      w.c.undo();
      expect(w.order, ['a', 'b', 'c']);
    });

    testWidgets('Boxes here is off with one node at the point', (t) async {
      await setUpWorld(t);
      await w.rightClick(w.at(const Offset(120, 120)));
      expect(w.c.selectedId, 'a');
      expect(w.enabled('canvas.context.boxesHere'), isFalse);
    });

    testWidgets('no page area, no menu: a click outside the canvas area opens nothing', (t) async {
      await setUpWorld(t);
      // The toolbar is not canvas.
      await w.rightClick(const Offset(300, 10));
      expect(w.open, isFalse);
    });
  });

  group('boxes that are not plain boxes', () {
    testWidgets('a disallowed box: heading, and Delete is the only enabled box entry; Undo restores it verbatim', (t) async {
      await setUpWorld(
        t,
        nodes: [tbox('x', 'test.off', ba, 'saved'), tbox('y', 'test.text', const Bounds(700, 100, 100, 50), 'y')],
        disallowed: {'test.off'},
      );
      final before = w.c.page.node('x')! as BoxRecord;
      await w.rightClick(w.at(const Offset(200, 200)));
      expect(find.byKey(const ValueKey('context-heading')), findsOneWidget);
      for (final id in [
        CanvasCommands.bringToFront,
        CanvasCommands.bringForward,
        CanvasCommands.sendBackward,
        CanvasCommands.sendToBack,
      ]) {
        expect(w.enabled(id), isFalse, reason: id);
      }
      expect(w.enabled(CanvasCommands.delete), isTrue);
      await w.choose(CanvasCommands.delete);
      expect(w.c.page.node('x'), isNull);
      w.c.undo();
      await t.pump();
      final after = w.c.page.node('x')! as BoxRecord;
      expect(after.data, before.data);
      expect(after.snapshotText, before.snapshotText);
    });

    testWidgets('the guard cancels when the type becomes allowed or disallowed while the menu is open', (t) async {
      await setUpWorld(
        t,
        nodes: [tbox('x', 'test.off', ba, 'saved')],
        disallowed: {'test.off'},
      );
      await w.rightClick(w.at(const Offset(200, 200)));
      expect(w.open, isTrue);
      await w.rebuild(disallowed: const {});
      await t.pump();
      await t.pump();
      expect(w.open, isFalse);
      expect(w.c.page.node('x'), isNotNull);

      await w.rightClick(w.at(const Offset(200, 200)));
      expect(w.open, isTrue);
      await w.rebuild(disallowed: const {'test.off'});
      await t.pump();
      await t.pump();
      expect(w.open, isFalse);
      expect(w.c.page.node('x'), isNotNull);
    });

    testWidgets('an unsupported box and a foreign node: Delete is off, layering is on', (t) async {
      final alien = tbox('u', 'vendor.alien', ba, 'alien');
      final foreign = ForeignNode.read(
        const RawJson.trusted('{"id":"g","type":"text","x":150,"y":150,"width":300,"height":200,"text":"canvas text"}'),
        fallbackId: 'g',
      );
      await setUpWorld(t, nodes: [alien, foreign, tbox('t', 'test.text', const Bounds(700, 100, 100, 50), 't')]);
      await w.rightClick(w.at(const Offset(130, 130)));
      expect(w.c.selectedId, 'u');
      expect(w.enabled(CanvasCommands.delete), isFalse);
      expect(w.enabled(CanvasCommands.bringToFront), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await w.rightClick(w.at(const Offset(430, 330)));
      expect(w.c.selectedId, 'g');
      expect(w.enabled(CanvasCommands.delete), isFalse);
      expect(w.enabled(CanvasCommands.sendToBack), isTrue);
      // The command registry agrees with the menu.
      expect(w.state.commands[CanvasCommands.delete]!.enabled, isFalse);
    });
  });

  group('revalidation', () {
    testWidgets('a box deleted by a remote merge while the menu is open closes it and runs nothing', (t) async {
      await setUpWorld(t);
      await w.rightClick(w.at(overlapPoint));
      expect(w.open, isTrue);
      w.c.applyExternal(w.c.page.removeNode('c'));
      await t.pump();
      await t.pump();
      expect(w.open, isFalse);
      expect(w.order, ['a', 'b']);
      expect(w.c.canUndo, isFalse);
    });

    testWidgets('a registry made again, another controller and disposal each close the menu', (t) async {
      await setUpWorld(t);
      await w.rightClick(w.at(overlapPoint));
      await w.rebuild(tools: CanvasToolSelection());
      await t.pump();
      await t.pump();
      expect(w.open, isFalse);

      await w.rightClick(w.at(overlapPoint));
      expect(w.open, isTrue);
      final other = CanvasController(tpage(threeBoxes(), id: 'q'), w.modules);
      addTearDown(other.dispose);
      await w.rebuild(controller: other);
      await t.pump();
      await t.pump();
      expect(w.open, isFalse);
      expect(w.order, ['a', 'b', 'c']);
      expect([for (final n in other.page.nodes) n.id], ['a', 'b', 'c']);

      await w.rightClick(w.at(overlapPoint));
      expect(w.open, isTrue);
      await t.pumpWidget(const SizedBox());
      await t.pump();
      await t.pump();
      expect(tt.takeException(), isNull);
    });

    testWidgets('a read-only flip leaves the menu open with the edit entries off in that frame', (t) async {
      await setUpWorld(t);
      await w.rightClick(w.at(overlapPoint));
      expect(w.enabled(CanvasCommands.sendToBack), isTrue);
      await w.rebuild(readOnly: true);
      await t.pump();
      expect(w.menu, findsOneWidget);
      expect(w.enabled(CanvasCommands.sendToBack), isFalse);
      expect(w.enabled(CanvasCommands.delete), isFalse);
    });

    testWidgets('another page opening before the deferred run: the command runs on neither', (t) async {
      await setUpWorld(t);
      final other = CanvasController(tpage(threeBoxes(), id: 'q'), w.modules);
      addTearDown(other.dispose);
      await w.rightClick(w.at(overlapPoint));
      final gate = Completer<void>();
      w.state.debugBeforeContextRun = () => gate.future;
      await w.choose(CanvasCommands.sendToBack);
      await w.rebuild(controller: other);
      gate.complete();
      await t.pump();
      await t.pump();
      expect(w.order, ['a', 'b', 'c']);
      expect([for (final n in other.page.nodes) n.id], ['a', 'b', 'c']);
      expect(other.canUndo, isFalse);
    });

    testWidgets('a selection change between choosing and running cancels the command', (t) async {
      await setUpWorld(t);
      await w.rightClick(w.at(overlapPoint));
      w.state.debugBeforeContextRun = () async => w.c.select('a');
      await w.choose(CanvasCommands.sendToBack);
      await t.pump();
      expect(w.order, ['a', 'b', 'c']);
    });

    testWidgets('the point commands are disposed after the run', (t) async {
      await setUpWorld(t);
      await w.rightClick(w.at(const Offset(900, 600)));
      await w.choose('canvas.context.newNote');
      await t.pump();
      expect(w.c.page.nodes, hasLength(4));
      expect(tt.takeException(), isNull);
    });
  });

  group('keyboard', () {
    testWidgets('Shift+F10 with a selection opens the box menu inside the box; arrows, Home, End, Enter', (t) async {
      await setUpWorld(t);
      w.c.select('c');
      await t.pump();
      await w.shiftF10();
      expect(w.menu, findsOneWidget);
      final box = t.getRect(find.byKey(const ValueKey('context-menu')));
      final boxScreen = Rect.fromLTWH(w.at(const Offset(200, 200)).dx, w.at(const Offset(200, 200)).dy, 300, 200);
      expect(boxScreen.contains(box.topLeft), isTrue);
      // Focus starts on the first enabled entry: Bring to front is off (c is on
      // top), so Bring forward is off too; Send backward is first.
      expect(w.focused(), 'Send backward');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
      expect(w.focused(), 'Send to back');
      await t.sendKeyEvent(LogicalKeyboardKey.end);
      await t.pump();
      expect(w.focused(), 'Delete box');
      await t.sendKeyEvent(LogicalKeyboardKey.home);
      await t.pump();
      expect(w.focused(), 'Send backward');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pump();
      expect(w.focused(), 'Delete box');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.home);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      await t.pump();
      await t.pump();
      expect(w.open, isFalse);
      expect(w.order, ['c', 'a', 'b']);
    });

    testWidgets('the Menu key opens the canvas menu with nothing selected; Escape closes and focus returns to the canvas', (t) async {
      await setUpWorld(t);
      await t.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await t.pump();
      await t.pump();
      expect(w.menu, findsOneWidget);
      expect(w.entries().first, 'canvas.context.newNote');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump();
      expect(w.open, isFalse);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'PageCanvas');
    });

    testWidgets('Tab and Shift+Tab move between entries and wrap inside the list', (t) async {
      await setUpWorld(t, nodes: [tbox('a', 'test.text', ba, 'alpha')]);
      w.c.select('a');
      await t.pump();
      await w.shiftF10();
      // One box: Boxes here and Bring... are off; Delete is the only enabled.
      expect(w.focused(), 'Delete box');
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(w.focused(), 'Delete box');
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      expect(w.menu, findsOneWidget);
    });

    testWidgets('Shift+F10 with focus in a text field goes to the field', (t) async {
      await setUpWorld(t, nodes: [tbox('f', 'test.field', ba, 'label')]);
      await t.tapAt(w.at(const Offset(200, 200)));
      await t.pumpAndSettle();
      expect(find.byType(EditableText), findsOneWidget);
      await w.shiftF10();
      expect(w.open, isFalse);
      await t.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await t.pump();
      expect(w.open, isFalse);
    });

    testWidgets('a selected box outside the view is revealed first and the menu opens inside it', (t) async {
      await setUpWorld(t, nodes: [
        tbox('a', 'test.text', ba, 'alpha'),
        tbox('far', 'test.text', const Bounds(3000, 2000, 300, 200), 'far'),
      ]);
      w.c.select('far');
      await t.pump();
      await w.shiftF10();
      await t.pump();
      expect(w.menu, findsOneWidget);
      expect(w.c.selectedId, 'far');
      final rect = t.getRect(find.byKey(const ValueKey('context-menu')));
      final screen = Rect.fromPoints(
        w.at(const Offset(3000, 2000)),
        w.at(const Offset(3300, 2200)),
      );
      expect(screen.inflate(1).contains(rect.topLeft), isTrue);
    });

    testWidgets('a corner covered by another box gives the visible centre', (t) async {
      await setUpWorld(t, nodes: [
        tbox('a', 'test.text', const Bounds(100, 100, 300, 200), 'alpha'),
        tbox('top', 'test.text', const Bounds(90, 90, 120, 120), 'top'),
      ]);
      w.c.select('a');
      await t.pump();
      await w.shiftF10();
      expect(w.menu, findsOneWidget);
      final rect = t.getRect(find.byKey(const ValueKey('context-menu')));
      // Not at the covered corner (112, 112) but at the box's centre (250, 200).
      expect(rect.left, greaterThan(w.at(const Offset(200, 190)).dx));
    });
  });

  group('inputs', () {
    testWidgets('a stylus barrel press, the eraser end and a right drag open nothing', (t) async {
      await setUpWorld(t, pen: true);
      var g = await t.startGesture(
        w.at(overlapPoint),
        kind: PointerDeviceKind.stylus,
        buttons: kSecondaryButton,
      );
      await g.up();
      await t.pump();
      expect(w.open, isFalse);
      g = await t.startGesture(w.at(overlapPoint), kind: PointerDeviceKind.invertedStylus);
      await g.up();
      await t.pump();
      expect(w.open, isFalse);
      g = await t.startGesture(
        w.at(const Offset(900, 600)),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.moveBy(const Offset(40, 0));
      await g.up();
      await g.removePointer();
      await t.pump();
      expect(w.open, isFalse);
    });

    testWidgets('a right click with the Pen tool opens the menu and starts no stroke', (t) async {
      await setUpWorld(t, pen: true);
      w.selection.select(w.pen);
      await t.pump();
      await w.rightClick(w.at(const Offset(900, 600)));
      expect(w.menu, findsOneWidget);
      expect(w.pen.started, 0);
      expect(w.selection.active, same(w.pen));
    });

    testWidgets('a right click on the note editor\'s own secondary tap opens no Noted menu', (t) async {
      await setUpWorld(t, nodes: [tbox('e', 'test.editor', ba, 'note')]);
      editorNode.requestFocus();
      await t.pump();
      expect(w.c.editingId, 'e');
      await w.rightClick(w.at(const Offset(200, 200)));
      expect(w.open, isFalse);
      expect(editorSecondaryTaps, 1);
    });

    testWidgets('a second button during the press opens nothing', (t) async {
      await setUpWorld(t);
      final g = await t.startGesture(
        w.at(const Offset(900, 600)),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton | kPrimaryMouseButton,
      );
      await g.up();
      await g.removePointer();
      await t.pump();
      expect(w.open, isFalse);
    });
  });

  group('claims, links and fields', () {
    testWidgets('an inner secondary-tap recognizer that wins (a text field) keeps the click', (t) async {
      await setUpWorld(t, nodes: [tbox('f', 'test.field', ba, 'label')]);
      await w.rightClick(w.at(const Offset(200, 200)));
      // The field's own selection toolbar, not Noted's menu.
      expect(w.open, isFalse);
    });

    testWidgets('a right click on a link opens the box menu', (t) async {
      await setUpWorld(t, nodes: [tbox('l', 'test.link', ba, 'a link')]);
      await w.rightClick(w.at(const Offset(200, 200)));
      expect(w.menu, findsOneWidget);
      expect(w.c.selectedId, 'l');
      expect(w.c.editingId, isNull);
    });

    testWidgets('the Menu key in the find bar and in a text field is left to the field', (t) async {
      await setUpWorld(t, nodes: [tbox('a', 'test.text', ba, 'alpha')]);
      w.state.openFind();
      await t.pump();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await t.pump();
      await t.pump();
      expect(w.open, isFalse);
      await w.shiftF10();
      expect(w.open, isFalse);
    });
  });

  group('a note being edited', () {
    testWidgets('right click on its grip opens its menu under the hold; Escape restores focus; the hold is released once', (t) async {
      await setUpWorld(t, nodes: [tbox('e', 'test.editor', ba, 'note'), tbox('o', 'test.text', const Bounds(700, 100, 100, 50), 'o')]);
      editorNode.requestFocus();
      await t.pump();
      expect(w.c.editingId, 'e');
      await w.rightClick(w.at(const Offset(250, 100 - boxGripHeight / 2)));
      expect(w.menu, findsOneWidget);
      expect(w.c.editorFocusHold.count, 1);
      expect(w.c.editingId, 'e');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump();
      await t.pump();
      expect(w.open, isFalse);
      expect(w.c.editorFocusHold.count, 0);
      expect(w.c.editingId, 'e');
      expect(editorNode.hasPrimaryFocus, isTrue);
    });

    testWidgets('Shift+F10 inside the note opens its menu; the canvas target also holds', (t) async {
      await setUpWorld(t, nodes: [tbox('e', 'test.editor', ba, 'note')]);
      editorNode.requestFocus();
      await t.pump();
      await w.shiftF10();
      expect(w.menu, findsOneWidget);
      expect(w.c.editorFocusHold.count, 1);
      expect(w.c.selectedId, 'e');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump();
      await t.pump();
      expect(w.c.editorFocusHold.count, 0);
      expect(editorNode.hasPrimaryFocus, isTrue);

      await w.rightClick(w.at(const Offset(900, 600)));
      expect(w.c.editorFocusHold.count, 1);
      await t.tapAt(const Offset(5, 700));
      await t.pump();
      await t.pump();
      await t.pump();
      expect(w.c.editorFocusHold.count, 0);
      expect(w.c.editingId, 'e');
    });

    testWidgets('right click on another box demotes the note, with no hold', (t) async {
      await setUpWorld(t, nodes: [tbox('e', 'test.editor', ba, 'note'), tbox('o', 'test.text', const Bounds(700, 100, 100, 50), 'o')]);
      editorNode.requestFocus();
      await t.pump();
      await w.rightClick(w.at(const Offset(720, 120)));
      expect(w.menu, findsOneWidget);
      expect(w.c.editorFocusHold.count, 0);
      expect(w.c.selectedId, 'o');
      await t.pump();
      expect(w.c.editingId, isNull);
    });

    testWidgets('the canvas disposing under an open menu releases the hold', (t) async {
      await setUpWorld(t, nodes: [tbox('e', 'test.editor', ba, 'note')]);
      editorNode.requestFocus();
      await t.pump();
      await w.shiftF10();
      expect(w.c.editorFocusHold.count, 1);
      await t.pumpWidget(const SizedBox());
      expect(w.c.editorFocusHold.count, 0);
      await t.pump();
      await t.pump();
    });
  });

  group('keys while a menu is open (B1)', () {
    testWidgets('Delete, Backspace, V, P, E and Ctrl+Z change nothing and the menu keeps focus', (t) async {
      await setUpWorld(t, pen: true);
      w.c.select('c');
      await t.pump();
      w.c.restack('a', StackMove.front);
      await t.pump();
      final order = w.order;
      await w.shiftF10();
      expect(w.menu, findsOneWidget);
      for (final k in [
        LogicalKeyboardKey.delete,
        LogicalKeyboardKey.backspace,
        LogicalKeyboardKey.keyV,
        LogicalKeyboardKey.keyP,
        LogicalKeyboardKey.keyE,
      ]) {
        await t.sendKeyEvent(k);
        await t.pump();
      }
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(w.menu, findsOneWidget);
      expect(w.order, order);
      expect(w.c.page.nodes, hasLength(3));
      expect(w.selection.active, isNull);
      expect(w.c.canUndo, isTrue);
    });
  });

  group('point commands', () {
    testWidgets('New note here creates the note at the point; Undo removes it', (t) async {
      await setUpWorld(t);
      final p = w.at(const Offset(900, 600));
      await w.rightClick(p);
      await w.choose('canvas.context.newNote');
      expect(w.c.page.nodes, hasLength(4));
      final made = w.c.page.nodes.last.bounds!;
      expect(made.x, closeTo(890, 1));
      expect(made.y, closeTo(586, 1));
      expect(w.c.selectedId, w.c.page.nodes.last.id);
      w.c.undo();
      expect(w.c.page.nodes, hasLength(3));
    });

    testWidgets('New note here with the Pen active selects Select and type first', (t) async {
      await setUpWorld(t, pen: true);
      w.selection.select(w.pen);
      await t.pump();
      await w.rightClick(w.at(const Offset(900, 600)));
      await w.choose('canvas.context.newNote');
      expect(w.selection.active, isNull);
      expect(w.c.page.nodes, hasLength(4));
    });

    testWidgets('Paste image or file places the box at the point', (t) async {
      await setUpWorld(t, withStore: true);
      FileClipboard.read = () async => [IncomingFile('p.png', Uint8List.fromList([1, 2, 3]))];
      addTearDown(() => FileClipboard.read = () async => const []);
      await w.rightClick(w.at(const Offset(900, 600)));
      await w.choose('canvas.context.paste');
      await t.pump();
      final made = w.c.page.nodes.whereType<BoxRecord>().where((b) => b.typeId == 'test.file');
      expect(made, hasLength(1));
      expect(made.single.bounds.x, closeTo(900, 1));
      expect(made.single.bounds.y, closeTo(600, 1));
    });

    testWidgets('a clipboard read that completes after another page opened inserts nothing on either', (t) async {
      await setUpWorld(t, withStore: true);
      final other = CanvasController(tpage(threeBoxes(), id: 'q'), w.modules);
      addTearDown(other.dispose);
      final release = Completer<List<IncomingFile>>();
      FileClipboard.read = () => release.future;
      addTearDown(() => FileClipboard.read = () async => const []);
      await w.rightClick(w.at(const Offset(900, 600)));
      await w.choose('canvas.context.paste');
      await w.rebuild(controller: other);
      release.complete([IncomingFile('p.png', Uint8List.fromList([1]))]);
      await t.pump();
      await t.pump();
      expect(w.c.page.nodes, hasLength(3));
      expect(other.page.nodes, hasLength(3));
      expect(w.store!.stored, isEmpty);
    });
  });

  group('radial and list differ only in layout', () {
    testWidgets('the keyboard openers show the list even with Radial set', (t) async {
      await setUpWorld(t, style: ContextMenuStyle.radial);
      await t.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await t.pump();
      await t.pump();
      expect(w.menu, findsOneWidget);
      expect(w.ring, findsNothing);
    });
  });

  group('touch', () {
    testWidgets('a hold on empty canvas opens the canvas menu at the finger and creates no note', (t) async {
      await setUpWorld(t);
      final p = w.at(const Offset(900, 600));
      final g = await w.hold(p);
      await g.up();
      await t.pumpAndSettle();
      expect(w.menu, findsOneWidget);
      expect(w.c.page.nodes, hasLength(3));
      expect(w.entries().first, 'canvas.context.newNote');
      final rect = t.getRect(w.menu);
      expect((rect.topLeft - p).distance, lessThan(20));
    });

    testWidgets('a quick tap on empty canvas still creates a note', (t) async {
      await setUpWorld(t);
      await t.tapAt(w.at(const Offset(900, 600)));
      await t.pumpAndSettle();
      expect(w.open, isFalse);
      expect(w.c.page.nodes, hasLength(4));
    });

    testWidgets('a hold then a drag opens nothing', (t) async {
      await setUpWorld(t);
      final g = await w.hold(w.at(const Offset(900, 600)));
      await g.moveBy(const Offset(60, 0));
      await g.up();
      await t.pumpAndSettle();
      expect(w.open, isFalse);
    });

    testWidgets('a second finger during the hold opens nothing', (t) async {
      await setUpWorld(t);
      final g = await w.hold(w.at(const Offset(900, 600)));
      final g2 = await t.startGesture(w.at(const Offset(700, 500)), pointer: 2);
      await g2.up();
      await g.up();
      await t.pumpAndSettle();
      expect(w.open, isFalse);
    });

    testWidgets('with the Pen tool active a finger hold opens nothing', (t) async {
      await setUpWorld(t, pen: true);
      w.selection.select(w.pen);
      await t.pump();
      final g = await w.hold(w.at(const Offset(900, 600)));
      await g.up();
      await t.pumpAndSettle();
      expect(w.open, isFalse);
    });

    testWidgets('a hold on a box opens the pick list; More opens the box menu with the box selected; Bring to front then Undo', (t) async {
      await setUpWorld(t);
      var g = await w.hold(w.at(overlapPoint));
      await g.up();
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('box-pick-list')), findsOneWidget);
      // More on a buried box's row.
      await t.tap(find.byKey(const ValueKey('pick-more-a')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('box-pick-list')), findsNothing);
      expect(w.menu, findsOneWidget);
      expect(w.c.selectedId, 'a');
      // Focus is on the menu's first entry and arrows move inside it.
      expect(w.focused(), 'Bring to front');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
      expect(w.focused(), 'Bring forward');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pump();
      await w.choose(CanvasCommands.bringToFront);
      expect(w.order, ['b', 'c', 'a']);
      w.c.undo();
      expect(w.order, ['a', 'b', 'c']);
      g = await w.hold(w.at(overlapPoint));
      await g.up();
      await t.pumpAndSettle();
      expect(find.byTooltip('Actions for this box'), findsNWidgets(3));
    });

    testWidgets('More on a disallowed box\'s row gives Delete only', (t) async {
      await setUpWorld(
        t,
        nodes: [tbox('x', 'test.off', ba, 'saved'), tbox('b', 'test.text', bb, 'bravo')],
        disallowed: {'test.off'},
      );
      final g = await w.hold(w.at(overlapPoint));
      await g.up();
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('pick-more-x')));
      await t.pumpAndSettle();
      expect(w.menu, findsOneWidget);
      expect(find.byKey(const ValueKey('context-heading')), findsOneWidget);
      expect(w.enabled(CanvasCommands.delete), isTrue);
      expect(w.enabled(CanvasCommands.sendToBack), isFalse);
    });
  });

  group('macOS Ctrl+click', () {
    testWidgets('Ctrl+primary over a note opens its box menu, places no caret and selects through the menu only', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await setUpWorld(t, nodes: [tbox('a', 'test.text', ba, 'alpha')]);
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        final g = await t.startGesture(w.at(const Offset(200, 200)), kind: PointerDeviceKind.mouse);
        await g.up();
        await g.removePointer();
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await t.pump();
        await t.pump();
        expect(w.menu, findsOneWidget);
        expect(w.c.selectedId, 'a');
        expect(w.c.editingId, isNull);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pump();
        await t.pump();
        await t.pumpWidget(const SizedBox());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('edges', () {
    testWidgets('right click 4 px from each corner keeps the menu fully inside the window', (t) async {
      await setUpWorld(t);
      final area = Rect.fromLTWH(0, CommandToolbar.height, 1200, 800 - CommandToolbar.height);
      for (final p in [
        area.topLeft + const Offset(4, 4),
        area.topRight + const Offset(-4, 4),
        area.bottomLeft + const Offset(4, -4),
        area.bottomRight + const Offset(-4, -4),
      ]) {
        await w.rightClick(p);
        expect(w.menu, findsOneWidget);
        final r = t.getRect(w.menu);
        expect(r.left, greaterThanOrEqualTo(8 - 0.01));
        expect(r.top, greaterThanOrEqualTo(8 - 0.01));
        expect(r.right, lessThanOrEqualTo(1200 - 8 + 0.01));
        expect(r.bottom, lessThanOrEqualTo(800 - 8 + 0.01));
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pump();
        await t.pump();
      }
    });
  });

  group('read-only', () {
    testWidgets('both targets open with the edit entries off and the selection unchanged', (t) async {
      await setUpWorld(t, readOnly: true, withStore: true);
      await w.rightClick(w.at(overlapPoint));
      expect(w.menu, findsOneWidget);
      expect(w.c.selectedId, isNull);
      expect(w.enabled(CanvasCommands.sendToBack), isFalse);
      expect(w.enabled(CanvasCommands.delete), isFalse);
      expect(w.enabled('canvas.context.boxesHere'), isFalse);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump();
      await w.rightClick(w.at(const Offset(900, 600)));
      expect(w.enabled('canvas.context.newNote'), isFalse);
      expect(w.enabled('canvas.context.paste'), isFalse);
    });
  });

  group('themes', () {
    testWidgets('the menu draws under Light and Precision', (t) async {
      for (final b in [Brightness.light, Brightness.dark]) {
        tt = t;
        w = World(t)..theme = notedThemeData(b);
        await w.pump();
        await w.rightClick(w.at(const Offset(900, 600)));
        expect(w.menu, findsOneWidget);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pump();
        await t.pump();
      }
    });
  });
}
