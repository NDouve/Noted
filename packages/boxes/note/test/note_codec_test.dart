// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_core/noted_core.dart';

Map<String, Object?> para(String text) => {
  'type': 'paragraph',
  'data': {
    'delta': [
      if (text.isNotEmpty) {'insert': text},
    ],
  },
};

NoteData doc(List<Map<String, Object?>> children) => NoteData({
  'document': {'type': 'page', 'children': children},
});

void main() {
  const codec = NoteCodec();

  test('snapshot text has one line per block, including nested ones', () {
    final data = doc([
      para('Title'),
      {
        'type': 'bulleted_list',
        'data': {
          'delta': [
            {'insert': 'one '},
            {
              'insert': 'bold',
              'attributes': {'bold': true},
            },
          ],
        },
        'children': [para('nested')],
      },
    ]);
    expect(codec.snapshotText(data), 'Title\none bold\nnested');
    expect(codec.aiExposure(data), isA<AiText>());
  });

  test('empty means only blank paragraphs', () {
    expect(codec.isEmpty(codec.create()), isTrue);
    expect(codec.isEmpty(doc([para('  '), para('')])), isTrue);
    expect(codec.isEmpty(doc([para('x')])), isFalse);
    expect(codec.isEmpty(doc([{'type': 'divider'}])), isFalse);
  });

  test('decode accepts its own output and rejects anything else', () {
    final data = codec.create();
    final round = codec.decode(RawJson.encode(codec.encode(data)).decode(), 1);
    expect(codec.snapshotText(round), '');
    expect(() => codec.decode('text', 1), throwsFormatException);
    expect(() => codec.decode({'document': 3}, 1), throwsFormatException);
  });

  test('the codec file imports neither Flutter nor appflowy_editor', () {
    final f = [
      File('lib/src/note_codec.dart'),
      File('packages/boxes/note/lib/src/note_codec.dart'),
    ].firstWhere((f) => f.existsSync());
    final imports = f.readAsLinesSync().where((l) => l.startsWith('import '));
    expect(imports, everyElement(isNot(contains('flutter'))));
    expect(imports, everyElement(isNot(contains('appflowy'))));
  });
}
