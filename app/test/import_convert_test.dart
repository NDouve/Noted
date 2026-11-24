// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/import/convert.dart';
import 'package:noted/src/import/import_format.dart';
import 'package:noted/src/import/import_limits.dart';
import 'package:noted/src/import/import_result.dart';
import 'package:noted/src/import/zip_reader.dart';
import 'package:noted_core/noted_core.dart';

import 'support/zip_builder.dart';

ConvertedNotes conv(ImportFormat f, String name, List<int> bytes, [ImportLimits limits = ImportLimits.desktop]) =>
    convertToNotesNow(f, name, Uint8List.fromList(bytes), limits);

List<Map<String, Object?>> blocksOf(ConvertedNotes r) {
  expect(r.error, isNull);
  return [for (final b in r.boxes) ...b];
}

Map<String, Object?> dataOf(Map<String, Object?> b) => (b['data'] ?? const <String, Object?>{}) as Map<String, Object?>;

List<Map<String, Object?>> delta(Map<String, Object?> b) => [
  for (final o in (dataOf(b)['delta'] as List? ?? const [])) o as Map<String, Object?>,
];

String textOf(Map<String, Object?> b) => delta(b).map((o) => o['insert']).join();

/// The cell texts of a table block, row by row.
List<List<String>> rowsOf(Map<String, Object?> table) {
  final d = dataOf(table);
  final rows = d['rowsLen'] as int, cols = d['colsLen'] as int;
  final out = [for (var r = 0; r < rows; r++) List.filled(cols, '')];
  for (final c in table['children']! as List) {
    final cd = dataOf(c as Map<String, Object?>);
    final para = (c['children']! as List).first as Map<String, Object?>;
    out[cd['rowPosition']! as int][cd['colPosition']! as int] = textOf(para);
  }
  return out;
}

