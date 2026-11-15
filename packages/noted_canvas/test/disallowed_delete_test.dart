// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A box whose type the page disallows can be selected for Delete only (0166):
// never moved, resized, restacked or opened. Delete removes it and Undo puts
// back the same saved bytes.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

const _off = 'test.other';
const _offSet = {_off};

class _Codec extends BoxCodec<String> {
  const _Codec(this.typeId);
  @override
  final String typeId;
  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.fixed;
  @override
  String create() => '';
  @override
  String decode(Object? json, int storedVersion) => json! as String;
  @override
  Object? encode(String data) => data;
  @override
  String snapshotText(String data) => data;
  @override
  bool isEmpty(String data) => data.trim().isEmpty;
  @override
  AiExposure aiExposure(String data) => AiText(data);
}

class _Module extends BoxModule<String> {
  const _Module(this.id);
  final String id;
  @override
  BoxCodec<String> get codec => _Codec(id);
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) =>
      Text('live ${box.data}', key: ValueKey('live-${box.boxId}'));
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) =>
      Text('live ${box.data}', key: ValueKey('live-${box.boxId}'));
}

BoxRecord _box(String type, String id, String text, Bounds at) =>
    commitBox(createBox(_Codec(type), at).withId(id), _Codec(type), text);

void main() {
  final modules = ModuleRegistry()
    ..register(const _Module('test.note'), alwaysOn: true, isDefault: true)
    ..register(const _Module(_off));
  final note = _box('test.note', 'a000000000000001', 'note', const Bounds(500, 300, 200, 60));
  final other = _box(_off, 'a000000000000002', 'one', const Bounds(50, 50, 200, 60));

  CanvasController controller() {
    var p = NotedPage.create(PageMeta.create(id: 'p', title: 'T', order: 0));
    p = p.insertNode(note).insertNode(other);
    final c = CanvasController(p, modules)..disallowedTypes = _offSet;
    return c;
  }

  String bytes(CanvasController c) => writePage(c.page);

  group('controller', () {
    test('selecting works; move, resize and restack do nothing', () {
      final c = controller();
      final before = bytes(c);
      c.select(other.id);
      expect(c.selectedId, other.id);
      c.beginGesture(other.id);
      c.updateGesture(other.id, const Bounds(90, 90, 300, 90), setsHeight: true);
      c.endGesture(other.id);
      c.setAutoHeight(other.id);
      expect(c.isInteracting, isFalse);
      for (final m in StackMove.values) {
        expect(c.canRestack(other.id, m), isFalse);
        expect(c.restack(other.id, m), isFalse);
      }
      expect(c.commit(other.id, 'x'), isNull);
      expect(c.editBox(other.id, 'x'), isNull);
      expect(bytes(c), before);
      expect(c.canUndo, isFalse);
      // Allowed again, the same box moves.
      c.disallowedTypes = const {};
      c.beginGesture(other.id);
      c.updateGesture(other.id, const Bounds(90, 90, 200, 60));
      c.endGesture(other.id);
      expect(bytes(c), isNot(before));
    });

    test('Delete removes it; Undo restores the same bytes; Redo deletes again', () {
      final c = controller();
      final before = bytes(c);
      c.select(other.id);
      c.delete(other.id);
      expect(c.page.node(other.id), isNull);
      expect(c.selectedId, isNull);
      expect(c.canUndo, isTrue);
      c.undo();
      expect(bytes(c), before);
      expect(c.canRedo, isTrue);
      c.redo();
      expect(c.page.node(other.id), isNull);
      expect(c.page.node(note.id), isNotNull);
      c.undo();
      expect(bytes(c), before);
    });
  });

  group('canvas', () {
    Future<GlobalKey<PageCanvasState>> pump(WidgetTester t, CanvasController c) async {
      final key = GlobalKey<PageCanvasState>();
      t.view.physicalSize = const Size(1000, 700);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageCanvas(key: key, controller: c, disallowedTypes: _offSet),
          ),
        ),
      );
      await t.pump();
      return key;
    }

    Future<void> clickBox(WidgetTester t) async {
      await t.tap(find.text('one'));
      // The click selects two frames after the pointer goes up.
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> key(WidgetTester t, LogicalKeyboardKey k, {bool ctrl = false}) async {
      if (ctrl) await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(k);
      if (ctrl) await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
    }

    testWidgets('a click selects it with no grip or handles; keys and commands leave it alone', (t) async {
      final c = controller();
      final k = await pump(t, c);
      final before = bytes(c);
      await clickBox(t);
      expect(c.selectedId, other.id);
      expect(find.byKey(const ValueKey('box-grip')), findsNothing);
      expect(find.byKey(const ValueKey('box-handle-right')), findsNothing);
      expect(find.byKey(const ValueKey('box-handle-bottomRight')), findsNothing);
      expect(c.editingId, isNull, reason: 'no editor opened');

      // Arrow keys nudge nothing; a drag from the box moves nothing.
      for (final a in [LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowDown]) {
        await key(t, a);
      }
      await t.drag(find.text('one'), const Offset(80, 40));
      await t.pump();
      c.select(other.id);
      for (final id in [
        CanvasCommands.bringToFront,
        CanvasCommands.bringForward,
        CanvasCommands.sendBackward,
        CanvasCommands.sendToBack,
      ]) {
        expect(k.currentState!.commands[id]!.enabled, isFalse, reason: id);
      }
      expect(bytes(c), before);
      expect(c.canUndo, isFalse);
      c.dispose();
    });

    testWidgets('Delete and Backspace remove it; Undo restores the same bytes; Redo deletes again', (t) async {
      for (final del in [LogicalKeyboardKey.delete, LogicalKeyboardKey.backspace]) {
        final c = controller();
        final k = await pump(t, c);
        final before = bytes(c);
        await clickBox(t);
        expect(k.currentState!.commands[CanvasCommands.delete]!.enabled, isTrue);
        await key(t, del);
        expect(c.page.node(other.id), isNull, reason: '$del');
        expect(find.text('one'), findsNothing);

        await key(t, LogicalKeyboardKey.keyZ, ctrl: true);
        expect(bytes(c), before, reason: 'the saved bytes are restored');
        expect(find.text('one'), findsOneWidget);

        await key(t, LogicalKeyboardKey.keyY, ctrl: true);
        expect(c.page.node(other.id), isNull);
        expect(c.page.node(note.id), isNotNull);
        c.dispose();
      }
    });

    testWidgets('the multi-selection rule: the canvas holds one selection, so a disallowed box is never part of a move', (t) async {
      // There is no multi-selection yet (one selectedId). Selecting the
      // allowed box and then the disallowed one leaves only the latter, which
      // cannot move; the allowed box keeps moving when it is the selection.
      final c = controller();
      await pump(t, c);
      c.select(note.id);
      c.select(other.id);
      expect(c.selectedId, other.id);
      final before = bytes(c);
      c.beginGesture(other.id);
      c.updateGesture(other.id, const Bounds(0, 0, 200, 60));
      c.endGesture(other.id);
      expect(bytes(c), before);
      c.beginGesture(note.id);
      c.updateGesture(note.id, const Bounds(520, 300, 200, 60));
      c.endGesture(note.id);
      expect(bytes(c), isNot(before));
      c.dispose();
    });
  });
}
