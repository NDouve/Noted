// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  Widget buildEditor(BuildContext context, BoxContext<String> box) => Text(box.data);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) => Text(box.data);
}

class _FakeMerge implements PageAiMerge {
  bool isAvailable = true;
  Completer<AiMergeProposal>? pending;
  final List<String> asked = [];
  final List<String> cancelled = [];

  @override
  bool available(String pageId, String boxId) => isAvailable;

  @override
  Future<AiMergeProposal> ask(String pageId, String boxId) {
    asked.add(boxId);
    return (pending = Completer<AiMergeProposal>()).future;
  }

  @override
  void cancel(String pageId, String boxId) => cancelled.add(boxId);
}

BoxRecord _box(String id, String text, {double y = 100, double x = 100, String type = 'test.text'}) =>
    BoxRecord.create(
      id: id,
      typeId: type,
      dataVersion: 1,
      bounds: Bounds(x, y, 200, 60),
      data: RawJson.encode(text),
      snapshotText: text,
      rev: 'r-$id-$text',
    );

BoxRecord _conflicted(String id, String mine, String theirs, {double y = 100, String type = 'test.text'}) =>
    _box(id, mine, y: y, type: type).withConflict(
      BoxConflict.other(node: _box(id, theirs, y: y, type: type).toRaw(), at: 5, device: 'Laptop'),
    );

