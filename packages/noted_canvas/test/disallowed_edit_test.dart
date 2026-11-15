// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A box whose type the page disallows is never decoded or re-encoded: edits,
// focus-loss cleanup and undo skip it, and it shows from its snapshot (0111).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

const _off = 'test.other';
const _offSet = {_off};

/// Counts decodes of the switchable type.
///
/// Not tested here: that a resize ignores `hostAspectRatio` (and the image
/// variant). A disallowed box is not editable, so it has no resize handles, and
/// `_aspectRatio` shares `_resolve`, which the display test shows is not decoded.
class _Counts {
  static int decodes = 0;
  static void reset() {
    decodes = 0;
  }
}

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
  String decode(Object? json, int storedVersion) {
    if (typeId == _off) _Counts.decodes++;
    return json! as String;
  }

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

/// Sets the text back to [before]; its inverse sets it to what it was.
class _SetText implements BoxEdit {
  const _SetText(this.before);
  final String before;
  @override
  (Object?, BoxEdit) apply(Object? data) => (before, _SetText(data! as String));
}

BoxRecord _box(String type, String id, String text, {Bounds? at}) =>
    commitBox(createBox(_Codec(type), at ?? const Bounds(50, 50, 200, 60)).withId(id), _Codec(type), text);

void main() {
  late ModuleRegistry modules;

  setUp(() {
    _Counts.reset();
    modules = ModuleRegistry()
      ..register(const _Module('test.note'), alwaysOn: true, isDefault: true)
      ..register(const _Module(_off));
  });

  NotedPage pageWith(List<BoxRecord> boxes) {
    var p = NotedPage.create(PageMeta.create(id: 'p', title: 'T', order: 0));
    for (final b in boxes) {
      p = p.insertNode(b);
    }
    return p;
  }

  CanvasController controller(List<BoxRecord> boxes) => CanvasController(pageWith(boxes), modules);

  final note = _box('test.note', 'a000000000000001', 'note', at: const Bounds(300, 300, 100, 40));
  final other = _box(_off, 'a000000000000002', 'one');

  String bytes(CanvasController c) => writePage(c.page);

  group('refused edits', () {
    test('commit, editBox and replaceBoxData change nothing and decode nothing', () {
      final c = controller([other]);
      c.disallowedTypes = _offSet;
      final before = bytes(c);
      expect(c.commit(other.id, 'x'), isNull);
      expect(c.editBox(other.id, 'x', undo: const _SetText('one')), isNull);
      expect(c.replaceBoxData({other.id: 'x'}), 0);
      expect(bytes(c), before);
      expect(c.canUndo, isFalse, reason: 'no undo step was recorded');
      expect(_Counts.decodes, 0);
      // Allowed again, the same calls work.
      c.disallowedTypes = const {};
      expect(c.commit(other.id, 'x'), isNotNull);
      expect(bytes(c), isNot(before));
    });

    test('insertBox refuses a box of a disallowed type', () {
      final c = controller([]);
      c.disallowedTypes = _offSet;
      c.insertBox(other);
      expect(c.page.nodes, isEmpty);
      expect(c.canUndo, isFalse);
      c.insertBox(note);
      expect(c.page.nodes, hasLength(1));
    });

    test('resolveWithData on a conflicted box of a disallowed type returns false and leaves it', () {
      final theirs = _box(_off, other.id, 'theirs');
      final conflicted = other.withConflict(BoxConflict.other(node: theirs.toRaw(), at: 1, device: 'L'));
      final c = controller([conflicted]);
      c.disallowedTypes = _offSet;
      final before = bytes(c);
      expect(c.resolveWithData(other.id, 'merged'), isFalse);
      expect(bytes(c), before);
      expect(c.canUndo, isFalse);
      expect(_Counts.decodes, 0);
      c.disallowedTypes = const {};
      expect(c.resolveWithData(other.id, 'merged'), isTrue);
    });

    test('focus-loss cleanup keeps an empty box of a disallowed type, undecoded', () {
      final empty = _box(_off, 'a000000000000003', '');
      final c = controller([empty]);
      final before = bytes(c);
      c.disallowedTypes = _offSet;
      c.setEditing(empty.id, true);
      c.setEditing(empty.id, false);
      expect(c.page.node(empty.id), isNotNull);
      expect(bytes(c), before);
      expect(_Counts.decodes, 0);
      // Allowed, the same empty box is discarded.
      c.disallowedTypes = const {};
      c.setEditing(empty.id, true);
      c.setEditing(empty.id, false);
      expect(c.page.node(empty.id), isNull);
    });

    test('setting the set notifies only when it changes', () {
      final c = controller([other]);
      var n = 0;
      c.addListener(() => n++);
      c.disallowedTypes = _offSet;
      c.disallowedTypes = {..._offSet};
      expect(n, 1);
      c.disallowedTypes = const {};
      expect(n, 2);
    });
  });

  group('undo and redo keep a blocked step', () {
    void move(CanvasController c, String id, Bounds to) {
      c.beginGesture(id);
      c.updateGesture(id, to);
      c.endGesture(id);
    }

    // A moves the note box, B edits the other box's content.
    CanvasController setup() {
      final c = controller([note, other]);
      move(c, note.id, const Bounds(400, 300, 100, 40));
      c.editBox(other.id, 'two', undo: const _SetText('one'));
      return c;
    }

    test('while disallowed Undo does nothing and the step stays; after re-allowing B then A undo', () {
      final c = setup();
      c.disallowedTypes = _offSet;
      _Counts.reset();
      final before = bytes(c);
      expect(c.canUndo, isFalse);
      c.undo();
      expect(bytes(c), before, reason: 'A is not applied either');
      expect((c.page.node(note.id)! as BoxRecord).bounds.x, 400);
      expect(_Counts.decodes, 0);
      c.disallowedTypes = const {};
      expect(c.canUndo, isTrue);
      c.undo();
      expect((c.page.node(other.id)! as BoxRecord).data!.decode(), 'one');
      c.undo();
      expect((c.page.node(note.id)! as BoxRecord).bounds.x, 300);
    });

    test('redo is kept the same way', () {
      final c = setup();
      c.undo(); // B undone
      c.disallowedTypes = _offSet;
      final before = bytes(c);
      expect(c.canRedo, isFalse);
      c.redo();
      expect(bytes(c), before);
      c.disallowedTypes = const {};
      expect(c.canRedo, isTrue);
      c.redo();
      expect((c.page.node(other.id)! as BoxRecord).data!.decode(), 'two');
    });

    test('a group holding the blocked step is blocked whole', () {
      final c = controller([note, other]);
      c.recordChange(
        PageChange.group([
          PageChange.bounds(note.id, note.bounds),
          const PageChange.content('a000000000000002', _SetText('one')),
        ]),
      );
      c.disallowedTypes = _offSet;
      expect(c.canUndo, isFalse);
      final before = bytes(c);
      c.undo();
      expect(bytes(c), before);
      c.disallowedTypes = const {};
      expect(c.canUndo, isTrue);
    });

    test('a bounds step on a disallowed box still undoes (guard)', () {
      final c = controller([other]);
      move(c, other.id, const Bounds(80, 80, 200, 60));
      c.disallowedTypes = _offSet;
      expect(c.canUndo, isTrue);
      c.undo();
      expect((c.page.node(other.id)! as BoxRecord).bounds.x, 50);
      expect(_Counts.decodes, 0);
    });

    test('(guard: these reverts never used a codec) Delete, an add and a replacement undo and redo at once, verbatim', () {
      // Delete, then Undo and Redo.
      var c = controller([other]);
      final raw = bytes(c);
      c.delete(other.id);
      c.disallowedTypes = _offSet;
      _Counts.reset();
      expect(c.canUndo, isTrue);
      c.undo();
      expect(bytes(c), raw);
      expect(c.canRedo, isTrue);
      c.redo();
      expect(c.page.node(other.id), isNull);
      expect(_Counts.decodes, 0);

      // A newly added box, then the disallow.
      c = controller([]);
      c.insertBox(other);
      c.disallowedTypes = _offSet;
      expect(c.canUndo, isTrue);
      c.undo();
      expect(c.page.nodes, isEmpty);
      c.redo();
      expect(bytes(c), writePage(pageWith([other])));
      expect(_Counts.decodes, 0);

      // A conflict resolved with Keep the other version.
      final theirs = _box(_off, other.id, 'theirs');
      final conflicted = other.withConflict(BoxConflict.other(node: theirs.toRaw(), at: 1, device: 'L'));
      c = controller([conflicted]);
      final conflictedBytes = bytes(c);
      c.resolveKeepTheirs(other.id);
      c.disallowedTypes = _offSet;
      expect(c.canUndo, isTrue);
      c.undo();
      expect(bytes(c), conflictedBytes);
      expect(_Counts.decodes, 0);
    });
  });

  group('display', () {
    Future<void> pump(WidgetTester t, CanvasController c, Set<String> off) async {
      t.view.physicalSize = const Size(1000, 700);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageCanvas(controller: c, disallowedTypes: off),
          ),
        ),
      );
      await t.pump();
    }

    testWidgets('a disallowed box shows from its snapshot with no decode; allowing it resolves again', (t) async {
      final c = controller([other, note]);
      c.disallowedTypes = _offSet;
      _Counts.reset();
      await pump(t, c, _offSet);
      expect(find.text('Not allowed on this page'), findsOneWidget);
      expect(find.text('one'), findsOneWidget);
      expect(find.byKey(ValueKey('live-${other.id}')), findsNothing);
      expect(_Counts.decodes, 0);

      c.disallowedTypes = const {};
      await pump(t, c, const {});
      await t.pump();
      expect(find.byKey(ValueKey('live-${other.id}')), findsOneWidget);
      expect(_Counts.decodes, greaterThan(0));

      // And off again: the cached live box is not kept.
      _Counts.reset();
      c.disallowedTypes = _offSet;
      await pump(t, c, _offSet);
      await t.pump();
      expect(find.byKey(ValueKey('live-${other.id}')), findsNothing);
      expect(find.text('Not allowed on this page'), findsOneWidget);
      c.dispose();
    });

    testWidgets('the Undo command is disabled while its step is blocked, and Ctrl+Z changes nothing', (t) async {
      final c = controller([note, other]);
      c.beginGesture(note.id);
      c.updateGesture(note.id, const Bounds(400, 300, 100, 40));
      c.endGesture(note.id);
      c.editBox(other.id, 'two', undo: const _SetText('one'));
      c.disallowedTypes = _offSet;
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
      expect(key.currentState!.commands['canvas.undo']!.enabled, isFalse);
      final before = writePage(c.page);
      _Counts.reset();
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(writePage(c.page), before, reason: 'the moved note box stays moved');
      expect(_Counts.decodes, 0);

      c.disallowedTypes = const {};
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageCanvas(key: key, controller: c),
          ),
        ),
      );
      await t.pump();
      expect(key.currentState!.commands['canvas.undo']!.enabled, isTrue);
      c.dispose();
    });

    testWidgets('the canvas asserts that the controller holds the set it is given', (t) async {
      final c = controller([other]);
      await pump(t, c, _offSet);
      expect(t.takeException(), isA<AssertionError>());
      c.dispose();
    });
  });
}
