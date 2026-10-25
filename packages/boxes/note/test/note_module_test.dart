// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

BoxRecord noteBox(String id, List<String> lines, {double x = 100}) {
  const codec = NoteCodec();
  final data = NoteData({
    'document': {
      'type': 'page',
      'children': [
        for (final l in lines)
          {
            'type': 'paragraph',
            'data': {
              'delta': [
                {'insert': l},
              ],
            },
          },
      ],
    },
  });
  return BoxRecord.create(
    id: id,
    typeId: NoteCodec.id,
    dataVersion: 1,
    bounds: Bounds(x, 100, 300, 40),
    data: RawJson.encode(codec.encode(data)),
    snapshotText: codec.snapshotText(data),
    rev: 'r',
  );
}

void main() {
  late ModuleRegistry modules;

  setUp(() {
    modules = ModuleRegistry()
      ..register(const NoteModule(), alwaysOn: true, isDefault: true);
  });

  Future<CanvasController> pump(WidgetTester t, NotedPage page) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = CanvasController(page, modules);
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: noteLocalizationsDelegates,
        home: Scaffold(body: PageCanvas(controller: c)),
      ),
    );
    await t.pumpAndSettle();
    return c;
  }

  NotedPage page(List<BoxRecord> boxes) {
    var p = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
    for (final b in boxes) {
      p = p.insertNode(b);
    }
    return p;
  }

  testWidgets('renders its text and grows to fit it', (t) async {
    final c = await pump(t, page([noteBox('n', ['first', 'second', 'third', 'fourth'])]));
    expect(find.textContaining('third', findRichText: true), findsOneWidget);
    final h = c.page.node('n')!.bounds!.height;
    expect(h, greaterThan(80));
    // A one-line note is shorter.
    final c2 = await pump(t, page([noteBox('m', ['only'])]));
    expect(c2.page.node('m')!.bounds!.height, lessThan(h));
  });

  testWidgets('a crowded page of notes builds without errors', (t) async {
    final boxes = [
      for (var i = 0; i < 40; i++)
        noteBox('n$i', ['note $i', 'line two'], x: (i % 8) * 140.0),
    ];
    final c = await pump(t, page(boxes));
    expect(c.page.nodes, hasLength(40));
    expect(t.takeException(), isNull);
  });

  testWidgets('a click creates a note that takes focus and commits through the codec', (t) async {
    final c = await pump(t, page([]));
    await t.tapAt(const Offset(400, 300));
    // A focused editor blinks its cursor forever, so pumpAndSettle would
    // never return; pump a few frames instead.
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(c.page.nodes, hasLength(1));
    expect(c.editingId, c.page.nodes.single.id);

    // Edits go through the codec into the page model.
    final box = c.page.nodes.single as BoxRecord;
    final next = c.commit(box.id, const NoteCodec().decode(
      {
        'document': {
          'type': 'page',
          'children': [
            {
              'type': 'paragraph',
              'data': {
                'delta': [
                  {'insert': 'typed'},
                ],
              },
            },
          ],
        },
      },
      1,
    ))!;
    expect(next.snapshotText, 'typed');
    expect(next.baseRev, box.rev);
  });
}
