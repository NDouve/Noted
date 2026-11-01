// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_ai/noted_box_ai.dart';
import 'package:noted_box_ai/src/ai_module.dart' show insertAiBox;
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

const ownerId = '0123456789abcdef';
const otherId = 'fedcba9876543210';

Map<String, Object?> para(String text) => {
  'type': 'paragraph',
  'data': {
    'delta': [
      {'insert': text},
    ],
  },
};

BoxRecord aiRecord(String id, List<Map<String, Object?>> blocks, {String? owner}) {
  const codec = AiCodec();
  final data = AiBoxData({
    'document': {'type': 'page', 'children': blocks},
    'owner': ?owner,
  });
  return commitBox(
    createBox(codec, const Bounds(100, 100, 360, 96)),
    codec,
    data,
  ).withId(id);
}

NotedPage pageOf(List<BoxRecord> boxes) {
  var p = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
  for (final b in boxes) {
    p = p.insertNode(b);
  }
  return p;
}

Map<String, Object?> storedOf(CanvasController c, String id) =>
    ((c.page.node(id)! as BoxRecord).data!.decode()! as Map).cast<String, Object?>();

List<Map<String, Object?>> storedBlocks(CanvasController c, String id) =>
    (((storedOf(c, id)['document']! as Map)['children']!) as List)
        .cast<Map<String, Object?>>();

