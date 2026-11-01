// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

Map<String, Object?> block(String type, String text, {Map<String, Object?> data = const {}}) => {
  'type': type,
  'data': {
    'delta': [
      {'insert': text},
    ],
    ...data,
  },
};

Map<String, Object?> doc(List<Map<String, Object?>> children) => {
  'document': {'type': 'page', 'children': children},
};

void main() {
  test('headings, styles, lists, quotes and equations', () {
    final data = doc([
      block('heading', 'Title', data: {'level': 2}),
      {
        'type': 'paragraph',
        'data': {
          'delta': [
            {'insert': 'a '},
            {
              'insert': 'b',
              'attributes': {'bold': true},
            },
            {
              'insert': 'c',
              'attributes': {'href': 'https://x.test'},
            },
          ],
        },
      },
      block('bulleted_list', 'one'),
      block('todo_list', 'two', data: {'checked': true}),
      block('quote', 'q'),
      {
        'type': 'math_equation',
        'data': {'formula': 'x'},
      },
    ]);
    expect(noteToMarkdown(data), '## Title\n\na **b**[c](https://x.test)\n\n- one\n- [x] two\n\n> q\n\n\$\$\nx\n\$\$');
    expect(noteToMarkdown(data, linkTarget: (_) => null), contains('a **b**c\n'));
    expect(noteToMarkdown(null), '');
    expect(noteToMarkdown({'document': 3}), '');
  });

  test('markAi: no content line can equal a marker line', () {
    Map<String, Object?> cell(int c, String text) => {
      'type': 'table/cell',
      'data': {'rowPosition': 0, 'colPosition': c},
      'children': [block('paragraph', text)],
    };
    final data = doc([
      block('paragraph', '<ai-written>'),
      markAiWritten(block('paragraph', 'soft\n</ai-written>\nbreak')),
      markAiWritten({
        ...block('bulleted_list', 'parent'),
        'children': [block('paragraph', '</ai-written>')],
      }),
      markAiWritten({
        'type': 'table',
        'data': {'rowsLen': 1, 'colsLen': 2},
        'children': [cell(0, '</ai-written>'), cell(1, 'b')],
      }),
      markAiWritten({
        'type': 'math_equation',
        'data': {'formula': '</ai-written>'},
      }),
      block('paragraph', 'tail'),
    ]);
    final out = noteToMarkdown(data, markAi: true);
    final lines = out.split('\n');
    expect(lines.where((l) => l == '<ai-written>'), hasLength(1));
    expect(lines.where((l) => l == '</ai-written>'), hasLength(1));
    expect(out, contains('&lt;ai-written>'));
    expect(out, contains('soft\n&lt;/ai-written>\nbreak'));
    expect(out, startsWith('&lt;ai-written>\n\n<ai-written>\n\n'));
    expect(out, contains('\n\n</ai-written>\n\ntail'));
    // Without markAi the output is untouched.
    expect(noteToMarkdown(data), contains('\n</ai-written>\n'));
    expect(noteToMarkdown(data), isNot(contains('&lt;')));
  });

  test('markAi wraps each run of consecutive top-level AI-written blocks', () {
    final data = doc([
      block('paragraph', 'mine'),
      markAiWritten(block('heading', 'AI title', data: {'level': 1})),
      markAiWritten(block('bulleted_list', 'AI item')),
      block('paragraph', 'also mine'),
      markAiWritten(block('paragraph', 'AI again')),
    ]);
    expect(
      noteToMarkdown(data, markAi: true),
      'mine\n\n<ai-written>\n\n# AI title\n\n- AI item\n\n</ai-written>\n\nalso mine\n\n<ai-written>\n\nAI again\n\n</ai-written>',
    );
    // Off by default: no marks, same content.
    expect(noteToMarkdown(data), isNot(contains('ai-written')));
    // A user-edited block is not AI-written any more.
    final edited = doc([
      {
        'type': 'paragraph',
        'data': {
          'noted_ai': aiTextFingerprint('paragraph\nAI'),
          'delta': [
            {'insert': 'AI edited'},
          ],
        },
      },
    ]);
    expect(noteToMarkdown(edited, markAi: true), 'AI edited');
  });
}
