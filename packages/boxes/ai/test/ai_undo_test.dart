// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_ai/noted_box_ai.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  testWidgets('Ctrl+Z in an AI box with an empty editor history undoes the page', (t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final access = NoAiBoxAccess();
    addTearDown(access.dispose);
    final modules = ModuleRegistry()
      ..register(const NoteModule(), alwaysOn: true, isDefault: true)
      ..register(AiModule(access: access));
    const codec = AiCodec();
    final record = commitBox(
      createBox(codec, const Bounds(100, 100, 360, 96)),
      codec,
      AiBoxData({
        'document': {
          'type': 'page',
          'children': [
            {
              'type': 'paragraph',
              'data': {
                'delta': [
                  {'insert': 'hello'},
                ],
              },
            },
          ],
        },
      }),
    ).withId('a');
    final c = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)).insertNode(record),
      modules,
    );
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: noteLocalizationsDelegates,
        home: Scaffold(body: PageCanvas(controller: c)),
      ),
    );
    await t.pumpAndSettle();
    c.setBackground(PageBackground.graph);
    await t.tap(find.text('hello', findRichText: true).last);
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(c.editingId, 'a');
    final editor = t.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;
    expect(editor.undoManager.undoStack.isEmpty, isTrue);

    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(c.page.meta.background, PageBackground.plain);
    expect(c.editingId, 'a');
  });
}