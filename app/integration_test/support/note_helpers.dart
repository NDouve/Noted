// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Helpers to put content on a page of the running app and to drive a note
/// editor. The app does not depend on `appflowy_editor` directly, so the
/// editor state is reached through `dynamic` calls on the widget the app built.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'harness.dart';

Map<String, Object?> para(String text) => {
  'type': 'paragraph',
  'data': {
    'delta': [
      if (text.isNotEmpty) {'insert': text},
    ],
  },
};

/// A table the way appflowy stores it: cells column by column.
Map<String, Object?> table(List<List<String>> rows) {
  final cols = rows.first.length;
  return {
    'type': 'table',
    'data': {
      'colsLen': cols,
      'rowsLen': rows.length,
      'colDefaultWidth': 80.0,
      'rowDefaultHeight': 40.0,
      'colMinimumWidth': 40.0,
      'borderWidth': 2.0,
    },
    'children': [
      for (var c = 0; c < cols; c++)
        for (var r = 0; r < rows.length; r++)
          {
            'type': 'table/cell',
            'data': {'colPosition': c, 'rowPosition': r},
            'children': [para(rows[r][c])],
          },
    ],
  };
}

Future<String> readCanvas(Directory dir, String id) =>
    File('${dir.path}${Platform.pathSeparator}$id.canvas').readAsString();

/// Adds a note box with [children] (appflowy node maps) to the open page.
String addNote(Session s, List<Map<String, Object?>> children, {double x = 100, double y = 100}) {
  final c = s.nb.current!;
  final box = c.createBoxAt(Bounds(x, y, 0, 0));
  final codec = c.modules.codecs.codecFor(box.typeId)!;
  c.commit(
    box.id,
    codec.decode({
      'document': {'type': 'page', 'children': children},
    }, 1),
  );
  return box.id;
}

/// A note with one paragraph of [text].
Future<String> putNote(Session s, String text, {double x = 100, double y = 100}) async {
  final id = addNote(s, [para(text)], x: x, y: y);
  await s.pump(300);
  return id;
}

PageCanvasState canvasState(WidgetTester t) => t.state<PageCanvasState>(find.byType(PageCanvas));

/// Screen position of a page (world) point.
Offset toScreen(WidgetTester t, Offset world) =>
    canvasState(t).view!.toScreen(world) +
    t.getTopLeft(find.byType(PageCanvas)) +
    const Offset(0, CommandToolbar.height);

/// Screen position of a canvas-local point (the viewport, below the toolbar).
Offset viewportPoint(WidgetTester t, Offset local) =>
    t.getTopLeft(find.byType(PageCanvas)) + const Offset(0, CommandToolbar.height) + local;

/// Clicks the empty canvas: a new note box takes focus.
Future<void> clickNewNote(Session s, {Offset at = const Offset(700, 300)}) async {
  await s.tester.tapAt(toScreen(s.tester, at));
  await s.pump(400);
}

/// Opens box [id] for editing with a click at its top-left corner.
Future<dynamic> editNote(Session s, String id) async {
  final b = s.nb.current!.page.node(id)!.bounds!;
  await s.tester.tapAt(toScreen(s.tester, Offset(b.x + 20, b.y + 10)));
  await s.pump(400);
  expect(s.nb.current!.editingId, id);
  return editorState(s.tester);
}

final Finder editorFinder = find.byWidgetPredicate((w) => w.runtimeType.toString() == 'AppFlowyEditor');

/// The appflowy `EditorState` of the box being edited (dynamic).
dynamic editorState(WidgetTester t) => (t.widget(editorFinder.first) as dynamic).editorState;

/// The cell node (dynamic) at [row], [col] of the first table.
dynamic cell(dynamic editor, int row, int col) =>
    (editor.document.root.children.first.children as Iterable).firstWhere(
      (n) => n.attributes['rowPosition'] == row && n.attributes['colPosition'] == col,
    );

String cellText(dynamic editor, int row, int col) =>
    cell(editor, row, col).children.first.delta.toPlainText() as String;

Object? cellValue(dynamic editor, int row, int col) =>
    cell(editor, row, col).children.first.attributes['formulaValue'];

/// Replaces the text of a cell through an editor transaction.
Future<void> setCellText(Session s, dynamic editor, int row, int col, String text) async {
  final p = cell(editor, row, col).children.first;
  final next = p.delta.slice(0, 0);
  if (text.isNotEmpty) next.insert(text);
  final tr = editor.transaction;
  tr.updateNode(p, {'delta': next.toJson()});
  await editor.apply(tr);
  await s.pump(200);
}

/// Inserts [text] at [offset] of the text node [node] (dynamic).
Future<void> insertTextAt(dynamic editor, dynamic node, int offset, String text) async {
  final change = node.delta.slice(0, 0);
  change.retain(offset);
  change.insert(text);
  final next = node.delta.compose(change);
  final tr = editor.transaction;
  tr.updateNode(node, {'delta': next.toJson()});
  await editor.apply(tr);
}

/// Taps a cell with the mouse (puts the caret in it).
Future<void> tapCell(Session s, dynamic editor, int row, int col) async {
  await s.tester.tapAt(s.tester.getCenter(find.byKey(cell(editor, row, col).key as Key)));
  await s.pump(250);
}

/// Selects characters [from]..[to] of the paragraph at [path] (dynamic
/// editor), using the editor's current selection as a template.
void selectRange(dynamic editor, List<int> path, int from, int to) {
  final sel = editor.selection;
  final a = sel.start.copyWith(path: path, offset: from);
  final b = sel.start.copyWith(path: path, offset: to);
  editor.selection = sel.copyWith(start: a, end: b);
}

/// The text a formula cell shows (its result).
Finder get formulaShown => find.byKey(const ValueKey('formula-value'));

String snapshotOf(Session s, String id) => (s.nb.current!.page.node(id)! as BoxRecord).snapshotText;
