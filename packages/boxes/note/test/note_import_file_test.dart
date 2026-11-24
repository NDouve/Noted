// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:appflowy_editor/appflowy_editor.dart' show Document;
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_box_note/src/note_editor_state.dart';
import 'package:noted_box_note/src/table_formulas.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

class _NoStore implements AttachmentStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('the note module stores nothing');
}

IncomingFile _file(String name, List<int> bytes) => IncomingFile(name, Uint8List.fromList(bytes));

void main() {
  const module = NoteModule();
  final store = _NoStore();

  Object? children(NoteData d) => (d.document['document']! as Map)['children'];

  test('an import file gives exactly its blocks', () async {
    final blocks = [
      noteHeading(1, [const NoteRun('Title')]),
      noteParagraph([const NoteRun('a '), const NoteRun('b', bold: true)]),
    ];
    final made = await module.createFromFile(_file('Report.noted-blocks.json', encodeNoteBlocksFile(blocks)), store);
    expect(made, isNotNull);
    expect(children(made!.$1), blocks);
    expect(made.$2.width, 480);
    expect(const NoteCodec().decode(const NoteCodec().encode(made.$1), 1).document, made.$1.document);
  });

  test('a table widens the box', () async {
    final rows = [
      for (var r = 0; r < 3; r++) [for (var c = 0; c < 20; c++) '$r'],
    ];
    final made = await module.createFromFile(_file('s.noted-blocks.json', encodeNoteBlocksFile(noteTables(rows))), store);
    expect(made!.$2.width, 1100);
  });

  test('an invalid block refuses the file', () async {
    List<int> file(Object? b) => utf8.encode(jsonEncode({'version': 1, 'blocks': b}));
    for (final bad in [
      file([
        {'type': 7},
      ]),
      file([
        {
          'type': 'paragraph',
          'data': {'delta': 'x'},
        },
      ]),
      utf8.encode('{"version":1}'),
      utf8.encode('garbage'),
    ]) {
      expect(await module.createFromFile(_file('x.noted-blocks.json', bad), store), isNull);
    }
  });

  test('.md gives markdownToNoteBlocks\' blocks', () async {
    const md = '# Title\r\n\r\nSome *text*\r\n';
    for (final name in ['n.md', 'N.MD', 'n.markdown']) {
      final made = await module.createFromFile(_file(name, utf8.encode(md)), store);
      expect(children(made!.$1), markdownToNoteBlocks(md));
    }
    expect(await module.createFromFile(_file('n.md', utf8.encode('  \n')), store), isNull);
  });

  test('other files are refused and no file is taken by affinity', () async {
    expect(await module.createFromFile(_file('n.txt', utf8.encode('x')), store), isNull);
    for (final name in ['a.md', 'a.noted-blocks.json', 'a.txt', 'a.png', 'a.pdf']) {
      expect(module.fileAffinity(_file(name, const [1])), 0, reason: name);
    }
  });

  test('imported cells that start with = stay text in the editor, also after reload', () async {
    const texts = ['=1+1', '=SUM(', '=', 'a=b', 'plain'];
    final blocks = noteTables([
      ['head'],
      for (final t in texts) [t],
    ]);
    final made = await module.createFromFile(_file('s.noted-blocks.json', encodeNoteBlocksFile(blocks)), store);

    void check(Map<String, Object?> document) {
      final editor = NoteEditorState(document: Document.fromJson(document));
      TableFormulas(editor).initialize();
      final cells = editor.document.root.children.first.children;
      final shown = <String>[];
      for (final c in cells) {
        final p = c.children.first;
        expect(p.attributes['formulaValue'], isNull, reason: p.delta!.toPlainText());
        shown.add(p.delta!.toPlainText().replaceAll('​', ''));
      }
      expect(shown, ['head', ...texts]);
    }

    check(made!.$1.document);
    // After reload: saved as JSON and read again.
    final reloaded = jsonDecode(jsonEncode(const NoteCodec().encode(made.$1))) as Map<String, dynamic>;
    check(reloaded);
    expect(tableCellText('a=b'), 'a=b');
    expect(tableCellText('=x'), '​=x');
  });
}
