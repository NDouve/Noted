// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_template/noted_box_template.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'fixtures.dart';

void main() {
  late CanvasController c;

  Future<void> pump(
    WidgetTester t, {
    required String source,
    bool register = true,
    bool enabled = true,
  }) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final modules = ModuleRegistry();
    if (register) {
      modules.register(const StickyLabelModule(), enabled: enabled);
    }
    c = CanvasController(readPage(source), modules);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PageCanvas(controller: c)),
      ),
    );
  }

  BoxRecord box() => c.page.nodes.first as BoxRecord;

  testWidgets('switched on: shows the label editor', (t) async {
    await pump(t, source: pageSource());
    expect(find.byKey(const ValueKey('sticky-label-field')), findsOneWidget);
    expect(find.text('Buy milk'), findsOneWidget);
    expect(find.text('Editable on other devices'), findsNothing);
  });

  testWidgets('switched off: shows the snapshot, data untouched', (t) async {
    final source = pageSource();
    await pump(t, source: source, enabled: false);
    expect(find.byType(UnsupportedBoxView), findsOneWidget);
    expect(find.text('Editable on other devices'), findsOneWidget);
    expect(find.text('Buy milk'), findsOneWidget);
    expect(find.byKey(const ValueKey('sticky-label-field')), findsNothing);
    expect(writePage(c.page), contains(futureData));
  });

  testWidgets('module not registered: same snapshot, data passes through', (
    t,
  ) async {
    final source = pageSource();
    await pump(t, source: source, register: false);
    expect(find.byType(UnsupportedBoxView), findsOneWidget);
    expect(find.text('Buy milk'), findsOneWidget);
    expect(writePage(c.page), contains(labelNode()));
  });

  testWidgets('switching the module on with setEnabled', (t) async {
    await pump(t, source: pageSource(), enabled: false);
    expect(find.byType(UnsupportedBoxView), findsOneWidget);
    // The host caches what it resolved, so open the page again after the
    // switch, as the app does when a module is toggled in settings.
    c.modules.setEnabled(StickyLabelCodec.id, true);
    final reopened = CanvasController(c.page, c.modules);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageCanvas(key: UniqueKey(), controller: reopened),
        ),
      ),
    );
    await t.pump();
    expect(find.byKey(const ValueKey('sticky-label-field')), findsOneWidget);
  });

  testWidgets('editing commits and updates the snapshot', (t) async {
    await pump(t, source: pageSource());
    await t.enterText(
      find.byKey(const ValueKey('sticky-label-field')),
      'Buy oat milk',
    );
    await t.pump();
    expect(box().snapshotText, 'Buy oat milk');
    final stored = jsonDecode(box().data!.text) as Map;
    expect(stored['text'], 'Buy oat milk');
    // Unknown keys written by another version are still there.
    expect(stored['pin'], {
      'x': [1, 2.5],
    });
    expect(stored['z'], true);
  });

  testWidgets('choosing a colour commits it', (t) async {
    await pump(t, source: pageSource());
    await t.tap(find.byKey(const ValueKey('sticky-label-color-purple')));
    await t.pump();
    final stored = jsonDecode(box().data!.text) as Map;
    expect(stored['color'], 'purple');
    expect(stored['text'], 'Buy milk');
    expect(box().snapshotText, 'Buy milk');
  });

  testWidgets('renders in dark theme', (t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final modules = ModuleRegistry()..register(const StickyLabelModule());
    c = CanvasController(readPage(pageSource()), modules);
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(body: PageCanvas(controller: c, readOnly: true)),
      ),
    );
    expect(find.byKey(const ValueKey('sticky-label-text')), findsOneWidget);
  });
}
