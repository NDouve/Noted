// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

// Builders for the blocks of a note document, in the form the note box
// stores them and `markdownToNoteBlocks` produces them. Text is stored
// literally: nothing is escaped or parsed, so no markup can appear.
// Pure Dart, so an import can build blocks off the UI isolate.

/// A stretch of text with one style.
final class NoteRun {
  const NoteRun(this.text, {this.bold = false, this.italic = false});

  final String text;
  final bool bold;
  final bool italic;
}

List<Map<String, Object?>> _delta(List<NoteRun> runs) {
  final out = <Map<String, Object?>>[];
  for (final r in runs) {
    if (r.text.isEmpty) continue;
    final last = out.isEmpty ? null : out.last;
    final attrs = last?['attributes'] as Map<String, Object?>?;
    if (last != null && (attrs?['bold'] == true) == r.bold && (attrs?['italic'] == true) == r.italic) {
      last['insert'] = '${last['insert']}${r.text}';
      continue;
    }
    out.add({
      'insert': r.text,
      if (r.bold || r.italic) 'attributes': <String, Object?>{if (r.bold) 'bold': true, if (r.italic) 'italic': true},
    });
  }
  return out;
}

Map<String, Object?> _textBlock(String type, List<NoteRun> runs, [Map<String, Object?> extra = const {}]) => {
  'type': type,
  'data': {'delta': _delta(runs), ...extra},
};

/// A paragraph; a `\n` in a run's text is a line break.
Map<String, Object?> noteParagraph(List<NoteRun> runs) => _textBlock('paragraph', runs);

/// A paragraph of one plain run.
Map<String, Object?> notePlainParagraph(String text) => noteParagraph([NoteRun(text)]);

/// A heading of [level] 1 to 6 (other values are clamped).
Map<String, Object?> noteHeading(int level, List<NoteRun> runs) => _textBlock('heading', runs, {'level': level.clamp(1, 6)});

Map<String, Object?> noteBulletedItem(List<NoteRun> runs) => _textBlock('bulleted_list', runs);

Map<String, Object?> noteNumberedItem(List<NoteRun> runs) => _textBlock('numbered_list', runs);

/// The widest a table cell's text may be, in UTF-8 bytes; longer text is cut.
const int noteCellMaxBytes = 2048;

/// The most cells a note box holds in a table.
const int noteTableMaxCells = 2000;

/// [text] cut to at most [maxBytes] UTF-8 bytes on a character boundary.
String cutUtf8(String text, int maxBytes) {
  if (text.length * 3 <= maxBytes) return text;
  var bytes = 0;
  var end = 0;
  for (final r in text.runes) {
    final n = r < 0x80 ? 1 : (r < 0x800 ? 2 : (r < 0x10000 ? 3 : 4));
    if (bytes + n > maxBytes) break;
    bytes += n;
    end += r > 0xFFFF ? 2 : 1;
  }
  return end == text.length ? text : text.substring(0, end);
}

/// A table of [rows] (every row is padded to the widest), cell text literal
/// and cut to [noteCellMaxBytes]. The first row is the header. At least one
/// row and one column.
Map<String, Object?> noteTable(List<List<String>> rows) {
  final cols = rows.fold<int>(1, (m, r) => r.length > m ? r.length : m);
  final n = rows.isEmpty ? 1 : rows.length;
  const width = 160.0, height = 40.0;
  String cell(int r, int c) => r < rows.length && c < rows[r].length ? cutUtf8(rows[r][c], noteCellMaxBytes) : '';
  return {
    'type': 'table',
    'data': {
      'colsLen': cols,
      'rowsLen': n,
      'colDefaultWidth': width,
      'rowDefaultHeight': height,
      'colMinimumWidth': 40.0,
    },
    'children': [
      // Column by column, as the note stores them.
      for (var c = 0; c < cols; c++)
        for (var r = 0; r < n; r++)
          {
            'type': 'table/cell',
            'data': {'colPosition': c, 'rowPosition': r, 'height': height, 'width': width},
            'children': [
              {
                'type': 'paragraph',
                'data': {
                  'delta': [
                    if (cell(r, c).isNotEmpty) {'insert': cell(r, c)},
                  ],
                },
              },
            ],
          },
    ],
  };
}

/// The tables for [rows]: one, or several of at most [maxCells] cells and
/// [maxBytes] of text each, cut by rows with the first row repeated as each
/// part's header.
List<Map<String, Object?>> noteTables(
  List<List<String>> rows, {
  int maxCells = noteTableMaxCells,
  int maxBytes = 256 * 1024,
}) {
  final cols = rows.fold<int>(1, (m, r) => r.length > m ? r.length : m);
  int rowBytes(List<String> r) => r.fold<int>(0, (n, c) => n + utf8.encode(cutUtf8(c, noteCellMaxBytes)).length);
  if (rows.length < 2) return [noteTable(rows)];
  final header = rows.first;
  final headerBytes = rowBytes(header);
  final parts = <Map<String, Object?>>[];
  var part = <List<String>>[];
  var bytes = headerBytes;
  for (var i = 1; i < rows.length; i++) {
    final b = rowBytes(rows[i]);
    if (part.isNotEmpty && ((part.length + 2) * cols > maxCells || bytes + b > maxBytes)) {
      parts.add(noteTable([header, ...part]));
      part = [];
      bytes = headerBytes;
    }
    part.add(rows[i]);
    bytes += b;
  }
  if (part.isNotEmpty) parts.add(noteTable([header, ...part]));
  return parts;
}

// ---- Size ---------------------------------------------------------------

