// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'formula/formula.dart';

/// Column letters above and row numbers beside the table the caret is in, so
/// formulas can be written (`=SUM(B2:B5)`). They are drawn over the editor,
/// are not part of the document and take no clicks.
///
/// Positions are measured from the cells' render boxes in the coordinates of
/// [rootKey]'s box, so they are right at any zoom. [refresh] re-measures
/// (call it when the table scrolls sideways).
class TableHeaders extends StatefulWidget {
  const TableHeaders({super.key, required this.editor, required this.rootKey});

  final EditorState editor;
  final GlobalKey rootKey;

  @override
  State<TableHeaders> createState() => TableHeadersState();
}

const double _labelHeight = 10;
const double _rowLabelWidth = 16;

typedef _Label = (String text, double start, double extent);

class TableHeadersState extends State<TableHeaders> {
  late StreamSubscription<EditorTransactionValue> _sub;
  List<_Label> _columns = const [];
  List<_Label> _rows = const [];
  double _top = 0;
  double _left = 0;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    widget.editor.selectionNotifier.addListener(refresh);
    _sub = widget.editor.transactionStream.listen((_) => refresh());
  }

  @override
  void dispose() {
    widget.editor.selectionNotifier.removeListener(refresh);
    _sub.cancel();
    super.dispose();
  }

  /// Measures again after the next frame.
  void refresh() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _measure();
    });
  }

  Node? _focusedTable() {
    final selection = widget.editor.selection;
    if (selection == null || !widget.editor.editable) return null;
    Node? node = widget.editor.getNodeAtPath(selection.end.path);
    while (node != null && node.type != TableBlockKeys.type) {
      node = node.parent;
    }
    return node;
  }

  void _measure() {
    final root = widget.rootKey.currentContext?.findRenderObject();
    final table = _focusedTable();
    if (table == null || root is! RenderBox || !root.hasSize) {
      return _set(const [], const [], 0, 0);
    }
    final block = table.key.currentContext?.findRenderObject();
    final rows = table.attributes[TableBlockKeys.rowsLen];
    final cols = table.attributes[TableBlockKeys.colsLen];
    if (block is! RenderBox || !block.hasSize || rows is! int || cols is! int) {
      return _set(const [], const [], 0, 0);
    }
    final blockBox =
        block.localToGlobal(Offset.zero, ancestor: root) & block.size;
    Rect? rectOf(int r, int c) {
      for (final cell in table.children) {
        if (cell.attributes[TableCellBlockKeys.rowPosition] == r &&
            cell.attributes[TableCellBlockKeys.colPosition] == c) {
          final box = cell.key.currentContext?.findRenderObject();
          if (box is RenderBox && box.hasSize) {
            return box.localToGlobal(Offset.zero, ancestor: root) & box.size;
          }
        }
      }
      return null;
    }

    final columns = <_Label>[];
    final rowLabels = <_Label>[];
    final first = rectOf(0, 0);
    if (first == null) return _set(const [], const [], 0, 0);
    for (var c = 0; c < cols; c++) {
      final rect = rectOf(0, c);
      if (rect == null) continue;
      // Hidden while its column is scrolled out of the table's view.
      if (rect.center.dx < blockBox.left || rect.center.dx > blockBox.right) {
        continue;
      }
      columns.add((columnName(c), rect.left, rect.width));
    }
    for (var r = 0; r < rows; r++) {
      final rect = rectOf(r, 0);
      if (rect == null) continue;
      rowLabels.add(('${r + 1}', rect.top, rect.height));
    }
    // The first cell sits inside the table's top and left borders.
    _set(columns, rowLabels, first.top, first.left);
  }

  void _set(List<_Label> columns, List<_Label> rows, double top, double left) {
    if (_same(columns, _columns) &&
        _same(rows, _rows) &&
        top == _top &&
        left == _left) {
      return;
    }
    setState(() {
      _columns = columns;
      _rows = rows;
      _top = top;
      _left = left;
    });
  }

  static bool _same(List<_Label> a, List<_Label> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    refresh();
    if (_columns.isEmpty && _rows.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: 9,
      height: 1,
      color: scheme.onSurface.withValues(alpha: 0.55),
    );
    Widget label(String text, Alignment alignment) => Align(
      alignment: alignment,
      child: Text(text, style: style, maxLines: 1, softWrap: false),
    );
    return IgnorePointer(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final (text, start, extent) in _columns)
            Positioned(
              key: ValueKey('col-header-$text'),
              left: start,
              top: _top - 2 - _labelHeight,
              width: extent,
              height: _labelHeight,
              child: label(text, Alignment.center),
            ),
          for (final (text, start, extent) in _rows)
            Positioned(
              key: ValueKey('row-header-$text'),
              left: _left - 2 - _rowLabelWidth,
              top: start,
              width: _rowLabelWidth,
              height: extent,
              child: label(text, Alignment.centerRight),
            ),
        ],
      ),
    );
  }
}
