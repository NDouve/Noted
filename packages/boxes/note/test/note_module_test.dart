// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'watchdog.dart';

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
    final c = await pump(
      t,
      page([
        noteBox('n', ['first', 'second', 'third', 'fourth']),
      ]),
    );
    expect(find.textContaining('third', findRichText: true), findsOneWidget);
    final h = c.page.node('n')!.bounds!.height;
    expect(h, greaterThan(80));
    // A one-line note is shorter.
    final c2 = await pump(
      t,
      page([
        noteBox('m', ['only']),
      ]),
    );
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

  testWidgets(
    'a click creates a note that takes focus and commits through the codec',
    (t) async {
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
      final next = c.commit(
        box.id,
        const NoteCodec().decode({
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
        }, 1),
      )!;
      expect(next.snapshotText, 'typed');
      expect(next.baseRev, box.rev);
    },
  );

  // Regression: appflowy's auto-scroll target (220 px by default) is larger
  // than a small box's viewport, and the scroller bounced up and down
  // forever, freezing the app. A fixed-height note with overflowing content
  // must stay responsive with the caret moving through it, at any zoom,
  // and auto-scroll must still follow the caret. The freeze is a
  // synchronous loop, so a watchdog isolate fails the run if it comes back.
  //
  // Also covers arrow up/down while zoomed: appflowy's own commands bounced
  // the caret between two lines when zoomed out.
  for (final zoom in [1.0, 0.3, 3.0]) {
    final name =
        'a fixed-height note scrolls to the caret without freezing at ${zoom}x';
    testWidgets(
      name,
      (t) => withWatchdog(t, name, const Duration(seconds: 60), () async {
        final box = noteBox('n', [
          for (var i = 0; i < 20; i++) 'line $i',
        ]).withBounds(const Bounds(100, 100, 300, 60)).withFixedHeight(true);
        final c = await pump(t, page([box]));
        final canvas = t.state<PageCanvasState>(find.byType(PageCanvas));
        // Centre the box, then zoom around the centre so it stays in view.
        final centre = canvas.view!.toWorld(const Offset(600, 400));
        c.requestBounds('n', Bounds(centre.dx - 150, centre.dy - 30, 300, 60));
        await t.pump();
        canvas.zoomTo(zoom);
        await t.pump();
        final b = c.page.node('n')!.bounds!;
        expect(b.height, 60, reason: 'fixed height must not grow');

        // Click the first line to put the caret there.
        final view = canvas.view!;
        await t.tapAt(view.toScreen(Offset(b.x + 40, b.y + 12)) + const Offset(0, CommandToolbar.height));
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 50));
        }
        expect(c.editingId, 'n');

        final scroller = t.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(BoxHost),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(scroller.position.pixels, 0);
        final editor = t
            .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
            .editorState;
        Future<void> settle() async {
          for (var i = 0; i < 40; i++) {
            await t.pump(const Duration(milliseconds: 250));
          }
        }

        for (var i = 1; i < 20; i++) {
          await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await t.pump(const Duration(milliseconds: 50));
          expect(editor.selection?.end.path, [
            i,
          ], reason: 'arrow down from line ${i - 1}');
        }
        await settle();
        expect(
          scroller.position.pixels,
          greaterThan(0),
          reason: 'auto-scroll should follow the caret',
        );

        for (var i = 18; i >= 0; i--) {
          await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
          await t.pump(const Duration(milliseconds: 50));
          expect(editor.selection?.end.path, [
            i,
          ], reason: 'arrow up from line ${i + 1}');
        }
        await settle();
        // Line 0's caret starts about 10 px down (6 px padding plus line
        // spacing); scrolled less than that, the caret is in view.
        expect(
          scroller.position.pixels,
          lessThan(10),
          reason: 'auto-scroll should follow the caret back up',
        );
        expect(c.page.node('n')!.bounds!.height, 60);
        expect(t.takeException(), isNull);
      }),
    );
  }

  // Touchpad two-finger scrolling arrives as pan/zoom events. A note that
  // scrolls takes the gesture; the canvas must not pan underneath it.
  for (final fixed in [true, false]) {
    testWidgets(
      'two-finger scroll over a ${fixed ? 'scrolling' : 'fitting'} note '
      '${fixed ? 'scrolls the note only' : 'pans the canvas'}',
      (t) async {
        var box = noteBox('n', [for (var i = 0; i < 30; i++) 'line $i']);
        if (fixed) {
          box = box
              .withBounds(const Bounds(100, 100, 300, 80))
              .withFixedHeight(true);
        }
        final c = await pump(t, page([box]));
        final canvas = t.state<PageCanvasState>(find.byType(PageCanvas));
        final v0 = canvas.view!;
        final b = c.page.node('n')!.bounds!;
        final scroller = t.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(BoxHost),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        final g = await t.startGesture(
          v0.toScreen(Offset(b.x + 150, b.y + 40)) + const Offset(0, CommandToolbar.height),
          kind: PointerDeviceKind.trackpad,
        );
        for (var i = 0; i < 10; i++) {
          await g.moveBy(const Offset(0, -10));
          await t.pump();
        }
        await g.up();
        await t.pumpAndSettle();
        if (fixed) {
          expect(scroller.position.pixels, greaterThan(0));
          expect(canvas.view!.offset, v0.offset);
        } else {
          expect(scroller.position.pixels, 0);
          expect(canvas.view!.offset, isNot(v0.offset));
        }
      },
    );
  }
}
