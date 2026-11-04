// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'fake_store.dart';

void main() {
  late FakeStore store;
  late CanvasController c;
  final bytes = Uint8List.fromList(utf8.encode('payload'));
  final hash = contentHash(bytes);

  Future<void> openFile(WidgetTester t, String name, {String? storedAs}) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    store = FakeStore();
    final modules = ModuleRegistry()
      ..register(const ImageModule())
      ..register(const FileModule(), isDefault: true);
    var page = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
    if (storedAs != null) {
      final ref = AttachmentRef(
        name: name,
        size: bytes.length,
        hash: hash,
        file: storedAs,
      );
      const codec = FileCodec();
      store.folder[storedAs] = bytes;
      page = page.insertNode(
        BoxRecord.create(
          id: 'b',
          typeId: codec.typeId,
          dataVersion: codec.dataVersion,
          bounds: const Bounds(40, 40, 280, 64),
          data: RawJson.encode(codec.encode(FileData(ref: ref))),
          snapshotText: '',
          rev: 'r',
        ).withFixedHeight(true),
      );
    }
    c = CanvasController(page, modules);
    await t.pumpWidget(
      MaterialApp(
        theme: notedThemeData(Brightness.light),
        home: Scaffold(
          body: PageCanvas(controller: c, attachments: store),
        ),
      ),
    );
    if (storedAs == null) {
      await t.runAsync(
        () => t.state<PageCanvasState>(find.byType(PageCanvas)).insertFiles([
          IncomingFile(name, bytes),
        ], at: const Offset(40, 40)),
      );
    }
    await t.pump();
    final box = find.byKey(const ValueKey('file-box'));
    await t.tap(box);
    await t.pump(const Duration(milliseconds: 50));
    await t.tap(box);
    await t.pump(const Duration(milliseconds: 400));
  }

  // .jar is runnable on every platform.
  testWidgets('a runnable file asks first, naming it; Cancel opens nothing', (
    t,
  ) async {
    await openFile(t, 'tool.jar');
    expect(find.byKey(const ValueKey('open-confirm-dialog')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('open-confirm-dialog')),
        matching: find.text('tool.jar'),
      ),
      findsOneWidget,
    );
    expect(store.opened, isEmpty);
    await t.tap(find.byKey(const ValueKey('open-confirm-cancel')));
    await t.pumpAndSettle();
    expect(store.opened, isEmpty);
  });

  testWidgets('Escape cancels', (t) async {
    await openFile(t, 'tool.jar');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(store.opened, isEmpty);
  });

  testWidgets('Open opens it', (t) async {
    await openFile(t, 'tool.jar');
    await t.tap(find.byKey(const ValueKey('open-confirm-open')));
    await t.pumpAndSettle();
    expect(store.opened.single.$1, 'tool.jar');
  });

  testWidgets('a document opens without asking', (t) async {
    await openFile(t, 'plan.pdf');
    expect(find.byKey(const ValueKey('open-confirm-dialog')), findsNothing);
    expect(store.opened.single.$1, 'plan.pdf');
  });

  testWidgets('a harmless shown name stored under a runnable name asks', (
    t,
  ) async {
    await openFile(t, 'a.pdf', storedAs: '$hash.jar');
    expect(find.byKey(const ValueKey('open-confirm-dialog')), findsOneWidget);
    expect(store.opened, isEmpty);
  });

  testWidgets('the label on the canvas has no text-reordering characters', (t) async {
    await openFile(t, 'invoice\u202Efdp.pdf');
    final shown = (t.widget(find.byKey(const ValueKey('file-box-name'))) as Text).data!;
    expect(shown, isNot(contains('\u202E')));
    expect(shown, contains('invoice'));
  });

  testWidgets('the type line names the stored extension when that raised the question', (t) async {
    await openFile(t, 'a.pdf', storedAs: '$hash.jar');
    expect(find.text('Type: .jar'), findsOneWidget);
  });

  testWidgets(
    'the file is verified after the answer: a change while asking is caught',
    (t) async {
      await openFile(t, 'tool.jar', storedAs: '$hash.jar');
      expect(find.byKey(const ValueKey('open-confirm-dialog')), findsOneWidget);
      store.folder['$hash.jar'] = Uint8List.fromList(
        utf8.encode('swapped while the dialog was open'),
      );
      await t.tap(find.byKey(const ValueKey('open-confirm-open')));
      await t.pumpAndSettle();
      expect(
        store.opened,
        isEmpty,
        reason: 'the damaged file is not handed over',
      );
    },
  );
}