void main() {
  late ModuleRegistry modules;
  late List<NotedPage> saved;

  setUp(() {
    modules = ModuleRegistry()..register(const _Module(), alwaysOn: true, isDefault: true);
    saved = [];
  });

  CanvasController controllerOf(List<BoxRecord> boxes) {
    var page = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
    for (final b in boxes) {
      page = page.insertNode(b);
    }
    return CanvasController(page, modules, onChanged: saved.add);
  }

  Future<void> pump(
    WidgetTester t,
    CanvasController c, {
    PageAiMerge? merge,
    IssueSilence? silence,
    bool settle = true,
  }) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: notedThemeData(Brightness.light),
        home: Scaffold(
          body: PageCanvas(controller: c, aiMerge: merge, issueSilence: silence),
        ),
      ),
    );
    if (settle) {
      await t.pumpAndSettle();
    } else {
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
    }
  }

  final dialog = find.byKey(const ValueKey('issues-dialog'));
  Finder key(String k) => find.byKey(ValueKey(k));
  String count(WidgetTester t) => t.widget<Text>(key('issues-count')).data!;

  BoxRecord landedBox(String id, {double y = 100}) =>
      _box(id, 'landed', y: y).withLanded(BoxLanded(at: 5, device: 'Laptop'));

  group('the sequence', () {
    testWidgets('opens with the page, in reading order, with n of m', (t) async {
      final c = controllerOf([
        _conflicted('c', 'c mine', 'c theirs', y: 500),
        _box('d', 'd').withConflict(BoxConflict.deleted(at: 5)).withBounds(const Bounds(100, 300, 200, 60)),
        landedBox('a', y: 100),
      ]);
      await pump(t, c);
      expect(dialog, findsOneWidget);
      expect(count(t), '1 of 3');
      expect(find.text('A box landed on another box'), findsOneWidget);
      expect(key('issue-explanation'), findsOneWidget);
      expect(
        t.widget<Text>(key('issue-explanation')).data,
        contains('arrived from Laptop while you were away and landed on top of another box'),
      );
      // Previous is off at the start.
      expect(t.widget<TextButton>(key('issues-previous')).onPressed, isNull);
      await t.tap(key('issues-next'));
      await t.pumpAndSettle();
      expect(count(t), '2 of 3');
      expect(find.text('Deleted on the other side'), findsOneWidget);
      await t.tap(key('issues-next'));
      await t.pumpAndSettle();
      expect(count(t), '3 of 3');
      expect(find.text('Conflicting changes'), findsOneWidget);
      expect(t.widget<TextButton>(key('issues-next')).onPressed, isNull);
      await t.tap(key('issues-previous'));
      await t.pumpAndSettle();
      expect(count(t), '2 of 3');
    });

    testWidgets('a settled issue moves on to the next; the last closes it', (t) async {
      final c = controllerOf([landedBox('a', y: 100), _conflicted('b', 'mine', 'theirs', y: 300)]);
      await pump(t, c);
      await t.tap(key('issue-leave'));
      await t.pumpAndSettle();
      expect(count(t), '1 of 1');
      expect(find.text('Conflicting changes'), findsOneWidget);
      await t.tap(key('conflict-keep-mine'));
      await t.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(key('issues-icon'), findsNothing);
    });

    testWidgets('Silence folds the issues into a red corner icon that reopens the first', (t) async {
      final c = controllerOf([landedBox('a', y: 100), _conflicted('b', 'mine', 'theirs', y: 300)]);
      await pump(t, c);
      await t.tap(key('issues-next'));
      await t.pumpAndSettle();
      await t.tap(key('issues-silence'));
      await t.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(key('issues-icon'), findsOneWidget);
      expect(key('issues-icon-count'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      final fill = t.widget<DecoratedBox>(
        find.descendant(of: key('issues-icon'), matching: find.byType(DecoratedBox)).first,
      );
      expect((fill.decoration as BoxDecoration).color, notedThemeData(Brightness.light).colorScheme.error);
      expect(t.getSize(key('issues-icon')), const Size(34, 34));
      await t.tap(key('issues-icon'));
      await t.pumpAndSettle();
      expect(count(t), '1 of 2');
      expect(find.text('A box landed on another box'), findsOneWidget);
    });

    testWidgets('Esc silences, and silence is kept per page for the run', (t) async {
      final c = controllerOf([_conflicted('b', 'mine', 'theirs')]);
      final silence = IssueSilence();
      await pump(t, c, silence: silence);
      expect(dialog, findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(key('issues-icon'), findsOneWidget);
      expect(key('issues-icon-count'), findsNothing, reason: 'one issue: no count');
      expect(silence.isSilenced('p'), isTrue);
      // The page opened again in the same run doesn't show the sequence.
      await t.pumpWidget(const SizedBox());
      await pump(t, c, silence: silence);
      expect(dialog, findsNothing);
      expect(key('issues-icon'), findsOneWidget);
      // A new run (a new silence record) shows it again.
      await t.pumpWidget(const SizedBox());
      await pump(t, c, silence: IssueSilence());
      expect(dialog, findsOneWidget);
    });

    testWidgets('a warning in the box opens that box’s issue only', (t) async {
      final c = controllerOf([landedBox('a', y: 100), _conflicted('b', 'mine', 'theirs', y: 300)]);
      final silence = IssueSilence()..silence('p');
      await pump(t, c, silence: silence);
      expect(dialog, findsNothing);
      expect(key('issue-chip-a'), findsOneWidget);
      expect(key('issue-chip-b'), findsOneWidget);
      expect(key('landed-frame'), findsOneWidget);
      await t.tap(key('issue-chip-b'));
      await t.pumpAndSettle();
      expect(count(t), '1 of 1');
      expect(find.text('Conflicting changes'), findsOneWidget);
      expect(key('issues-next'), findsNothing);
      await t.tap(key('issues-silence'));
      await t.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(c.issues(), hasLength(2));
    });

    testWidgets('a read-only page shows no issues', (t) async {
      final c = controllerOf([_conflicted('b', 'mine', 'theirs')])..readOnly = true;
      await pump(t, c);
      expect(dialog, findsNothing);
      expect(key('issues-icon'), findsNothing);
      expect(key('issue-chip-b'), findsNothing);
    });
  });

  group('landed boxes', () {
    testWidgets('Place it closes the dialog with the box red and selected', (t) async {
      final c = controllerOf([landedBox('a')]);
      await pump(t, c);
      await t.tap(key('issue-place'));
      await t.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(c.selectedId, 'a');
      expect(key('landed-frame'), findsOneWidget);
      expect((t.widget<DecoratedBox>(key('landed-frame')).decoration as BoxDecoration).border, isNotNull);
      expect((c.page.node('a')! as BoxRecord).landed, isNotNull, reason: 'still marked until moved');
    });

    testWidgets('the first move clears the marker, as one undo step', (t) async {
      final c = controllerOf([landedBox('a')]);
      await pump(t, c);
      await t.tap(key('issue-place'));
      await t.pumpAndSettle();
      final before = (c.page.node('a')! as BoxRecord).bounds;
      c.beginGesture('a');
      c.updateGesture('a', Bounds(before.x + 300, before.y + 200, before.width, before.height));
      c.endGesture('a');
      await t.pumpAndSettle();
      expect((c.page.node('a')! as BoxRecord).landed, isNull);
      expect(key('landed-frame'), findsNothing);
      expect(key('issues-icon'), findsNothing);
      c.undo();
      final back = c.page.node('a')! as BoxRecord;
      expect(back.landed, isNotNull);
      expect(back.bounds, before);
      c.redo();
      expect((c.page.node('a')! as BoxRecord).landed, isNull);
    });

    testWidgets('Leave it here clears the marker; undo brings it back', (t) async {
      final c = controllerOf([landedBox('a')]);
      await pump(t, c);
      await t.tap(key('issue-leave'));
      await t.pumpAndSettle();
      expect(dialog, findsNothing);
      expect((c.page.node('a')! as BoxRecord).landed, isNull);
      c.undo();
      expect((c.page.node('a')! as BoxRecord).landed, isNotNull);
    });

    test('the marker survives a restart until the box is placed', () {
      final c = controllerOf([landedBox('a')]);
      NotedPage reopen() => readPage(writePage(c.page));
      expect(c.issues(), hasLength(1));
      expect(pageIssues(reopen(), canOpen: (_) => true).single.kind, PageIssueKind.landed);
      c.beginGesture('a');
      c.updateGesture('a', const Bounds(900, 900, 200, 60));
      c.endGesture('a');
      expect(pageIssues(reopen(), canOpen: (_) => true), isEmpty);
    });

    test('a move that changes nothing keeps the marker', () {
      final c = controllerOf([landedBox('a')]);
      c.beginGesture('a');
      c.endGesture('a');
      expect((c.page.node('a')! as BoxRecord).landed, isNotNull);
    });
  });

  group('conflict choices', () {
    Future<void> choose(WidgetTester t, String k) async {
      await t.tap(key(k));
      await t.pumpAndSettle();
    }

    testWidgets('both versions are shown side by side with their labels', (t) async {
      final c = controllerOf([_conflicted('a', 'mine', 'theirs')]);
      await pump(t, c);
      expect(find.descendant(of: key('conflict-mine'), matching: find.text('mine')), findsOneWidget);
      expect(find.descendant(of: key('conflict-theirs'), matching: find.text('theirs')), findsOneWidget);
      expect(find.textContaining('Laptop · saved'), findsOneWidget);
    });

    testWidgets('keep this version, and undo', (t) async {
      final c = controllerOf([_conflicted('a', 'mine', 'theirs')]);
      await pump(t, c);
      await choose(t, 'conflict-keep-mine');
      final n = c.page.node('a')! as BoxRecord;
      expect(n.isConflicted, isFalse);
      expect(n.snapshotText, 'mine');
      expect(saved, isNotEmpty);
      c.undo();
      expect((c.page.node('a')! as BoxRecord).isConflicted, isTrue);
    });

    testWidgets('keep the other version, and undo', (t) async {
      final c = controllerOf([_conflicted('a', 'mine', 'theirs')]);
      await pump(t, c);
      await choose(t, 'conflict-keep-theirs');
      final n = c.page.node('a')! as BoxRecord;
      expect(n.snapshotText, 'theirs');
      expect(n.isConflicted, isFalse);
      expect(c.page.nodes, hasLength(1));
      c.undo();
      final back = c.page.node('a')! as BoxRecord;
      expect(back.snapshotText, 'mine');
      expect(back.isConflicted, isTrue);
    });

    testWidgets('place both adds the other as a new box beside it, one undo step', (t) async {
      final c = controllerOf([_conflicted('a', 'mine', 'theirs')]);
      await pump(t, c);
      await choose(t, 'conflict-place-both');
      expect(c.page.nodes, hasLength(2));
      final a = c.page.node('a')! as BoxRecord;
      final other = c.page.nodes.firstWhere((n) => n.id != 'a') as BoxRecord;
      expect(a.snapshotText, 'mine');
      expect(a.isConflicted, isFalse);
      expect(other.snapshotText, 'theirs');
      expect(other.isConflicted, isFalse);
      expect(other.bounds.x, greaterThanOrEqualTo(a.bounds.right));
      c.undo();
      expect(c.page.nodes, hasLength(1));
      expect((c.page.node('a')! as BoxRecord).isConflicted, isTrue);
      c.redo();
      expect(c.page.nodes, hasLength(2));
    });

    testWidgets('deleted on the other side: keep the box, or delete it, both undoable', (t) async {
      final c = controllerOf([_box('a', 'mine').withConflict(BoxConflict.deleted(at: 5))]);
      await pump(t, c);
      expect(key('conflict-place-both'), findsNothing);
      expect(key('conflict-keep-theirs'), findsNothing);
      expect(find.textContaining('The other side deleted this box'), findsOneWidget);
      await choose(t, 'conflict-keep-mine');
      expect(c.page.nodes, hasLength(1));
      expect(c.hasConflicts, isFalse);
      c.undo();
      expect(c.hasConflicts, isTrue);
      c.resolveDelete('a');
      expect(c.page.nodes, isEmpty);
      c.undo();
      expect(c.hasConflicts, isTrue);
    });

    testWidgets('delete it from the dialog', (t) async {
      final c = controllerOf([_box('a', 'mine').withConflict(BoxConflict.deleted(at: 5))]);
      await pump(t, c);
      await choose(t, 'conflict-delete');
      expect(c.page.nodes, isEmpty);
      c.undo();
      expect(c.page.nodes, hasLength(1));
    });

    group('a box this device can’t open', () {
      BoxRecord unknownMine() => _box('u', 'mine', type: 'future.thing');
      BoxRecord unknownTheirs() => _box('u', 'theirs', type: 'future.thing').withBounds(const Bounds(400, 100, 200, 60));
      BoxRecord conflictedUnknown() =>
          unknownMine().withConflict(BoxConflict.other(node: unknownTheirs().toRaw(), at: 5, device: 'Laptop'));

      testWidgets('is settled from snapshots, with no AI option', (t) async {
        final c = controllerOf([conflictedUnknown()]);
        final merge = _FakeMerge();
        await pump(t, c, merge: merge);
        expect(find.text('Conflicting changes in a box this device can’t open'), findsOneWidget);
        expect(key('conflict-ask-ai'), findsNothing);
        expect(find.descendant(of: key('conflict-theirs'), matching: find.text('theirs')), findsOneWidget);
        expect(key('conflict-keep-mine'), findsOneWidget);
        expect(key('conflict-keep-theirs'), findsOneWidget);
        expect(key('conflict-place-both'), findsOneWidget);
      });

      testWidgets('keep this version leaves the box byte for byte', (t) async {
        final c = controllerOf([conflictedUnknown()]);
        await pump(t, c);
        await choose(t, 'conflict-keep-mine');
        expect((c.page.node('u')! as BoxRecord).toRaw(), unknownMine().toRaw());
      });

      testWidgets('keep the other version takes its data byte for byte', (t) async {
        final c = controllerOf([conflictedUnknown()]);
        await pump(t, c);
        await choose(t, 'conflict-keep-theirs');
        final n = c.page.node('u')! as BoxRecord;
        expect(n.data?.text, unknownTheirs().data?.text);
        expect(n.snapshotText, 'theirs');
        expect(n.typeId, 'future.thing');
        c.undo();
        expect((c.page.node('u')! as BoxRecord).isConflicted, isTrue);
      });

      testWidgets('place both copies the other version byte for byte', (t) async {
        final c = controllerOf([conflictedUnknown()]);
        await pump(t, c);
        await choose(t, 'conflict-place-both');
        expect(c.page.nodes, hasLength(2));
        final added = c.page.nodes.firstWhere((n) => n.id != 'u') as BoxRecord;
        expect(added.data?.text, unknownTheirs().data?.text);
        expect(added.typeId, 'future.thing');
        expect((c.page.node('u')! as BoxRecord).data?.text, unknownMine().data?.text);
        c.undo();
        expect(c.page.nodes, hasLength(1));
      });
    });
  });

  group('the page AI', () {
    testWidgets('the option is hidden without a PageAiMerge, or when it is not available', (t) async {
      final c = controllerOf([_conflicted('a', 'mine', 'theirs')]);
      await pump(t, c);
      expect(key('conflict-ask-ai'), findsNothing);
      final merge = _FakeMerge()..isAvailable = false;
      await t.pumpWidget(const SizedBox());
      await pump(t, controllerOf([_conflicted('a', 'mine', 'theirs')]), merge: merge);
      expect(dialog, findsOneWidget);
      expect(key('conflict-ask-ai'), findsNothing);
    });

    testWidgets('the option is shown when available, and only for a conflict', (t) async {
      final merge = _FakeMerge();
      await pump(t, controllerOf([_conflicted('a', 'mine', 'theirs')]), merge: merge);
      expect(key('conflict-ask-ai'), findsOneWidget);
      expect(find.text('Ask the page AI to merge'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await pump(
        t,
        controllerOf([_box('a', 'mine').withConflict(BoxConflict.deleted(at: 5))]),
        merge: merge,
      );
      expect(key('conflict-ask-ai'), findsNothing);
    });

    testWidgets('waiting shows progress; choosing something else cancels the request', (t) async {
      final merge = _FakeMerge();
      final c = controllerOf([_conflicted('a', 'mine', 'theirs')]);
      await pump(t, c, merge: merge);
      await t.tap(key('conflict-ask-ai'));
      await t.pump();
      expect(merge.asked, ['a']);
      expect(key('conflict-ask-ai'), findsNothing);
      expect(key('conflict-ai-waiting'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Other choices stay available while waiting.
      await t.tap(key('conflict-keep-theirs'));
      await t.pump(const Duration(milliseconds: 400));
      expect(merge.cancelled, ['a']);
      expect((c.page.node('a')! as BoxRecord).snapshotText, 'theirs');
      // A late proposal changes nothing.
      merge.pending!.complete(const AiMergeProposal(markdown: 'late', data: 'late', dataVersion: 1));
      await t.pumpAndSettle();
      expect((c.page.node('a')! as BoxRecord).snapshotText, 'theirs');
    });

    testWidgets('a proposal is shown beside both versions and applied only on request, one undo step', (t) async {
      final merge = _FakeMerge();
      final c = controllerOf([_conflicted('a', 'mine', 'theirs')]);
      await pump(t, c, merge: merge);
      await t.tap(key('conflict-ask-ai'));
      await t.pump();
      merge.pending!.complete(const AiMergeProposal(markdown: 'merged text', data: 'merged', dataVersion: 1, by: 'Claude'));
      await t.pumpAndSettle();
      expect(find.descendant(of: key('conflict-ai-proposal'), matching: find.text('merged text')), findsOneWidget);
      expect(key('conflict-mine'), findsOneWidget);
      expect(key('conflict-theirs'), findsOneWidget);
      expect(find.textContaining('Proposed by Claude'), findsOneWidget);
      // Nothing changed yet.
      expect((c.page.node('a')! as BoxRecord).snapshotText, 'mine');
      expect(c.page.node('a')!.toRaw(), _conflicted('a', 'mine', 'theirs').toRaw());
      expect(find.text('Use the AI’s merge'), findsOneWidget);
      await t.tap(key('conflict-use-ai'));
      await t.pumpAndSettle();
      final n = c.page.node('a')! as BoxRecord;
      expect(n.snapshotText, 'merged');
      expect(n.isConflicted, isFalse);
      expect(dialog, findsNothing);
      c.undo();
      final back = c.page.node('a')! as BoxRecord;
      expect(back.snapshotText, 'mine');
      expect(back.isConflicted, isTrue);
      expect(merge.cancelled, isEmpty);
    });

    testWidgets('discarding a proposal changes nothing; an AI error is explained', (t) async {
      final merge = _FakeMerge();
      final c = controllerOf([_conflicted('a', 'mine', 'theirs')]);
      await pump(t, c, merge: merge);
      await t.tap(key('conflict-ask-ai'));
      await t.pump();
      merge.pending!.complete(const AiMergeProposal(markdown: 'm', data: 'm', dataVersion: 1));
      await t.pumpAndSettle();
      await t.tap(key('conflict-discard-ai'));
      await t.pumpAndSettle();
      expect(key('conflict-ai-proposal'), findsNothing);
      expect(key('conflict-ask-ai'), findsOneWidget);
      expect((c.page.node('a')! as BoxRecord).isConflicted, isTrue);
      await t.tap(key('conflict-ask-ai'));
      await t.pump();
      merge.pending!.completeError(StateError('declined'));
      await t.pumpAndSettle();
      expect(key('conflict-ai-error'), findsOneWidget);
      expect(key('conflict-ask-ai'), findsOneWidget);
    });

    testWidgets('navigating away or silencing cancels a pending request', (t) async {
      final merge = _FakeMerge();
      final c = controllerOf([_conflicted('a', 'mine', 'theirs'), landedBox('l', y: 400)]);
      await pump(t, c, merge: merge);
      await t.tap(key('conflict-ask-ai'));
      await t.pump();
      await t.tap(key('issues-silence'));
      await t.pumpAndSettle();
      expect(merge.cancelled, ['a']);
    });
  });
}
