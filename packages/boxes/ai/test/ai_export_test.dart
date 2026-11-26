// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The AI box's export (Box API 0.18): its text with no `<ai-written>` marker,
// and a view that is only drawn for a picture stays out of the live registry.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_ai/noted_box_ai.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

Map<String, Object?> para(String text) => {
  'type': 'paragraph',
  'data': {
    'delta': [
      {'insert': text},
    ],
  },
};

AiBoxData data(List<Map<String, Object?>> blocks) => AiBoxData({
  'document': {'type': 'page', 'children': blocks},
});

void main() {
  final module = AiModule();
  const context = ExportContext(size: Size(300, 100));
  Future<String> out(AiBoxData d, ExportFormat f) async => utf8.decode((await module.export(d, f, context))!.bytes);

  final mixed = data([para('mine'), markAiWritten(para('theirs <b>')), para('after')]);

  test('the snapshot text has markers, the export has none', () async {
    expect(const AiCodec().snapshotText(mixed), contains('<ai-written>'));
    for (final f in [ExportFormat.text, ExportFormat.markdown, ExportFormat.html]) {
      expect(await out(mixed, f), isNot(contains('ai-written')), reason: f.id);
    }
    expect(await out(mixed, ExportFormat.text), 'mine\n\ntheirs <b>\n\nafter');
  });

  test('markdown is escaped, html is a page', () async {
    expect(await out(mixed, ExportFormat.markdown), contains('theirs &lt;b>'));
    expect(await out(mixed, ExportFormat.html), contains('<p>theirs &lt;b&gt;</p>'));
  });

  test('lists text, markdown, html and png', () {
    expect([for (final f in module.exportFormats(mixed)) f.id], ['text', 'markdown', 'html', 'png']);
  });

  testWidgets('an offscreen AI view is not in the note\'s live registry', (t) async {
    for (final offscreen in [false, true]) {
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(
        MaterialApp(
          localizationsDelegates: noteLocalizationsDelegates,
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 300,
              child: Builder(
                builder: (context) => module.hostBuild(
                  context,
                  BoxBinding(
                    boxId: 'ai',
                    data: mixed,
                    bounds: const Rect.fromLTWH(0, 0, 400, 300),
                    readOnly: true,
                    autoHeight: false,
                    autofocus: false,
                    commit: (_) {},
                    requestBounds: (_) {},
                    offscreen: offscreen,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(noteLiveCount('ai'), offscreen ? 0 : 1, reason: 'offscreen: $offscreen');
    }
  });
}
