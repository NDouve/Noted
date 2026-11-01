// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_ai/noted_box_ai.dart';
import 'package:noted_core/noted_core.dart';

Map<String, Object?> para(String text) => {
  'type': 'paragraph',
  'data': {
    'delta': [
      if (text.isNotEmpty) {'insert': text},
    ],
  },
};

AiBoxData boxOf(List<Map<String, Object?>> blocks, {String? owner}) =>
    AiBoxData({
      'document': {'type': 'page', 'children': blocks},
      'owner': ?owner,
    });

List<Map<String, Object?>> blocksOf(AiBoxData d) =>
    ((d.json['document']! as Map)['children']! as List)
        .cast<Map<String, Object?>>();

AiBoxData merged(MergeResult<AiBoxData> r) => (r as Merged<AiBoxData>).data;

String textOf(Map<String, Object?> b) => [
  for (final op in ((b['data']! as Map)['delta']! as List))
    (op as Map)['insert'],
].join();

void main() {
  const codec = AiCodec();
  const owner = '0123456789abcdef';

  test('both sides add paragraphs: both kept, mine first, owner kept', () {
    final base = boxOf([para('a')], owner: owner);
    final m = boxOf([para('a'), para('mine')], owner: owner);
    final t = boxOf([para('a'), para('theirs')], owner: owner);
    final d = merged(codec.merge(base, m, t));
    expect(blocksOf(d).map(textOf), ['a', 'mine', 'theirs']);
    expect(d.owner, owner);
  });

  test('AI-written marks stay on the blocks an AI added', () {
    final base = boxOf([para('user')], owner: owner);
    final aiBlock = markAiWritten(para('from the AI'));
    final m = boxOf([para('user'), aiBlock], owner: owner);
    final t = boxOf([para('user'), para('typed')], owner: owner);
    for (final d in [
      merged(codec.merge(base, m, t)),
      merged(codec.merge(base, t, m)),
    ]) {
      final blocks = blocksOf(d);
      expect(blocks.map(textOf), contains('from the AI'));
      final ai = blocks.firstWhere((b) => textOf(b) == 'from the AI');
      expect(ai, aiBlock);
      expect(isAiWritten(ai), isTrue);
      expect(isAiWritten(blocks.firstWhere((b) => textOf(b) == 'typed')),
          isFalse);
    }
  });

  test('both sides add AI blocks: all marks kept', () {
    final base = boxOf([para('x')]);
    final a1 = markAiWritten(para('one'));
    final a2 = markAiWritten(para('two'));
    final d = merged(
      codec.merge(base, boxOf([para('x'), a1]), boxOf([para('x'), a2])),
    );
    expect(blocksOf(d).where(isAiWritten).map(textOf), ['one', 'two']);
  });

  test('stale marks are not repaired or removed by the merge', () {
    // A user edit of an AI block is an edit of a base block: a conflict.
    final base = boxOf([markAiWritten(para('ai'))]);
    final edited = boxOf([para('ai!')]);
    expect(
      codec.merge(base, edited, boxOf([markAiWritten(para('ai')), para('t')])),
      isA<Conflicted<AiBoxData>>(),
    );
  });

  test('the owner is three-way: one side changing it wins, both differing '
      'conflicts', () {
    final base = boxOf([para('a')], owner: owner);
    final m = boxOf([para('a'), para('m')], owner: owner);
    final t = boxOf([para('a')], owner: 'fedcba9876543210');
    expect(merged(codec.merge(base, m, t)).owner, 'fedcba9876543210');
    final t2 = boxOf([para('a'), para('t')], owner: 'aaaaaaaaaaaaaaaa');
    final m2 = boxOf([para('a'), para('m')], owner: 'bbbbbbbbbbbbbbbb');
    expect(codec.merge(base, m2, t2), isA<Conflicted<AiBoxData>>());
  });

  test('unknown keys pass through', () {
    final base = AiBoxData({
      'document': {
        'type': 'page',
        'children': [para('a')],
      },
      'future': [1, 2],
    });
    final m = AiBoxData({...base.json, 'future': [1, 2]});
    final t = boxOf([para('a'), para('t')]);
    // Theirs dropped the key and mine didn't change it: dropped.
    expect(merged(codec.merge(base, m, t)).json.containsKey('future'), isFalse);
    // Mine kept it unchanged and theirs too: kept.
    final t2 = AiBoxData({
      ...base.json,
      'document': {
        'type': 'page',
        'children': [para('a'), para('t')],
      },
    });
    expect(merged(codec.merge(base, m, t2)).json['future'], [1, 2]);
  });

  group('a closed-app AI append (0117) and a user append', () {
    // The write the MCP server does while Noted is closed.
    Map<String, Object?> closedAppend(AiBoxData d, String markdown) =>
        applyAiWrite(
          d.json,
          AiWrite(
            connectionId: owner,
            content: markdown,
            mode: AiWriteMode.append,
          ),
        );

    test('on a new box (blank first line): both kept, AI marked', () {
      final base = boxOf([para('')], owner: owner);
      final ai = AiBoxData(closedAppend(base, 'Summary\n\n- one\n- two'));
      // The user typed into the blank line.
      final user = boxOf([para('my note')], owner: owner);
      final d = merged(codec.merge(base, user, ai));
      final blocks = blocksOf(d);
      expect(blocks.map(textOf), ['my note', 'Summary', 'one', 'two']);
      expect(isAiWritten(blocks[0]), isFalse);
      expect(blocks.skip(1).every(isAiWritten), isTrue);
      expect(d.owner, owner);
      // And the other way round (mine is the AI's).
      final d2 = merged(codec.merge(base, ai, user));
      expect(blocksOf(d2).map(textOf), ['Summary', 'one', 'two', 'my note']);
    });

    test('after existing text and a trailing blank line', () {
      final base = boxOf([para('notes'), para('')], owner: owner);
      final ai = AiBoxData(closedAppend(base, 'AI says'));
      final user = boxOf([para('notes'), para(''), para('more')], owner: owner);
      final d = merged(codec.merge(base, user, ai));
      expect(blocksOf(d).map(textOf), ['notes', '', 'more', 'AI says']);
      expect(isAiWritten(blocksOf(d).last), isTrue);
    });

    test('through the page merge: no conflict, one box, both parts', () {
      final registry = CodecRegistry()..register(codec);
      BoxRecord record(AiBoxData d, {String? rev}) => BoxRecord.create(
        id: 'ai1',
        typeId: aiBoxTypeId,
        dataVersion: 1,
        bounds: const Bounds(0, 0, 300, 100),
        data: RawJson.encode(codec.encode(d)),
        snapshotText: codec.snapshotText(d),
        rev: rev ?? 'r0',
      );
      NotedPage pageOf(BoxRecord b) =>
          NotedPage.create(PageMeta.create(id: 'p', title: 'T', order: 0))
              .insertNode(b);

      final baseData = boxOf([para('notes'), para('')], owner: owner);
      final base = pageOf(record(baseData));
      // Mine: the user appended a line in the open page.
      final mineData = boxOf([para('notes'), para('user line')], owner: owner);
      final mine = pageOf(
        commitBox(record(baseData), codec, mineData),
      );
      // Theirs: the closed-app write changed the saved file (a new rev, as
      // any edit).
      final aiData = AiBoxData(
        applyAiWrite(
          baseData.json,
          AiWrite(
            connectionId: owner,
            content: 'AI line',
            mode: AiWriteMode.append,
          ),
        ),
      );
      final theirs = pageOf(commitBox(record(baseData), codec, aiData));

      final r = mergePage(base, mine, theirs, registry, theirsTime: 5);
      expect(r.conflictedIds, isEmpty);
      final box = r.page.node('ai1')! as BoxRecord;
      expect(box.conflicts, isEmpty);
      expect(box.isConflicted, isFalse);
      expect(box.snapshotText, contains('user line'));
      expect(box.snapshotText, contains('AI line'));
      final out = codec.decode(box.data!.decode(), 1);
      expect(blocksOf(out).map(textOf), ['notes', 'user line', 'AI line']);
      expect(isAiWritten(blocksOf(out).last), isTrue);
      expect(isAiWritten(blocksOf(out)[1]), isFalse);
      expect(box.rev, isNot(anyOf('r0', (mine.node('ai1')! as BoxRecord).rev)));
    });

    test('a closed-app replace of AI text on one side is a conflict', () {
      final base = boxOf([markAiWritten(para('old AI')), para('')]);
      final replaced = AiBoxData(
        applyAiWrite(
          base.json,
          AiWrite(
            connectionId: owner,
            content: 'new AI',
            mode: AiWriteMode.replaceAiText,
          ),
        ),
      );
      final user = boxOf([markAiWritten(para('old AI')), para('x')]);
      expect(codec.merge(base, user, replaced), isA<Conflicted<AiBoxData>>());
    });
  });
}
