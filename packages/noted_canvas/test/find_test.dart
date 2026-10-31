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

/// Shows its text and records what Find on page told it.
class _TextModule extends BoxModule<String> {
  const _TextModule();
  @override
  BoxCodec<String> get codec => const _TextCodec();
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) =>
      _Box(box: box);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) =>
      _Box(box: box);
}

class _Box extends StatelessWidget {
  const _Box({required this.box});
  final BoxContext<String> box;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<BoxFind?>(
    valueListenable: box.find,
    builder: (context, f, _) {
      final ranges = f?.query.rangesIn(box.data);
      final cur = f?.currentBoxId == box.boxId ? f!.currentOccurrence : -1;
      return Text(
        '${box.data}|${ranges?.length ?? 0}|$cur',
        key: ValueKey('box-${box.boxId}'),
      );
    },
  );
}

BoxRecord textBox(String id, String text, double x, double y,
    {double w = 200, double h = 60}) {
  return BoxRecord.create(
    id: id,
    typeId: 'test.text',
    dataVersion: 1,
    bounds: Bounds(x, y, w, h),
    data: RawJson.encode(text),
    snapshotText: text,
    rev: 'r',
  );
}

void main() {
  late ModuleRegistry modules;
  setUp(() {
    modules = ModuleRegistry()
      ..register(const _TextModule(), alwaysOn: true, isDefault: true);
  });

  NotedPage page(List<BoxRecord> boxes) {
    var p = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
    for (final b in boxes) {
      p = p.insertNode(b);
    }
    return p;
  }

  Future<(CanvasController, GlobalKey<PageCanvasState>)> pump(
    WidgetTester t,
    NotedPage p, {
    bool readOnly = false,
  }) async {
    t.view.physicalSize = const Size(1000, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = CanvasController(p, modules);
    final key = GlobalKey<PageCanvasState>();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageCanvas(key: key, controller: c, readOnly: readOnly),
        ),
      ),
    );
    await t.pump();
    await t.pump();
    return (c, key);
  }

  final threeBoxes = [
    textBox('a', 'Alpha beta', 0, 0),
    textBox('b', 'beta gamma beta', 0, 1200),
    textBox('c', 'delta', 2400, 100),
  ];

  testWidgets('Ctrl+F opens the bar; typing counts matches', (t) async {
    final (_, key) = await pump(t, page(threeBoxes));
    expect(find.byKey(const ValueKey('find-bar')), findsNothing);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey('find-bar')), findsOneWidget);
    expect(key.currentState!.find.isOpen, isTrue);

    await t.enterText(find.byKey(const ValueKey('find-field')), 'beta');
    await t.pump();
    // Alpha beta (1) and beta gamma beta (2).
    expect(find.text('1 of 3'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('find-field')), 'zzz');
    await t.pump();
    expect(find.text('No matches'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('find-field')), 'beta gamma');
    await t.pump();
    expect(find.text('1 of 3'), findsOneWidget, reason: 'words are ANDed per box');
    await t.enterText(find.byKey(const ValueKey('find-field')), '"gamma beta"');
    await t.pump();
    expect(find.text('1 of 1'), findsOneWidget);
  });

  testWidgets('modules are told the query and which match is current', (t) async {
    final (_, key) = await pump(t, page(threeBoxes));
    key.currentState!.find.open(text: 'beta');
    await t.pump();
    await t.pump();
    // Box a: 1 match, current 0; box b: 2 matches, not current (-1).
    expect(find.text('Alpha beta|1|0'), findsOneWidget);
    expect(find.text('beta gamma beta|2|-1'), findsOneWidget);
    key.currentState!.find.step(1);
    await t.pump();
    expect(find.text('Alpha beta|1|-1'), findsOneWidget);
    expect(find.text('beta gamma beta|2|0'), findsOneWidget);
    key.currentState!.find.step(1);
    await t.pump();
    expect(find.text('beta gamma beta|2|1'), findsOneWidget);
    // Wraps around.
    key.currentState!.find.step(1);
    await t.pump();
    expect(find.text('Alpha beta|1|0'), findsOneWidget);
  });

  testWidgets('boxes with a match are framed, the current one more strongly',
      (t) async {
    final (_, key) = await pump(t, page(threeBoxes));
    key.currentState!.find.open(text: 'beta');
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey('find-frame-current')), findsOneWidget);
    // Box b is far away and may not be built, but a framed box that is built
    // is either current or a plain match; delta never is.
    final framed = find.byKey(const ValueKey('find-frame-current')).evaluate().length +
        find.byKey(const ValueKey('find-frame-match')).evaluate().length;
    expect(framed, inInclusiveRange(1, 2));
    key.currentState!.find.close();
    await t.pump();
    expect(find.byKey(const ValueKey('find-frame-current')), findsNothing);
    expect(find.byKey(const ValueKey('find-frame-match')), findsNothing);
    // Closed: modules get no find state.
    expect(find.text('Alpha beta|0|-1'), findsOneWidget);
  });

  testWidgets('Enter and Shift+Enter step; the view follows the match',
      (t) async {
    final (_, key) = await pump(t, page(threeBoxes));
    final state = key.currentState!;
    state.find.open(text: 'beta');
    await t.pump();
    await t.pump();
    expect(find.text('1 of 3'), findsOneWidget);
    final first = state.view!;

    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(find.text('2 of 3'), findsOneWidget);
    // Box b is at y 1200: the view moved down to it, with no zoom change.
    final second = state.view!;
    expect(second.scale, first.scale);
    final visible = second.visible(const Size(1000, 700 - CommandToolbar.height));
    expect(visible.overlaps(const Rect.fromLTWH(0, 1200, 200, 60)), isTrue);
    expect(visible.overlaps(const Rect.fromLTWH(0, 0, 200, 60)), isFalse);

    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(find.text('3 of 3'), findsOneWidget);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    expect(find.text('2 of 3'), findsOneWidget);
    // Up and down buttons.
    await t.tap(find.byKey(const ValueKey('find-next')));
    await t.pump();
    expect(find.text('3 of 3'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('find-previous')));
    await t.pump();
    expect(find.text('2 of 3'), findsOneWidget);
    // Back on the first box, the view returns to it.
    await t.tap(find.byKey(const ValueKey('find-previous')));
    await t.pump();
    final back = state.view!.visible(const Size(1000, 700 - CommandToolbar.height));
    expect(back.overlaps(const Rect.fromLTWH(0, 0, 200, 60)), isTrue);
  });

  testWidgets('a box that does not fit zooms out; it never zooms in',
      (t) async {
    final big = textBox('big', 'needle', 0, 0, w: 2400, h: 2400);
    final small = textBox('small', 'needle', 3000, 0, w: 100, h: 40);
    final (_, key) = await pump(t, page([small, big]));
    final state = key.currentState!;
    // Order is top to bottom, left to right: big, then small.
    state.find.open(text: 'needle');
    await t.pump();
    await t.pump();
    final v = state.view!;
    expect(v.scale, lessThan(0.5));
    final vis = v.visible(const Size(1000, 700 - CommandToolbar.height));
    expect(vis.contains(const Offset(0, 0)), isTrue);
    expect(vis.contains(const Offset(2400, 2400)), isTrue);
    // Stepping to the small box at a low zoom does not zoom in.
    final before = v.scale;
    state.find.step(1);
    await t.pump();
    expect(state.view!.scale, before);
    // From 100%, the big box (next, wrapping) zooms out again.
    state.zoomTo(1);
    await t.pump();
    expect(state.view!.scale, 1);
    state.find.step(1);
    await t.pump();
    expect(state.view!.scale, lessThan(0.5));
  });

  testWidgets('Esc closes the bar and clears the highlights', (t) async {
    final (_, key) = await pump(t, page(threeBoxes));
    key.currentState!.find.open(text: 'beta');
    await t.pump();
    await t.pump();
    expect(find.text('Alpha beta|1|0'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.byKey(const ValueKey('find-bar')), findsNothing);
    expect(key.currentState!.find.isOpen, isFalse);
    expect(find.text('Alpha beta|0|-1'), findsOneWidget);
    expect(find.byKey(const ValueKey('find-frame-current')), findsNothing);
  });

  testWidgets('typing in the bar never deletes the selected box', (t) async {
    final (c, key) = await pump(t, page(threeBoxes));
    c.select('a');
    key.currentState!.find.open(text: 'abc');
    await t.pump();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.backspace);
    await t.pump();
    expect(c.page.node('a'), isNotNull);
  });

  testWidgets('F3 and Shift+F3 step, and open the bar when it is closed',
      (t) async {
    final (_, key) = await pump(t, page(threeBoxes));
    await t.sendKeyEvent(LogicalKeyboardKey.f3);
    await t.pump();
    expect(key.currentState!.find.isOpen, isTrue);
    key.currentState!.find.setText('beta');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.f3);
    await t.pump();
    expect(find.text('2 of 3'), findsOneWidget);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.f3);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    expect(find.text('1 of 3'), findsOneWidget);
  });

  testWidgets('Find works on a read-only page', (t) async {
    final (_, key) = await pump(t, page(threeBoxes), readOnly: true);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(key.currentState!.find.isOpen, isTrue);
  });

  testWidgets('a request from the app opens the bar with the text and match',
      (t) async {
    final requests = ValueNotifier<FindRequest?>(null);
    t.view.physicalSize = const Size(1000, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = CanvasController(page(threeBoxes), modules);
    final key = GlobalKey<PageCanvasState>();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageCanvas(key: key, controller: c, findRequests: requests),
        ),
      ),
    );
    await t.pump();
    // For another page: left alone.
    requests.value = const FindRequest(pageId: 'other', text: 'beta');
    await t.pump();
    expect(key.currentState!.find.isOpen, isFalse);
    expect(requests.value, isNotNull);
    requests.value = const FindRequest(
      pageId: 'p',
      text: 'beta',
      boxId: 'b',
      occurrence: 1,
    );
    await t.pump();
    await t.pump();
    expect(requests.value, isNull);
    final f = key.currentState!.find;
    expect(f.isOpen, isTrue);
    expect(f.text, 'beta');
    expect(f.currentMatch!.boxId, 'b');
    expect(f.currentMatch!.occurrence, 1);
    expect(find.text('3 of 3'), findsOneWidget);
  });

  testWidgets('extra commands from the app are in the registry and toolbar',
      (t) async {
    t.view.physicalSize = const Size(1000, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var ran = 0;
    final c = CanvasController(page(threeBoxes), modules);
    final key = GlobalKey<PageCanvasState>();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageCanvas(
            key: key,
            controller: c,
            extraCommands: () => [
              Command(
                id: 'app.search',
                label: 'Search all pages',
                icon: Icons.manage_search_rounded,
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyF,
                  control: true,
                  shift: true,
                ),
                whileEditing: true,
                whileReadOnly: true,
                invoke: () => ran++,
              ),
            ],
          ),
        ),
      ),
    );
    await t.pump();
    expect(key.currentState!.commands['app.search'], isNotNull);
    expect(find.byKey(const ValueKey('app.search')), findsOneWidget);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(ran, 1);
    // Ctrl+Shift+F is not Ctrl+F.
    expect(key.currentState!.find.isOpen, isFalse);
  });

  test('both toolbars always show Search; Find on page is on View', () {
    expect(tabbedToolbarLayout.trailing.expand((g) => g), contains('app.search'));
    expect(
      tabbedToolbarLayout.tabs.last.groups.expand((g) => g),
      containsAll(['canvas.find', 'canvas.fitAll']),
    );
    expect(contextualToolbarLayout.trailing.expand((g) => g), containsAll(['app.search', 'canvas.fitAll']));
  });
}
