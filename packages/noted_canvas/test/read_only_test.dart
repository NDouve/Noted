// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

class _TextCodec extends BoxCodec<String> {
  const _TextCodec();
  @override
  String get typeId => 'test.text';
  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.growsWithContent;
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

/// The editor is a TextField, the view a plain Text: tests can tell them apart.
class _TextModule extends BoxModule<String> {
  const _TextModule();
  @override
  BoxCodec<String> get codec => const _TextCodec();
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) =>
      TextField(controller: TextEditingController(text: box.data), onChanged: box.commit);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) =>
      Text(box.data, key: const ValueKey('view'));
}

void main() {
  late ModuleRegistry modules;
  late List<NotedPage> saved;

  setUp(() {
    modules = ModuleRegistry()..register(const _TextModule(), alwaysOn: true, isDefault: true);
    saved = [];
  });

  /// A page with one box holding "hello".
  (NotedPage, String) pageWithBox() {
    final c = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: 'T', order: 0)),
      modules,
    );
    final box = c.createBoxAt(const Bounds(50, 50, 0, 0));
    c.commit(box.id, 'hello');
    final page = c.page;
    c.dispose();
    return (page, box.id);
  }

  CanvasController readOnlyController() {
    final (page, _) = pageWithBox();
    return CanvasController(page, modules, onChanged: saved.add, readOnly: true);
  }

  group('controller', () {
    test('blocks every mutation and never reports a change', () {
      final (page, id) = pageWithBox();
      final c = CanvasController(page, modules, onChanged: saved.add, readOnly: true);
      final before = writePage(c.page);

      expect(() => c.createBoxAt(const Bounds(0, 0, 0, 0)), throwsStateError);
      expect(c.commit(id, 'changed'), isNull);
      expect(c.editBox(id, 'changed', bounds: const Bounds(0, 0, 10, 10)), isNull);
      c.requestBounds(id, const Bounds(0, 0, 500, 500));
      c.beginGesture(id);
      c.updateGesture(id, const Bounds(300, 300, 100, 100));
      c.endGesture(id);
      c.setAutoHeight(id);
      c.insertBox(
        createBox(const _TextCodec(), const Bounds(0, 0, 10, 10)),
      );
      c.delete(id);
      c.undo();
      c.redo();
      c.updateMeta(c.page.meta.withTitle('Renamed'));
      c.resolveKeepMine(id);
      c.resolveKeepTheirs(id);
      c.resolveKeepBoth(id);
      c.resolveDelete(id);
      expect(c.resolveWithData(id, 'x'), isFalse);
      c.beginToolSession();
      expect(c.isInteracting, isFalse);
      // An empty box losing focus is not discarded either.
      c.setEditing(id, false);

      expect(writePage(c.page), before);
      expect(saved, isEmpty);
      expect(c.canUndo, isFalse);
      c.dispose();
    });

    test('turning read-only ends editing and gestures; turning it off allows edits', () {
      final (page, id) = pageWithBox();
      final c = CanvasController(page, modules, onChanged: saved.add);
      c.setEditing(id, true);
      c.beginGesture(id);
      expect(c.isInteracting, isTrue);
      var notified = 0;
      c.addListener(() => notified++);

      c.readOnly = true;
      expect(c.editingId, isNull);
      expect(c.isInteracting, isFalse);
      expect(notified, 1);
      saved.clear();
      expect(c.commit(id, 'nope'), isNull);
      expect(saved, isEmpty);

      c.readOnly = false;
      expect(c.commit(id, 'yes'), isNotNull);
      expect(saved, hasLength(1));
      c.dispose();
    });

    test('changes from outside are shown but not saved', () {
      final (page, id) = pageWithBox();
      final c = CanvasController(page, modules, onChanged: saved.add, readOnly: true);
      final other = CanvasController(page, modules)..commit(id, 'from elsewhere');
      c.applyExternal(other.page);
      expect((c.page.node(id)! as BoxRecord).snapshotText, 'from elsewhere');
      expect(saved, isEmpty);
      other.dispose();
      c.dispose();
    });
  });

  group('canvas', () {
    Future<void> pump(WidgetTester t, CanvasController c, {bool readOnly = false}) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(home: Scaffold(body: PageCanvas(controller: c, readOnly: readOnly))),
      );
    }

    testWidgets('shows boxes with the module view: no editor, grip, handles or toolbar', (t) async {
      final c = readOnlyController();
      await pump(t, c);
      expect(find.byKey(const ValueKey('view')), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(MouseRegion).evaluate().where((e) {
        final w = e.widget as MouseRegion;
        return w.cursor == SystemMouseCursors.move || w.cursor == SystemMouseCursors.resizeLeftRight;
      }), isEmpty);
      // Zooming still works.
      expect(find.text('Fit all'), findsOneWidget);
      c.dispose();
    });

    testWidgets('clicking empty canvas creates nothing and the delete key does nothing', (t) async {
      final c = readOnlyController();
      await pump(t, c);
      final before = writePage(c.page);
      await t.tapAt(const Offset(700, 500));
      await t.pump();
      c.select(c.page.nodes.first.id);
      await t.sendKeyEvent(LogicalKeyboardKey.delete);
      await t.sendKeyEvent(LogicalKeyboardKey.keyZ, ) ;
      await t.pump();
      expect(writePage(c.page), before);
      expect(saved, isEmpty);
      c.dispose();
    });

    testWidgets('dragging a box does not move it', (t) async {
      final c = readOnlyController();
      await pump(t, c);
      final before = c.page.nodes.first.bounds;
      final box = t.getTopLeft(find.byKey(const ValueKey('view')));
      final g = await t.startGesture(box + const Offset(0, -7));
      await g.moveBy(const Offset(80, 80));
      await g.up();
      await t.pump();
      expect(c.page.nodes.first.bounds, before);
      expect(saved, isEmpty);
      c.dispose();
    });

    testWidgets('PageCanvas(readOnly: true) alone gives the read-only view', (t) async {
      final (page, _) = pageWithBox();
      final c = CanvasController(page, modules, onChanged: saved.add);
      await pump(t, c, readOnly: true);
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(const ValueKey('view')), findsOneWidget);
      c.dispose();
    });

    testWidgets('a page switched to read-only while shown loses its editor', (t) async {
      final (page, _) = pageWithBox();
      final c = CanvasController(page, modules, onChanged: saved.add);
      await pump(t, c);
      expect(find.byType(TextField), findsOneWidget);
      c.readOnly = true;
      await t.pump();
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(const ValueKey('view')), findsOneWidget);
      c.readOnly = false;
      await t.pump();
      expect(find.byType(TextField), findsOneWidget);
      c.dispose();
    });
  });
}
