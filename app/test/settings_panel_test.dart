// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/ai/ai_access_service.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_tree_view.dart';
import 'package:noted/src/settings_panel.dart';
import 'package:noted_box_ai/noted_box_ai.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_box_template/noted_box_template.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/real_io.dart';
import 'support/settle_saves.dart';

void main() {
  late Directory root;
  late AiAccessService service;
  late Notebook nb;
  late String a;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_settings');
    final data = await Directory('${root.path}/app').create();
    service = AiAccessService(dataFolder: data);
    nb = Notebook(
      PageStore(await Directory('${root.path}/pages').create()),
      buildModules(aiAccess: service),
      saveDelay: Duration.zero,
      bindersFile: File('${data.path}/binders.json'),
      aiAccess: service,
    );
    await nb.load();
    a = nb.currentId!;
  });

  tearDown(() async {
    await nb.flush();
    nb.dispose();
    service.dispose();
    await root.delete(recursive: true);
  });

  // Pumps the panel of a page or binder on its own.
  Future<void> pumpPanel(WidgetTester t, Widget panel, {double width = 1000}) async {
    t.view.physicalSize = Size(width, 1800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: panel)));
    await t.pump();
  }

  // Taps with real IO allowed to finish.
  Future<void> tap(WidgetTester t, String key) async {
    await t.runAsync(() async {
      await t.tap(find.byKey(ValueKey(key)));
      await realIoPause(50);
    });
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
  }

  bool selected(WidgetTester t, String key) => t.widget<ChoiceChip>(find.byKey(ValueKey(key))).selected;

  // Real file IO needs the real clock in a widget test.
  Future<T> io<T>(WidgetTester t, Future<T> Function() f) async => (await t.runAsync(f)) as T;

  Future<BinderSection> binder(WidgetTester t, String name) => io(t, () async {
    final dir = await Directory('${root.path}/$name').create();
    return nb.addBinder(dir.path);
  });

  group('AI access', () {
    testWidgets('a page shows what it inherits and from where', (t) async {
      final b = await binder(t, 'Work');
      await io(t, () => nb.setBinderAiAccess(b.path, AiAccess.privileged));
      final page = await io(t, () => nb.createPage(binderPath: b.path));
      await pumpPanel(t, SettingsPanel.page(notebook: nb, pageId: page));

      expect(find.text('Same as binder (Privileged)'), findsOneWidget);
      expect(selected(t, 'settings-ai-inherit'), isTrue);
      expect(find.textContaining('Now: Privileged, from the binder'), findsOneWidget);

      // A subpage of a page that tightened further: source is the parent.
      final sub = await io(t, () => nb.createPage(parentId: page));
      await io(t, () => nb.setAiAccess(page, AiAccess.guarded));
      await pumpPanel(t, SettingsPanel.page(notebook: nb, pageId: sub));
      expect(find.text('Same as parent (Guarded)'), findsOneWidget);
      expect(find.textContaining('Now: Guarded, from the parent page'), findsOneWidget);
    });

    testWidgets('a page offers only values that tighten what it inherits', (t) async {
      final b = await binder(t, 'Work');
      await io(t, () => nb.setBinderAiAccess(b.path, AiAccess.privileged));
      final page = await io(t, () => nb.createPage(binderPath: b.path));
      await pumpPanel(t, SettingsPanel.page(notebook: nb, pageId: page));

      expect(find.byKey(const ValueKey('settings-ai-open')), findsNothing, reason: 'looser: not offered');
      // The value equal to the inherited one is the pin, labelled as such.
      expect(find.text('Same as binder (Privileged)'), findsOneWidget);
      expect(find.text('Privileged (keep even if the binder changes)'), findsOneWidget);
      expect(find.text('Privileged'), findsNothing, reason: 'not listed twice under one name');
      expect(find.byKey(const ValueKey('settings-ai-guarded')), findsOneWidget);

      // Pinning: own == inherited is stored, selected, and survives the binder changing.
      await tap(t, 'settings-ai-privileged');
      expect(nb.ownAiAccess(page), AiAccess.privileged);
      expect(selected(t, 'settings-ai-privileged'), isTrue);
      expect(selected(t, 'settings-ai-inherit'), isFalse);
      await io(t, () => nb.setBinderAiAccess(b.path, AiAccess.guarded));
      expect(nb.aiAccessFor(page).value, AiAccess.guarded, reason: 'tightening only: stricter binder wins');
      await io(t, () => nb.setBinderAiAccess(b.path, AiAccess.open));
      expect(nb.aiAccessFor(page).value, AiAccess.privileged, reason: 'the pin holds when the binder loosens');
      await io(t, () => nb.setBinderAiAccess(b.path, AiAccess.privileged));

      await tap(t, 'settings-ai-guarded');
      expect(nb.ownAiAccess(page), AiAccess.guarded);
      expect(selected(t, 'settings-ai-guarded'), isTrue);
      expect(find.textContaining('Now: Guarded, set on this page'), findsOneWidget);
      await tap(t, 'settings-ai-inherit');
      expect(nb.ownAiAccess(page), isNull);
    });

    testWidgets('at 400 px no choice is cut off with an ellipsis', (t) async {
      final b = await binder(t, 'Work');
      await io(t, () => nb.setBinderAiAccess(b.path, AiAccess.privileged));
      final page = await io(t, () => nb.createPage(binderPath: b.path));
      await pumpPanel(t, SettingsPanel.page(notebook: nb, pageId: page), width: 400);

      final pin = find.byKey(const ValueKey('settings-ai-privileged'));
      expect(pin, findsOneWidget);
      final label = find.descendant(of: pin, matching: find.byType(Text));
      final box = t.renderObject<RenderParagraph>(label);
      // The long label wraps to a second line instead of ending in an ellipsis.
      expect(box.getMaxIntrinsicWidth(double.infinity), greaterThan(box.size.width));
      expect(box.size.height, greaterThan(30));
      expect(box.didExceedMaxLines, isFalse);
      expect(t.takeException(), isNull);
      // Every chip's text is shown whole: no paragraph wider than its chip.
      for (final chip in find.byType(ChoiceChip).evaluate()) {
        final c = find.byWidget(chip.widget);
        final p = t.renderObject<RenderParagraph>(find.descendant(of: c, matching: find.byType(Text)).first);
        expect(p.didExceedMaxLines, isFalse);
        expect(t.getRect(c).right, lessThanOrEqualTo(400));
      }
    });

    testWidgets('a top-level standalone page may choose any value', (t) async {
      await pumpPanel(t, SettingsPanel.page(notebook: nb, pageId: a));
      for (final s in AiAccess.values) {
        expect(find.byKey(ValueKey('settings-ai-${s.value}')), findsOneWidget);
      }
      expect(find.text('App default (Guarded)'), findsOneWidget);
      expect(find.text('Guarded (keep even if the app default changes)'), findsOneWidget);
      expect(find.text('Guarded'), findsNothing);
    });

    testWidgets('a binder offers all three and the app default, and saves its choice', (t) async {
      final b = await binder(t, 'Work');
      await pumpPanel(t, SettingsPanel.binder(notebook: nb, binderPath: b.path));
      expect(find.text('Binder settings'), findsOneWidget);
      expect(find.text('Background'), findsNothing, reason: 'a background is a page setting');
      expect(find.text('App default (Guarded)'), findsOneWidget);
      expect(find.text('Guarded (keep even if the app default changes)'), findsOneWidget);
      expect(find.text('Guarded'), findsNothing, reason: 'no plain duplicate next to the app default');
      for (final s in AiAccess.values) {
        expect(find.byKey(ValueKey('settings-ai-${s.value}')), findsOneWidget);
      }
      expect(selected(t, 'settings-ai-inherit'), isTrue);
      await tap(t, 'settings-ai-open');
      expect(nb.binderAiAccess(b.path), AiAccess.open);
      expect(selected(t, 'settings-ai-open'), isTrue);
    });
  });

  group('Privileged codes', () {
    testWidgets('issue a Reader code for a page, shown once; list, revoke with confirm', (t) async {
      await io(t, () => nb.setAiAccess(a, AiAccess.privileged));
      await pumpPanel(t, SettingsPanel.page(notebook: nb, pageId: a));
      expect(find.byKey(ValueKey('settings-codes-$a')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-no-codes')), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('settings-connect')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('settings-code-label')), 'Feedback – work chat');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('settings-code-expiry-7')));
      await t.pump();
      await t.runAsync(() async {
        await t.tap(find.byKey(const ValueKey('settings-code-create')));
        await realIoPause(50);
      });
      await t.pumpAndSettle();
      final code = t.widget<SelectableText>(find.byKey(const ValueKey('settings-code'))).data!;
      expect(code, startsWith('noted_'));
      expect(find.text('Code for Feedback – work chat'), findsOneWidget);

      // Escape doesn't close the stage that shows the code.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-code')), findsOneWidget);
      await t.runAsync(() async {
        await t.tap(find.byKey(const ValueKey('settings-code-copy')));
        await realIoPause(20);
      });
      await t.pump();
      expect(find.text('Copied'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('settings-code-done')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-code')), findsNothing);

      // Listed, and in the store only as a hash.
      final stored = service.codesFor(AiCodeTargetKind.page, a);
      expect(stored, hasLength(1));
      expect(stored.single.role, AiCodeRole.reader);
      expect(stored.single.expires, isNotNull);
      expect(File(service.store.file.path).readAsStringSync(), isNot(contains(code)));
      expect(find.text('Feedback – work chat'), findsOneWidget);
      final id = stored.single.id;
      expect(find.byKey(ValueKey('settings-facts-$id')), findsOneWidget);
      expect(
        t.widget<Text>(find.byKey(ValueKey('settings-facts-$id'))).data,
        allOf(contains('Reader'), contains('Never used'), contains('Expires')),
      );

      // Revoke asks first.
      await t.tap(find.byKey(ValueKey('settings-revoke-$id')));
      await t.pumpAndSettle();
      expect(find.text('Revoke Feedback – work chat?'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(service.codesFor(AiCodeTargetKind.page, a), hasLength(1));
      await t.tap(find.byKey(ValueKey('settings-revoke-$id')));
      await t.pumpAndSettle();
      await t.runAsync(() async {
        await t.tap(find.byKey(const ValueKey('settings-revoke-confirm')));
        await realIoPause(50);
      });
      await t.pumpAndSettle();
      // Revoked, not deleted: the row stays with its date and no Revoke button.
      expect(service.codesFor(AiCodeTargetKind.page, a).single.isRevoked, isTrue);
      expect(find.byKey(const ValueKey('settings-no-codes')), findsNothing);
      expect(find.byKey(ValueKey('settings-revoke-$id')), findsNothing);
      expect(t.widget<Text>(find.byKey(ValueKey('settings-revoked-$id'))).data, startsWith('Revoked 20'));
      expect(find.byKey(ValueKey('settings-approval-$id')), findsNothing);
      expect(
        t.widget<Text>(find.byKey(ValueKey('settings-facts-$id'))).data,
        isNot(contains('Expires')),
      );
    });

    testWidgets('the activity of a revoked code stays, marked, in app and closed-app entries', (t) async {
      final code = await io(t, () => service.issue(AiCodeTarget.page(a), role: AiCodeRole.reader, label: 'Gone chat'));
      expect(code, startsWith('noted_'));
      final id = service.codesFor(AiCodeTargetKind.page, a).single.id;
      service.log.append(
        AiActivityEntry(
          time: DateTime.utc(2026, 11, 1, 10),
          code: id,
          target: AiCodeTarget.page(a),
          op: 'read_page',
          app: 'Claude Code',
          label: 'Gone chat',
          result: 'ok',
        ),
      );
      service.mcpLog.writeAsStringSync(
        '${AiMcpLogEntry(
          time: DateTime.utc(2026, 11, 1, 11),
          code: id,
          target: AiCodeTarget.page(a),
          op: 'search',
          app: 'Cursor',
          label: 'Gone chat',
          result: 'ok',
        ).encode()}\n',
      );
      // A line of a code that was never issued is still dropped.
      service.mcpLog.writeAsStringSync(
        '${AiMcpLogEntry(
          time: DateTime.utc(2026, 11, 1, 12),
          code: '0123456789abcdef',
          target: AiCodeTarget.page(a),
          op: 'search',
          app: 'Stranger',
          label: 'X',
          result: 'ok',
        ).encode()}\n',
        mode: FileMode.append,
      );
      await io(t, () => service.revoke(id));
      await pumpPanel(t, SettingsPanel.page(notebook: nb, pageId: a));
      expect(find.textContaining('Read page · Claude Code · Gone chat · code revoked'), findsOneWidget);
      expect(
        find.textContaining('Search · Cursor · Gone chat · while Noted was closed · code revoked'),
        findsOneWidget,
      );
      expect(find.textContaining('Stranger'), findsNothing);
    });

    testWidgets('a binder has its own codes; each shows its approval; activity shows, closed-app entries too', (t) async {
      final b = await binder(t, 'Work');
      await io(t, () => nb.setBinderAiAccess(b.path, AiAccess.privileged));
      final binderId = b.binder!.id;
      final code = await service.issue(
        AiCodeTarget.binder(binderId),
        role: AiCodeRole.reader,
        label: 'Binder chat',
      );
      expect(code, startsWith('noted_'));
      final issued = service.codesFor(AiCodeTargetKind.binder, binderId).single;
      // Old session data in the file is ignored.
      service.store.update(
        (d) => d.put(
          issued.copyWith(
            sessions: [AiCodeSession(id: 's1', app: 'Claude Code', approved: DateTime.utc(2026, 11, 1))],
          ),
        ),
      );
      service.mcpLog.writeAsStringSync(
        '${AiMcpLogEntry(
          time: DateTime.utc(2026, 11, 1, 11),
          code: issued.id,
          target: AiCodeTarget.binder(binderId),
          op: 'search',
          app: 'Cursor',
          label: 'Binder chat',
          result: 'pending_approval',
        ).encode()}\n',
      );
      service.log.append(
        AiActivityEntry(
          time: DateTime.utc(2026, 11, 1, 10),
          code: issued.id,
          target: AiCodeTarget.binder(binderId),
          op: 'read_page',
          app: 'Claude Code',
          label: 'Binder chat',
          result: 'ok',
        ),
      );
      // Another target's code is not listed here.
      await io(t, () => service.issue(AiCodeTarget.page(a), role: AiCodeRole.reader, label: 'Other'));

      await pumpPanel(t, SettingsPanel.binder(notebook: nb, binderPath: b.path));
      expect(find.text('Binder chat'), findsOneWidget);
      expect(find.text('Other'), findsNothing);
      expect(find.textContaining('Read page · Claude Code · Binder chat'), findsOneWidget);
      expect(find.textContaining('Search · Cursor · Binder chat · while Noted was closed'), findsOneWidget);
      expect(find.byKey(ValueKey('settings-approval-${issued.id}')), findsOneWidget);
      expect(find.text('Not approved yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-session-s1')), findsNothing, reason: 'no session list any more');

      await io(t, () async => service.store.approveCode(issued.id, now: DateTime.utc(2026, 11, 2)));
      service.changed();
      await t.pump();
      expect(find.text('Not approved yet'), findsNothing);
      expect(find.textContaining('Approved '), findsOneWidget);
    });

    testWidgets('no Codes section unless Privileged, or codes exist to revoke', (t) async {
      await pumpPanel(t, SettingsPanel.page(notebook: nb, pageId: a));
      expect(find.byKey(ValueKey('settings-codes-$a')), findsNothing);
      await io(t, () => service.issue(AiCodeTarget.page(a), role: AiCodeRole.reader, label: 'Old'));
      await t.pump();
      expect(find.byKey(ValueKey('settings-codes-$a')), findsOneWidget);
    });
  });

  group('Box types allowed', () {
    testWidgets('a page can only tighten; the binder can allow or not; the note box is not listed', (t) async {
      final b = await binder(t, 'Work');
      final page = await io(t, () => nb.createPage(binderPath: b.path));
      await pumpPanel(t, SettingsPanel.page(notebook: nb, pageId: page));
      expect(find.text('AI boxes'), findsOneWidget);
      expect(find.text('Note boxes'), findsNothing);
      expect(selected(t, 'settings-type-$aiBoxTypeId-allowed'), isTrue);
      expect(nb.disallowedBoxTypesFor(page), isEmpty);

      await tap(t, 'settings-type-$aiBoxTypeId-off');
      expect(nb.ownBoxType(page, aiBoxTypeId), isFalse);
      expect(nb.disallowedBoxTypesFor(page), {aiBoxTypeId});
      expect(selected(t, 'settings-type-$aiBoxTypeId-off'), isTrue);
      await tap(t, 'settings-type-$aiBoxTypeId-allowed');
      expect(nb.ownBoxType(page, aiBoxTypeId), isNull);
      expect(nb.disallowedBoxTypesFor(page), isEmpty);

      // The binder disallows it: the page only shows that, with the source.
      await pumpPanel(t, SettingsPanel.binder(notebook: nb, binderPath: b.path));
      await tap(t, 'settings-type-$aiBoxTypeId-off');
      expect(nb.binderBoxType(b.path, aiBoxTypeId), isFalse);
      expect(nb.disallowedBoxTypesFor(page), {aiBoxTypeId});
      await pumpPanel(t, SettingsPanel.page(notebook: nb, pageId: page));
      expect(find.text('Not allowed (set by the binder)'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-type-$aiBoxTypeId-allowed')), findsNothing);
      // A subpage inherits it too, naming no level it can change.
      final sub = await io(t, () => nb.createPage(parentId: page));
      expect(nb.disallowedBoxTypesFor(sub), {aiBoxTypeId});
      expect(nb.boxTypeAvailabilityFor(sub, aiBoxTypeId).source, ConfigSource.binder);
    });

    testWidgets('disallowed: Insert is disabled, the box shows its snapshot read-only, allowing restores it, data untouched', (t) async {
      t.view.physicalSize = const Size(1600, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      const codec = AiCodec();
      nb.current!.insertBox(
        BoxRecord.create(
          id: 'aibox',
          typeId: aiBoxTypeId,
          dataVersion: codec.dataVersion,
          bounds: const Bounds(40, 40, 400, 140),
          data: RawJson.encode(codec.encode(codec.create())),
          snapshotText: 'Saved snapshot text',
          rev: 'r0',
        ),
      );
      await settleSaves(t, nb);
      await t.pumpWidget(MaterialApp(home: Home(notebook: nb)));
      await t.pump();
      await t.pump();
      // What the box holds: its type, saved data, snapshot and revision. (The
      // live box may size itself to its content; its bounds aren't compared.)
      String content() {
        final n = nb.current!.page.nodes.single as BoxRecord;
        return '${n.typeId}|${n.data?.text}|${n.snapshotText}|${n.rev}';
      }

      final before = content();
      PageCanvasState canvas() => t.state<PageCanvasState>(find.byType(PageCanvas));
      expect(canvas().commands[AiCommands.insert]!.enabled, isTrue);
      expect(find.text('Not allowed on this page'), findsNothing);

      await settleSaves(t, nb);
      await io(t, () => nb.setBoxType(a, aiBoxTypeId, false));
      await t.pump();
      await t.pump();
      expect(canvas().commands[AiCommands.insert]!.enabled, isFalse);
      expect(canvas().commands[AiCommands.insert]!.tooltip, contains('not allowed on this page'));
      expect(find.text('Not allowed on this page'), findsOneWidget);
      expect(find.text('Saved snapshot text'), findsOneWidget);
      expect(find.text('AI'), findsNothing, reason: 'no module header: the live box is not shown');
      // The page content (boxes) is untouched byte for byte; only the header
      // holds the choice.
      expect(writePage(nb.current!.page).contains('"boxTypes"'), isTrue);
      expect(content(), before);

      await settleSaves(t, nb);
      await io(t, () => nb.setBoxType(a, aiBoxTypeId, null));
      await t.pump();
      await t.pump();
      expect(canvas().commands[AiCommands.insert]!.enabled, isTrue);
      expect(find.text('Not allowed on this page'), findsNothing);
      expect(find.text('AI'), findsWidgets);
      expect(content(), before, reason: 'allowing again leaves the box as it was');
      expect(writePage(nb.current!.page).contains('"boxTypes"'), isFalse);
    });
  });

  group('where the settings are', () {
    testWidgets('the page header has Page settings; the binder cover and header have Binder settings', (t) async {
      final b = await binder(t, 'Work');
      t.view.physicalSize = const Size(1600, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: Home(notebook: nb)));
      await t.pump();
      await t.pump();
      await t.tap(find.byTooltip('Page settings'));
      await t.pumpAndSettle();
      expect(find.text('Page settings'), findsWidgets);
      expect(find.byKey(const ValueKey('settings-panel')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('settings-close')));
      await t.pumpAndSettle();

      await t.tap(find.byKey(ValueKey('binder-settings-${b.path}')));
      await t.pumpAndSettle();
      expect(find.text('Binder settings'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('settings-close')));
      await t.pumpAndSettle();

      await t.runAsync(() async {
        nb.showCover(b.path);
        await realIoPause(50);
      });
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cover-settings')));
      await t.pumpAndSettle();
      expect(find.text('Binder settings'), findsOneWidget);
    });

    testWidgets('the page and binder right-click menus keep only actions', (t) async {
      final b = await binder(t, 'Work');
      t.view.physicalSize = const Size(1000, 1200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 260,
              height: 900,
              child: ListenableBuilder(listenable: nb, builder: (context, _) => PageTreeView(notebook: nb)),
            ),
          ),
        ),
      );
      await t.pump();
      const settingsWords = [
        'AI access',
        'Open',
        'Privileged',
        'Guarded',
        'Store images and files',
        'Embed attachments',
        'Background',
        'Box types',
      ];
      final at = t.getCenter(find.byKey(ValueKey('page-row-$a'))) + const Offset(-40, 0);
      await t.runAsync(() => t.tapAt(at, buttons: kSecondaryButton));
      await t.pumpAndSettle();
      for (final s in ['New subpage', 'Rename', 'Move to folder…', 'Save as template…', 'Delete']) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      for (final s in settingsWords) {
        expect(find.text(s), findsNothing, reason: s);
      }
      await t.tapAt(const Offset(900, 1100));
      await t.pumpAndSettle();

      await t.runAsync(() => t.tap(find.byKey(ValueKey('binder-menu-${b.path}'))));
      await t.pumpAndSettle();
      for (final s in ['New page', 'Open cover', 'Save as template…', 'Remove from sidebar']) {
        expect(find.text(s), findsWidgets, reason: s);
      }
      for (final s in settingsWords) {
        expect(find.text(s), findsNothing, reason: s);
      }
    });
  });

  group('panel polish', () {
    double opacity(WidgetTester t) => t.widget<AnimatedOpacity>(find.byKey(const ValueKey('settings-scroll-cue'))).opacity;

    testWidgets('a cue shows at the bottom edge while the panel continues below, and goes at the end', (t) async {
      t.view.physicalSize = const Size(1000, 500);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: Scaffold(body: SettingsPanel.page(notebook: nb, pageId: a))));
      await t.pumpAndSettle();
      expect(opacity(t), 1);
      await t.drag(find.byType(SingleChildScrollView).first, const Offset(0, -3000));
      await t.pumpAndSettle();
      expect(opacity(t), 0, reason: 'nothing more below');
    });

    testWidgets('no cue when everything fits', (t) async {
      await pumpPanel(t, SettingsPanel.page(notebook: nb, pageId: a));
      await t.pumpAndSettle();
      expect(opacity(t), 0);
    });

    testWidgets('the Codes and Activity sub-headings are lighter than the section headings', (t) async {
      await io(t, () => nb.setAiAccess(a, AiAccess.privileged));
      await pumpPanel(t, SettingsPanel.page(notebook: nb, pageId: a));
      TextStyle style(Finder f) => t.widget<Text>(f).style!;
      final section = style(find.text('AI access'));
      for (final key in ['settings-codes-heading', 'settings-activity-heading']) {
        final sub = style(find.byKey(ValueKey(key)));
        expect(sub.fontSize, lessThan(section.fontSize!), reason: key);
        expect(sub.color, isNot(section.color), reason: '$key is muted');
      }
    });
  });

  group('Attachments', () {
    var n = 0;
    late Notebook churn;
    late String boxId;

    // A notebook with a box type whose conversion edits the box each time.
    setUp(() async {
      n = 0;
      churn = Notebook(
        PageStore(await Directory('${root.path}/churn').create()),
        ModuleRegistry()
          ..register(const NoteModule(), alwaysOn: true, isDefault: true)
          ..register(
            _Churning((d) => churn.current!.editBox(boxId, d.copyWith(text: 'edit ${n++}'))),
          ),
        saveDelay: Duration.zero,
        bindersFile: File('${root.path}/app/churn-binders.json'),
      );
      await churn.load();
      const codec = StickyLabelCodec();
      final box = commitBox(createBox(codec, Bounds(10, 10, 100, 40)), codec, const StickyLabelData(text: 'x'));
      boxId = box.id;
      churn.current!.insertBox(box);
    });

    tearDown(() async {
      await churn.flush();
      churn.dispose();
    });

    testWidgets('a box that keeps changing is reported under the buttons', (t) async {
      await pumpPanel(t, SettingsPanel.page(notebook: churn, pageId: churn.currentId!));
      await tap(t, 'settings-att-embed');
      final notice = t.widget<Text>(find.byKey(const ValueKey('settings-att-notice'))).data!;
      expect(
        notice,
        'Embedded 0 attachments. 1 box changed while this ran and was left as it was; '
        'press Embed attachments again.',
      );
      await tap(t, 'settings-att-to-folder');
      expect(
        t.widget<Text>(find.byKey(const ValueKey('settings-att-notice'))).data,
        endsWith('press Move attachments to folder again.'),
      );
    });
  });

  group('Background', () {
    testWidgets('a page that is not open shows its background and can be changed without opening it', (t) async {
      final other = await io(t, () => nb.createPage());
      await io(t, () => nb.open(a));
      expect(nb.currentId, a);
      await pumpPanel(t, SettingsPanel.page(notebook: nb, pageId: other));
      for (final b in PageBackground.values) {
        final chip = t.widget<ChoiceChip>(find.byKey(ValueKey('settings-bg-${b.name}')));
        expect(chip.onSelected, isNotNull);
        expect(chip.selected, b == nb.backgroundOf(other), reason: 'the current one shows selected');
      }
      expect(selected(t, 'settings-bg-${PageBackground.plain.name}'), isTrue);

      await tap(t, 'settings-bg-${PageBackground.graph.name}');
      await settleSaves(t, nb);
      expect(nb.currentId, a, reason: 'the open page stays open');
      expect(nb.backgroundOf(other), PageBackground.graph);
      expect(selected(t, 'settings-bg-${PageBackground.graph.name}'), isTrue);
    });

    testWidgets('on the open page the chips work', (t) async {
      await pumpPanel(t, SettingsPanel.page(notebook: nb, pageId: a));
      await tap(t, 'settings-bg-${PageBackground.dots.name}');
      expect(nb.backgroundOf(a), PageBackground.dots);
      expect(selected(t, 'settings-bg-${PageBackground.dots.name}'), isTrue);
    });
  });
}


/// A box type whose conversion edits the box while it runs, as sync would,
/// so the conversion has to skip it.
class _Churning extends BoxModule<StickyLabelData> {
  const _Churning(this.edit);

  final void Function(StickyLabelData data) edit;

  @override
  BoxCodec<StickyLabelData> get codec => const StickyLabelCodec();

  @override
  Widget buildEditor(BuildContext context, BoxContext<StickyLabelData> box) => const SizedBox();

  @override
  Widget buildView(BuildContext context, BoxContext<StickyLabelData> box) => const SizedBox();

  @override
  Future<StickyLabelData?> convertAttachments(
    StickyLabelData data,
    AttachmentStorage to,
    AttachmentStore store,
    List<String> overLimit,
  ) async {
    edit(data);
    return data.copyWith(text: '${data.text}!');
  }
}
