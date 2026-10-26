// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pure Dart: no Flutter or appflowy_editor imports, so the codec can later
// move into a package a non-UI process can load.

import 'package:noted_core/noted_core.dart';

/// A plain note box's content: an appflowy_editor document in its native
/// JSON form (`{"document": {...}}`), as `Document.toJson()` produces it.
final class NoteData {
  const NoteData(this.document);

  final Map<String, Object?> document;
}

/// The data side of the plain note box (0015): grows with its content.
final class NoteCodec extends BoxCodec<NoteData> {
  const NoteCodec();

  static const String id = 'noted.note';

  @override
  String get typeId => id;

  @override
  int get dataVersion => 1;

  @override
  BoxApiVersion get apiVersion => boxApiVersion;

  @override
  BoxSizing get sizing => BoxSizing.growsWithContent;

  @override
  NoteData create() => const NoteData({
    'document': {
      'type': 'page',
      'children': [
        {
          'type': 'paragraph',
          'data': {'delta': <Object?>[]},
        },
      ],
    },
  });

  @override
  NoteData decode(Object? json, int storedVersion) {
    if (json is! Map<String, Object?> ||
        json['document'] is! Map<String, Object?>) {
      throw const FormatException('not a note document');
    }
    return NoteData(json);
  }

  @override
  Object? encode(NoteData data) => data.document;

  /// One line per block, in document order. A table gives one line per row,
  /// its cells joined by ` | `; a block equation is `$$latex$$` and an inline
  /// one `$latex$`, so a reader sees the formula source.
  @override
  String snapshotText(NoteData data) {
    final lines = <String>[];
    _collectLines(data.document['document'], lines);
    return lines.join('\n');
  }

  /// Empty means only blank paragraphs: any other block (a divider, a
  /// table, an image) counts as content.
  @override
  bool isEmpty(NoteData data) {
    var empty = true;
    _walk(data.document['document'], (node, text) {
      final type = node['type'];
      if ((type != 'page' && type != 'paragraph') ||
          (text != null && text.trim().isNotEmpty)) {
        empty = false;
      }
      return empty;
    });
    return empty;
  }

  @override
  AiExposure aiExposure(NoteData data) => AiText(snapshotText(data));
}

/// Names in the appflowy document JSON that the note module relies on beyond
/// appflowy's plain text blocks. Kept here so the codec stays free of
/// Flutter and appflowy imports.
abstract final class NoteFormat {
  /// Block equation: `{"type": "math_equation", "data": {"formula": "..."}}`.
  static const String mathBlockType = 'math_equation';

  /// Attribute (block data and text run) that holds LaTeX source.
  static const String formulaKey = 'formula';

  /// The one character an inline equation occupies in its text run: U+FFFC
  /// OBJECT REPLACEMENT CHARACTER, as the inline widget replaces it on
  /// screen. Its attributes carry the formula: `{"insert": U+FFFC,
  /// "attributes": {"formula": "x^2"}}`.
  static final String inlineMathChar = String.fromCharCode(0xFFFC);

  static const String tableType = 'table';
  static const String tableCellType = 'table/cell';
  static const String rowPosition = 'rowPosition';
  static const String colPosition = 'colPosition';

  /// Key, in the data of a table cell's paragraph, of the last computed
  /// value of the cell's formula, as the text the cell shows (`"3"`,
  /// `"#DIV/0!"`). A cell is a formula when its text starts with `=`; the
  /// formula itself stays the paragraph's text, so a reader that knows
  /// nothing of formulas still sees it:
  /// `{"type": "paragraph", "data": {"delta": [{"insert": "=A1+B1"}],
  /// "formulaValue": "3"}}`. Absent on cells that are not formulas. The
  /// snapshot shows this value instead of the formula text.
  static const String formulaValueKey = 'formulaValue';

  /// Keys, in the data of a table cell, of the background of its row and of
  /// its column (appflowy's own keys). The value is a [TableFill] role, see
  /// there; absent means no background. The text snapshot does not mention
  /// backgrounds: they are decoration, not content.
  static const String rowBackgroundKey = 'rowBackgroundColor';
  static const String colBackgroundKey = 'colBackgroundColor';
}

/// The theme roles a table row, column or cell can be filled with. "No
/// fill" is the absence of the attribute.
enum FillRole { accent, secondary, tertiary, alert }

