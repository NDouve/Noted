// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:noted_core/noted_core.dart';

import 'import_limits.dart';
import 'import_result.dart';
import 'mini_xml.dart';
import 'sheet_blocks.dart';
import 'zip_reader.dart';

/// The sheets of an `.xlsx` as tables: shared, inline and plain strings,
/// booleans, numbers as written, formulas as their cached value, dates as the
/// stored number (cell formats aren't applied). A cell is placed by its
/// reference; one past the row or column limit is skipped before anything is
/// allocated, and `<dimension>` is ignored.
BlocksResult xlsxToBlocks(Uint8List bytes, ImportLimits limits) => sheetsToBlocks(xlsxSheets(bytes, limits), limits);

/// The sheets of an `.xlsx`, in workbook order.
List<SheetData> xlsxSheets(Uint8List bytes, ImportLimits limits) {
  final zip = ZipReader(bytes, limits);
  final workbook = zip.read('xl/workbook.xml');
  if (workbook == null) throw const ImportException('is not an Excel workbook');
  final wb = parseXmlTree(_decode(workbook), maxDepth: limits.xmlDepth);
  final rels = <String, String>{};
  final relBytes = zip.read('xl/_rels/workbook.xml.rels');
  if (relBytes != null) {
    for (final r in parseXmlTree(_decode(relBytes), maxDepth: limits.xmlDepth).elements) {
      final id = r.attributes['Id'], target = r.attributes['Target'];
      if (id != null && target != null) rels[id] = _partPath(target);
    }
  }
  final shared = <String>[];
  final sharedBytes = zip.read('xl/sharedStrings.xml');
  if (sharedBytes != null) {
    parseXml(_decode(sharedBytes), _SharedStrings(shared), maxDepth: limits.xmlDepth);
  }
  final sheets = <SheetData>[];
  var n = 0;
  for (final s in wb.child('sheets')?.elements ?? const <XmlElement>[]) {
    if (s.name != 'sheet') continue;
    n++;
    final name = s.attributes['name'] ?? 'Sheet $n';
    final path = rels[s.attributes['id'] ?? ''] ?? 'xl/worksheets/sheet$n.xml';
    final data = zip.read(path);
    if (data == null) continue;
    final h = _SheetReader(shared, limits);
    parseXml(_decode(data), h, maxDepth: limits.xmlDepth);
    sheets.add(gridOf(name, h.cells, rowsCut: h.rowsCut, columnsCut: h.columnsCut));
  }
  if (sheets.isEmpty) throw const ImportException('has no sheets to import');
  return sheets;
}

String _decode(Uint8List b) => utf8.decode(b, allowMalformed: true);

/// A part path from a relationship target, relative to `xl/`.
String _partPath(String target) {
  if (target.startsWith('/')) return target.substring(1);
  final parts = <String>['xl'];
  for (final p in target.split('/')) {
    if (p == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else if (p.isNotEmpty && p != '.') {
      parts.add(p);
    }
  }
  return parts.join('/');
}

/// `xl/sharedStrings.xml`: the text of each `si` (not its phonetic runs).
class _SharedStrings implements XmlHandler {
  _SharedStrings(this.out);

  final List<String> out;
  final List<String> _stack = [];
  StringBuffer? _current;

  @override
  void start(String name, Map<String, String> attributes) {
    _stack.add(name);
    if (name == 'si') _current = StringBuffer();
  }

  @override
  void end(String name) {
    _stack.removeLast();
    if (name == 'si') {
      out.add(cutUtf8(_current.toString(), noteCellMaxBytes));
      _current = null;
    }
  }

  @override
  void text(String text) {
    if (_current != null && _stack.isNotEmpty && _stack.last == 't' && !_stack.contains('rPh')) {
      if (_current!.length < noteCellMaxBytes * 2) _current!.write(text);
    }
  }
}

/// One worksheet: its `c` cells, placed by reference.
class _SheetReader implements XmlHandler {
  _SheetReader(this._shared, this._limits);

  final List<String> _shared;
  final ImportLimits _limits;

  /// Row to column to text.
  final Map<int, Map<int, String>> cells = {};
  bool rowsCut = false;
  bool columnsCut = false;

  final List<String> _stack = [];
  int _row = -1;
  int _col = -1;
  String? _type;
  bool _skip = false;
  StringBuffer _value = StringBuffer();
  StringBuffer _inline = StringBuffer();
  bool _hasValue = false;

  @override
  void start(String name, Map<String, String> attributes) {
    _stack.add(name);
    switch (name) {
      case 'row':
        final r = int.tryParse(attributes['r'] ?? '');
        _row = r != null && r > 0 ? r - 1 : _row + 1;
        _col = -1;
      case 'c':
        final ref = _parseRef(attributes['r']);
        if (ref != null) {
          _row = ref.$1;
          _col = ref.$2;
        } else {
          _col++;
        }
        _type = attributes['t'];
        // Past a limit, the cell is read no further and nothing is stored.
        _skip = _row >= _limits.rows || _col >= _limits.columns;
        _value = StringBuffer();
        _inline = StringBuffer();
        _hasValue = false;
    }
  }

  @override
  void end(String name) {
    _stack.removeLast();
    if (name != 'c') return;
    final text = _cellText();
    if (text.isEmpty) return;
    if (_row >= _limits.rows) {
      rowsCut = true;
      return;
    }
    if (_col >= _limits.columns) {
      columnsCut = true;
      return;
    }
    (cells[_row] ??= {})[_col] = text;
  }

  @override
  void text(String text) {
    if (!_stack.contains('c')) return;
    if (_skip) {
      if (text.trim().isNotEmpty && (_stack.last == 'v' || _stack.last == 't')) _hasValue = true;
      return;
    }
    final last = _stack.last;
    if (last == 'v') {
      if (_value.length < noteCellMaxBytes * 2) _value.write(text);
    } else if (last == 't' && _stack.contains('is') && !_stack.contains('rPh')) {
      if (_inline.length < noteCellMaxBytes * 2) _inline.write(text);
    }
  }

  String _cellText() {
    if (_skip) {
      // Only whether the cell had anything matters.
      return _hasValue ? '-' : '';
    }
    final v = _value.toString();
    String t;
    switch (_type) {
      case 's':
        final i = int.tryParse(v.trim());
        t = i != null && i >= 0 && i < _shared.length ? _shared[i] : '';
      case 'inlineStr':
        t = _inline.toString();
      case 'b':
        t = v.trim() == '1' ? 'TRUE' : (v.trim() == '0' ? 'FALSE' : v);
      default:
        t = v;
    }
    _hasValue = t.isNotEmpty;
    return _hasValue ? cutUtf8(t, noteCellMaxBytes) : '';
  }
}

/// The zero-based (row, column) of a reference like `B7`, or null.
(int, int)? _parseRef(String? ref) {
  if (ref == null) return null;
  var i = 0;
  var col = 0;
  while (i < ref.length) {
    final c = ref.codeUnitAt(i);
    if (c < 0x41 || c > 0x5A) break;
    col = col * 26 + (c - 0x40);
    i++;
    if (i > 3) return null;
  }
  if (i == 0 || i == ref.length) return null;
  final row = int.tryParse(ref.substring(i));
  if (row == null || row < 1) return null;
  return (row - 1, col - 1);
}
