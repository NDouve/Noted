// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedColors;

import 'formula/formula.dart';
import 'note_codec.dart';

/// Spreadsheet formulas in table cells, on the editor side.
///
/// A cell is a formula when its text starts with `=`. The text stays the
/// cell's paragraph text; the last computed value is stored beside it in the
/// paragraph's data ([NoteFormat.formulaValueKey]). [TableFormulas.sync]
/// keeps that value current after every transaction and rewrites references
/// when rows or columns are inserted or deleted; [formulaSpanDecorator]
/// shows the value instead of the text while the caret is elsewhere.

typedef _Pending = (Node, List<TableEdit>, int, int);

/// The cell nodes of a table by position, or null while the table is
/// between two steps of one of appflowy's table actions (they apply several
/// transactions in a row, and in between the cell count or positions do not
/// add up).
final class _Layout {
  _Layout(this.rows, this.cols, this.cells, this.positions);

  final int rows;
  final int cols;

  /// `cells[row][col]`.
  final List<List<Node>> cells;

  final Map<Node, (int, int)> positions;

  static _Layout? read(Node table) {
    final rows = table.attributes[TableBlockKeys.rowsLen];
    final cols = table.attributes[TableBlockKeys.colsLen];
    if (rows is! int || cols is! int || rows < 1 || cols < 1) return null;
    final children = table.children;
    if (children.length != rows * cols) return null;
    final grid = List.generate(rows, (_) => List<Node?>.filled(cols, null));
    final positions = <Node, (int, int)>{};
    for (final cell in children) {
      final r = cell.attributes[TableCellBlockKeys.rowPosition];
      final c = cell.attributes[TableCellBlockKeys.colPosition];
      if (r is! int || c is! int || r < 0 || c < 0 || r >= rows || c >= cols) {
        return null;
      }
      if (grid[r][c] != null) return null;
      grid[r][c] = cell;
      positions[cell] = (r, c);
    }
    return _Layout(rows, cols, [
      for (final row in grid) [for (final c in row) c!],
    ], positions);
  }
}

/// The text of a table cell: its first block, which is the only one a cell
/// shows.
String cellText(Node cell) {
  final first = cell.children.isEmpty ? null : cell.children.first;
  if (first == null) return '';
  final delta = first.delta;
  if (delta != null) return delta.toPlainText();
  if (first.type == NoteFormat.mathBlockType) {
    final f = first.attributes[NoteFormat.formulaKey];
    return '\$\$${f is String ? f : ''}\$\$';
  }
  return '';
}

/// Keeps the formulas of the tables in one editor current.
final class TableFormulas {
  TableFormulas(this.editor);

  final EditorState editor;

  /// The last consistent layout of each table, to see what changed.
  final Map<Node, _Layout> _layouts = {};

  /// Call after a transaction was applied ([source] is where it came from).
  ///
  /// 1. If rows or columns were inserted or deleted since the last
  ///    consistent state of a table, the formulas in the cells that were
  ///    already there are rewritten (one transaction, which joins the undo
  ///    step of the edit itself). Not after an undo or redo: those restore
  ///    the formula text themselves.
  /// 2. The stored value of every cell is brought up to date (a transaction
  ///    that is not recorded for undo).
  void sync(TransactionSource? source) {
    final tables = <Node>[];
    _findTables(editor.document.root, tables);
    _layouts.removeWhere((t, _) => !tables.contains(t));
    final layouts = <Node, _Layout>{};
    final pending = <_Pending>[];
    final rewriting =
        source != TransactionSource.undo && source != TransactionSource.redo;
    for (final table in tables) {
      final next = _Layout.read(table);
      if (next == null) {
        // Between two steps of a table action: keep the last good layout.
        final kept = _layouts[table];
        if (kept != null) layouts[table] = kept;
        continue;
      }
      layouts[table] = next;
      final prev = _layouts[table];
      if (prev == null) continue;
      final edits = _inferEdits(prev, next);
      // A copied cell's position is meaningless once rows or columns moved.
      if (edits.isNotEmpty && _copied?.table == table) _copied = null;
      if (!rewriting || edits.isEmpty) continue;
      for (final cell in prev.positions.keys) {
        if (!next.positions.containsKey(cell)) continue;
        final first = _firstBlock(cell);
        final delta = first?.delta;
        if (first == null || delta == null) continue;
        if (isFormulaText(delta.toPlainText())) {
          pending.add((first, edits, 0, 0));
        }
      }
      _duplicates(prev, next, edits, pending);
    }
    _layouts
      ..clear()
      ..addAll(layouts);
    _pending.addAll(pending);
    _schedule();
  }

