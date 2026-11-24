// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/import/import_dialog.dart';
import 'package:noted/src/import/import_format.dart';

void main() {
  const none = ImportCapabilities();
  const all = ImportCapabilities(pdfPages: true, sheetImages: true, wordPageImages: true, slideImages: true);

  List<String> labels(ImportFormat f, [ImportCapabilities caps = none]) => [
    for (final o in importOptions(f, caps)) o.choice.label,
  ];

  test('the choices of each format, in order', () {
    expect(labels(ImportFormat.text), ['As text', 'As a file']);
    expect(labels(ImportFormat.markdown), ['As text', 'As a file']);
    expect(labels(ImportFormat.word), ['As text', 'As an image', 'As a file']);
    expect(labels(ImportFormat.sheet), ['As a table', 'As an image', 'As a file']);
    expect(labels(ImportFormat.csv), ['As a table', 'As an image', 'As a file']);
    expect(labels(ImportFormat.pdf), ['Pages as images', 'As a file']);
    expect(labels(ImportFormat.slides), ['Slides as images', 'As a file']);
    expect(importOptions(ImportFormat.image, none), isEmpty);
  });

  test('off choices say why; the image choices are off until a renderer is there', () {
    String? off(ImportFormat f, ImportChoice c, [ImportCapabilities caps = none]) =>
        importOptions(f, caps).firstWhere((o) => o.choice == c).off;
    expect(off(ImportFormat.word, ImportChoice.asImage), "This device can't show Word pages as images");
    expect(off(ImportFormat.slides, ImportChoice.slidesAsImages), "This device can't show slides as images");
    expect(off(ImportFormat.pdf, ImportChoice.pagesAsImages), "This device can't show PDF pages as images");
    expect(off(ImportFormat.sheet, ImportChoice.asImage), "This device can't show sheets as images");
    expect(off(ImportFormat.pdf, ImportChoice.pagesAsImages, all), isNull);
    expect(off(ImportFormat.sheet, ImportChoice.asImage, all), isNull);
  });

  test('a type the page disallows is off', () {
    final o = importOptions(ImportFormat.sheet, all, disallowed: {'noted.image'});
    expect(o.map((e) => e.off), [null, 'Not allowed on this page', null]);
    expect(importOptions(ImportFormat.text, none, disallowed: {'noted.file'}).last.off, 'Not allowed on this page');
  });

  test('a switched-off module\'s choices are off', () {
    final o = importOptions(ImportFormat.sheet, all, switchedOff: {'noted.image'});
    expect(o.map((e) => e.off), [null, 'Switched off', null]);
    expect(importAsks(ImportFormat.pdf, all, const {}, {'noted.image'}), isFalse);
  });

  test('only a format with a choice besides a file asks', () {
    expect(importAsks(ImportFormat.text, none, const {}), isTrue);
    expect(importAsks(ImportFormat.sheet, none, const {}), isTrue);
    expect(importAsks(ImportFormat.pdf, none, const {}), isFalse, reason: 'no renderer: a file box, as before');
    expect(importAsks(ImportFormat.pdf, all, const {}), isTrue);
    expect(importAsks(ImportFormat.slides, none, const {}), isFalse);
    expect(importAsks(ImportFormat.image, all, const {}), isFalse);
    expect(importAsks(ImportFormat.word, none, const {'noted.image'}), isTrue);
  });

  Future<void> open(WidgetTester t, void Function(ImportDecision?) result, List<ImportOption> options, {int more = 0}) async {
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result(await showImportDialog(context, fileName: 'book.xlsx', options: options, more: more)),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
  }

  testWidgets('the first enabled choice is the default; off choices show their text and can not be chosen', (t) async {
    ImportDecision? got;
    await open(t, (d) => got = d, importOptions(ImportFormat.sheet, none));
    expect(find.text('book.xlsx'), findsOneWidget);
    expect(find.text('As a table'), findsOneWidget);
    expect(find.text("This device can't show sheets as images"), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('import-choice-asImage')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('import-ok')));
    await t.pumpAndSettle();
    expect(got!.choice, ImportChoice.asTable, reason: 'the off choice did not take');
    expect(got!.useForAll, isFalse);
  });

  testWidgets('another choice, and Use for all only with more files', (t) async {
    ImportDecision? got;
    await open(t, (d) => got = d, importOptions(ImportFormat.sheet, none));
    expect(find.byKey(const ValueKey('import-use-all')), findsNothing);
    await t.tap(find.byKey(const ValueKey('import-choice-asFile')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('import-ok')));
    await t.pumpAndSettle();
    expect(got!.choice, ImportChoice.asFile);

    got = null;
    await open(t, (d) => got = d, importOptions(ImportFormat.sheet, none), more: 2);
    await t.tap(find.byKey(const ValueKey('import-use-all')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('import-ok')));
    await t.pumpAndSettle();
    expect(got!.choice, ImportChoice.asTable);
    expect(got!.useForAll, isTrue);
  });

  testWidgets('Cancel gives null; with every choice off, Import is off', (t) async {
    var called = false;
    ImportDecision? got = const ImportDecision(ImportChoice.asFile);
    await open(t, (d) {
      called = true;
      got = d;
    }, importOptions(ImportFormat.text, none));
    await t.tap(find.byKey(const ValueKey('import-cancel')));
    await t.pumpAndSettle();
    expect(called, isTrue);
    expect(got, isNull);

    await open(t, (_) {}, importOptions(ImportFormat.pdf, none, disallowed: {'noted.file'}));
    expect(t.widget<FilledButton>(find.byKey(const ValueKey('import-ok'))).onPressed, isNull);
  });
}