void main() {
  late ValueNotifier<List<AiConnectionInfo>> connections;
  late ModuleRegistry modules;

  const mine = AiConnectionInfo(id: ownerId, name: 'Claude Code', createdAt: 1);
  const other = AiConnectionInfo(id: otherId, name: 'Notes helper', createdAt: 2);

  setUp(() {
    connections = ValueNotifier(const [mine, other]);
    modules = ModuleRegistry()
      ..register(const NoteModule(), alwaysOn: true, isDefault: true)
      ..register(AiModule(connections: connections));
  });

  tearDown(() => connections.dispose());

  Future<(CanvasController, GlobalKey<PageCanvasState>)> pump(
    WidgetTester t,
    NotedPage page, {
    Brightness brightness = Brightness.light,
    ToolbarArrangement layout = contextualToolbarLayout,
    bool readOnly = false,
  }) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = CanvasController(page, modules);
    final key = GlobalKey<PageCanvasState>();
    await t.pumpWidget(
      MaterialApp(
        theme: notedThemeData(brightness),
        localizationsDelegates: noteLocalizationsDelegates,
        home: Scaffold(
          body: PageCanvas(
            key: key,
            controller: c,
            readOnly: readOnly,
            toolbar: layout,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    return (c, key);
  }

  Finder marks() => find.byKey(const ValueKey('note-block-mark'));
  Text ownerText(WidgetTester t) =>
      t.widget<Text>(find.byKey(const ValueKey('ai-box-owner')));

  group('the box', () {
    testWidgets('has an AI label and shows its content', (t) async {
      await pump(t, pageOf([aiRecord('a', [para('hello')])]));
      expect(find.byKey(const ValueKey('ai-box-label')), findsOneWidget);
      expect(find.text('AI'), findsOneWidget);
      expect(find.textContaining('hello', findRichText: true), findsOneWidget);
    });

    for (final b in Brightness.values) {
      testWidgets('marks AI-written blocks only (${b.name})', (t) async {
        await pump(
          t,
          pageOf([
            aiRecord('a', [
              para('user line'),
              markAiWritten(para('ai line')),
            ]),
          ]),
          brightness: b,
        );
        expect(marks(), findsOneWidget);
        final bar = t.widget<DecoratedBox>(marks());
        final color = (bar.decoration as BoxDecoration).color!;
        expect(color.a, greaterThan(0));
        // The mark is the muted text color of the theme.
        final scheme = notedThemeData(b).colorScheme;
        expect(
          color.toARGB32(),
          scheme.onSurfaceVariant.withValues(alpha: 0.6).toARGB32(),
        );
      });
    }

    testWidgets('a mark that no longer matches the text is not drawn', (t) async {
      final stale = markAiWritten(para('before'));
      (((stale['data']! as Map)['delta']! as List).first as Map)['insert'] = 'after';
      await pump(t, pageOf([aiRecord('a', [stale])]));
      expect(marks(), findsNothing);
    });

    testWidgets('the mark takes no room', (t) async {
      final (c, _) = await pump(
        t,
        pageOf([
          aiRecord('plain', [para('same text')]),
          aiRecord('marked', [markAiWritten(para('same text'))]).withBounds(
            const Bounds(600, 100, 360, 96),
          ),
        ]),
      );
      expect(
        c.page.node('plain')!.bounds!.height,
        c.page.node('marked')!.bounds!.height,
      );
    });
  });

  group('Connected AI', () {
    testWidgets('shows the owner by name', (t) async {
      await pump(t, pageOf([aiRecord('a', [para('x')], owner: ownerId)]));
      expect(ownerText(t).data, 'Claude Code');
    });

    testWidgets('no owner, or an owner that is not listed: No connected AI', (
      t,
    ) async {
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      expect(ownerText(t).data, 'No connected AI');
      await pump(
        t,
        pageOf([aiRecord('a', [para('x')], owner: 'aaaaaaaaaaaaaaaa')]),
      );
      expect(ownerText(t).data, 'No connected AI');
    });

    testWidgets('a revoked connection leaves the box user-owned, content kept', (
      t,
    ) async {
      final (c, _) = await pump(
        t,
        pageOf([aiRecord('a', [markAiWritten(para('kept'))], owner: ownerId)]),
      );
      expect(ownerText(t).data, 'Claude Code');
      connections.value = const [other];
      await t.pump();
      expect(ownerText(t).data, 'No connected AI');
      expect(find.textContaining('kept', findRichText: true), findsOneWidget);
      expect(marks(), findsOneWidget);
      expect(storedBlocks(c, 'a'), hasLength(1));
    });

    testWidgets('the menu lists the connections and None', (t) async {
      await pump(t, pageOf([aiRecord('a', [para('x')], owner: ownerId)]));
      await t.tap(find.byKey(const ValueKey('ai-box-picker')));
      await t.pumpAndSettle();
      expect(find.text('Claude Code'), findsWidgets);
      expect(find.byKey(const ValueKey('ai-owner-$ownerId')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-owner-$otherId')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-owner-none')), findsOneWidget);
      expect(find.text('None'), findsOneWidget);
    });

    testWidgets('with no connections the menu offers None only', (t) async {
      connections.value = const [];
      await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await t.tap(find.byKey(const ValueKey('ai-box-picker')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-owner-none')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-owner-$ownerId')), findsNothing);
    });

    testWidgets('choosing one commits its id, content untouched', (t) async {
      final (c, _) = await pump(t, pageOf([aiRecord('a', [para('x')])]));
      await t.tap(find.byKey(const ValueKey('ai-box-picker')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ai-owner-$otherId')));
      await t.pumpAndSettle();
      final stored = storedOf(c, 'a');
      expect(stored['owner'], otherId);
      expect(storedBlocks(c, 'a'), hasLength(1));
      expect(ownerText(t).data, 'Notes helper');
      // Never a secret: the stored data holds nothing but the id.
      expect(stored.keys.toSet(), {'document', 'owner'});
    });

    testWidgets('None removes the owner', (t) async {
      final (c, _) = await pump(
        t,
        pageOf([aiRecord('a', [para('x')], owner: ownerId)]),
      );
      await t.tap(find.byKey(const ValueKey('ai-box-picker')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ai-owner-none')));
      await t.pumpAndSettle();
      expect(storedOf(c, 'a').containsKey('owner'), isFalse);
      expect(ownerText(t).data, 'No connected AI');
    });

    testWidgets('a read-only page shows the owner but no menu', (t) async {
      await pump(
        t,
        pageOf([aiRecord('a', [para('x')], owner: ownerId)]),
        readOnly: true,
      );
      expect(ownerText(t).data, 'Claude Code');
      expect(find.byKey(const ValueKey('ai-box-picker')), findsNothing);
    });
  });

  group('editing', () {
    EditorState editorOf(WidgetTester t) =>
        t.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;

    Future<EditorState> edit(WidgetTester t, {int path = 0, int? offset}) async {
      await t.tap(find.textContaining('ai one', findRichText: true));
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      final editor = editorOf(t);
      final node = editor.getNodeAtPath([path])!;
      editor.selection = Selection.collapsed(
        Position(path: [path], offset: offset ?? node.delta!.length),
      );
      await t.pump();
      return editor;
    }

    testWidgets('typing in an AI block ends its mark and strips the tag', (
      t,
    ) async {
      final (c, _) = await pump(
        t,
        pageOf([
          aiRecord('a', [
            markAiWritten(para('ai one')),
            markAiWritten(para('ai two')),
          ], owner: ownerId),
        ]),
      );
      expect(marks(), findsNWidgets(2));
      final editor = await edit(t, path: 0);
      await editor.insertTextAtCurrentSelection('!');
      await t.pump(const Duration(milliseconds: 50));
      await t.pump(const Duration(milliseconds: 50));

      final blocks = storedBlocks(c, 'a');
      expect(isAiWritten(blocks[0]), isFalse);
      expect((blocks[0]['data']! as Map).containsKey('noted_ai'), isFalse);
      expect(isAiWritten(blocks[1]), isTrue);
      expect(marks(), findsOneWidget);
      // The owner survives editing.
      expect(storedOf(c, 'a')['owner'], ownerId);
    });

    testWidgets('a block the user adds never carries a valid mark', (t) async {
      final (c, _) = await pump(
        t,
        pageOf([aiRecord('a', [markAiWritten(para('ai one'))], owner: ownerId)]),
      );
      final editor = await edit(t);
      await editor.insertNewLine();
      await editor.insertTextAtCurrentSelection('mine');
      await t.pump(const Duration(milliseconds: 50));
      await t.pump(const Duration(milliseconds: 50));

      final blocks = storedBlocks(c, 'a');
      expect(blocks, hasLength(2));
      expect(isAiWritten(blocks[0]), isTrue);
      expect(isAiWritten(blocks[1]), isFalse);
      expect((blocks[1]['data']! as Map).containsKey('noted_ai'), isFalse);
      expect(marks(), findsOneWidget);
    });

    testWidgets('turning an AI paragraph into a heading ends the mark', (
      t,
    ) async {
      final (c, _) = await pump(
        t,
        pageOf([aiRecord('a', [markAiWritten(para('ai one'))])]),
      );
      final editor = await edit(t);
      final node = editor.getNodeAtPath([0])!;
      await editor.apply(
        editor.transaction
          ..updateNode(node, {'level': 1})
          ..insertNode(
            [1],
            Node(type: 'heading', attributes: {...node.attributes, 'level': 1}),
          )
          ..deleteNode(node),
      );
      await t.pump(const Duration(milliseconds: 50));
      await t.pump(const Duration(milliseconds: 50));
      final blocks = storedBlocks(c, 'a');
      expect(blocks.single['type'], 'heading');
      expect(isAiWritten(blocks.single), isFalse);
      expect((blocks.single['data']! as Map).containsKey('noted_ai'), isFalse);
    });

    testWidgets('a rebuild between two edits keeps the same editor', (t) async {
      final (c, _) = await pump(
        t,
        pageOf([aiRecord('a', [para('ai one')], owner: ownerId)]),
      );
      final first = await edit(t);
      await first.insertTextAtCurrentSelection('1');
      await t.pump(const Duration(milliseconds: 100));

      // Choosing another owner rebuilds the box.
      await t.tap(find.byKey(const ValueKey('ai-box-picker')));
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(milliseconds: 500));
      await t.tap(find.byKey(const ValueKey('ai-owner-$otherId')));
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(milliseconds: 500));
      expect(storedOf(c, 'a')['owner'], otherId);

      final second = editorOf(t);
      expect(identical(second, first), isTrue);
      second.selection = Selection.collapsed(
        Position(path: [0], offset: second.getNodeAtPath([0])!.delta!.length),
      );
      await t.pump();
      await second.insertTextAtCurrentSelection('2');
      await t.pump(const Duration(milliseconds: 100));
      expect(identical(editorOf(t), first), isTrue);
      expect(aiBlockText(storedBlocks(c, 'a').single), 'ai one12');
    });

    testWidgets('an AI write of content the editor had restarts it', (t) async {
      const codec = AiCodec();
      AiBoxData write(CanvasController c) => codec.aiWrite(
        codec.decode((c.page.node('a')! as BoxRecord).data!.decode(), 1),
        AiWrite(connectionId: ownerId, content: 'A', mode: AiWriteMode.replace),
      )!;
      final (c, _) = await pump(t, pageOf([aiRecord('a', [para('')], owner: ownerId)]));
      c.replaceBoxData({'a': write(c)});
      await t.pumpAndSettle();

      // The user types "!" after the AI's "A": the box stores "A!".
      await t.tap(find.text('A', findRichText: true).last);
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      var editor = editorOf(t);
      editor.selection = Selection.collapsed(Position(path: [0], offset: 1));
      await t.pump();
      await editor.insertTextAtCurrentSelection('!');
      await t.pump(const Duration(milliseconds: 100));
      expect(aiBlockText(storedBlocks(c, 'a').single), 'A!');

      // The AI writes "A" again; the editor starts over from it.
      c.replaceBoxData({'a': write(c)});
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(aiBlockText(storedBlocks(c, 'a').single), 'A');
      if (find.byType(AppFlowyEditor).evaluate().isEmpty) {
        await t.tap(find.text('A', findRichText: true).last);
        for (var i = 0; i < 5; i++) {
          await t.pump(const Duration(milliseconds: 50));
        }
      }
      editor = editorOf(t);
      editor.selection = Selection.collapsed(Position(path: [0], offset: 1));
      await t.pump();
      await editor.insertTextAtCurrentSelection('x');
      await t.pump(const Duration(milliseconds: 100));
      // Based on the AI's write, not on the "A!" the editor had.
      expect(aiBlockText(storedBlocks(c, 'a').single), 'Ax');
    });

    testWidgets('a box being edited stays edited through an AI write, so Escape still leaves it', (t) async {
      const codec = AiCodec();
      final (c, _) = await pump(t, pageOf([aiRecord('a', [para('B')], owner: ownerId)]));
      await t.tap(find.text('B', findRichText: true).last);
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(c.editingId, 'a');

      c.replaceBoxData({
        'a': codec.aiWrite(
          codec.decode((c.page.node('a')! as BoxRecord).data!.decode(), 1),
          AiWrite(connectionId: ownerId, content: 'A', mode: AiWriteMode.replace),
        )!,
      });
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(c.editingId, 'a');
      expect(find.byType(AppFlowyEditor), findsOneWidget);
      final focus = FocusManager.instance.primaryFocus;
      expect(
        focus?.context != null &&
            find.descendant(of: find.byType(AppFlowyEditor), matching: find.byWidget(focus!.context!.widget)).evaluate().isNotEmpty,
        isTrue,
        reason: 'the new editor has the focus',
      );

      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(c.editingId, isNull);
    });

    testWidgets('an AI write into a box not being edited takes no focus', (t) async {
      const codec = AiCodec();
      final (c, _) = await pump(t, pageOf([aiRecord('a', [para('B')], owner: ownerId)]));
      expect(c.editingId, isNull);
      final before = FocusManager.instance.primaryFocus;
      c.replaceBoxData({
        'a': codec.aiWrite(
          codec.decode((c.page.node('a')! as BoxRecord).data!.decode(), 1),
          AiWrite(connectionId: ownerId, content: 'A', mode: AiWriteMode.replace),
        )!,
      });
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(c.editingId, isNull);
      expect(FocusManager.instance.primaryFocus, before);
      expect(find.byType(AppFlowyEditor), findsNothing, reason: 'still the light view');
    });

    testWidgets('an AI write shows in the open box at once', (t) async {
      final (c, _) = await pump(t, pageOf([aiRecord('a', [para('')], owner: ownerId)]));
      expect(marks(), findsNothing);
      const codec = AiCodec();
      final box = c.page.node('a')! as BoxRecord;
      final data = codec.decode(box.data!.decode(), 1);
      final next = codec.aiWrite(
        data,
        AiWrite(connectionId: ownerId, content: 'from the AI', mode: AiWriteMode.replace),
      )!;
      c.editBox('a', next);
      await t.pumpAndSettle();
      expect(find.textContaining('from the AI', findRichText: true), findsOneWidget);
      expect(marks(), findsOneWidget);
    });
  });

  group('insert command', () {
    testWidgets('inserts an AI box and selects it', (t) async {
      final (c, key) = await pump(t, pageOf([]));
      final cmd = key.currentState!.commands[AiCommands.insert]!;
      expect(cmd.label, 'AI box');
      expect(cmd.icon, Icons.auto_awesome_rounded);
      expect(cmd.enabled, isTrue);
      await cmd.run();
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(c.page.nodes, hasLength(1));
      final box = c.page.nodes.single as BoxRecord;
      expect(box.typeId, aiBoxTypeId);
      expect(c.selectedId, box.id);
      expect(find.byKey(const ValueKey('ai-box-label')), findsOneWidget);
      expect(storedOf(c, box.id).containsKey('owner'), isFalse);
    });

    testWidgets('with no view, and a page whose only node has no bounds, '
        'the box goes at the margin', (t) async {
      final foreign = ForeignNode.read(
        RawJson.trusted('{"id":"f"}'),
        fallbackId: 'f',
      );
      expect(foreign.bounds, isNull);
      final c = CanvasController(pageOf([]).insertNode(foreign), modules);
      insertAiBox(c, null);
      final added = c.page.nodes.whereType<BoxRecord>().single;
      expect(added.bounds.x, 40);
      expect(added.bounds.y, 40);
      expect(added.typeId, aiBoxTypeId);
    });

    testWidgets('is centred on the view, selected and focused', (t) async {
      final (c, key) = await pump(t, pageOf([aiRecord('a', [para('x')])]));
      final centre = key.currentState!.viewCentre!;
      await key.currentState!.commands[AiCommands.insert]!.run();
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      final added = c.page.nodes.firstWhere((n) => n.id != 'a');
      final b = added.bounds!;
      expect(b.x + b.width / 2, closeTo(centre.dx, 1));
      expect(b.y + b.height / 2, closeTo(centre.dy, 25));
      expect(c.selectedId, added.id);
      expect(c.editingId, added.id);
    });

    testWidgets('an owner can be picked right after inserting', (t) async {
      final (c, key) = await pump(t, pageOf([]));
      await key.currentState!.commands[AiCommands.insert]!.run();
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.tap(find.byKey(const ValueKey('ai-box-picker')));
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(milliseconds: 500));
      await t.tap(find.byKey(const ValueKey('ai-owner-$ownerId')));
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(milliseconds: 500));
      expect(c.page.nodes, hasLength(1));
      expect(storedOf(c, c.page.nodes.single.id)['owner'], ownerId);
    });

    for (final layout in [tabbedToolbarLayout, contextualToolbarLayout]) {
      testWidgets('replaces the placeholder in the ${layout.runtimeType}', (
        t,
      ) async {
        await pump(t, pageOf([]), layout: layout);
        t.view.physicalSize = const Size(2400, 800);
        await t.pumpAndSettle();
        if (layout is TabbedToolbarLayout) {
          await t.tap(find.byKey(CommandToolbar.tabKey('insert')));
          await t.pump();
        }
        expect(find.byKey(const ValueKey(AiCommands.insert)), findsOneWidget);
        expect(find.byTooltip('AI box (coming later)'), findsNothing);
        expect(find.text('AI box'), findsOneWidget);
      });
    }

    testWidgets('without the module the placeholder stays', (t) async {
      modules = ModuleRegistry()
        ..register(const NoteModule(), alwaysOn: true, isDefault: true);
      final (_, key) = await pump(t, pageOf([]));
      expect(
        key.currentState!.commands[AiCommands.insert]!.label,
        'AI box (coming later)',
      );
    });
  });
}
