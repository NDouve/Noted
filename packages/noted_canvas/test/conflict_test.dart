// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

class _Codec extends BoxCodec<String> {
  const _Codec();
  @override
  String get typeId => 'test.text';
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
  AiExposure aiExposure(String data) => AiText(data);
}

class _Module extends BoxModule<String> {
  const _Module();
  @override
  BoxCodec<String> get codec => const _Codec();
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) => Text(box.data);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) => Text(box.data);
}

BoxRecord _box(String id, String text, {Bounds? at}) => BoxRecord.create(
  id: id,
  typeId: 'test.text',
  dataVersion: 1,
  bounds: at ?? const Bounds(100, 100, 200, 60),
  data: RawJson.encode(text),
  snapshotText: text,
  rev: 'r-$id-$text',
);

void main() {
  late ModuleRegistry modules;
  late List<NotedPage> saved;

  setUp(() {
    modules = ModuleRegistry()..register(const _Module(), alwaysOn: true, isDefault: true);
    saved = [];
  });

  final mine = _box('a', 'mine');
  final theirs = _box('a', 'theirs');
  final conflicted = mine.withConflict(
    BoxConflict.other(node: theirs.toRaw(), at: DateTime(2026, 10, 25, 9, 5).millisecondsSinceEpoch),
  );
  final deletedFlag = mine.withConflict(BoxConflict.deleted(at: 5));

  CanvasController controllerOf(BoxRecord b) => CanvasController(
    NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)).insertNode(b),
    modules,
    onChanged: saved.add,
  );

  Future<void> pump(WidgetTester t, CanvasController c) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: PageCanvas(controller: c))));
    await t.pump();
  }

  testWidgets('a conflicted box shows an amber frame and a Conflict badge', (t) async {
    final c = controllerOf(conflicted);
    await pump(t, c);
    expect(find.byKey(const ValueKey('conflict-badge-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('conflict-frame')), findsOneWidget);
    expect(find.text('Conflict'), findsOneWidget);
    // A box without conflicts has neither.
    final c2 = controllerOf(mine);
    await pump(t, c2);
    expect(find.byKey(const ValueKey('conflict-badge-a')), findsNothing);
  });

  testWidgets('the badge opens both versions side by side', (t) async {
    final c = controllerOf(conflicted);
    await pump(t, c);
    await t.tap(find.byKey(const ValueKey('conflict-badge-a')));
    await t.pumpAndSettle();
    expect(find.text('This device'), findsOneWidget);
    expect(find.textContaining('Other version, saved 2026-10-25 09:05'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const ValueKey('conflict-mine')), matching: find.text('mine')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(const ValueKey('conflict-theirs')), matching: find.text('theirs')),
      findsOneWidget,
    );
  });

  testWidgets('Keep mine from the dialog drops the conflict', (t) async {
    final c = controllerOf(conflicted);
    await pump(t, c);
    await t.tap(find.byKey(const ValueKey('conflict-badge-a')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('conflict-keep-mine')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('conflict-dialog')), findsNothing);
    expect(find.byKey(const ValueKey('conflict-badge-a')), findsNothing);
    expect((c.page.node('a')! as BoxRecord).snapshotText, 'mine');
    expect(saved, isNotEmpty);
  });

  group('resolutions', () {
    test('keep mine, and undo', () {
      final c = controllerOf(conflicted);
      c.resolveKeepMine('a');
      final n = c.page.node('a')! as BoxRecord;
      expect(n.isConflicted, isFalse);
      expect(n.toRaw(), mine.toRaw());
      c.undo();
      expect((c.page.node('a')! as BoxRecord).isConflicted, isTrue);
      c.redo();
      expect((c.page.node('a')! as BoxRecord).isConflicted, isFalse);
    });

    test('keep theirs replaces the box; undo brings mine back', () {
      final c = controllerOf(conflicted);
      c.resolveKeepTheirs('a');
      final n = c.page.node('a')! as BoxRecord;
      expect(n.snapshotText, 'theirs');
      expect(n.isConflicted, isFalse);
      expect(c.page.nodes, hasLength(1));
      c.undo();
      final back = c.page.node('a')! as BoxRecord;
      expect(back.snapshotText, 'mine');
      expect(back.isConflicted, isTrue);
    });

    test('keep both adds the other version to the right with a new id', () {
      final c = controllerOf(conflicted);
      c.resolveKeepBoth('a');
      expect(c.page.nodes, hasLength(2));
      final a = c.page.node('a')! as BoxRecord;
      final other = c.page.nodes.last as BoxRecord;
      expect(a.isConflicted, isFalse);
      expect(a.snapshotText, 'mine');
      expect(other.id, isNot('a'));
      expect(other.snapshotText, 'theirs');
      expect(other.isConflicted, isFalse);
      expect(other.bounds.x, greaterThanOrEqualTo(a.bounds.x + a.bounds.width));
      expect(other.bounds.y, a.bounds.y);
      // One undo step takes both changes back.
      c.undo();
      expect(c.page.nodes, hasLength(1));
      expect((c.page.node('a')! as BoxRecord).isConflicted, isTrue);
      c.redo();
      expect(c.page.nodes, hasLength(2));
      expect(c.conflictedBoxes, isEmpty);
    });

    test('deleted on the other side: keep or delete, both undoable', () {
      final c = controllerOf(deletedFlag);
      expect(c.hasConflicts, isTrue);
      c.resolveKeepMine('a');
      expect(c.page.nodes, hasLength(1));
      expect(c.hasConflicts, isFalse);
      c.undo();
      c.resolveDelete('a');
      expect(c.page.nodes, isEmpty);
      c.undo();
      expect((c.page.node('a')! as BoxRecord).isConflicted, isTrue);
    });
  });

  testWidgets('a deleted-on-the-other-side box offers Keep and Delete', (t) async {
    final c = controllerOf(deletedFlag);
    await pump(t, c);
    await t.tap(find.byKey(const ValueKey('conflict-badge-a')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('conflict-keep-theirs')), findsNothing);
    await t.tap(find.byKey(const ValueKey('conflict-delete')));
    await t.pumpAndSettle();
    expect(c.page.nodes, isEmpty);
  });

  test('applyExternal swaps the page and saves only when asked', () {
    final c = controllerOf(mine);
    final next = c.page.replaceNode(theirs);
    c.applyExternal(next, save: false);
    expect(saved, isEmpty);
    expect((c.page.node('a')! as BoxRecord).snapshotText, 'theirs');
    c.applyExternal(c.page.removeNode('a'));
    expect(saved, hasLength(1));
  });
}
