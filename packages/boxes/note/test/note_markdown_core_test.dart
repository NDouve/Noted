// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_core/noted_core.dart' as core;

void main() {
  test('the note package uses the core importer', () {
    expect(identical(markdownToNoteBlocks, core.markdownToNoteBlocks), isTrue);
  });

  test('the core importer writes what the note module reads: equation names and character', () {
    // The core importer hard-codes these (it has no NoteFormat).
    final block = markdownToNoteBlocks('\$\$ a \$\$').single;
    expect(block['type'], NoteFormat.mathBlockType);
    expect((block['data']! as Map).keys.single, NoteFormat.formulaKey);
    final inline = markdownToNoteBlocks('x \$y\$').single;
    final op = ((inline['data']! as Map)['delta']! as List)[1] as Map;
    expect(op['insert'], NoteFormat.inlineMathChar);
    expect((op['attributes']! as Map).keys.single, NoteFormat.formulaKey);
  });
}
