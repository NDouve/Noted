// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/import/document_render.dart';
import 'package:noted/src/import/import_flow.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import '../support/harness.dart';

/// A PDF of [pages] pages of 612 by 792 points, written by hand: each page
/// fills a rectangle, so that it has something to draw.
Uint8List tinyPdf(int pages) {
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  void object(int n, String body) {
    offsets.add(out.length);
    out.write('$n 0 obj\n$body\nendobj\n');
  }

  final kids = [for (var i = 0; i < pages; i++) '${3 + 2 * i} 0 R'].join(' ');
  object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  object(2, '<< /Type /Pages /Kids [$kids] /Count $pages >>');
  for (var i = 0; i < pages; i++) {
    final page = 3 + 2 * i;
    object(page, '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents ${page + 1} 0 R >>');
    final content = '0.${i + 2} 0.4 0.6 rg ${50 + 40 * i} 100 300 400 re f';
    object(page + 1, '<< /Length ${content.length} >>\nstream\n$content\nendstream');
  }
  final xref = out.length;
  out.write('xref\n0 ${offsets.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size ${offsets.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return Uint8List.fromList(ascii.encode(out.toString()));
}

/// Import (design 2026-11-23-01): entry I1 in step_map.json.
void importSuite() {
  group('import', () {
    testWidgets('I1: a two-page PDF is two image boxes in order through the real renderer; a broken PDF is refused', (t) async {
      await withSession(t, 'importpdf', (s) async {
        final notices = <String>[];
        final sub = s.nb.attachmentNotices.listen(notices.add);
        addTearDown(sub.cancel);
        final canvas = t.state<PageCanvasState>(find.byType(PageCanvas));
        List<BoxRecord> boxes() => s.nb.current!.page.nodes.whereType<BoxRecord>().toList();

        Future<void> importPdf(String name, Uint8List bytes) async {
          importPicker = () async => [ImportSource(name, length: () async => bytes.length, read: () async => bytes)];
          unawaited(canvas.commands.invoke('app.import'));
          await s.until(() => find.byKey(const ValueKey('import-dialog')).evaluate().isNotEmpty, what: 'the import dialog');
          await t.tap(find.byKey(const ValueKey('import-choice-pagesAsImages')));
          await s.pump(100);
          await t.tap(find.byKey(const ValueKey('import-ok')));
          await s.pump(100);
          await s.until(() => importsRunning.value == 0, what: 'the import');
          await s.pump(300);
        }

        try {
          await importPdf('doc.pdf', tinyPdf(2));
          final b = boxes();
          expect(b.map((x) => x.typeId), ['noted.image', 'noted.image']);
          expect(b[0].data.toString(), contains('doc-1.png'));
          expect(b[1].data.toString(), contains('doc-2.png'));
          expect(b[1].bounds.y, greaterThan(b[0].bounds.y));
          await s.flush();
          final files = s.nb.attachments!.folder.listSync().whereType<File>().toList();
          expect(files, hasLength(2));
          for (final f in files) {
            expect(f.path, endsWith('.png'));
            final size = pngSize(f.readAsBytesSync());
            expect(size, isNotNull, reason: '${f.path} is a PNG');
            expect(size!.width, 1275);
            expect(size.height, 1650);
          }
          expect(notices, isEmpty);

          await importPdf('broken.pdf', Uint8List.fromList(utf8.encode('this is not a PDF')));
          expect(boxes(), hasLength(2));
          expect(notices, ['"broken.pdf" can’t be read.']);
        } finally {
          importPicker = pickImportSources;
        }
      });
    });
  });
}
