// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_core/noted_core.dart';

Map<String, Object?> para(
  String text, {
  Map<String, Object?>? attrs,
  Map<String, Object?>? extra,
  String type = 'paragraph',
}) => {
  'type': type,
  'data': {
    'delta': [
      if (text.isNotEmpty) {'insert': text, 'attributes': ?attrs},
    ],
    ...?extra,
  },
};

Map<String, Object?> runs(List<Map<String, Object?>> ops) => {
  'type': 'paragraph',
  'data': {'delta': ops},
};

NoteData doc(List<Map<String, Object?>> children) => NoteData({
  'document': {'type': 'page', 'children': children},
});

List<String> texts(MergeResult<NoteData> r) {
  final d = (r as Merged<NoteData>).data.document['document']! as Map;
  return [
    for (final b in d['children']! as List)
      [
        for (final op in ((b as Map)['data'] as Map)['delta'] as List)
          (op as Map)['insert'] as String,
      ].join(),
  ];
}

List<Object?> blocks(MergeResult<NoteData> r) =>
    ((r as Merged<NoteData>).data.document['document']! as Map)['children']!
        as List<Object?>;

void main() {
  const codec = NoteCodec();

  MergeResult<NoteData> merge(
    List<Map<String, Object?>> b,
    List<Map<String, Object?>> m,
    List<Map<String, Object?>> t,
  ) => codec.merge(doc(b), doc(m), doc(t));

  void conflicts(
    List<Map<String, Object?>> b,
    List<Map<String, Object?>> m,
    List<Map<String, Object?>> t,
  ) => expect(merge(b, m, t), isA<Conflicted<NoteData>>());

  group('blocks inserted', () {
    test('both append a paragraph: mine first, then theirs', () {
      final base = [para('a'), para('b')];
      expect(
        texts(merge(base, [...base, para('mine')], [...base, para('theirs')])),
        ['a', 'b', 'mine', 'theirs'],
      );
    });

    test('inserts at different positions keep both', () {
      final base = [para('a'), para('b'), para('c')];
      final m = [para('a'), para('m'), para('b'), para('c')];
      final t = [para('a'), para('b'), para('c'), para('t')];
      expect(texts(merge(base, m, t)), ['a', 'm', 'b', 'c', 't']);
      expect(texts(merge(base, t, m)), ['a', 'm', 'b', 'c', 't']);
    });

    test('insert at the same position: mine first', () {
      final base = [para('a'), para('b')];
      final m = [para('a'), para('m'), para('b')];
      final t = [para('a'), para('t1'), para('t2'), para('b')];
      expect(texts(merge(base, m, t)), ['a', 'm', 't1', 't2', 'b']);
    });

    test('prepend on one side, append on the other', () {
      final base = [para('a'), para('b')];
      expect(
        texts(merge(base, [para('first'), ...base], [...base, para('last')])),
        ['first', 'a', 'b', 'last'],
      );
    });

    test('the same insert on both sides is kept once', () {
      final base = [para('a')];
      final m = [...base, para('same'), para('also')];
      expect(texts(merge(base, m, [...m])), ['a', 'same', 'also']);
    });

    test('only one side changed', () {
      final base = [para('a')];
      final m = [...base, para('m')];
      expect(texts(merge(base, m, base)), ['a', 'm']);
      expect(texts(merge(base, base, m)), ['a', 'm']);
    });

    test('block types and data of inserted blocks come through untouched', () {
      final base = [para('a')];
      final heading = para(
        'H',
        type: 'heading',
        extra: {'level': 2, 'unknown': {'x': 1}},
      );
      final r = merge(base, [...base, heading], [...base, para('t')]);
      expect(blocks(r)[1], heading);
      expect(texts(r), ['a', 'H', 't']);
    });

    test('an equation block or a table can be inserted', () {
      final base = [para('a')];
      final eq = {
        'type': NoteFormat.mathBlockType,
        'data': {NoteFormat.formulaKey: 'x^2'},
      };
      final r = codec.merge(
        doc(base),
        doc([...base, eq]),
        doc([para('t'), ...base]),
      );
      expect(blocks(r), [para('t'), para('a'), eq]);
    });

    test('no blocks at all in the base', () {
      expect(
        texts(merge([], [para('m')], [para('t')])),
        ['m', 't'],
      );
    });
  });

  group('text added to the end of the last block, or the start of the first',
      () {
    test('both append to the last block', () {
      final r = merge(
        [para('a'), para('hi')],
        [para('a'), para('hi there')],
        [para('a'), para('hi you')],
      );
      // The runs join (same attributes): "hi" + " there" + " you".
      expect(texts(r), ['a', 'hi there you']);
    });

    test('both prepend to the first block', () {
      final r = merge(
        [para('hi'), para('z')],
        [para('one hi'), para('z')],
        [para('two hi'), para('z')],
      );
      expect(texts(r), ['one two hi', 'z']);
    });

    test('one appends text, the other appends a block', () {
      final r = merge(
        [para('a'), para('hi')],
        [para('a'), para('hi!')],
        [para('a'), para('hi'), para('new')],
      );
      expect(texts(r), ['a', 'hi!', 'new']);
    });

    test('a single block: mine appends, theirs prepends', () {
      final r = merge([para('mid')], [para('mid end')], [para('start mid')]);
      expect(texts(r), ['start mid end']);
    });

    test('the same appended text on both sides counts once', () {
      final r = merge([para('hi')], [para('hi!')], [para('hi!')]);
      expect(texts(r), ['hi!']);
    });

    test('appended runs with other attributes stay separate runs', () {
      final bold = {'bold': true};
      final r = merge(
        [para('hi')],
        [
          runs([
            {'insert': 'hi'},
            {'insert': ' B', 'attributes': bold},
          ]),
        ],
        [para('hi t')],
      );
      final delta = (blocks(r).first as Map)['data'] as Map;
      expect(delta['delta'], [
        {'insert': 'hi'},
        {'insert': ' B', 'attributes': bold},
        {'insert': ' t'},
      ]);
    });

    test('text added to a block that has no runs yet', () {
      final r = merge([para('')], [para('m')], [para('t')]);
      expect(texts(r), ['m', 't']);
    });

    test('the other data of the extended block is kept', () {
      final base = [para('hi', extra: {'x': 1}, type: 'bulleted_list')];
      final m = [para('hi A', extra: {'x': 1}, type: 'bulleted_list')];
      final r = merge(base, m, base);
      expect((blocks(r).first as Map)['type'], 'bulleted_list');
      expect(((blocks(r).first as Map)['data'] as Map)['x'], 1);
    });
  });

  group('trailing blank paragraph', () {
    test('typing into the blank line of a new box on both sides', () {
      final r = merge([para('')], [para('m')], [para('t')]);
      expect(texts(r), ['m', 't']);
    });

    test('a side that dropped the blank line (AI append) and a user append',
        () {
      final base = [para('a'), para('')];
      final m = [para('a'), para('ai block')];
      final t = [para('a'), para(''), para('user')];
      final r = merge(base, m, t);
      expect(texts(r), ['a', 'ai block', '', 'user']);
    });

    test('both keep the blank line: it stays at the end', () {
      final base = [para('a'), para('')];
      final r = merge(
        base,
        [para('a'), para('m'), para('')],
        [para('a'), para('t'), para('')],
      );
      expect(texts(r), ['a', 'm', 't', '']);
    });

    test('one side dropped the blank line: it goes', () {
      final base = [para('a'), para('')];
      final r = merge(base, [para('a'), para('m')], base);
      expect(texts(r), ['a', 'm']);
    });

    test('a blank line only one side added is kept', () {
      final base = [para('a')];
      expect(
        texts(merge(base, [para('a'), para('')], base)),
        ['a', ''],
      );
    });

    test('a blank line given attributes is an added block, nothing is lost',
        () {
      final base = [para('a'), para('')];
      final styled = [
        para('a'),
        {
          'type': 'paragraph',
          'data': {
            'delta': <Object?>[],
            'align': 'center',
          },
        },
      ];
      // The styled line is not a plain blank, so it is not ignored: it is
      // kept as an added block, and so are theirs.
      expect(
        texts(merge(base, styled, [...base, para('t')])),
        ['a', '', '', 't'],
      );
    });
  });

  group('anything else is a conflict', () {
    final base = [para('a'), para('b'), para('c')];

    test('an edited block', () {
      conflicts(
        base,
        [para('a'), para('B'), para('c')],
        [...base, para('t')],
      );
    });

    test('text added in the middle of a block', () {
      conflicts(
        [para('hello world')],
        [para('hello big world')],
        [para('hello world!')],
      );
    });

    test('a deleted block', () {
      conflicts(base, [para('a'), para('c')], [...base, para('t')]);
    });

    test('a reordered block', () {
      conflicts(
        base,
        [para('b'), para('a'), para('c')],
        [...base, para('t')],
      );
    });

    test('an attribute change on a base run', () {
      conflicts(
        [para('a')],
        [para('a', attrs: {'bold': true})],
        [para('a'), para('t')],
      );
    });

    test('a block data change (to-do ticked, heading level)', () {
      conflicts(
        [para('a', extra: {'checked': false}, type: 'todo_list')],
        [para('a', extra: {'checked': true}, type: 'todo_list')],
        [para('a', extra: {'checked': false}, type: 'todo_list'), para('t')],
      );
    });

    test('a block turned into another type', () {
      conflicts(
        [para('a')],
        [para('a', type: 'heading')],
        [para('a'), para('t')],
      );
    });

    test('text appended to a block that is not the last, or prepended to '
        'one that is not the first', () {
      conflicts(
        [para('a'), para('b'), para('c')],
        [para('a!'), para('b'), para('c')],
        [para('a'), para('b'), para('c'), para('t')],
      );
      conflicts(
        [para('a'), para('b'), para('c')],
        [para('a'), para('b'), para('x c')],
        [para('a'), para('b'), para('c'), para('t')],
      );
      conflicts(
        [para('a'), para('b')],
        [para('a'), para('x b')],
        [para('a'), para('b'), para('t')],
      );
    });

    test('text appended to the last block, and a block before it edited', () {
      conflicts(
        [para('a'), para('hi')],
        [para('a'), para('hi!')],
        [para('A'), para('hi')],
      );
    });

    test('text both prepended and appended by one side', () {
      conflicts(
        [para('mid')],
        [para('pre mid post')],
        [para('mid2'), para('t')],
      );
    });

    test('the same block edited the same way on both sides is still a '
        'change, not an addition', () {
      conflicts(
        [para('a'), para('b')],
        [para('a'), para('B')],
        [para('a'), para('B')],
      );
    });

    test('an inline equation in the last run is not extended', () {
      final f = NoteFormat.inlineMathChar;
      final base = [
        runs([
          {
            'insert': f,
            'attributes': {NoteFormat.formulaKey: 'x'},
          },
        ]),
      ];
      final m = [
        runs([
          {
            'insert': '$f!',
            'attributes': {NoteFormat.formulaKey: 'x'},
          },
        ]),
      ];
      conflicts(base, m, [...base, para('t')]);
    });

    test('a changed root type, or a table cell edit, is a conflict', () {
      final r = codec.merge(
        doc([para('a')]),
        NoteData({
          'document': {
            'type': 'other',
            'children': [para('a'), para('m')],
          },
        }),
        doc([para('a'), para('t')]),
      );
      expect(r, isA<Conflicted<NoteData>>());
      final table = {
        'type': NoteFormat.tableType,
        'children': [para('cell')],
      };
      final edited = {
        'type': NoteFormat.tableType,
        'children': [para('cell2')],
      };
      conflicts([table], [edited], [table, para('t')]);
    });

    test('a malformed document is a conflict, never a throw', () {
      expect(
        codec.merge(
          NoteData(const {'document': 5}),
          doc([para('a')]),
          doc([para('a')]),
        ),
        isA<Conflicted<NoteData>>(),
      );
    });
  });

  group('other top-level keys', () {
    test('unknown keys pass through; one side changing one wins', () {
      final b = NoteData({
        'document': {
          'type': 'page',
          'children': [para('a')],
        },
        'future': {'x': 1},
      });
      final m = NoteData({
        'document': {
          'type': 'page',
          'children': [para('a'), para('m')],
        },
        'future': {'x': 1},
      });
      final t = NoteData({
        'document': {
          'type': 'page',
          'children': [para('a')],
        },
        'future': {'x': 2},
        'added': true,
      });
      final r = (codec.merge(b, m, t) as Merged<NoteData>).data.document;
      expect(r['future'], {'x': 2});
      expect(r['added'], true);
    });

    test('a key both sides changed differently is a conflict', () {
      NoteData withKey(Object? v) => NoteData({
        'document': {
          'type': 'page',
          'children': [para('a')],
        },
        'k': v,
      });
      expect(
        codec.merge(withKey(1), withKey(2), withKey(3)),
        isA<Conflicted<NoteData>>(),
      );
    });
  });

  test('inputs are not changed', () {
    final b = doc([para('a'), para('')]);
    final m = doc([para('a'), para('m')]);
    final t = doc([para('a'), para(''), para('t')]);
    String snap(NoteData d) => d.document.toString();
    final before = [snap(b), snap(m), snap(t)];
    codec.merge(b, m, t);
    expect([snap(b), snap(m), snap(t)], before);
  });
}