void main() {
  group('txt', () {
    test('a run of lines is one paragraph with line breaks; blank lines separate', () {
      final b = blocksOf(conv(ImportFormat.text, 'n.txt', utf8.encode('one\r\ntwo\n\n\nthree\n')));
      expect(b.map(textOf), ['one\ntwo', 'three']);
      expect(b.map((e) => e['type']), everyElement('paragraph'));
    });

    test('no markdown is read, and bad bytes are replaced', () {
      final b = blocksOf(conv(ImportFormat.text, 'n.txt', [...utf8.encode('# not *a* heading '), 0xFF]));
      expect(b.single['type'], 'paragraph');
      expect(textOf(b.single), '# not *a* heading �');
    });

    test('an empty file has nothing to import', () {
      expect(conv(ImportFormat.text, 'n.txt', utf8.encode('  \n')).error, 'has no text to import');
    });
  });

  group('markdown', () {
    test('blocks are markdownToNoteBlocks\'', () {
      const md = '# T\n\n- a\n- b\n';
      final r = conv(ImportFormat.markdown, 'n.md', utf8.encode(md));
      expect(blocksOf(r), markdownToNoteBlocks(md));
    });
  });

  group('csv and tsv', () {
    test('quoting, quotes, a newline in a cell, CRLF rows', () {
      final r = conv(ImportFormat.csv, 'a.csv', utf8.encode('a,b\r\n"x,1","he said ""hi"""\r\n"line1\nline2",\r\n'));
      final t = blocksOf(r).single;
      expect(rowsOf(t), [
        ['a', 'b'],
        ['x,1', 'he said "hi"'],
        ['line1\nline2', ''],
      ]);
    });

    test('a tsv splits on tabs', () {
      final t = blocksOf(conv(ImportFormat.csv, 'a.tsv', utf8.encode('a\tb\n1,5\t2\n'))).single;
      expect(rowsOf(t), [
        ['a', 'b'],
        ['1,5', '2'],
      ]);
    });

    test('a one-row file is kept; an empty one refused', () {
      expect(rowsOf(blocksOf(conv(ImportFormat.csv, 'a.csv', utf8.encode('x,y'))).single), [
        ['x', 'y'],
      ]);
      expect(conv(ImportFormat.csv, 'a.csv', utf8.encode('\n\n')).error, 'has nothing to import');
    });

    test('rows and columns past the limits are cut and named once', () {
      final text = [for (var r = 0; r < 600; r++) [for (var c = 0; c < 60; c++) 'x'].join(',')].join('\n');
      final r = conv(ImportFormat.csv, 'a.csv', utf8.encode(text));
      final cells = blocksOf(r).map((t) => dataOf(t)).toList();
      expect(cells.every((d) => d['colsLen'] == 50), isTrue);
      expect(r.notices.single, contains('rows past 500'));
      expect(r.notices.single, contains('columns past 50'));
    });
  });

  group('zip', () {
    final limits = ImportLimits.desktop;
    test('stored and deflated entries are read by name', () {
      for (final store in [true, false]) {
        final z = ZipReader(buildZip({'a.txt': 'hello', 'b/c.bin': List.generate(5000, (i) => i % 7)}, store: store), limits);
        expect(utf8.decode(z.read('a.txt')!), 'hello');
        expect(z.read('b/c.bin'), List.generate(5000, (i) => i % 7));
        expect(z.read('none'), isNull);
        expect(z.has('a.txt'), isTrue);
      }
    });

    test('a bomb stops at the limit', () {
      final zip = buildZip({'big.bin': Uint8List(8 * 1024 * 1024)});
      const small = ImportLimits(sourceBytes: 1 << 30, entryBytes: 1024 * 1024, archiveBytes: 1 << 30);
      expect(() => ZipReader(zip, small).read('big.bin'), throwsA(isA<ImportException>().having((e) => e.reason, 'reason', 'is too large to import')));
      // A header that lies about the size is stopped by the count, not believed.
      final lying = buildZip({'big.bin': Uint8List(8 * 1024 * 1024)}, claimedSize: 10);
      expect(() => ZipReader(lying, limits).read('big.bin'), throwsA(isA<ImportException>()));
      // The whole archive counts too.
      const total = ImportLimits(sourceBytes: 1 << 30, entryBytes: 1 << 30, archiveBytes: 100 * 1024);
      final two = ZipReader(buildZip({'a': Uint8List(80 * 1024), 'b': Uint8List(80 * 1024)}), total);
      two.read('a');
      expect(() => two.read('b'), throwsA(isA<ImportException>()));
    });

    test('encrypted, zip64, truncated and garbage are refused', () {
      expect(() => ZipReader(buildZip({'a': 'x'}, encrypted: true), limits).read('a'),
          throwsA(isA<ImportException>().having((e) => e.reason, 'r', contains('encrypted'))));
      expect(() => ZipReader(buildZip({'a': 'x'}, zip64: true), limits), throwsA(isA<ImportException>()));
      final whole = buildZip({'a': 'x' * 1000});
      expect(() => ZipReader(Uint8List.sublistView(whole, 0, whole.length - 30), limits), throwsA(isA<ImportException>()));
      expect(() => ZipReader(Uint8List.fromList(List.filled(100, 7)), limits), throwsA(isA<ImportException>()));
      expect(() => ZipReader(Uint8List(0), limits), throwsA(isA<ImportException>()));
      // Data cut out from under a good directory.
      final z = buildZip({'a': 'y' * 100}, store: true);
      final cut = Uint8List.fromList(z)..setRange(0, 4, [0, 0, 0, 0]);
      expect(() => ZipReader(cut, limits).read('a'), throwsA(isA<ImportException>()));
    });

    test('too many entries are refused', () {
      const few = ImportLimits(sourceBytes: 1000, entryBytes: 1000, archiveBytes: 1000, entries: 3);
      expect(() => ZipReader(buildZip({for (var i = 0; i < 4; i++) 'f$i': 'x'}), few), throwsA(isA<ImportException>()));
    });
  });

  group('docx', () {
    test('headings, paragraphs, bold and italic', () {
      final b = blocksOf(conv(
        ImportFormat.word,
        'd.docx',
        buildDocx(
          wp('Title text', style: 'Title') +
              wp('Chapter', style: 'Heading2') +
              wp('plain') +
              wp('strong', bold: true) +
              wp('slanted', italic: true) +
              wp(''),
        ),
      ));
      expect(b.map((e) => e['type']), ['heading', 'heading', 'paragraph', 'paragraph', 'paragraph']);
      expect(dataOf(b[0])['level'], 1);
      expect(dataOf(b[1])['level'], 2);
      expect(delta(b[3]).single['attributes'], {'bold': true});
      expect(delta(b[4]).single['attributes'], {'italic': true});
    });

    test('lists: numbered by numbering.xml, else bulleted', () {
      const numbering =
          '<w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>'
          '<w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>'
          '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>';
      final b = blocksOf(conv(
        ImportFormat.word,
        'd.docx',
        buildDocx(wp('one', numId: '1') + wp('two', numId: '1') + wp('dot', numId: '2') + wp('zero', numId: '0'), numbering: numbering),
      ));
      expect(b.map((e) => e['type']), ['numbered_list', 'numbered_list', 'bulleted_list', 'paragraph']);
    });

    test('tables, including one of a single row', () {
      String tr(List<String> cells) => '<w:tr>${cells.map((c) => '<w:tc>${wp(c)}</w:tc>').join()}</w:tr>';
      final b = blocksOf(conv(
        ImportFormat.word,
        'd.docx',
        buildDocx('<w:tbl>${tr(['a', 'b'])}${tr(['1', '2'])}</w:tbl>${wp('between')}<w:tbl>${tr(['only', 'row'])}</w:tbl>'),
      ));
      expect(b.map((e) => e['type']), ['table', 'paragraph', 'table']);
      expect(rowsOf(b[0]), [
        ['a', 'b'],
        ['1', '2'],
      ]);
      expect(rowsOf(b[2]), [
        ['only', 'row'],
      ]);
    });

    test('a tracked deletion is dropped, an insertion kept, line breaks and tabs read', () {
      const body = '<w:p><w:r><w:t>keep </w:t></w:r><w:del><w:r><w:delText>gone</w:delText></w:r></w:del>'
          '<w:ins><w:r><w:t>added</w:t></w:r></w:ins><w:r><w:br/><w:tab/><w:t>x</w:t></w:r></w:p>';
      final b = blocksOf(conv(ImportFormat.word, 'd.docx', buildDocx(body)));
      expect(textOf(b.single), 'keep added\n\tx');
    });

    test('text is literal: * [1] & \$ stay, with no backslash', () {
      final b = blocksOf(conv(ImportFormat.word, 'd.docx', buildDocx(wp(r'*a* [1] & $x$ _y_ <b>'))));
      expect(textOf(b.single), r'*a* [1] & $x$ _y_ <b>');
      final json = utf8.decode(encodeNoteBlocksFile(b));
      expect(json, isNot(contains(r'\\')));
    });

    test('a long document goes past 0118\'s markdown budget unchanged', () {
      final body = [for (var i = 0; i < 6000; i++) wp('*item* [$i] \$x\$ a_b_c')].join();
      final b = blocksOf(conv(ImportFormat.word, 'd.docx', buildDocx(body)));
      expect(b.length, 6000);
      expect(textOf(b.last), '*item* [5999] \$x\$ a_b_c');
    });

    test('a DOCTYPE, an invalid numeric reference and deep nesting are refused', () {
      ConvertedNotes of(String xml) => conv(
        ImportFormat.word,
        'd.docx',
        buildZip({'word/document.xml': xml}),
      );
      const open = '<w:document xmlns:w="x"><w:body>';
      const close = '</w:body></w:document>';
      expect(of('<!DOCTYPE d [<!ENTITY a "b">]>$open${wp('&a;')}$close').error, contains('document type'));
      for (final ref in ['&#0;', '&#xD800;', '&#x110000;', '&#xZZ;', '&#;']) {
        expect(of('$open<w:p><w:r><w:t>$ref</w:t></w:r></w:p>$close').error, isNotNull, reason: ref);
      }
      expect(of('$open<w:p><w:r><w:t>&#x41;&#66;&amp;&lt;</w:t></w:r></w:p>$close').error, isNull);
      expect(of('$open${'<w:x>' * 300}${'</w:x>' * 300}$close').error, contains('nested too deeply'));
      expect(of('$open${'<w:x>' * 200}${'</w:x>' * 200}${wp('ok')}$close').error, isNull);
      expect(of('$open<w:p>').error, isNotNull, reason: 'unclosed');
    });

    test('a Word file with no text, a non-Word zip and a broken zip are refused', () {
      expect(conv(ImportFormat.word, 'd.docx', buildDocx('')).error, 'has no text to import');
      expect(conv(ImportFormat.word, 'd.docx', buildZip({'x': 'y'})).error, 'is not a Word document');
      expect(conv(ImportFormat.word, 'd.docx', [1, 2, 3]).error, 'can’t be read');
    });

    test('more than 50 columns are cut and said', () {
      final cells = [for (var i = 0; i < 60; i++) '<w:tc>${wp('c$i')}</w:tc>'].join();
      final r = conv(ImportFormat.word, 'd.docx', buildDocx('<w:tbl><w:tr>$cells</w:tr></w:tbl>'));
      expect(dataOf(blocksOf(r).single)['colsLen'], 50);
      expect(r.notices.single, contains('50'));
    });
  });

  group('xlsx', () {
    String c(String ref, String v, {String? t}) => '<c r="$ref"${t == null ? '' : ' t="$t"'}><v>$v</v></c>';
    String row(int n, String cells) => '<row r="$n">$cells</row>';

    test('shared, inline and plain strings, booleans, numbers, cached formulas and two sheets', () {
      final bytes = buildXlsx({
        'First': row(1, c('A1', '0', t: 's') + c('B1', '1', t: 's')) +
            row(
              2,
              '<c r="A2" t="inlineStr"><is><t>inline</t></is></c>'
              '<c r="B2" t="str"><v>plain</v></c>'
              '<c r="C2" t="b"><v>1</v></c>'
              '<c r="D2"><v>3.50</v></c>'
              '<c r="E2"><f>SUM(A1:B1)</f><v>7</v></c>'
              '<c r="F2" t="e"><v>#DIV/0!</v></c>',
            ),
        'Second': row(1, c('A1', '2', t: 's')),
      }, shared: ['Name', 'Qty', 'only']);
      final r = conv(ImportFormat.sheet, 'x.xlsx', bytes);
      final b = blocksOf(r);
      expect(b.map((e) => e['type']), ['heading', 'table', 'heading', 'table']);
      expect(textOf(b[0]), 'First');
      expect(textOf(b[2]), 'Second');
      expect(rowsOf(b[1]), [
        ['Name', 'Qty', '', '', '', ''],
        ['inline', 'plain', 'TRUE', '3.50', '7', '#DIV/0!'],
      ]);
      expect(rowsOf(b[3]), [
        ['only'],
      ]);
    });

    test('a far cell is skipped without a dense grid, and the cut is named', () {
      final bytes = buildXlsx({'S': row(1, c('A1', '1') + c('XFD1', '2')) + row(1048576, c('XFD1048576', '9'))});
      final sw = Stopwatch()..start();
      final r = conv(ImportFormat.sheet, 'x.xlsx', bytes);
      expect(sw.elapsedMilliseconds, lessThan(5000));
      final t = blocksOf(r).last;
      expect(rowsOf(t), [
        ['1'],
      ]);
      expect(r.notices.single, allOf(contains('rows past 500'), contains('columns past 50'), contains('S')));
    });

    test('a sheet over 2,000 cells is split by rows into boxes of at most 2,000 cells, header repeated', () {
      final rows = StringBuffer();
      for (var r = 1; r <= 500; r++) {
        rows.write(row(r, [for (var k = 0; k < 50; k++) c('${_col(k)}$r', '${r * 100 + k}')].join()));
      }
      final r = conv(ImportFormat.sheet, 'x.xlsx', buildXlsx({'Big': rows.toString()}));
      expect(r.error, isNull);
      expect(r.boxes.length, greaterThan(5));
      var dataRows = 0;
      for (final box in r.boxes) {
        final tables = box.where((b) => b['type'] == 'table').toList();
        expect(tables.length, 1, reason: 'a table never spans boxes, one per box here');
        final cells = tables.fold<int>(0, (n, t) => n + noteBlockCells(t));
        expect(cells, lessThanOrEqualTo(2000));
        final rowsHere = rowsOf(tables.single);
        expect(rowsHere.first.first, '100', reason: 'the first row is every part\'s header');
        dataRows += rowsHere.length - 1;
      }
      expect(dataRows, 499);
      // The first box has the heading.
      expect(r.boxes.first.first['type'], 'heading');
    });

    test('a \$-heavy sheet gives real table blocks, not text', () {
      final rows = StringBuffer();
      for (var i = 1; i <= 300; i++) {
        rows.write(row(i, '${c('A$i', '$i')}<c r="B$i" t="inlineStr"><is><t>\$x\$ [a] *b* \$y\$</t></is></c>'));
      }
      final r = conv(ImportFormat.sheet, 'x.xlsx', buildXlsx({'D': rows.toString()}));
      final t = blocksOf(r).where((b) => b['type'] == 'table');
      expect(t, isNotEmpty);
      expect(rowsOf(t.first)[1][1], '\$x\$ [a] *b* \$y\$');
    });

    test('a one-row sheet is kept, an empty workbook refused', () {
      final r = conv(ImportFormat.sheet, 'x.xlsx', buildXlsx({'One': row(1, c('A1', '5') + c('B1', '6'))}));
      expect(rowsOf(blocksOf(r).last), [
        ['5', '6'],
      ]);
      expect(conv(ImportFormat.sheet, 'x.xlsx', buildXlsx({'E': ''})).error, 'has nothing to import');
      expect(conv(ImportFormat.sheet, 'x.xlsx', buildZip({'a': 'b'})).error, 'is not an Excel workbook');
    });

    test('a DOCTYPE in a sheet refuses the file', () {
      final z = buildZip({
        'xl/workbook.xml': '<workbook><sheets><sheet name="S" id="r1"/></sheets></workbook>',
        'xl/_rels/workbook.xml.rels': '<Relationships><Relationship Id="r1" Target="worksheets/s.xml"/></Relationships>',
        'xl/worksheets/s.xml': '<!DOCTYPE x><worksheet/>',
      });
      expect(conv(ImportFormat.sheet, 'x.xlsx', z).error, contains('document type'));
    });
  });

  group('notices', () {
    final long = 'y' * 3000;
    const shortened = 'long cells were shortened.';

    test('long cells are shortened and said, with the file named', () {
      final d = conv(ImportFormat.word, 'd.docx', buildDocx('<w:tbl><w:tr><w:tc>${wp(long)}</w:tc></w:tr></w:tbl>'));
      expect(d.notices, ['"d.docx": $shortened']);
      final x = conv(
        ImportFormat.sheet,
        'x.xlsx',
        buildXlsx({'S': '<row r="1"><c r="A1" t="inlineStr"><is><t>$long</t></is></c></row>'}),
      );
      expect(x.notices, ['"x.xlsx": $shortened']);
      final c = conv(ImportFormat.csv, 'a.csv', utf8.encode('a,b\n$long,2'));
      expect(c.notices, ['"a.csv": $shortened']);
      final cell = rowsOf(blocksOf(c).single)[1][0];
      expect(utf8.encode(cell).length, 2048);
      expect(conv(ImportFormat.csv, 'a.csv', utf8.encode('a,b\n1,2')).notices, isEmpty);
    });

    test('cut rows and columns name the file, and a csv has no sheet label', () {
      final text = [for (var r = 0; r < 600; r++) [for (var c = 0; c < 60; c++) 'x'].join(',')].join('\n');
      final n = conv(ImportFormat.csv, 'a.csv', utf8.encode(text)).notices.single;
      expect(n, '"a.csv": left out rows past 500; columns past 50.');
      final cells = [for (var k = 0; k < 60; k++) '<w:tc>${wp('c')}</w:tc>'].join();
      expect(conv(ImportFormat.word, 'd.docx', buildDocx('<w:tbl><w:tr>$cells</w:tr></w:tbl>')).notices.single, startsWith('"d.docx": '));
    });
  });

  group('sizes', () {
    test('text over 256 KiB goes into more note boxes', () {
      final text = List.generate(600, (i) => 'p${'x' * 1000}').join('\n\n');
      final r = conv(ImportFormat.text, 'long.txt', utf8.encode(text));
      expect(r.boxes.length, 3);
      expect(r.notices, isEmpty);
      for (final box in r.boxes) {
        expect(box.fold<int>(0, (n, b) => n + noteBlockBytes(b)), lessThanOrEqualTo(256 * 1024));
      }
      expect(r.boxes.expand((b) => b).length, 600);
    });

    test('one paragraph over 256 KiB is cut', () {
      final r = conv(ImportFormat.text, 'one.txt', utf8.encode('y' * (600 * 1024)));
      expect(r.boxes.length, 3);
    });

    test('past 20 boxes the rest is dropped and the file named', () {
      final text = List.generate(100, (i) => 'x' * 100).join('\n\n');
      const tiny = ImportLimits(sourceBytes: 1 << 20, entryBytes: 1 << 20, archiveBytes: 1 << 20, noteBytes: 400);
      final r = conv(ImportFormat.text, 'big.txt', utf8.encode(text), tiny);
      expect(r.boxes.length, 20);
      expect(r.notices, ['"big.txt" is too long; the first part was imported.']);
    });

    test('the isolate gives the same result', () async {
      final bytes = Uint8List.fromList(utf8.encode('a\n\nb'));
      final r = await convertToNotes(ImportFormat.text, 'n.txt', bytes, ImportLimits.desktop);
      expect(r.boxes.single.map(textOf), ['a', 'b']);
    });
  });

  test('formats by extension, and what the dialog asks', () {
    expect(ImportFormat.of('A.DOCX'), ImportFormat.word);
    expect(ImportFormat.of('a.tsv'), ImportFormat.csv);
    expect(ImportFormat.of('a.doc'), isNull);
    expect(ImportFormat.of('noext'), isNull);
  });
}

String _col(int i) => i < 26 ? String.fromCharCode(0x41 + i) : String.fromCharCode(0x41 + i ~/ 26 - 1) + String.fromCharCode(0x41 + i % 26);
