// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:noted_core/noted_core.dart';

import 'import_limits.dart';
import 'import_result.dart';
import 'mini_xml.dart';
import 'zip_reader.dart';

/// The most columns of a Word table that are kept.
const int docxMaxColumns = 50;

/// The note blocks of a `.docx`: headings, paragraphs, bulleted and numbered
/// list items, bold and italic text, line breaks and tabs, and tables (cell
/// text only, at most [docxMaxColumns] columns). Pictures, comments, field
/// codes and tracked deletions are dropped; tracked insertions are kept.
BlocksResult docxToBlocks(Uint8List bytes, ImportLimits limits, String fileName) {
  final zip = ZipReader(bytes, limits);
  final doc = zip.read('word/document.xml');
  if (doc == null) throw const ImportException('is not a Word document');
  final numbering = zip.read('word/numbering.xml');
  final formats = numbering == null ? const _Numbering({}, {}) : _readNumbering(_decode(numbering), limits);
  final root = parseXmlTree(_decode(doc), maxDepth: limits.xmlDepth);
  final body = root.child('body');
  if (body == null) throw const ImportException('is not a Word document');
  final blocks = <Map<String, Object?>>[];
  final notices = <String>[];
  var cutColumns = false;
  var longCells = false;

  void walk(XmlElement parent) {
    for (final e in parent.elements) {
      switch (e.name) {
        case 'p':
          final b = _paragraph(e, formats);
          if (b != null) blocks.add(b);
        case 'tbl':
          final rows = _tableRows(e);
          if (rows.isEmpty) break;
          var cols = 0;
          for (final r in rows) {
            if (r.length > cols) cols = r.length;
          }
          if (cols > docxMaxColumns) {
            cutColumns = true;
            for (var i = 0; i < rows.length; i++) {
              if (rows[i].length > docxMaxColumns) rows[i] = rows[i].sublist(0, docxMaxColumns);
            }
          }
          longCells = longCells || rows.any((r) => r.any((c) => utf8.encode(c).length > noteCellMaxBytes));
          blocks.addAll(noteTables(rows, maxCells: limits.noteCells, maxBytes: limits.noteBytes));
        case 'sdt':
          final content = e.child('sdtContent');
          if (content != null) walk(content);
      }
    }
  }

  walk(body);
  if (cutColumns) notices.add('"$fileName": table columns past $docxMaxColumns were left out.');
  if (longCells) notices.add('"$fileName": long cells were shortened.');
  return BlocksResult(blocks, notices);
}

String _decode(Uint8List b) => utf8.decode(b, allowMalformed: true);

// ---- Lists --------------------------------------------------------------

class _Numbering {
  const _Numbering(this.numToAbstract, this.formats);

  /// numId to abstractNumId.
  final Map<String, String> numToAbstract;

  /// abstractNumId to the number format of each level.
  final Map<String, Map<int, String>> formats;

  bool numbered(String numId, int level) {
    final f = formats[numToAbstract[numId]];
    if (f == null) return false;
    return (f[level] ?? f[0]) == 'decimal';
  }
}

_Numbering _readNumbering(String xml, ImportLimits limits) {
  final root = parseXmlTree(xml, maxDepth: limits.xmlDepth);
  final nums = <String, String>{};
  final formats = <String, Map<int, String>>{};
  for (final e in root.elements) {
    if (e.name == 'abstractNum') {
      final id = e.attributes['abstractNumId'];
      if (id == null) continue;
      final levels = <int, String>{};
      for (final l in e.elements) {
        if (l.name != 'lvl') continue;
        final fmt = l.child('numFmt')?.attributes['val'];
        final level = int.tryParse(l.attributes['ilvl'] ?? '');
        if (fmt != null && level != null) levels[level] = fmt;
      }
      formats[id] = levels;
    } else if (e.name == 'num') {
      final id = e.attributes['numId'];
      final abs = e.child('abstractNumId')?.attributes['val'];
      if (id != null && abs != null) nums[id] = abs;
    }
  }
  return _Numbering(nums, formats);
}

// ---- Paragraphs ---------------------------------------------------------

Map<String, Object?>? _paragraph(XmlElement p, _Numbering numbering) {
  final runs = <NoteRun>[];
  _inline(p, runs, false, false);
  if (runs.every((r) => r.text.trim().isEmpty)) return null;
  final props = p.child('pPr');
  final style = (props?.child('pStyle')?.attributes['val'] ?? '').toLowerCase().replaceAll(' ', '');
  if (style == 'title') return noteHeading(1, runs);
  final heading = RegExp(r'^heading([1-9])$').firstMatch(style);
  if (heading != null) return noteHeading(int.parse(heading.group(1)!), runs);
  final num = props?.child('numPr');
  final numId = num?.child('numId')?.attributes['val'];
  if (numId != null && numId != '0') {
    final level = int.tryParse(num?.child('ilvl')?.attributes['val'] ?? '') ?? 0;
    return numbering.numbered(numId, level) ? noteNumberedItem(runs) : noteBulletedItem(runs);
  }
  return noteParagraph(runs);
}

bool _on(XmlElement? e) {
  if (e == null) return false;
  final v = e.attributes['val'];
  return v == null || !(v == '0' || v == 'false' || v == 'off');
}

/// The text runs under [e]. A tracked deletion is skipped, an insertion kept.
void _inline(XmlElement e, List<NoteRun> out, bool bold, bool italic) {
  for (final c in e.elements) {
    switch (c.name) {
      case 'r':
        final props = c.child('rPr');
        final b = bold || _on(props?.child('b'));
        final i = italic || _on(props?.child('i'));
        for (final x in c.elements) {
          switch (x.name) {
            case 't':
              out.add(NoteRun(x.text, bold: b, italic: i));
            case 'tab':
              out.add(NoteRun('\t', bold: b, italic: i));
            case 'br':
              if (x.attributes['type'] != 'page') out.add(NoteRun('\n', bold: b, italic: i));
            case 'cr':
              out.add(NoteRun('\n', bold: b, italic: i));
            case 'noBreakHyphen':
              out.add(NoteRun('-', bold: b, italic: i));
          }
        }
      case 'hyperlink' || 'ins' || 'smartTag' || 'fldSimple' || 'moveTo' || 'sdt' || 'sdtContent' || 'customXml':
        _inline(c, out, bold, italic);
    }
  }
}

// ---- Tables -------------------------------------------------------------

List<List<String>> _tableRows(XmlElement tbl) {
  final rows = <List<String>>[];
  for (final tr in tbl.elements) {
    if (tr.name != 'tr') continue;
    rows.add([
      for (final tc in tr.elements)
        if (tc.name == 'tc') _cellText(tc),
    ]);
  }
  return rows;
}

String _cellText(XmlElement tc) {
  final lines = <String>[];
  void walk(XmlElement e) {
    for (final c in e.elements) {
      if (c.name == 'p') {
        final runs = <NoteRun>[];
        _inline(c, runs, false, false);
        lines.add(runs.map((r) => r.text).join());
      } else if (c.name == 'tbl' || c.name == 'tr' || c.name == 'tc' || c.name == 'sdt' || c.name == 'sdtContent') {
        walk(c);
      }
    }
  }

  walk(tc);
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  return lines.join('\n');
}