/// How a table background is stored: as a theme role, so it follows the
/// theme (light and dark) instead of being one fixed color.
///
/// The value of `rowBackgroundColor` / `colBackgroundColor` is `"role:"` and
/// the role's name, for example `{"colBackgroundColor": "role:accent"}`.
/// appflowy's keys are kept, so a document is still a plain appflowy
/// document: an older Noted, or appflowy itself, cannot read the role as a
/// color (`tryToColor` returns null for it) and simply shows no background;
/// nothing breaks, so the note data version stays 1.
///
/// Values written before roles existed were fixed `0xAARRGGBB` strings at 25%
/// alpha computed from the app's light or dark scheme. A value that is
/// exactly one of those eight is read as its role; any other value is a
/// fixed color and is rendered as stored. Reading never rewrites a value.
abstract final class TableFill {
  static const String prefix = 'role:';

  /// The stored form of [role].
  static String encode(FillRole role) => '$prefix${role.name}';

  /// The role a stored background value stands for, or null if it is not a
  /// role and not one of the legacy fixed values.
  static FillRole? roleOf(Object? stored) {
    if (stored is! String) return null;
    if (stored.startsWith(prefix)) {
      final name = stored.substring(prefix.length);
      for (final r in FillRole.values) {
        if (r.name == name) return r;
      }
      return null;
    }
    final m = _hex.firstMatch(stored);
    if (m == null) return null;
    return _legacy[int.parse(m.group(1)!, radix: 16)];
  }

  static final RegExp _hex = RegExp(r'^0x([0-9a-fA-F]{8})$');

  /// What the first version wrote: each role at 25% alpha, from the light
  /// and the dark scheme of the app's seed color.
  static const Map<int, FillRole> _legacy = {
    0x40515b92: FillRole.accent,
    0x405b5d72: FillRole.secondary,
    0x4077536d: FillRole.tertiary,
    0x40ba1a1a: FillRole.alert,
    0x40bac3ff: FillRole.accent,
    0x40c3c5dd: FillRole.secondary,
    0x40e6bad7: FillRole.tertiary,
    0x40ffb4ab: FillRole.alert,
  };
}

/// A block's plain text, or null if it has none. Equations keep their LaTeX
/// source between dollar signs.
String? _textOf(Map<String, Object?> node) {
  final data = node['data'];
  if (data is! Map<String, Object?>) return null;
  if (node['type'] == NoteFormat.mathBlockType) {
    final formula = data[NoteFormat.formulaKey];
    return formula is String ? '\$\$$formula\$\$' : '\$\$\$\$';
  }
  if (data['delta'] is! List) return null;
  final value = data[NoteFormat.formulaValueKey];
  final b = StringBuffer();
  for (final op in data['delta']! as List) {
    if (op is! Map || op['insert'] is! String) continue;
    final attributes = op['attributes'];
    final formula = attributes is Map
        ? attributes[NoteFormat.formulaKey]
        : null;
    if (formula is String) {
      b.write('\$$formula\$');
    } else {
      b.write(op['insert']);
    }
  }
  final text = b.toString();
  // A formula cell reads as its result, not its formula.
  if (value is String && text.startsWith('=')) return value;
  return text;
}

/// Adds [node]'s lines to [lines], depth-first.
void _collectLines(Object? node, List<String> lines) {
  if (node is! Map<String, Object?>) return;
  if (node['type'] == NoteFormat.tableType) {
    lines.addAll(_tableRows(node));
    return;
  }
  final text = _textOf(node);
  if (text != null) lines.add(text);
  final children = node['children'];
  if (children is List) {
    for (final c in children) {
      _collectLines(c, lines);
    }
  }
}

/// One line per table row. appflowy stores cells column by column, so they
/// are regrouped by their row and column positions; a cell with several
/// blocks has them joined by a space.
List<String> _tableRows(Map<String, Object?> table) {
  final cells = <(int row, int col, String text)>[];
  final children = table['children'];
  if (children is! List) return const [];
  for (final cell in children) {
    if (cell is! Map<String, Object?>) continue;
    final data = cell['data'];
    final row = data is Map ? data[NoteFormat.rowPosition] : null;
    final col = data is Map ? data[NoteFormat.colPosition] : null;
    if (row is! int || col is! int) continue;
    final parts = <String>[];
    _collectLines(cell, parts);
    cells.add((row, col, parts.join(' ')));
  }
  cells.sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
  final rows = <int, List<String>>{};
  for (final (row, _, text) in cells) {
    (rows[row] ??= []).add(text);
  }
  return [for (final r in rows.values) r.join(' | ')];
}

/// Visits each block depth-first with its plain text (null if it has no
/// text). Stops when [visit] returns false.
bool _walk(
  Object? node,
  bool Function(Map<String, Object?> node, String? text) visit,
) {
  if (node is! Map<String, Object?>) return true;
  final text = _textOf(node);
  if (!visit(node, text)) return false;
  final children = node['children'];
  if (children is List) {
    for (final c in children) {
      if (!_walk(c, visit)) return false;
    }
  }
  return true;
}
