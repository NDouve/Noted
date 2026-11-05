// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

BoxRecord _note(String id, List<Map<String, Object?>> delta) {
  const codec = NoteCodec();
  final data = NoteData({
    'document': {
      'type': 'page',
      'children': [
        {
          'type': 'paragraph',
          'data': {'delta': delta},
        },
      ],
    },
  });
  return BoxRecord.create(
    id: id,
    typeId: NoteCodec.id,
    dataVersion: 1,
    bounds: const Bounds(100, 100, 400, 40),
    data: RawJson.encode(codec.encode(data)),
    snapshotText: codec.snapshotText(data),
    rev: 'r',
  );
}

void main() {
  late CanvasController c;

  Future<void> frames(WidgetTester t, [int n = 6]) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pump(WidgetTester t, List<Map<String, Object?>> delta) async {
    t.view.physicalSize = const Size(1600, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final modules = ModuleRegistry()..register(const NoteModule(), alwaysOn: true, isDefault: true);
    c = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)).insertNode(_note('n', delta)),
      modules,
    );
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: noteLocalizationsDelegates,
        home: Scaffold(body: PageCanvas(controller: c)),
      ),
    );
    await t.pumpAndSettle();
  }

  PageCanvasState canvas(WidgetTester t) => t.state<PageCanvasState>(find.byType(PageCanvas));

  Future<EditorState> focusNote(WidgetTester t, {double dx = 20}) async {
    final b = c.page.node('n')!.bounds!;
    await t.tapAt(canvas(t).view!.toScreen(Offset(b.x + dx, b.y + 10)) + const Offset(0, CommandToolbar.height));
    await frames(t);
    expect(c.editingId, 'n');
    return t.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;
  }

  Future<void> ctrlK(WidgetTester t) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyK);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await frames(t);
  }

  List<Map<String, Object?>> delta(EditorState e) =>
      e.document.root.children.first.delta!.toJson().cast<Map<String, Object?>>();

  test('addresses without a scheme become https; linkAt finds the whole link', () {
    expect(normalizeLink('example.com'), 'https://example.com');
    expect(normalizeLink(' mailto:a@b.c '), 'mailto:a@b.c');
    expect(normalizeLink('   '), isNull);
    for (final p in [r'\\host\share\x.pdf', '//host/share/x.pdf', '/home/user/x.pdf', r'C:\x\y.pdf']) {
      expect(normalizeLink(' $p '), p, reason: 'a path is kept as typed');
    }
  });

  testWidgets('Ctrl+K links the selection to the address typed', (t) async {
    await pump(t, [
      {'insert': 'see the docs here'},
    ]);
    final editor = await focusNote(t);
    editor.selection = Selection.single(path: [0], startOffset: 8, endOffset: 12);
    await frames(t);
    await ctrlK(t);
    expect(find.text('Insert link'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('link-address')), 'docs.example.com');
    await t.tap(find.byKey(const ValueKey('link-save')));
    await frames(t);
    expect(delta(editor), [
      {'insert': 'see the '},
      {
        'insert': 'docs',
        'attributes': {'href': 'https://docs.example.com'},
      },
      {'insert': ' here'},
    ]);
    // The link reached the page.
    expect((c.page.node('n')! as BoxRecord).data!.text, contains('https://docs.example.com'));
  });

  testWidgets('Ctrl+K in a link edits it; Remove link takes it off', (t) async {
    await pump(t, [
      {'insert': 'a '},
      {
        'insert': 'link',
        'attributes': {'href': 'https://old.example'},
      },
      {'insert': ' b'},
    ]);
    final editor = await focusNote(t);
    editor.selection = Selection.collapsed(Position(path: [0], offset: 4));
    await frames(t);
    expect(linkAt(editor, editor.selection!.start)?.href, 'https://old.example');
    await ctrlK(t);
    expect(find.text('Edit link'), findsOneWidget);
    expect(find.text('https://old.example'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('link-address')), 'https://new.example');
    await t.tap(find.byKey(const ValueKey('link-save')));
    await frames(t);
    expect(delta(editor)[1], {
      'insert': 'link',
      'attributes': {'href': 'https://new.example'},
    });

    editor.selection = Selection.collapsed(Position(path: [0], offset: 3));
    await frames(t);
    await ctrlK(t);
    await t.tap(find.byKey(const ValueKey('link-remove')));
    await frames(t);
    expect(delta(editor).every((op) => op['attributes'] == null || (op['attributes']! as Map)['href'] == null), isTrue);
  });

  testWidgets('with a bare caret outside a link, the address is inserted as a link', (t) async {
    await pump(t, [
      {'insert': 'go: '},
    ]);
    final editor = await focusNote(t);
    editor.selection = Selection.collapsed(Position(path: [0], offset: 4));
    await frames(t);
    await ctrlK(t);
    await t.enterText(find.byKey(const ValueKey('link-address')), 'https://noted.example');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await frames(t);
    expect(delta(editor).last, {
      'insert': 'https://noted.example',
      'attributes': {'href': 'https://noted.example'},
    });
  });

  testWidgets('the Link command is enabled only in a note and opens the same dialog', (t) async {
    await pump(t, [
      {'insert': 'text'},
    ]);
    final link = canvas(t).commands[NoteCommands.link]!;
    expect(link.enabled, isFalse);
    expect(link.tooltip, 'Link (Ctrl+K)');
    await focusNote(t);
    expect(link.enabled, isTrue);
    await t.tap(find.byTooltip('Link (Ctrl+K)'));
    await frames(t);
    expect(find.text('Insert link'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await frames(t);
    expect(c.editingId, 'n', reason: 'the note is still being edited');
  });

  testWidgets('Ctrl+click on a link opens it', (t) async {
    final opened = <String>[];
    final before = linkOpener;
    linkOpener = (url) async => opened.add(url);
    addTearDown(() => linkOpener = before);
    await pump(t, [
      {
        'insert': 'linked words here',
        'attributes': {'href': 'https://open.example'},
      },
    ]);
    await focusNote(t, dx: 40);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final b = c.page.node('n')!.bounds!;
    await t.tapAt(canvas(t).view!.toScreen(Offset(b.x + 60, b.y + 14)) + const Offset(0, CommandToolbar.height));
    await frames(t);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(opened, ['https://open.example']);
  });

  group('opening a link with the real opener', () {
    final launched = <String>[];

    setUp(() {
      launched.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) async {
          if (call.method == 'launch') launched.add((call.arguments as Map)['url'] as String);
          return true;
        },
      );
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        null,
      );
    });

    Future<void> ctrlClick(WidgetTester t, String href) async {
      await pump(t, [
        {
          'insert': 'linked words here',
          'attributes': {'href': href},
        },
      ]);
      await focusNote(t, dx: 40);
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final b = c.page.node('n')!.bounds!;
      await t.tapAt(canvas(t).view!.toScreen(Offset(b.x + 60, b.y + 14)) + const Offset(0, CommandToolbar.height));
      await frames(t);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await frames(t);
    }

    testWidgets('a file: link to a program asks first; Cancel opens nothing', (t) async {
      await ctrlClick(t, 'file:///C:/tools/setup1.jar');
      expect(find.byKey(const ValueKey('open-confirm-dialog')), findsOneWidget);
      expect(launched, isEmpty);
      await t.tap(find.byKey(const ValueKey('open-confirm-cancel')));
      await frames(t);
      expect(launched, isEmpty);
    });

    testWidgets('a file: link to a program opens after Open', (t) async {
      await ctrlClick(t, 'file:///C:/tools/setup2.jar');
      await t.tap(find.byKey(const ValueKey('open-confirm-open')));
      await frames(t);
      expect(launched, hasLength(1));
    });

    testWidgets('a file: link to a document opens without asking', (t) async {
      await ctrlClick(t, 'file:///C:/docs/plan.pdf');
      expect(find.byKey(const ValueKey('open-confirm-dialog')), findsNothing);
      expect(launched, hasLength(1));
    });

    testWidgets('an https: link opens without asking', (t) async {
      await ctrlClick(t, 'https://open.example/setup.jar');
      expect(find.byKey(const ValueKey('open-confirm-dialog')), findsNothing);
      expect(launched, hasLength(1));
    });

    Future<void> lightCtrlClick(WidgetTester t, String href) async {
      await pump(t, [
        {
          'insert': 'linked words here',
          'attributes': {'href': href},
        },
      ]);
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final b = c.page.node('n')!.bounds!;
      await t.tapAt(canvas(t).view!.toScreen(Offset(b.x + 60, b.y + 14)) + const Offset(0, CommandToolbar.height));
      await frames(t);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await frames(t);
    }

    testWidgets('a Ctrl+click on a link in the light view asks too', (t) async {
      await lightCtrlClick(t, 'file:///C:/tools/light.jar');
      expect(c.editingId, isNull);
      expect(find.byKey(const ValueKey('open-confirm-dialog')), findsOneWidget);
      expect(launched, isEmpty);
      await t.tap(find.byKey(const ValueKey('open-confirm-cancel')));
      await frames(t);
      expect(launched, isEmpty);
    });

    testWidgets('Alt+Shift+Enter on a selected link asks too', (t) async {
      await pump(t, [
        {
          'insert': 'linked words here',
          'attributes': {'href': 'file:///C:/tools/keys.jar'},
        },
      ]);
      final editor = await focusNote(t, dx: 40);
      final node = editor.document.root.children.first;
      editor.selection = Selection.single(path: node.path, startOffset: 0, endOffset: 10);
      await frames(t);
      await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await frames(t);
      expect(find.byKey(const ValueKey('open-confirm-dialog')), findsOneWidget);
      expect(launched, isEmpty);
    });

    // Links that are paths without a file: scheme.
    for (final path in [r'C:\tools\path1.jar', 'C:/tools/path2.jar', r'\\host\share\path3.jar', '//host/share/path4.jar']) {
      testWidgets('the path $path asks first', (t) async {
        await pump(t, [
          {'insert': 'plain'},
        ]);
        unawaited(linkOpener(path));
        await frames(t);
        expect(find.byKey(const ValueKey('open-confirm-dialog')), findsOneWidget);
        expect(launched, isEmpty);
        await t.tap(find.byKey(const ValueKey('open-confirm-cancel')));
        await frames(t);
        expect(launched, isEmpty);
      });
    }

    for (final word in ['cmd', 'example.com']) {
      testWidgets('the bare address $word opens as http://, never as it is', (t) async {
        await pump(t, [
          {'insert': 'plain'},
        ]);
        await t.runAsync(() => linkOpener(word));
        expect(find.byKey(const ValueKey('open-confirm-dialog')), findsNothing);
        expect(launched, ['http://$word']);
      });
    }

    // Scheme-less paths clicked in the editor reach the file path, not http.
    for (final path in [r'\\host\share\click1.jar', '//host/share/click2.jar', '/home/user/click3.jar', r'C:\x\click4.jar']) {
      testWidgets('Ctrl+click on the path $path asks as a file', (t) async {
        await ctrlClick(t, path);
        expect(find.byKey(const ValueKey('open-confirm-dialog')), findsOneWidget);
        expect(find.byKey(const ValueKey('open-confirm-name')), findsOneWidget);
        expect(launched, isEmpty);
        await t.tap(find.byKey(const ValueKey('open-confirm-cancel')));
        await frames(t);
        expect(launched, isEmpty);
      });
    }

    testWidgets('Ctrl+click on a bare word still opens as http://', (t) async {
      await ctrlClick(t, 'example.com');
      expect(find.byKey(const ValueKey('open-confirm-dialog')), findsNothing);
      expect(launched, ['http://example.com']);
    });

    for (final link in ['ms-msdt:/id PCWDiagnostic', 'search-ms:query=x', 'shell:startup', 'javascript:alert(1)', 'weird-thing:x']) {
      testWidgets('Ctrl+click on $link asks, naming the scheme; Cancel opens nothing', (t) async {
        await ctrlClick(t, link);
        expect(find.text('Open this link?'), findsOneWidget);
        final scheme = link.substring(0, link.indexOf(':'));
        expect(t.widget<Text>(find.byKey(const ValueKey('open-confirm-scheme'))).data, '$scheme:');
        expect(launched, isEmpty);
        await t.tap(find.byKey(const ValueKey('open-confirm-cancel')));
        await frames(t);
        expect(launched, isEmpty);
      });
    }

    testWidgets('a scheme question opens the link after Open', (t) async {
      await ctrlClick(t, 'ms-msdt:/id x');
      await t.tap(find.byKey(const ValueKey('open-confirm-open')));
      await frames(t);
      expect(launched, hasLength(1));
    });

    testWidgets('Escape cancels a scheme question', (t) async {
      await ctrlClick(t, 'search-ms:query=y');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await frames(t);
      expect(find.byKey(const ValueKey('open-confirm-dialog')), findsNothing);
      expect(launched, isEmpty);
    });

    for (final link in ['https://a.example', 'http://a.example', 'mailto:a@b.example']) {
      testWidgets('Ctrl+click on $link opens without asking', (t) async {
        await ctrlClick(t, link);
        expect(find.byKey(const ValueKey('open-confirm-dialog')), findsNothing);
        expect(launched, hasLength(1));
      });
    }

    testWidgets('a noted: link asks too: nothing in the app handles it, so the system would', (t) async {
      await ctrlClick(t, 'noted:page/1');
      expect(find.text('Open this link?'), findsOneWidget);
      expect(launched, isEmpty);
    });

    // Relative text with a backslash is no path: never handed to the system.
    for (final rel in [r'x\..\calc', r'..\..\Windows\System32\calc', r'docs\plan.pdf', r'example.com\docs']) {
      testWidgets('Ctrl+click on the relative $rel opens nothing', (t) async {
        await ctrlClick(t, rel);
        expect(find.byKey(const ValueKey('open-confirm-dialog')), findsNothing);
        expect(launched, isEmpty);
        expect(find.text("This link can't be opened."), findsOneWidget);
      });
    }

    testWidgets('example.com\\docs typed into Ctrl+K is not a path: it gets https://', (t) async {
      expect(normalizeLink(r'example.com\docs'), r'https://example.com\docs');
      expect(normalizeLink(r'docs\plan.pdf'), r'https://docs\plan.pdf');
      await ctrlClick(t, normalizeLink(r'example.com\docs')!);
      expect(find.byKey(const ValueKey('open-confirm-dialog')), findsNothing);
      expect(launched.where((u) => !u.startsWith('http')), isEmpty);
    });

    testWidgets(
      'a drive path whose .. segments resolve to a program asks',
      (t) async {
        await ctrlClick(t, r'C:\tools\evil.jar\x\..');
        expect(find.byKey(const ValueKey('open-confirm-dialog')), findsOneWidget);
        expect(launched, isEmpty);
      },
      skip: !Platform.isWindows,
    );

    // A path typed into Ctrl+K is saved as typed, so Ctrl+click reaches the file check.
    for (final path in [r'\\host\share\typed1.jar', '//host/share/typed2.jar', '/home/user/typed3.jar', r'C:\x\typed4.jar']) {
      testWidgets('typing the path $path into Ctrl+K, then Ctrl+click, asks as a file', (t) async {
        await pump(t, [
          {'insert': 'linked words here'},
        ]);
        final editor = await focusNote(t, dx: 40);
        editor.selection = Selection.single(path: [0], startOffset: 0, endOffset: 10);
        await frames(t);
        await ctrlK(t);
        await t.enterText(find.byKey(const ValueKey('link-address')), path);
        await t.tap(find.byKey(const ValueKey('link-save')));
        await frames(t);
        expect(delta(editor).first['attributes'], {'href': path});
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        final b = c.page.node('n')!.bounds!;
        await t.tapAt(canvas(t).view!.toScreen(Offset(b.x + 60, b.y + 14)) + const Offset(0, CommandToolbar.height));
        await frames(t);
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await frames(t);
        expect(find.byKey(const ValueKey('open-confirm-name')), findsOneWidget);
        expect(launched, isEmpty);
      });
    }

    testWidgets('a scheme link in the light view asks too', (t) async {
      await lightCtrlClick(t, 'ms-msdt:/id light');
      expect(find.text('Open this link?'), findsOneWidget);
      expect(launched, isEmpty);
    });

    testWidgets('Alt+Shift+Enter on a scheme link asks too', (t) async {
      await pump(t, [
        {
          'insert': 'linked words here',
          'attributes': {'href': 'ms-msdt:/id keys'},
        },
      ]);
      final editor = await focusNote(t, dx: 40);
      final node = editor.document.root.children.first;
      editor.selection = Selection.single(path: node.path, startOffset: 0, endOffset: 10);
      await frames(t);
      await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await frames(t);
      expect(find.text('Open this link?'), findsOneWidget);
      expect(launched, isEmpty);
    });

    testWidgets('a path with a literal percent sign is not refused, but asks', (t) async {
      await pump(t, [
        {'insert': 'plain'},
      ]);
      unawaited(linkOpener(r'C:\docs\100%.txt'));
      await frames(t);
      expect(find.text("This link can't be opened."), findsNothing);
      expect(find.byKey(const ValueKey('open-confirm-dialog')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('open-confirm-open')));
      await frames(t);
      expect(launched, hasLength(1));
    });

    // The system decodes escapes before it runs a file: any % asks.
    for (final path in [
      r'C:\x\tool%2Ejar',
      'file:///C:/x/tool%252Ejar',
      r'\\host\share\x%2Ecmd',
      r'C:\x\%252E%252E\y.txt',
      r'C:\Windows\System32\calc%2Eexe',
    ]) {
      testWidgets('the escaped target $path asks; Cancel opens nothing', (t) async {
        await pump(t, [
          {'insert': 'plain'},
        ]);
        unawaited(linkOpener(path));
        await frames(t);
        expect(find.byKey(const ValueKey('open-confirm-dialog')), findsOneWidget);
        expect(launched, isEmpty);
        await t.tap(find.byKey(const ValueKey('open-confirm-cancel')));
        await frames(t);
        expect(launched, isEmpty);
      });
    }

    testWidgets('Ctrl+click on an escaped file: link asks', (t) async {
      await ctrlClick(t, 'file:///C:/x/calc%252Eexe');
      expect(find.byKey(const ValueKey('open-confirm-dialog')), findsOneWidget);
      expect(launched, isEmpty);
    });

    // An 8.3 short name can stand for a long runnable name.
    for (final path in [r'C:\x\PAYLOA~1.DIA', r'\\host\share\TOOL~1.APP', '/home/u/PROBE~2.TXT']) {
      testWidgets('the short name $path asks', (t) async {
        await pump(t, [
          {'insert': 'plain'},
        ]);
        unawaited(linkOpener(path));
        await frames(t);
        expect(find.byKey(const ValueKey('open-confirm-dialog')), findsOneWidget);
        expect(launched, isEmpty);
        await t.tap(find.byKey(const ValueKey('open-confirm-cancel')));
        await frames(t);
        expect(launched, isEmpty);
      });
    }

    // The dialog names what will run: decoded and resolved.
    for (final (path, name) in [
      (r'C:\Windows\System32\calc%2Eexe', 'calc.exe'),
      (r'C:\x\%252E%252E\evil.jar', 'evil.jar'),
    ]) {
      testWidgets('the dialog for $path shows $name', (t) async {
        await pump(t, [
          {'insert': 'plain'},
        ]);
        unawaited(linkOpener(path));
        await frames(t);
        expect(t.widget<Text>(find.byKey(const ValueKey('open-confirm-name'))).data, name);
        await t.tap(find.byKey(const ValueKey('open-confirm-cancel')));
        await frames(t);
      });
    }

    testWidgets('the dialog shows evil.jar for evil.jar with .. segments', (t) async {
      await pump(t, [
        {'insert': 'plain'},
      ]);
      unawaited(linkOpener(r'C:\tools\evil.jar\x\..'));
      await frames(t);
      expect(t.widget<Text>(find.byKey(const ValueKey('open-confirm-name'))).data, 'evil.jar');
      await t.tap(find.byKey(const ValueKey('open-confirm-cancel')));
      await frames(t);
    }, skip: !Platform.isWindows);

    // A query or an escaped ? must not hide a program's name.
    for (final path in ['file:///C:/x/probe.cmd?.pdf', r'C:\x\probe.cmd%3F.pdf']) {
      testWidgets('$path never launches without the question', (t) async {
        await pump(t, [
          {'insert': 'plain'},
        ]);
        unawaited(linkOpener(path));
        await frames(t);
        expect(launched, isEmpty);
        expect(
          find.byKey(const ValueKey('open-confirm-dialog')).evaluate().isNotEmpty ||
              find.text("This link can't be opened.").evaluate().isNotEmpty,
          isTrue,
        );
      });
    }

    testWidgets('c:foo.jar (a drive without a root) gets the notice on every platform', (t) async {
      await pump(t, [
        {'insert': 'plain'},
      ]);
      unawaited(linkOpener('c:foo.jar'));
      await frames(t);
      expect(find.byKey(const ValueKey('open-confirm-dialog')), findsNothing);
      expect(launched, isEmpty);
      expect(find.text("This link can't be opened."), findsOneWidget);
    });

    testWidgets('a name with a control character is refused with a notice', (t) async {
      await pump(t, [
        {'insert': 'plain'},
      ]);
      unawaited(linkOpener('file:///C:/tools/evil.jar%00.pdf'));
      await frames(t);
      expect(find.byKey(const ValueKey('open-confirm-dialog')), findsNothing);
      expect(launched, isEmpty);
      expect(find.text("This link can't be opened."), findsOneWidget);
    });
  });
}