  /// Reads the tables as they are and stores the values of their formulas,
  /// without any rewriting. For a document that was just loaded.
  void initialize() {
    final tables = <Node>[];
    _findTables(editor.document.root, tables);
    for (final table in tables) {
      final layout = _Layout.read(table);
      if (layout != null) _layouts[table] = layout;
    }
    _updateValues(_layouts.values);
  }

  /// A formula paragraph to rewrite: first the edits (insert/delete of rows
  /// and columns), then a shift by (rows, columns) for a copy.
  final List<_Pending> _pending = [];
  bool _scheduled = false;

  static Node? _firstBlock(Node cell) =>
      cell.children.isEmpty ? null : cell.children.first;

  /// Duplicated rows and columns.
  ///
  /// appflowy's "duplicate row/column" inserts new cell nodes that are
  /// `copyWith` copies of the cells of the row/column before them (the
  /// whole column in one transaction; a row cell by cell, in several
  /// transactions, of which only the last one leaves a consistent table).
  /// A plain "insert row/column" makes empty cells instead. So a new row
  /// (column) is a duplicate when it is not the first, none of its cells
  /// existed in [prev] and the text of each equals the text of the cell
  /// before it, at the moment of insertion, before any rewrite of ours has
  /// run. Its formulas are then the original's, adjusted for the insertion
  /// like any other cell, and shifted one row (column) on, the way a copy of
  /// the original would be.
  ///
  /// Not recognised: a duplicate whose cells have no formula (nothing to
  /// do) and a duplicate made together with other row or column edits in
  /// one step.
  void _duplicates(
    _Layout prev,
    _Layout next,
    List<TableEdit> edits,
    List<_Pending> out,
  ) {
    bool isNew(Node c) => !prev.positions.containsKey(c);
    void take(Node cell, int dr, int dc) {
      final first = _firstBlock(cell);
      final delta = first?.delta;
      if (first == null || delta == null) return;
      if (isFormulaText(delta.toPlainText())) out.add((first, edits, dr, dc));
    }

    for (var r = 1; r < next.rows; r++) {
      final row = next.cells[r];
      if (!row.every(isNew)) continue;
      var same = true;
      for (var c = 0; c < next.cols && same; c++) {
        same = cellText(row[c]) == cellText(next.cells[r - 1][c]);
      }
      if (!same) continue;
      for (final cell in row) {
        take(cell, 1, 0);
      }
    }
    for (var c = 1; c < next.cols; c++) {
      final col = [for (var r = 0; r < next.rows; r++) next.cells[r][c]];
      if (!col.every(isNew)) continue;
      var same = true;
      for (var r = 0; r < next.rows && same; r++) {
        same = cellText(col[r]) == cellText(next.cells[r][c - 1]);
      }
      if (!same) continue;
      for (final cell in col) {
        take(cell, 0, 1);
      }
    }
  }

  // Copy and paste of a formula cell ----------------------------------

  /// The last copy of a whole formula cell: where it came from and the text
  /// that went to the clipboard.
  ({Node table, int row, int col, String text})? _copied;

  List<CommandShortcutEvent>? _commands;

  /// [base] with copy, cut and paste replaced by versions that shift a
  /// formula copied from one cell of a table when it is pasted into another
  /// cell of the same table.
  ///
  /// appflowy's copy only puts the selected plain text on the clipboard (no
  /// table or cell information), so the source cell is remembered here at
  /// copy time: the selection must cover the whole text of one cell, which
  /// must be a formula. The paste is recognised by the clipboard still
  /// holding that text, and then replaces the selection with the shifted
  /// text (only into the same table, and only when the result is a formula,
  /// i.e. the paste starts at the beginning of the cell). Everything else
  /// is left to appflowy's own handlers: a paste of other text, from outside
  /// the table or the editor, into another table, or after rows or columns
  /// were inserted or deleted, is verbatim. Cut forgets the source (a moved
  /// formula keeps its references, as in Excel).
  List<CommandShortcutEvent> commandShortcuts(List<CommandShortcutEvent> base) {
    return _commands ??= [
      for (final e in base)
        if (e.key == copyCommand.key)
          e.copyWith(handler: _copyHandler(e.handler))
        else if (e.key == cutCommand.key)
          e.copyWith(
            handler: (s) {
              _copied = null;
              return e.handler(s);
            },
          )
        else if (e.key == pasteCommand.key)
          e.copyWith(handler: _pasteHandler(e.handler))
        else
          e,
    ];
  }