/// The text of [block] and its children, in UTF-8 bytes.
int noteBlockBytes(Map<String, Object?> block) {
  var n = 0;
  final data = block['data'];
  final delta = data is Map<String, Object?> ? data['delta'] : null;
  if (delta is List) {
    for (final op in delta) {
      final t = op is Map ? op['insert'] : null;
      if (t is String) n += utf8.encode(t).length;
    }
  }
  final kids = block['children'];
  if (kids is List) {
    for (final k in kids) {
      if (k is Map<String, Object?>) n += noteBlockBytes(k);
    }
  }
  return n;
}

/// The table cells in [block] and its children.
int noteBlockCells(Map<String, Object?> block) {
  var n = block['type'] == 'table/cell' ? 1 : 0;
  final kids = block['children'];
  if (kids is List) {
    for (final k in kids) {
      if (k is Map<String, Object?>) n += noteBlockCells(k);
    }
  }
  return n;
}

/// What [groupNoteBlocks] made.
final class NoteGroups {
  const NoteGroups(this.groups, this.truncated);

  final List<List<Map<String, Object?>>> groups;

  /// Blocks were left out: the groups' limit was reached.
  final bool truncated;
}

/// [blocks] cut into groups for note boxes: each group has at most
/// [maxBytes] of text and [maxCells] table cells, and blocks stay whole,
/// except a text block over [maxBytes] on its own, which is cut into blocks
/// of the same style. A table never spans boxes: the caller cuts a table
/// with [noteTables]. Past [maxGroups] the rest is dropped and
/// [NoteGroups.truncated] is set.
NoteGroups groupNoteBlocks(
  List<Map<String, Object?>> blocks, {
  int maxBytes = 256 * 1024,
  int maxCells = noteTableMaxCells,
  int maxGroups = 20,
}) {
  final groups = <List<Map<String, Object?>>>[];
  var current = <Map<String, Object?>>[];
  var bytes = 0, cells = 0;
  var truncated = false;
  for (final b in blocks.expand((b) => _cutLong(b, maxBytes))) {
    final nb = noteBlockBytes(b), nc = noteBlockCells(b);
    if (current.isNotEmpty && (bytes + nb > maxBytes || cells + nc > maxCells)) {
      groups.add(current);
      current = [];
      bytes = cells = 0;
    }
    if (groups.length >= maxGroups) {
      truncated = true;
      current = [];
      break;
    }
    current.add(b);
    bytes += nb;
    cells += nc;
  }
  if (current.isNotEmpty) groups.add(current);
  return NoteGroups(groups, truncated);
}

Iterable<Map<String, Object?>> _cutLong(Map<String, Object?> block, int maxBytes) sync* {
  final data = block['data'];
  final delta = data is Map<String, Object?> ? data['delta'] : null;
  if (delta is! List || block['children'] != null || noteBlockBytes(block) <= maxBytes) {
    yield block;
    return;
  }
  // Runs are cut by characters into pieces of at most maxBytes.
  var piece = <Object?>[];
  var size = 0;
  Map<String, Object?> make() => {
    'type': block['type'],
    'data': {...(data as Map<String, Object?>), 'delta': piece},
  };
  for (final op in delta) {
    if (op is! Map<String, Object?>) continue;
    final raw = op['insert'];
    if (raw is! String) continue;
    var text = raw;
    final attrs = op['attributes'];
    while (text.isNotEmpty) {
      var take = cutUtf8(text, maxBytes - size);
      if (take.isEmpty && size == 0) take = String.fromCharCode(text.runes.first);
      if (take.isEmpty) {
        // The piece is full (or a character is wider than what is left).
        yield make();
        piece = [];
        size = 0;
        continue;
      }
      piece.add({'insert': take, 'attributes': ?attrs});
      size += utf8.encode(take).length;
      text = text.substring(take.length);
    }
  }
  if (piece.isNotEmpty) yield make();
}

// ---- The import file ------------------------------------------------------

/// The deepest block nesting a note import file may have.
const int noteBlocksMaxDepth = 64;

/// The bytes of the import file: `{"version":1,"blocks":[...]}`.
List<int> encodeNoteBlocksFile(List<Map<String, Object?>> blocks) => utf8.encode(jsonEncode({'version': 1, 'blocks': blocks}));

/// The blocks of an import file, or null if it isn't one or a block is not
/// a note block (a map with a string type, a data map, a list of runs each
/// with a string `insert`, and children that are blocks).
List<Map<String, Object?>>? decodeNoteBlocksFile(List<int> bytes) {
  try {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map || json['version'] != 1) return null;
    final blocks = json['blocks'];
    if (blocks is! List || blocks.isEmpty) return null;
    final out = <Map<String, Object?>>[];
    for (final b in blocks) {
      if (!_validBlock(b, 0)) return null;
      out.add(_typed(b as Map));
    }
    return out;
  } on FormatException {
    return null;
  }
}

/// [m] as a map with string keys, its nested maps and lists too.
Map<String, Object?> _typed(Map<Object?, Object?> m) => {for (final e in m.entries) e.key as String: _deep(e.value)};

Object? _deep(Object? v) => v is Map ? _typed(v) : (v is List ? [for (final e in v) _deep(e)] : v);

bool _validBlock(Object? b, int depth) {
  if (b is! Map || depth > noteBlocksMaxDepth) return false;
  if (b.keys.any((k) => k is! String)) return false;
  if (b['type'] is! String) return false;
  final data = b['data'];
  if (data != null) {
    if (data is! Map) return false;
    final delta = data['delta'];
    if (delta != null) {
      if (delta is! List) return false;
      for (final op in delta) {
        if (op is! Map || op['insert'] is! String) return false;
        final a = op['attributes'];
        if (a != null && a is! Map) return false;
      }
    }
  }
  final kids = b['children'];
  if (kids != null) {
    if (kids is! List) return false;
    for (final k in kids) {
      if (!_validBlock(k, depth + 1)) return false;
    }
  }
  return true;
}
