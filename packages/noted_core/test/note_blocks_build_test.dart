// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  test('blocks have the form markdownToNoteBlocks makes', () {
    expect(noteHeading(2, [const NoteRun('Title')]), markdownToNoteBlocks('## Title').single);
    expect(
      noteParagraph([const NoteRun('a '), const NoteRun('b', bold: true), const NoteRun(' c', italic: true)]),
      markdownToNoteBlocks('a **b** *c*').single..['data'] = {
        'delta': [
          {'insert': 'a '},
          {
            'insert': 'b',
            'attributes': {'bold': true},
          },
          {
            'insert': ' c',
            'attributes': {'italic': true},
          },
        ],
      },
    );
    expect(noteBulletedItem([const NoteRun('x')]), markdownToNoteBlocks('- x').single);
    expect(
      noteTable([
        ['a', 'b'],
        ['1', '2'],
      ]),
      markdownToNoteBlocks('| a | b |\n|---|---|\n| 1 | 2 |').single,
    );
  });

  test('text is literal: no escapes, no markup', () {
    const text = '*a* [1] & \$x\$ \\ <b>';
    final b = notePlainParagraph(text);
    expect(((b['data']! as Map)['delta']! as List).single, {'insert': text});
    expect(utf8.decode(encodeNoteBlocksFile([b])), contains(r'\\'));
    expect(decodeNoteBlocksFile(encodeNoteBlocksFile([b]))!.single, b);
  });

  test('a one-row table is kept and a table is padded', () {
    final t = noteTable([
      ['a', 'b'],
    ]);
    expect((t['data']! as Map)['rowsLen'], 1);
    expect((t['data']! as Map)['colsLen'], 2);
    final p = noteTable([
      ['a', 'b'],
      ['c'],
    ]);
    expect((p['children']! as List), hasLength(4));
  });

  test('a table over the cell limit is cut by rows, the header repeated', () {
    final rows = [
      for (var r = 0; r < 500; r++) [for (var c = 0; c < 50; c++) '$r'],
    ];
    final parts = noteTables(rows);
    expect(parts.length, greaterThan(10));
    for (final p in parts) {
      expect(noteBlockCells(p), lessThanOrEqualTo(2000));
    }
    String cellText(Map<String, Object?> t, int col, int row) {
      for (final c in t['children']! as List) {
        final d = (c as Map)['data']! as Map;
        if (d['colPosition'] == col && d['rowPosition'] == row) {
          final delta = (((c['children']! as List).first as Map)['data']! as Map)['delta']! as List;
          return delta.isEmpty ? '' : (delta.first as Map)['insert']! as String;
        }
      }
      return '?';
    }

    var data = 0;
    for (final p in parts) {
      expect(cellText(p, 0, 0), '0', reason: 'header repeated');
      data += (p['data']! as Map)['rowsLen']! as int;
      data -= 1;
    }
    expect(data, 499);
  });

  test('a table of long cells is cut by bytes too: every group is within 256 KiB', () {
    // 2,000 cells of 2,000 bytes would be 4 MB in one box.
    final rows = [
      for (var r = 0; r < 40; r++) [for (var c = 0; c < 50; c++) 'x' * 2000],
    ];
    final parts = noteTables(rows);
    expect(parts.length, 39, reason: 'header and one 100 KB row per part');
    for (final p in parts) {
      expect(noteBlockBytes(p), lessThanOrEqualTo(256 * 1024));
      expect(noteBlockCells(p), lessThanOrEqualTo(2000));
    }
    final g = groupNoteBlocks(parts, maxGroups: 100);
    expect(g.truncated, isFalse);
    for (final grp in g.groups) {
      expect(grp.fold<int>(0, (n, b) => n + noteBlockBytes(b)), lessThanOrEqualTo(256 * 1024));
    }
    // Header in each part, every data row once.
    expect(parts.fold<int>(0, (n, p) => n + ((p['data']! as Map)['rowsLen']! as int) - 1), 39);
  });

  test('cell text is cut on a character boundary', () {
    final t = noteTable([
      ['é' * 5000],
    ]);
    final delta = (((((t['children']! as List).first as Map)['children']! as List).first as Map)['data']! as Map)['delta']! as List;
    final text = (delta.single as Map)['insert']! as String;
    expect(utf8.encode(text).length, lessThanOrEqualTo(noteCellMaxBytes));
    expect(text.length, 1024);
  });

  test('groups: 256 KiB of text and 2,000 cells per box, blocks whole', () {
    final para = notePlainParagraph('x' * 1000);
    final g = groupNoteBlocks([for (var i = 0; i < 700; i++) para], maxBytes: 256 * 1024);
    expect(g.truncated, isFalse);
    expect(g.groups.length, 3);
    for (final grp in g.groups) {
      expect(grp.fold<int>(0, (n, b) => n + noteBlockBytes(b)), lessThanOrEqualTo(256 * 1024));
    }
    expect(g.groups.expand((x) => x).length, 700);

    final rows = [
      for (var r = 0; r < 500; r++) [for (var c = 0; c < 50; c++) '1'],
    ];
    final cells = groupNoteBlocks(noteTables(rows));
    expect(cells.groups.length, greaterThan(5));
    for (final grp in cells.groups) {
      expect(grp.fold<int>(0, (n, b) => n + noteBlockCells(b)), lessThanOrEqualTo(2000));
    }
  });

  test('one text block over the limit is cut into blocks of its style', () {
    final big = noteHeading(1, [NoteRun('é' * 10000, bold: true)]);
    final g = groupNoteBlocks([big], maxBytes: 4096);
    final all = g.groups.expand((x) => x).toList();
    expect(all.length, greaterThan(4));
    for (final b in all) {
      expect(b['type'], 'heading');
      expect(noteBlockBytes(b), lessThanOrEqualTo(4096));
    }
    expect(all.map(noteBlockBytes).fold<int>(0, (a, b) => a + b), 20000);
  });

  test('more than 20 groups: the rest is dropped and said', () {
    final para = notePlainParagraph('x' * 100);
    final g = groupNoteBlocks([for (var i = 0; i < 50; i++) para], maxBytes: 150);
    expect(g.groups.length, 20);
    expect(g.truncated, isTrue);
    final ok = groupNoteBlocks([for (var i = 0; i < 20; i++) para], maxBytes: 150);
    expect(ok.groups.length, 20);
    expect(ok.truncated, isFalse);
  });

  test('the import file: blocks round-trip and an invalid block refuses it', () {
    final blocks = [
      noteHeading(1, [const NoteRun('h')]),
      noteTable([
        ['a'],
      ]),
    ];
    expect(decodeNoteBlocksFile(encodeNoteBlocksFile(blocks)), blocks);
    List<int> file(Object? b) => utf8.encode(jsonEncode({'version': 1, 'blocks': b}));
    expect(decodeNoteBlocksFile(file([5])), isNull);
    expect(decodeNoteBlocksFile(file([{'data': {}}])), isNull);
    expect(
      decodeNoteBlocksFile(file([
        {
          'type': 'paragraph',
          'data': {
            'delta': [
              {'insert': 3},
            ],
          },
        },
      ])),
      isNull,
    );
    expect(decodeNoteBlocksFile(file([])), isNull);
    expect(decodeNoteBlocksFile(utf8.encode('{"version":2,"blocks":[]}')), isNull);
    expect(decodeNoteBlocksFile(utf8.encode('not json')), isNull);
    expect(decodeNoteBlocksFile([0xFF, 0xFE]), isNull);
  });
}