  /// The table cell paragraph the single-block [selection] is in, with the
  /// cell position, or null.
  ({Node para, Node table, int row, int col})? _cellOf(Selection selection) {
    if (!selection.isSingle) return null;
    final para = editor.getNodeAtPath(selection.start.path);
    final cell = para?.parent;
    final table = cell?.parent;
    if (para == null ||
        cell == null ||
        table == null ||
        cell.type != NoteFormat.tableCellType ||
        table.type != TableBlockKeys.type ||
        _firstBlock(cell) != para) {
      return null;
    }
    final layout = _layouts[table];
    final pos = layout?.positions[cell];
    if (pos == null) return null;
    return (para: para, table: table, row: pos.$1, col: pos.$2);
  }

  CommandShortcutEventHandler _copyHandler(
    CommandShortcutEventHandler original,
  ) => (state) {
    _copied = null;
    final selection = state.selection?.normalized;
    if (selection != null && !selection.isCollapsed) {
      final at = _cellOf(selection);
      final text = at?.para.delta?.toPlainText();
      if (at != null &&
          text != null &&
          isFormulaText(text) &&
          selection.start.offset == 0 &&
          selection.end.offset == text.length) {
        _copied = (table: at.table, row: at.row, col: at.col, text: text);
      }
    }
    return original(state);
  };

  CommandShortcutEventHandler _pasteHandler(
    CommandShortcutEventHandler original,
  ) => (state) {
    final copied = _copied;
    final selection = state.selection?.normalized;
    final target = selection == null ? null : _cellOf(selection);
    if (copied == null ||
        selection == null ||
        target == null ||
        target.table != copied.table) {
      return original(state);
    }
    () async {
      final data = await AppFlowyClipboard.getData();
      final text = data.text;
      final start = selection.start.offset;
      final shifted = text == null
          ? null
          : shiftFormula(
              text,
              target.row - copied.row,
              target.col - copied.col,
            );
      if (editor.isDisposed ||
          text != copied.text ||
          shifted == null ||
          start != 0 ||
          target.para.parent == null) {
        original(state);
        return;
      }
      final tx = editor.transaction;
      final length = selection.end.offset - start;
      if (length > 0) tx.deleteText(target.para, start, length);
      tx.insertText(target.para, start, shifted);
      tx.afterSelection = Selection.collapsed(
        Position(path: target.para.path, offset: start + shifted.length),
      );
      await editor.apply(tx);
    }();
    return KeyEventResult.handled;
  };

