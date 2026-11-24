// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

/// A zip file for tests: entries by name, stored or deflated.
Uint8List buildZip(
  Map<String, Object> entries, {
  bool store = false,
  bool encrypted = false,
  bool zip64 = false,
  int? claimedSize,
}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var count = 0;
  for (final e in entries.entries) {
    final name = utf8.encode(e.key);
    final raw = e.value is String ? utf8.encode(e.value as String) : e.value as List<int>;
    final packed = store ? raw : ZLibEncoder(raw: true).convert(raw);
    final offset = out.length;
    final flags = encrypted ? 1 : 0;
    final method = store ? 0 : 8;
    final usize = claimedSize ?? raw.length;
    final crc = _crc32(raw);
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, flags, Endian.little)
      ..setUint16(8, method, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, packed.length, Endian.little)
      ..setUint32(22, usize, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(name)
      ..add(packed);
    final c = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, flags, Endian.little)
      ..setUint16(10, method, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, packed.length, Endian.little)
      ..setUint32(24, usize, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(c.buffer.asUint8List())
      ..add(name);
    count++;
  }
  final cdOffset = out.length;
  out.add(central.takeBytes());
  final cdSize = out.length - cdOffset;
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, zip64 ? 0xFFFF : count, Endian.little)
    ..setUint16(10, zip64 ? 0xFFFF : count, Endian.little)
    ..setUint32(12, cdSize, Endian.little)
    ..setUint32(16, cdOffset, Endian.little);
  out.add(end.buffer.asUint8List());
  return out.takeBytes();
}

const String _w = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"';

/// A `.docx` with [body] as the content of `w:body`, and optional numbering.
Uint8List buildDocx(String body, {String? numbering, bool store = false}) => buildZip({
  'word/document.xml': '<?xml version="1.0"?><w:document $_w><w:body>$body</w:body></w:document>',
  'word/numbering.xml': ?(numbering == null ? null : '<w:numbering $_w>$numbering</w:numbering>'),
}, store: store);

/// A `w:p` of plain runs.
String wp(String text, {String? style, bool bold = false, bool italic = false, String? numId}) =>
    '<w:p><w:pPr>${style == null ? '' : '<w:pStyle w:val="$style"/>'}'
    '${numId == null ? '' : '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="$numId"/></w:numPr>'}</w:pPr>'
    '<w:r><w:rPr>${bold ? '<w:b/>' : ''}${italic ? '<w:i/>' : ''}</w:rPr><w:t xml:space="preserve">${_esc(text)}</w:t></w:r></w:p>';

String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// An `.xlsx` of named sheets, each a map from reference to cell XML
/// (`<c r="A1" ...>`), with optional shared strings.
Uint8List buildXlsx(Map<String, String> sheets, {List<String> shared = const []}) {
  const ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
  final names = sheets.keys.toList();
  return buildZip({
    'xl/workbook.xml':
        '<workbook $ns><sheets>${[for (var i = 0; i < names.length; i++) '<sheet name="${names[i]}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}</sheets></workbook>',
    'xl/_rels/workbook.xml.rels':
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '${[for (var i = 0; i < names.length; i++) '<Relationship Id="rId${i + 1}" Target="worksheets/sheet${i + 1}.xml"/>'].join()}</Relationships>',
    if (shared.isNotEmpty)
      'xl/sharedStrings.xml': '<sst $ns>${[for (final s in shared) '<si><t>${_esc(s)}</t></si>'].join()}</sst>',
    for (var i = 0; i < names.length; i++)
      'xl/worksheets/sheet${i + 1}.xml': '<worksheet $ns><sheetData>${sheets[names[i]]}</sheetData></worksheet>',
  });
}

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? 0xEDB88320 ^ (crc >>> 1) : crc >>> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
