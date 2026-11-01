// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

Map<String, Object?> para(String text) => {
  'type': 'paragraph',
  'data': {
    'delta': [
      {'insert': text},
    ],
  },
};

Map<String, Object?> emptyPara() => {
  'type': 'paragraph',
  'data': {'delta': <Object?>[]},
};

Map<String, Object?> ai(String text) => markAiWritten(para(text));

Map<String, Object?> box(List<Object?> children, {String? owner}) => {
  'document': {'type': 'page', 'children': children},
  'owner': ?owner,
  'extra': {'keep': true},
};

AiWrite w(AiWriteMode mode, String md) => AiWrite(connectionId: 'c', content: md, mode: mode);

List<Object?> kids(Map<String, Object?> b) => ((b['document']! as Map)['children']! as List).cast<Object?>();

String text(Object? block) => aiBlockText(block! as Map);

void main() {
  test('append adds marked blocks after the existing ones and drops the blank first line', () {
    final out = applyAiWrite(box([para('mine'), emptyPara()], owner: 'c1'), w(AiWriteMode.append, 'one\n\ntwo'));
    expect(kids(out).map(text), ['mine', 'one', 'two']);
    expect(isAiWritten(kids(out)[0]! as Map), isFalse);
    expect(isAiWritten(kids(out)[1]! as Map), isTrue);
    expect(isAiWritten(kids(out)[2]! as Map), isTrue);
    expect(out['owner'], 'c1');
    expect(out['extra'], {'keep': true});
  });

  test('replace discards everything, user blocks included', () {
    final out = applyAiWrite(box([para('mine'), ai('theirs')]), w(AiWriteMode.replace, 'new'));
    expect(kids(out).map(text), ['new']);
    expect(isAiWritten(kids(out).single! as Map), isTrue);
  });

  test('replace with empty content leaves one empty paragraph', () {
    final out = applyAiWrite(box([para('mine'), ai('theirs')]), w(AiWriteMode.replace, ''));
    expect(kids(out), [emptyPara()]);
  });

  test('replaceAiText removes every run of AI blocks and puts the new ones where the first run was', () {
    final mine1 = para('user 1');
    final mine2 = para('user 2');
    final mine3 = para('user 3');
    final out = applyAiWrite(
      box([mine1, ai('a1'), ai('a2'), mine2, ai('a3'), mine3]),
      w(AiWriteMode.replaceAiText, 'new 1\n\nnew 2'),
    );
    expect(kids(out).map(text), ['user 1', 'new 1', 'new 2', 'user 2', 'user 3']);
    expect(kids(out).map((b) => isAiWritten(b! as Map)), [false, true, true, false, false]);
    // User blocks are the same content, byte for byte.
    expect(jsonEncode(kids(out)[0]), jsonEncode(mine1));
    expect(jsonEncode(kids(out)[3]), jsonEncode(mine2));
    expect(jsonEncode(kids(out)[4]), jsonEncode(mine3));
  });

  test('repeating the same replaceAiText write is idempotent, dividers included', () {
    final write = w(AiWriteMode.replaceAiText, 'one\n\n---\n\ntwo\n\n---');
    final first = applyAiWrite(box([para('mine')]), write);
    expect(kids(first).map((b) => (b! as Map)['type']), ['paragraph', 'paragraph', 'divider', 'paragraph', 'divider']);
    final second = applyAiWrite(first, write);
    final third = applyAiWrite(second, write);
    expect(jsonEncode(second), jsonEncode(first));
    expect(jsonEncode(third), jsonEncode(first));
    // A divider the AI wrote is gone when the AI text is replaced with nothing.
    final cleared = applyAiWrite(first, w(AiWriteMode.replaceAiText, ''));
    expect(kids(cleared).map(text), ['mine']);
  });

  test('replaceAiText with no AI block appends, like append', () {
    final out = applyAiWrite(box([para('mine'), emptyPara()]), w(AiWriteMode.replaceAiText, 'x'));
    expect(kids(out).map(text), ['mine', 'x']);
    expect(isAiWritten(kids(out)[1]! as Map), isTrue);
  });

  test('replaceAiText with empty content removes the AI text and keeps the rest', () {
    final out = applyAiWrite(box([ai('a'), para('mine'), ai('b')]), w(AiWriteMode.replaceAiText, ''));
    expect(kids(out).map(text), ['mine']);
    final onlyAi = applyAiWrite(box([ai('a')]), w(AiWriteMode.replaceAiText, ''));
    expect(kids(onlyAi), [emptyPara()]);
  });

  test('a block the user edited is no longer AI text and stays through replaceAiText', () {
    final edited = ai('written');
    ((edited['data']! as Map)['delta']! as List)[0] = {'insert': 'written, then edited'};
    final out = applyAiWrite(box([edited, ai('b')]), w(AiWriteMode.replaceAiText, 'n'));
    expect(kids(out).map(text), ['written, then edited', 'n']);
    expect(identical(kids(out)[0], edited), isTrue);
  });

  test('the input is not changed, and a box without a document gets one', () {
    final input = box([para('mine')]);
    final before = jsonEncode(input);
    applyAiWrite(input, w(AiWriteMode.append, 'x'));
    expect(jsonEncode(input), before);
    final out = applyAiWrite({'owner': 'c'}, w(AiWriteMode.append, 'x'));
    expect(kids(out).map(text), ['x']);
    expect(out['owner'], 'c');
  });

  test('written markdown uses the importer: images and unsafe links are gone', () {
    final out = applyAiWrite(box([]), w(AiWriteMode.append, '![i](http://x/y.png)\n\n[a](file:///x)'));
    expect(jsonEncode(out), isNot(contains('image')));
    expect(jsonEncode(out), isNot(contains('file:')));
  });
}