  /// The editor's transaction stream cannot take a transaction while it is
  /// delivering one, so changes are applied right after. That also records
  /// the rewrite for undo after the edit that caused it, which is the order
  /// undo needs. The transactions made here come back to [sync], find
  /// nothing more to do, and are done.
  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (editor.isDisposed) return;
      final pending = [..._pending];
      _pending.clear();
      if (pending.isNotEmpty) _rewrite(pending);
      // Fresh: a table action may be half done, and then it is left alone.
      _updateValues([
        for (final t in _layouts.keys.toList())
          if (t.parent != null) ?_Layout.read(t),
      ]);
    });
  }

  void _rewrite(List<_Pending> pending) {
    if (editor.isDisposed) return;
    final tx = editor.transaction;
    for (final (para, edits, dr, dc) in pending) {
      final delta = para.delta;
      if (para.parent == null || delta == null) continue;
      final old = delta.toPlainText();
      var text = old;
      for (final e in edits) {
        text = adjustFormula(text, e);
      }
      text = shiftFormula(text, dr, dc);
      if (text != old) _replaceText(tx, para, old, text);
    }
    if (tx.operations.isEmpty) return;
    tx.afterSelection = editor.selection;
    editor.apply(tx, withUpdateSelection: false);
  }

  void _updateValues(Iterable<_Layout> layouts) {
    final tx = editor.transaction;
    for (final layout in layouts) {
      final texts = [
        for (final row in layout.cells) [for (final c in row) cellText(c)],
      ];
      final sheet = FormulaSheet(
        rows: layout.rows,
        cols: layout.cols,
        textAt: (r, c) => texts[r][c],
      );
      for (var r = 0; r < layout.rows; r++) {
        for (var c = 0; c < layout.cols; c++) {
          final cell = layout.cells[r][c];
          final para = cell.children.isEmpty ? null : cell.children.first;
          if (para == null || para.delta == null) continue;
          final stored = para.attributes[NoteFormat.formulaValueKey];
          final want = isFormulaText(texts[r][c])
              ? sheet.displayAt(r, c)
              : null;
          if (want != stored) {
            tx.updateNode(para, {NoteFormat.formulaValueKey: want});
          }
        }
      }
    }
    if (tx.operations.isEmpty) return;
    tx.afterSelection = editor.selection;
    editor.apply(
      tx,
      withUpdateSelection: false,
      options: const ApplyOptions(source: TransactionSource.none),
    );
  }

  static void _findTables(Node node, List<Node> out) {
    for (final child in node.children) {
      if (child.type == TableBlockKeys.type) {
        out.add(child);
      } else {
        _findTables(child, out);
      }
    }
  }

  /// Replaces only the differing middle of [old], so formatting elsewhere in
  /// the cell stays.
  static void _replaceText(Transaction tx, Node para, String old, String text) {
    var start = 0;
    while (start < old.length &&
        start < text.length &&
        old[start] == text[start]) {
      start++;
    }
    var endOld = old.length;
    var endNew = text.length;
    while (endOld > start &&
        endNew > start &&
        old[endOld - 1] == text[endNew - 1]) {
      endOld--;
      endNew--;
    }
    tx.replaceText(para, start, endOld - start, text.substring(start, endNew));
  }

  /// The row and column edits that turn [prev] into [next], found by which
  /// cell nodes survived: appflowy's actions keep the nodes of the cells
  /// that stay and only change their positions. Deletions come first, last
  /// to first, then insertions, first to last, each in the numbering at that
  /// moment. Empty when nothing structural happened, when no cell survived
  /// (the table was rebuilt) or when survivors changed order.
  static List<TableEdit> _inferEdits(_Layout prev, _Layout next) {
    final rowOf = List<int?>.filled(prev.rows, null);
    final colOf = List<int?>.filled(prev.cols, null);
    var survivors = 0;
    prev.positions.forEach((cell, pos) {
      final now = next.positions[cell];
      if (now == null) return;
      survivors++;
      rowOf[pos.$1] ??= now.$1;
      colOf[pos.$2] ??= now.$2;
    });
    if (survivors == 0) return const [];
    final rows = _axisEdits(rowOf, next.rows, DeleteRow.new, InsertRow.new);
    final cols = _axisEdits(
      colOf,
      next.cols,
      DeleteColumn.new,
      InsertColumn.new,
    );
    if (rows == null || cols == null) return const [];
    return [...rows, ...cols];
  }

  static List<TableEdit>? _axisEdits(
    List<int?> newIndexOf,
    int newCount,
    TableEdit Function(int) delete,
    TableEdit Function(int) insert,
  ) {
    final edits = <TableEdit>[];
    for (var i = newIndexOf.length - 1; i >= 0; i--) {
      if (newIndexOf[i] == null) edits.add(delete(i));
    }
    final kept = <int>[];
    for (final n in newIndexOf) {
      if (n == null) continue;
      if (kept.isNotEmpty && n <= kept.last) return null;
      kept.add(n);
    }
    final keptSet = kept.toSet();
    for (var n = 0; n < newCount; n++) {
      if (!keptSet.contains(n)) edits.add(insert(n));
    }
    return edits;
  }
}

/// Shows a formula cell's value in place of its text while the caret is not
/// in it, falling back to [inner] for everything else.
///
/// The value is one widget standing for the first character (the `=`), and
/// the rest of the text is kept in the line at zero size, so the text the
/// editor lays out is as long as the document's: positions from a click map
/// straight to the formula text.
TextSpanDecoratorForAttribute formulaSpanDecorator(
  EditorState editor,
  TextSpanDecoratorForAttribute inner,
) => (context, node, index, text, before, after) {
  final span = _formulaSpan(context, editor, node, index, text, before);
  return span ?? inner(context, node, index, text, before, after);
};

TextSpan? _formulaSpan(
  BuildContext context,
  EditorState editor,
  Node node,
  int index,
  TextInsert text,
  TextSpan before,
) {
  if (node.type != ParagraphBlockKeys.type ||
      node.parent?.type != NoteFormat.tableCellType) {
    return null;
  }
  final value = node.attributes[NoteFormat.formulaValueKey];
  if (value is! String) return null;
  final plain = node.delta?.toPlainText() ?? '';
  if (!isFormulaText(plain)) return null;
  final selection = editor.selection;
  if (editor.editable &&
      selection != null &&
      selection.isSingle &&
      listEquals(selection.start.path, node.path)) {
    return null;
  }
  const hidden = TextStyle(fontSize: 0, color: Color(0x00000000));
  if (index > 0) return TextSpan(text: text.text, style: hidden);
  final style = before.style ?? const TextStyle();
  final isError = FormulaError.fromCode(value) != null;
  final rest = text.text.substring(1);
  return TextSpan(
    children: [
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: Text(
          value,
          key: const ValueKey('formula-value'),
          style: isError
              ? style.copyWith(color: NotedColors.of(context).formulaError)
              : style,
        ),
      ),
      if (rest.isNotEmpty) TextSpan(text: rest, style: hidden),
    ],
  );
}
