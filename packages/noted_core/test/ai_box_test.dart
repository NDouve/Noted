// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

Map<String, Object?> para(String text, {Map<String, Object?> data = const {}}) => {
  'type': 'paragraph',
  'data': {
    'delta': [
      {'insert': text},
    ],
    ...data,
  },
};

void main() {
  test('the fingerprint is FNV-1a 64 of the UTF-8 bytes, as 16 hex characters', () {
    expect(aiTextFingerprint(''), 'cbf29ce484222325');
    expect(aiTextFingerprint('a'), 'af63dc4c8601ec8c');
    expect(aiTextFingerprint('foobar'), '85944171f73967e8');
    expect(aiTextFingerprint('é'), isNot(aiTextFingerprint('e')));
    expect(aiTextFingerprint('héllo'), matches(RegExp(r'^[0-9a-f]{16}$')));
  });

  test('block text: runs, equations, children and tables', () {
    expect(
      aiBlockText({
        'type': 'paragraph',
        'data': {
          'delta': [
            {'insert': 'Hello '},
            {
              'insert': 'world',
              'attributes': {'bold': true},
            },
          ],
        },
      }),
      'Hello world',
    );
    expect(
      aiBlockText({
        'type': 'math_equation',
        'data': {'formula': 'E=mc^2'},
      }),
      'E=mc^2',
    );
    expect(
      aiBlockText({
        'type': 'bulleted_list',
        'data': {
          'delta': [
            {'insert': 'a'},
          ],
        },
        'children': [para('b')],
      }),
      'a\nb',
    );
    expect(
      aiBlockText({
        'type': 'table',
        'data': {'rowsLen': 1, 'colsLen': 2},
        'children': [
          {
            'type': 'table/cell',
            'data': {'rowPosition': 0, 'colPosition': 0},
            'children': [para('x')],
          },
          {
            'type': 'table/cell',
            'data': {'rowPosition': 0, 'colPosition': 1},
            'children': [para('y')],
          },
        ],
      }),
      'x\ny',
    );
    expect(aiBlockText({'type': 'divider'}), '');
  });

  test('a block is AI-written only while its mark matches its text', () {
    final plain = para('Hello');
    expect(isAiWritten(plain), isFalse);
    final marked = markAiWritten(plain);
    expect(isAiWritten(marked), isTrue);
    expect((plain['data']! as Map).containsKey('noted_ai'), isFalse, reason: 'copy');
    expect((marked['data']! as Map)['noted_ai'], aiTextFingerprint('paragraph\nHello'));
    expect(aiBlockFingerprint(plain), aiTextFingerprint('paragraph\nHello'));

    // Changing the block's type ends the mark; bold and other data don't.
    expect(isAiWritten({...marked, 'type': 'heading'}), isFalse);
    final bold = {
      ...marked,
      'data': {
        ...(marked['data']! as Map),
        'checked': true,
        'delta': [
          {
            'insert': 'Hello',
            'attributes': {'bold': true},
          },
        ],
      },
    };
    expect(isAiWritten(bold), isTrue);

    // The user edits the text: the mark no longer matches.
    final edited = {
      ...marked,
      'data': {
        ...(marked['data']! as Map),
        'delta': [
          {'insert': 'Hello!'},
        ],
      },
    };
    expect(isAiWritten(edited), isFalse);

    // An inline formula or a link target is content too.
    Map<String, Object?> withAttrs(Map<String, Object?> attrs) => para('x', data: {
          'delta': [
            {'insert': 'x', 'attributes': attrs},
          ],
        });
    final formula = markAiWritten(withAttrs({'formula': 'a+b'}));
    expect(isAiWritten(formula), isTrue);
    final formulaEdited = {
      ...formula,
      'data': {
        ...(formula['data']! as Map),
        'delta': [
          {
            'insert': 'x',
            'attributes': {'formula': 'a-b'},
          },
        ],
      },
    };
    expect(isAiWritten(formulaEdited), isFalse);
    final link = markAiWritten(withAttrs({'href': 'https://a.example'}));
    expect(isAiWritten(link), isTrue);
    final relinked = {
      ...link,
      'data': {
        ...(link['data']! as Map),
        'delta': [
          {
            'insert': 'x',
            'attributes': {'href': 'https://b.example'},
          },
        ],
      },
    };
    expect(isAiWritten(relinked), isFalse);

    // An empty block is never AI-written, even with a matching mark.
    expect(isAiWritten(markAiWritten(para(''))), isFalse);
    expect(isAiWritten(para('x', data: {'noted_ai': 7})), isFalse);
    expect(isAiWritten({'type': 'paragraph'}), isFalse);
  });

  test('the owner comes from stored data', () {
    expect(aiBoxTypeId, 'noted.ai');
    expect(aiBoxOwner({'document': {}, 'owner': '0123456789abcdef'}), '0123456789abcdef');
    expect(aiBoxOwner({'document': {}}), isNull);
    expect(aiBoxOwner({'owner': 5}), isNull);
    expect(aiBoxOwner({'owner': ''}), isNull);
    expect(aiBoxOwner(null), isNull);
    expect(aiBoxOwner('x'), isNull);
  });
}
