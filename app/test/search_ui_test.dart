// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

const _codec = NoteCodec();

BoxRecord noteBox(String id, List<String> lines, {double y = 40}) {
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
    bounds: Bounds(40, y, 360, 60),
    data: RawJson.encode(_codec.encode(data)),
    snapshotText: _codec.snapshotText(data),
    rev: 'r',
  );
}

NotedPage notePage(
  String id,
  String title,
  List<List<String>> boxes, {
  String? parent,
  int order = 0,
}) {
  var p = NotedPage.create(
    PageMeta.create(id: id, parentId: parent, title: title, order: order),
  );
  for (final (i, lines) in boxes.indexed) {
    p = p.insertNode(noteBox('$id-b$i', lines, y: 40 + i * 400.0));
  }
  return p;
}

void main() {
  late Directory root;
  late Directory pages;
  late Directory work;
  late Notebook nb;

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
  }

  Future<void> until(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
    await t.pump(const Duration(milliseconds: 50));
  }

  Future<void> start(WidgetTester t, {bool broken = false}) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.runAsync(() async {
      root = await Directory.systemTemp.createTemp('noted_search_ui');
      pages = await Directory('${root.path}/pages').create();
      work = await Directory('${root.path}/Work').create();
      final store = PageStore(pages);
      await store.save(
        notePage('alpha', 'Alpha', [
          ['Meeting notes about the budget'],
          ['Second box mentions the budget again'],
        ]),
      );
      await store.save(notePage('beta', 'Beta', [['Nothing relevant']], order: 1));
      await store.save(notePage('gamma', 'Gamma', [['The Budget is final']], order: 2));
      if (broken) File('${pages.path}/broken.canvas').writeAsStringSync('not a page');
      nb = Notebook(
        store,
        buildModules(),
        saveDelay: Duration.zero,
        bindersFile: File('${root.path}/binders.json'),
      );
      await nb.load();
      final binder = await nb.addBinder(work.path);
      await PageStore(work).save(notePage('projects', 'Projects', [['top of the binder']]));
      await PageStore(work).save(
        notePage('plan', 'Plan', [['Annual budget review']], parent: 'projects'),
      );
      await nb.removeBinder(binder.path);
      await nb.addBinder(work.path);
      await nb.open('alpha');
    });
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: noteLocalizationsDelegates,
        home: Home(notebook: nb),
      ),
    );
    await settle(t);
  }

  Future<void> finish(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await settle(t);
    await t.runAsync(() async {
      await nb.flush();
      nb.dispose();
      await root.delete(recursive: true);
    });
  }

  Future<void> ctrlShift(WidgetTester t, LogicalKeyboardKey key) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(key);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
  }

  bool fieldFocused(WidgetTester t) =>
      t.widget<TextField>(find.byKey(const ValueKey('search-field'))).focusNode!.hasFocus;

  Future<void> search(WidgetTester t, String text) async {
    await t.enterText(find.byKey(const ValueKey('search-field')), text);
    for (var i = 0; i < 6; i++) {
      await settle(t);
    }
    await settle(t);
    await settle(t);
  }

  testWidgets('results are grouped by page, with the path and a marked snippet', (t) async {
    await start(t);
    expect(find.byKey(const ValueKey('search-results')), findsNothing);
    await search(t, 'budget');

    // Alpha (two boxes), Gamma, and the binder's Plan, in sidebar order.
    expect(find.byKey(const ValueKey('search-page-alpha')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-page-gamma')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-page-plan')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-page-beta')), findsNothing);
    final alpha = t.getTopLeft(find.byKey(const ValueKey('search-page-alpha'))).dy;
    final gamma = t.getTopLeft(find.byKey(const ValueKey('search-page-gamma'))).dy;
    final plan = t.getTopLeft(find.byKey(const ValueKey('search-page-plan'))).dy;
    expect(alpha, lessThan(gamma));
    expect(gamma, lessThan(plan));

    // Two snippets under Alpha, one under each other page.
    expect(find.byKey(const ValueKey('search-result-alpha-alpha-b0')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-result-alpha-alpha-b1')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-result-gamma-gamma-b0')), findsOneWidget);

    // The path: "Pages / Alpha"; the binder page is "Work / Projects / Plan".
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('search-page-title-plan')),
        matching: find.textContaining('Work / Projects / ', findRichText: true),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('search-page-title-alpha')),
        matching: find.textContaining('Pages / ', findRichText: true),
      ),
      findsOneWidget,
    );

    // The match is marked in the snippet (case kept).
    final scheme = Theme.of(t.element(find.byType(Scaffold))).colorScheme;
    final marked = <String>[];
    final snippet = find.descendant(
      of: find.byKey(const ValueKey('search-result-gamma-gamma-b0')),
      matching: find.byType(RichText),
    );
    t.widget<RichText>(snippet.first).text.visitChildren((s) {
      if (s is TextSpan && s.style?.backgroundColor == scheme.tertiaryContainer) {
        marked.add(s.text!);
      }
      return true;
    });
    expect(marked, ['Budget']);
    await finish(t);
  });

  testWidgets('clicking a snippet opens the page with Find on page on that match', (t) async {
    await start(t);
    await search(t, 'budget');
    await t.tap(find.byKey(const ValueKey('search-result-plan-plan-b0')));
    await until(t, () => nb.currentId == 'plan');
    await settle(t);
    expect(nb.currentId, 'plan');
    // The find bar is open with the search text, and the match is current.
    expect(find.byKey(const ValueKey('find-bar')), findsOneWidget);
    expect(t.widget<TextField>(find.byKey(const ValueKey('find-field'))).controller!.text, 'budget');
    expect(find.text('1 of 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('find-frame-current')), findsOneWidget);
    // And the word is highlighted in the note.
    final scheme = Theme.of(t.element(find.byType(Scaffold))).colorScheme;
    final marks = <String>[];
    for (final w in t.widgetList<RichText>(find.byType(RichText))) {
      w.text.visitChildren((s) {
        if (s is TextSpan && s.style?.backgroundColor == scheme.tertiary) marks.add(s.text!);
        return true;
      });
    }
    expect(marks, ['budget']);
    await finish(t);
  });

  testWidgets('clicking a result on the open page highlights the clicked box', (t) async {
    await start(t);
    await search(t, 'budget');
    await t.tap(find.byKey(const ValueKey('search-result-alpha-alpha-b1')));
    await settle(t);
    expect(nb.currentId, 'alpha');
    expect(find.byKey(const ValueKey('find-bar')), findsOneWidget);
    // Two matches on Alpha; the second box's is current.
    expect(find.text('2 of 2'), findsOneWidget);
    // The view moved to it (it is 400 px below the first box).
    await finish(t);
  });

  testWidgets('Enter opens the first result; Escape clears the search', (t) async {
    await start(t);
    await search(t, 'final');
    await t.tap(find.byKey(const ValueKey('search-field')));
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await until(t, () => nb.currentId == 'gamma');
    expect(nb.currentId, 'gamma');
    await settle(t);
    await t.tap(find.byKey(const ValueKey('search-field')));
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.byKey(const ValueKey('search-results')), findsNothing);
    expect(t.widget<TextField>(find.byKey(const ValueKey('search-field'))).controller!.text, '');
    // The page tree is back.
    expect(find.byKey(const ValueKey('page-row-alpha')), findsOneWidget);
    await finish(t);
  });

  testWidgets('no results, and pages that could not be read are listed', (t) async {
    await start(t, broken: true);
    await search(t, 'zzzznothing');
    expect(find.byKey(const ValueKey('search-empty')), findsOneWidget);
    final listed = find.byKey(const ValueKey('search-not-searched'));
    expect(listed, findsOneWidget);
    expect(find.text('NOT SEARCHED'), findsOneWidget);
    expect(
      find.descendant(of: listed, matching: find.textContaining('broken', findRichText: true)),
      findsOneWidget,
    );
    await finish(t);
  });

  testWidgets('Ctrl+Shift+F focuses the search field from the canvas', (t) async {
    await start(t);
    expect(fieldFocused(t), isFalse);
    await ctrlShift(t, LogicalKeyboardKey.keyF);
    await t.pump();
    expect(fieldFocused(t), isTrue);
    await finish(t);
  });

  testWidgets('Ctrl+Shift+F and Ctrl+F work while a note editor has focus', (t) async {
    await start(t);
    // Put the caret in the note (no pumpAndSettle once an editor is focused).
    await t.tap(find.textContaining('Meeting notes', findRichText: true));
    await t.pump();
    await t.pump();
    expect(nb.current!.editingId, isNotNull);

    await ctrlShift(t, LogicalKeyboardKey.keyF);
    await t.pump();
    expect(fieldFocused(t), isTrue, reason: 'the editor does not swallow Ctrl+Shift+F');
    // The note was not changed by the shortcut.
    final box = nb.current!.page.nodes.whereType<BoxRecord>().first;
    expect(box.snapshotText, 'Meeting notes about the budget');

    // Back in the note: Ctrl+F opens Find on page, not the editor's own.
    await t.tap(find.textContaining('Meeting notes', findRichText: true));
    await t.pump();
    await t.pump();
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey('find-bar')), findsOneWidget);
    expect(find.byType(FindBar), findsOneWidget);
    await finish(t);
  });

  testWidgets('the toolbar has a Search button that focuses the field', (t) async {
    await start(t);
    final button = find.byKey(const ValueKey('app.search'));
    expect(button, findsOneWidget);
    // In the view group, after the page background.
    final fit = t.getCenter(find.byKey(const ValueKey('canvas.fitAll'))).dx;
    expect(t.getCenter(button).dx, greaterThan(fit));
    await t.tap(button);
    await t.pump();
    await t.pump();
    expect(fieldFocused(t), isTrue);
    await finish(t);
  });
}
