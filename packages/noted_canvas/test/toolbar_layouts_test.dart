// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';

// The two built-in toolbars, drawn from a registry of stand-in commands with
// the real ids.
void main() {
  late CommandRegistry registry;
  late ValueNotifier<bool> pen;
  late ValueNotifier<bool> caret;

  Command cmd(
    String id, {
    ValueNotifier<bool>? checked,
    ValueNotifier<bool>? enabled,
    bool readOnly = false,
  }) => Command(
    id: id,
    label: id,
    icon: Icons.circle,
    checked: checked == null ? null : () => checked.value,
    enabled: enabled == null ? null : () => enabled.value,
    listenable: Listenable.merge([?checked, ?enabled]),
    whileReadOnly: readOnly,
    invoke: () {},
  );

  setUp(() {
    pen = ValueNotifier(false);
    caret = ValueNotifier(false);
    const view = {
      'canvas.zoomOut',
      'canvas.zoomReset',
      'canvas.zoomIn',
      'canvas.fitAll',
      'canvas.pageBackground',
      'canvas.find',
      'app.search',
    };
    final ids = <String>{
      for (final l in [tabbedToolbarLayout, contextualToolbarLayout])
        ...switch (l) {
          TabbedToolbarLayout() => [
            ...l.leading.expand((g) => g),
            ...l.tabs.expand((t) => t.groups.expand((g) => g)),
            ...l.trailing.expand((g) => g),
          ],
          ContextualToolbarLayout() => [
            ...l.leading.expand((g) => g),
            ...l.sections.expand((s) => s.groups.expand((g) => g)),
            ...l.trailing.expand((g) => g),
          ],
        },
    }..removeAll(toolbarPlaceholders.keys);
    registry = CommandRegistry()
      ..registerAll([
        for (final id in ids)
          cmd(
            id,
            checked: id == 'noted.drawing.pen' ? pen : null,
            enabled: id.startsWith('noted.note.') ? caret : null,
            readOnly: view.contains(id),
          ),
      ]);
    registry.registerAll(placeholderCommands(registry));
  });

  tearDown(() {
    registry.dispose();
    pen.dispose();
    caret.dispose();
  });

  Future<void> pump(
    WidgetTester t,
    ToolbarArrangement layout, {
    bool readOnly = false,
    Brightness brightness = Brightness.light,
  }) async {
    t.view.physicalSize = const Size(2400, 600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: notedThemeData(brightness),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: CommandToolbar(
              registry: registry,
              layout: layout,
              readOnly: readOnly,
            ),
          ),
        ),
      ),
    );
  }

  bool shown(String id) => find.byKey(ValueKey(id)).evaluate().isNotEmpty;

  group('Tabs', () {
    testWidgets('Home is chosen first; each tab shows its own commands', (
      t,
    ) async {
      await pump(t, tabbedToolbarLayout);
      for (final tab in ['home', 'insert', 'draw', 'view']) {
        expect(find.byKey(CommandToolbar.tabKey(tab)), findsOneWidget);
      }
      expect(shown('noted.note.bold'), isTrue);
      expect(shown('noted.note.insertTable'), isFalse);

      final cases = {
        'insert': ['noted.note.insertTable', 'noted.ai.insert'],
        'draw': ['noted.drawing.pen', 'noted.drawing.lasso', 'noted.drawing.color.0'],
        'view': ['canvas.zoomIn', 'canvas.fitAll', 'canvas.find'],
        'home': ['noted.note.bold', 'noted.note.clearFormatting'],
      };
      for (final MapEntry(key: tab, value: ids) in cases.entries) {
        await t.tap(find.byKey(CommandToolbar.tabKey(tab)));
        await t.pump();
        for (final id in ids) {
          expect(shown(id), isTrue, reason: '$id on $tab');
        }
        // Undo, Redo and Search stay.
        for (final id in ['canvas.undo', 'canvas.redo', 'app.search']) {
          expect(shown(id), isTrue, reason: '$id on $tab');
        }
        if (tab != 'draw') expect(shown('noted.drawing.pen'), isFalse);
      }
      expect(t.takeException(), isNull);
    });

    testWidgets('two rows: the tabs above a 52px bar', (t) async {
      await pump(t, tabbedToolbarLayout);
      final h = t.getSize(find.byType(CommandToolbar)).height;
      expect(h, CommandToolbar.heightFor(tabbedToolbarLayout));
      expect(CommandToolbar.heightFor(tabbedToolbarLayout), 40 + 52);
      // Undo sits on the row of the tabs, Bold on the bar under it.
      final tab = t.getCenter(find.byKey(CommandToolbar.tabKey('home')));
      expect(t.getCenter(find.byKey(const ValueKey('canvas.undo'))).dy, tab.dy);
      expect(
        t.getCenter(find.byKey(const ValueKey('noted.note.bold'))).dy,
        greaterThan(tab.dy + 20),
      );
      // Search at the far right.
      expect(
        t.getCenter(find.byKey(const ValueKey('app.search'))).dx,
        greaterThan(t.getCenter(find.byKey(CommandToolbar.tabKey('view'))).dx),
      );
    });

    testWidgets('placeholders are disabled and say "coming later"', (t) async {
      await pump(t, tabbedToolbarLayout);
      await t.tap(find.byKey(CommandToolbar.tabKey('insert')));
      await t.pump();
      for (final label in ['Image', 'File', 'AI box', 'Encrypted box']) {
        final b = find.descendant(
          of: find.byTooltip('$label (coming later)'),
          matching: find.byType(TextButton),
        );
        expect(t.widget<TextButton>(b).onPressed, isNull, reason: label);
      }
      await t.tap(find.byKey(CommandToolbar.tabKey('draw')));
      await t.pump();
      for (final tip in ['Highlighter (coming later)', 'Lasso select (coming later)']) {
        final b = find.ancestor(
          of: find.byTooltip(tip),
          matching: find.byType(IconButton),
        );
        expect(t.widget<IconButton>(b).onPressed, isNull, reason: tip);
      }
    });

    testWidgets('on a read-only page only View is left', (t) async {
      await pump(t, tabbedToolbarLayout, readOnly: true);
      expect(find.byKey(CommandToolbar.tabKey('home')), findsNothing);
      expect(find.byKey(CommandToolbar.tabKey('view')), findsOneWidget);
      expect(shown('canvas.fitAll'), isTrue);
      expect(shown('app.search'), isTrue);
      expect(shown('canvas.undo'), isFalse);
    });
  });

  group('Contextual', () {
    Finder section(String id) => find.byKey(CommandToolbar.sectionKey(id));

    testWidgets('one 52px bar; tools and history left, view right', (t) async {
      await pump(t, contextualToolbarLayout);
      expect(t.getSize(find.byType(CommandToolbar)).height, 52);
      double x(String id) => t.getCenter(find.byKey(ValueKey(id))).dx;
      expect(x('canvas.select'), lessThan(x('noted.drawing.pen')));
      expect(x('noted.drawing.eraser'), lessThan(x('canvas.undo')));
      expect(x('canvas.redo'), lessThan(t.getCenter(section('insert')).dx));
      expect(t.getCenter(section('insert')).dx, lessThan(x('app.search')));
      expect(x('app.search'), lessThan(x('canvas.fitAll')));
      expect(x('canvas.fitAll'), lessThan(x('canvas.zoomReset')));
      expect(x('canvas.zoomReset'), lessThan(x('canvas.pageBackground')));
    });

    testWidgets('the middle swaps: insert, text with a caret, ink with the pen', (
      t,
    ) async {
      await pump(t, contextualToolbarLayout);
      expect(section('insert'), findsOneWidget);
      expect(shown('noted.ai.insert'), isTrue);
      expect(shown('noted.note.bold'), isFalse);

      caret.value = true;
      await t.pump();
      expect(section('text'), findsOneWidget);
      expect(section('insert'), findsNothing);
      expect(shown('noted.note.bold'), isTrue);
      expect(shown('noted.note.insertTable'), isTrue);

      pen.value = true;
      await t.pump();
      expect(section('pen'), findsOneWidget);
      expect(shown('noted.drawing.color.0'), isTrue);
      expect(shown('noted.drawing.width.8'), isTrue);
      expect(shown('noted.note.bold'), isFalse);

      pen.value = false;
      caret.value = false;
      await t.pump();
      expect(section('insert'), findsOneWidget);
      // The ends never change.
      for (final id in ['canvas.select', 'canvas.undo', 'app.search', 'canvas.zoomReset']) {
        expect(shown(id), isTrue, reason: id);
      }
    });

    for (final b in Brightness.values) {
      testWidgets('the middle is shaded with surface-hover (${b.name})', (
        t,
      ) async {
        await pump(t, contextualToolbarLayout, brightness: b);
        final box = t.widget<Container>(section('insert')).decoration! as BoxDecoration;
        expect(box.color, notedThemeData(b).colorScheme.surfaceContainerHighest);
        expect(box.color, isNot(notedThemeData(b).colorScheme.surface));
      });
    }
  });
}
