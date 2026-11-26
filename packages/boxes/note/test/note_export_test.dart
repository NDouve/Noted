// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The note box's export (Box API 0.18): plain text, markdown, a web page and
// the host's picture of its view.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';

NoteData _note(List<Map<String, Object?>> children) => NoteData({
  'document': {'type': 'page', 'children': children},
});

Map<String, Object?> _para(String text, [Map<String, Object?>? attrs]) => {
  'type': 'paragraph',
  'data': {
    'delta': [
      {'insert': text, 'attributes': ?attrs},
    ],
  },
};

void main() {
  const module = NoteModule();
  const context = ExportContext(size: Size(300, 100));
  Future<String> text(NoteData d, ExportFormat f, [ExportContext c = context]) async =>
      utf8.decode((await module.export(d, f, c))!.bytes);

  test('lists text, markdown, html and png; the host adds jpeg and pdf', () {
    expect(
      [for (final f in module.exportFormats(_note([_para('x')]))) f.id],
      ['text', 'markdown', 'html', 'png'],
    );
  });

  test('plain text is the note\'s snapshot text', () async {
    final data = _note([_para('Hello'), _para('World')]);
    expect(await text(data, ExportFormat.text), const NoteCodec().snapshotText(data));
    expect(await text(data, ExportFormat.text), contains('Hello'));
  });

  test('markdown is the escaped export form', () async {
    final data = _note([_para('a [b](javascript:x) <i>')]);
    expect(await text(data, ExportFormat.markdown), r'a \[b\]\(javascript:x\) &lt;i>');
  });

  test('html is a standalone page', () async {
    final out = await text(_note([_para('x <b>')]), ExportFormat.html);
    expect(out, contains('<p>x &lt;b&gt;</p>'));
    expect(out, contains('<!DOCTYPE html>'));
  });

  test('png is the host\'s picture of the view, or nothing without one', () async {
    final png = Uint8List.fromList([1, 2, 3]);
    final c = ExportContext(size: const Size(10, 10), viewRenderer: () async => png);
    final file = await module.export(_note([_para('x')]), ExportFormat.png, c);
    expect(file!.bytes, png);
    expect(file.name, isEmpty);
    expect(await module.export(_note([_para('x')]), ExportFormat.png, context), isNull);
  });

  test('a format it doesn\'t list gives nothing', () async {
    expect(await module.export(_note([_para('x')]), ExportFormat.svg, context), isNull);
  });
}
