// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_ai/noted_box_ai.dart';
import 'package:noted_core/noted_core.dart';

Map<String, Object?> para(String text, {Map<String, Object?>? extra}) => {
  'type': 'paragraph',
  'data': {
    'delta': [
      {'insert': text},
    ],
    ...?extra,
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

void main() {
  const codec = AiCodec();
  const owner = '0123456789abcdef';

  group('format', () {
    test('type id, sizing and API version', () {
      expect(codec.typeId, aiBoxTypeId);
      expect(codec.typeId, 'noted.ai');
      expect(codec.sizing, BoxSizing.growsWithContent);
      expect(codec.apiVersion, boxApiVersion);
    });

    test('a new box is an empty note with no owner', () {
      final d = codec.create();
      expect(d.owner, isNull);
      expect(blocksOf(d), hasLength(1));
      expect(codec.isEmpty(d), isFalse);
      expect(codec.snapshotText(d), '');
      expect((codec.encode(d)! as Map).containsKey('owner'), isFalse);
    });

    test('decode and encode keep every key, unknown ones included', () {
      final stored = {
        'document': {
          'type': 'page',
          'children': [para('hi')],
        },
        'owner': owner,
        'future': {
          'x': [1, 2.50, null],
        },
      };
      final text = jsonEncode(stored);
      final d = codec.decode(jsonDecode(text), 1);
      expect(d.owner, owner);
      expect(jsonEncode(codec.encode(d)), text);
      // The owner and the unknown key survive a content change too.
      final n = d.withNote(boxOf([para('changed')]).note);
      expect(n.owner, owner);
      expect(n.json['future'], stored['future']);
      expect(blocksOf(n).single['data'], isNot(contains('noted_ai')));
    });

    test('unreadable data throws', () {
      expect(() => codec.decode('nope', 1), throwsFormatException);
      expect(() => codec.decode({'owner': owner}, 1), throwsFormatException);
    });

    test('owner changes touch nothing else', () {
      final d = boxOf([para('a')], owner: owner);
      expect(d.withOwner(null).json.containsKey('owner'), isFalse);
      expect(d.withOwner('fedcba9876543210').owner, 'fedcba9876543210');
      expect(d.withOwner(null).json['document'], d.json['document']);
    });

    test('aiOwner is the owner', () {
      expect(codec.aiOwner(boxOf([para('a')], owner: owner)), owner);
      expect(codec.aiOwner(boxOf([para('a')])), isNull);
    });

    test('never empty, so it is not removed when it loses focus', () {
      expect(codec.isEmpty(boxOf([para('')])), isFalse);
      expect(codec.isEmpty(boxOf([para('')], owner: owner)), isFalse);
      expect(codec.isEmpty(boxOf([para('x')])), isFalse);
    });

    test('concurrent edits of a block are a conflict', () {
      final d = boxOf([para('a')]);
      expect(
        codec.merge(d, boxOf([para('b')]), boxOf([para('c')])),
        isA<Conflicted<AiBoxData>>(),
      );
      // The additions-only merge has its own tests: ai_merge_test.dart.
    });
  });

  group('snapshot and exposure', () {
    test('markdown with AI-written blocks marked', () {
      final d = boxOf([
        para('mine'),
        markAiWritten(para('theirs')),
        markAiWritten(para('more')),
        para('after'),
      ]);
      const expected =
          'mine\n\n<ai-written>\n\ntheirs\n\nmore\n\n</ai-written>\n\nafter';
      expect(codec.snapshotText(d), expected);
      final exposure = codec.aiExposure(d);
      expect(exposure, isA<AiText>());
      expect((exposure as AiText).text, expected);
    });

    test('a mark that no longer matches is not shown', () {
      final stale = markAiWritten(para('old'));
      ((stale['data']! as Map)['delta']! as List).first['insert'] = 'edited';
      expect(codec.snapshotText(boxOf([stale])), 'edited');
    });
  });

  group('aiWrite', () {
    final write = AiWrite(
      connectionId: owner,
      content: '# Title\n\n- one\n- two\n',
      mode: AiWriteMode.replace,
    );

    test('replace: the document becomes the new blocks, all marked', () {
      final d = boxOf([para('user text')], owner: owner);
      final n = codec.aiWrite(d, write)!;
      final b = blocksOf(n);
      expect(b.map((e) => e['type']), ['heading', 'bulleted_list', 'bulleted_list']);
      expect(b.every(isAiWritten), isTrue);
      expect(n.owner, owner);
      expect(codec.snapshotText(n), contains('<ai-written>'));
      expect(codec.snapshotText(n), isNot(contains('user text')));
    });

    test('replaceAiText: the AI blocks are replaced, the user blocks stay in place', () {
      final ai1 = markAiWritten(para('old ai'));
      final d = boxOf([para('before'), ai1, para('after')], owner: owner);
      final n = codec.aiWrite(
        d,
        AiWrite(connectionId: owner, content: 'fresh', mode: AiWriteMode.replaceAiText),
      )!;
      final b = blocksOf(n);
      expect(b.map(aiBlockText), ['before', 'fresh', 'after']);
      expect(b.map(isAiWritten), [false, true, false]);
      expect(b[0], blocksOf(d)[0]);
      expect(b[2], blocksOf(d)[2]);
      expect(n.owner, owner);
    });

    test('append: existing blocks stay, a trailing empty paragraph goes', () {
      final d = boxOf([para('user text'), para('')], owner: owner);
      final n = codec.aiWrite(
        d,
        AiWrite(connectionId: owner, content: 'added', mode: AiWriteMode.append),
      )!;
      final b = blocksOf(n);
      expect(b, hasLength(2));
      expect(isAiWritten(b[0]), isFalse);
      expect(b[0], blocksOf(d)[0]);
      expect(isAiWritten(b[1]), isTrue);
      expect(n.owner, owner);
    });

    test('append keeps earlier AI blocks marked', () {
      final first = codec.aiWrite(codec.create(), write)!;
      final second = codec.aiWrite(
        first,
        AiWrite(connectionId: owner, content: 'more', mode: AiWriteMode.append),
      )!;
      expect(blocksOf(second), hasLength(4));
      expect(blocksOf(second).every(isAiWritten), isTrue);
    });

    test('writing leaves an unowned box unowned and keeps unknown keys', () {
      final d = AiBoxData({...boxOf([para('')]).json, 'future': 1});
      final n = codec.aiWrite(d, write)!;
      expect(n.owner, isNull);
      expect(n.json['future'], 1);
    });

    test('empty content leaves one empty paragraph', () {
      final n = codec.aiWrite(
        boxOf([para('x')]),
        AiWrite(connectionId: owner, content: '', mode: AiWriteMode.replace),
      )!;
      expect(blocksOf(n), hasLength(1));
      expect(codec.snapshotText(n), '');
    });

    test('the input data is not changed', () {
      final d = boxOf([para('keep')]);
      final before = jsonEncode(d.json);
      codec.aiWrite(d, write);
      expect(jsonEncode(d.json), before);
    });
  });

  group('stripStaleAiMarks', () {
    test('keeps matching marks and returns the same map', () {
      final doc = boxOf([markAiWritten(para('a')), para('b')]).json;
      expect(identical(stripStaleAiMarks(doc), doc), isTrue);
    });

    test('drops a mark whose text or type changed, without touching the input', () {
      final edited = markAiWritten(para('a'));
      final retyped = markAiWritten(para('c'));
      retyped['type'] = 'heading';
      final doc = boxOf([edited, retyped, markAiWritten(para('ok'))]).json;
      ((edited['data']! as Map)['delta']! as List).first['insert'] = 'a!';
      final out = stripStaleAiMarks(doc);
      final b = blocksOf(AiBoxData(out));
      expect((b[0]['data']! as Map).containsKey('noted_ai'), isFalse);
      expect((b[1]['data']! as Map).containsKey('noted_ai'), isFalse);
      expect(isAiWritten(b[2]), isTrue);
      // The input still has the stale marks.
      expect((blocksOf(AiBoxData(doc))[0]['data']! as Map).containsKey('noted_ai'), isTrue);
    });

    test('an empty block that copied a mark loses it', () {
      final copy = markAiWritten(para('text'));
      ((copy['data']! as Map)['delta']! as List).clear();
      final b = blocksOf(AiBoxData(stripStaleAiMarks(boxOf([copy]).json)));
      expect((b.single['data']! as Map).containsKey('noted_ai'), isFalse);
    });
  });
}
