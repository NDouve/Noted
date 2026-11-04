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
  const win = RunnablePlatform.windows;
  const mac = RunnablePlatform.macos;
  const lin = RunnablePlatform.linux;

  bool run(String n, RunnablePlatform p, {String? pathExt, bool bit = false}) =>
      isRunnableFileName(
        n,
        platform: p,
        pathExt: pathExt ?? '',
        executableBit: bit,
      );

  group('Windows', () {
    test('the fixed list, in any case', () {
      for (final e
          in 'exe bat cmd com ps1 vbs vbe js jse wsf wsh msc lnk url msi msp scr cpl hta pif reg jar'
              .split(' ')) {
        expect(run('x.$e', win), isTrue, reason: e);
        expect(run('X.${e.toUpperCase()}', win), isTrue, reason: e);
      }
    });
    test('PATHEXT adds extensions, parsed defensively', () {
      expect(run('x.py', win), isFalse);
      expect(run('x.py', win, pathExt: '.COM;.EXE;.PY'), isTrue);
      expect(run('x.rb', win, pathExt: ' ; .exe;;rb ;..;a b;.x/y'), isTrue);
      expect(run('x.xy', win, pathExt: ';.x/y;.a b'), isFalse);
      expect(pathExtExtensions(null), isEmpty);
    });
    test('a missing PATHEXT still uses the fixed list', () {
      expect(isRunnableFileName('a.exe', platform: win, pathExt: ''), isTrue);
    });
    test('trailing dots and spaces are stripped', () {
      expect(run('x.exe.', win), isTrue);
      expect(run('x.exe ', win), isTrue);
      expect(run('x.exe. . ', win), isTrue);
    });
    test('only the last extension counts', () {
      expect(run('report.pdf.exe', win), isTrue);
      expect(run('report.exe.pdf', win), isFalse);
    });
    test('documents and no extension are not runnable', () {
      expect(run('plan.pdf', win), isFalse);
      expect(run('README', win), isFalse);
      expect(run('', win), isFalse);
      expect(run('dir.exe/plan', win), isFalse);
    });
  });

  test('macOS list', () {
    for (final e
        in 'app command tool sh pkg mpkg dmg terminal workflow jar scpt applescript'
            .split(' ')) {
      expect(run('x.$e', mac), isTrue, reason: e);
    }
    expect(run('x.APP', mac), isTrue);
    expect(run('x.exe', mac), isFalse);
    expect(run('x.pdf', mac), isFalse);
  });

  test('Linux list and the permission bit', () {
    for (final e in 'sh run bin appimage desktop jar py pl'.split(' ')) {
      expect(run('x.$e', lin), isTrue, reason: e);
    }
    expect(run('x.AppImage', lin), isTrue);
    expect(run('x.exe', lin), isFalse);
    expect(run('x.pdf', lin), isFalse);
    expect(run('x.pdf', lin, bit: true), isTrue);
    expect(run('x.pdf', win, bit: true), isFalse);
  });

  test('either the shown name or the stored name asks', () {
    bool ask(String shown, String? stored) => needsOpenConfirmation(
      displayName: shown,
      storedName: stored,
      platform: win,
      pathExt: '',
    );
    expect(ask('a.exe', 'h.pdf'), isTrue);
    expect(ask('a.pdf', 'h.exe'), isTrue);
    expect(ask('a.pdf', 'h.pdf'), isFalse);
    expect(ask('a.pdf', null), isFalse);
  });

  group('the file box', () {
    late FakeStore store;
    late CanvasController c;
    final bytes = Uint8List.fromList(utf8.encode('payload'));

    Future<void> openFile(WidgetTester t, String name) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      store = FakeStore();
      final modules = ModuleRegistry()
        ..register(const ImageModule())
        ..register(const FileModule(), isDefault: true);
      c = CanvasController(
        NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)),
        modules,
      );
      await t.pumpWidget(
        MaterialApp(
          theme: notedThemeData(Brightness.light),
          home: Scaffold(
            body: PageCanvas(controller: c, attachments: store),
          ),
        ),
      );
      await t.runAsync(
        () => t.state<PageCanvasState>(find.byType(PageCanvas)).insertFiles([
          IncomingFile(name, bytes),
        ], at: const Offset(40, 40)),
      );
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
      expect(find.textContaining('"tool.jar"'), findsOneWidget);
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
  });
}
