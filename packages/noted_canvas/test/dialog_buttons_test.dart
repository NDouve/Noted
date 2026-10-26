// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The Button guidelines for the conflict view: exactly one primary button per
// dialog, the proceeding action; the others are secondary or destructive.

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
  Widget buildEditor(BuildContext context, BoxContext<String> box) =>
      Text(box.data);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) =>
      Text(box.data);
}

BoxRecord _box(String text) => BoxRecord.create(
  id: 'a',
  typeId: 'test.text',
  dataVersion: 1,
  bounds: const Bounds(100, 100, 200, 60),
  data: RawJson.encode(text),
  snapshotText: text,
  rev: 'r-$text',
);

void main() {
  for (final brightness in Brightness.values) {
    group('in ${brightness.name} mode', () {
      final theme = notedThemeData(brightness);
      final scheme = theme.colorScheme;

      Future<void> open(WidgetTester t, BoxRecord box) async {
        t.view.physicalSize = const Size(1400, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final modules = ModuleRegistry()
          ..register(const _Module(), alwaysOn: true, isDefault: true);
        final c = CanvasController(
          NotedPage.create(
            PageMeta.create(id: 'p', title: '', order: 0),
          ).insertNode(box),
          modules,
        );
        await t.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(body: PageCanvas(controller: c)),
          ),
        );
        await t.pump();
        await t.tap(find.byKey(const ValueKey('conflict-badge-a')));
        await t.pumpAndSettle();
      }

      final conflicted = _box('mine').withConflict(
        BoxConflict.other(node: _box('theirs').toRaw(), at: 5),
      );
      final deleted = _box('mine').withConflict(BoxConflict.deleted(at: 5));

      testWidgets('the conflict view has one primary: Keep mine', (t) async {
        await open(t, conflicted);
        final dialog = find.byKey(const ValueKey('conflict-dialog'));
        final primaries = find.descendant(
          of: dialog,
          matching: find.byType(FilledButton),
        );
        expect(primaries, findsOneWidget);
        expect(
          find.descendant(of: primaries, matching: find.text('Keep mine')),
          findsOneWidget,
        );
        // The other resolutions are secondary, Cancel is a ghost button.
        for (final key in [
          'conflict-keep-theirs',
          'conflict-keep-both',
          'conflict-edit',
        ]) {
          expect(
            find.descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(Text),
            ),
            findsOneWidget,
          );
          expect(t.widget(find.byKey(ValueKey(key))), isA<OutlinedButton>());
        }
        expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
        // The primary fill is the accent.
        expect(
          theme.filledButtonTheme.style!.backgroundColor!.resolve({}),
          scheme.primary,
        );
      });

      testWidgets('a deleted conflict: Keep box primary, Delete box destructive', (
        t,
      ) async {
        await open(t, deleted);
        final dialog = find.byKey(const ValueKey('conflict-dialog'));
        expect(
          find.descendant(of: dialog, matching: find.byType(FilledButton)),
          findsOneWidget,
        );
        final del = find.byKey(const ValueKey('conflict-delete'));
        expect(t.widget(del), isA<OutlinedButton>());
        expect(
          DefaultTextStyle.of(
            t.element(find.descendant(of: del, matching: find.text('Delete box'))),
          ).style.color,
          scheme.error,
        );
      });

      testWidgets('Edit manually: Use this version is primary for this device', (
        t,
      ) async {
        await open(t, conflicted);
        await t.tap(find.byKey(const ValueKey('conflict-edit')));
        await t.pumpAndSettle();
        final dialog = find.byKey(const ValueKey('conflict-edit-dialog'));
        final primaries = find.descendant(
          of: dialog,
          matching: find.byType(FilledButton),
        );
        expect(primaries, findsOneWidget);
        expect(
          t.widget(find.byKey(const ValueKey('conflict-use-mine'))),
          isA<FilledButton>(),
        );
        expect(
          t.widget(find.byKey(const ValueKey('conflict-use-theirs'))),
          isA<OutlinedButton>(),
        );
      });
    });
  }
}
