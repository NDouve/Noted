// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:appflowy_editor/appflowy_editor.dart';

/// The note box's editor state: appflowy's, with table layout kept out of
/// the undo history.
///
/// A table measures itself after it is built or changed: each column
/// (`table_col.dart`) post-frame callback calls
/// `TableNode.updateRowHeight`, which writes the measured `height` of the
/// row's cells and the table's `colsHeight` through a transaction applied
/// with the default options. Those transactions were recorded as user edits,
/// so after any table change the top undo step was a measurement and Ctrl+Z
/// seemed to do nothing (a measurement after an undo also started a new step
/// and dropped the redo stack). They come from appflowy and cannot be
/// applied differently from here, so [apply] recognises them by shape and
/// applies them as [TransactionSource.none].
///
/// Why that is safe: a measurement only sets `height`, `width` and
/// `colsHeight` on a table or its cells, values that are a function of the
/// content and the layout, not user data. Undoing a user step restores the
/// structure and text; the table then measures itself again, as it does
/// whenever it is built. A step's inverse never needs the old measurement.
///
/// Two more facts that make recording them harmful. A measurement made for a
/// cell that was just removed has an empty path, so applying it writes the
/// cell's size onto the page itself; those are dropped. And an update's
/// recorded "old attributes" list every other attribute of the node as it was
/// (positions included), so undoing a measurement put stale row and column
/// positions back.
///
/// Column resizing: dragging a column border changes the cells' `width`
/// in place (no transaction) and, when the drag ends, applies a transaction
/// whose "old" width is already the new one, so by itself it can neither be
/// undone nor redone. Here that transaction is given the width the column
/// had before the drag (remembered from the last committed state) and is
/// recorded as a user edit: one undo step per resize.
class NoteEditorState extends EditorState {
  NoteEditorState({required super.document}) {
    _remember();
  }

  /// The committed width of each table cell, by node id: what a column
  /// resize started from.
  final Map<String, double> _widths = {};

  static const String _height = 'height';
  static const String _width = 'width';
  static const String _colsHeight = 'colsHeight';
  static const Set<String> _layoutKeys = {_height, _width, _colsHeight};

  @override
  Future<void> apply(
    Transaction transaction, {
    bool isRemote = false,
    ApplyOptions options = const ApplyOptions(),
    bool withUpdateSelection = true,
    bool skipHistoryDebounce = false,
    bool skipEditableCheck = false,
  }) async {
    var remember = true;
    if (!isRemote &&
        options.resolvedSource == TransactionSource.userEdit &&
        _isLayout(transaction)) {
      // Measurements of a cell that was just removed have no path left (it
      // is empty) and would write the cell's size onto the page itself.
      transaction.operations.removeWhere((op) => op.path.isEmpty);
      if (transaction.operations.isEmpty) return;
      if (_restoreOldWidths(transaction)) {
        // A column resize: recorded, with the right old widths.
      } else {
        options = const ApplyOptions(source: TransactionSource.none);
        // A measurement can arrive in the middle of a drag, when the widths
        // on the nodes are not committed yet.
        remember = false;
      }
    }
    await super.apply(
      transaction,
      isRemote: isRemote,
      options: options,
      withUpdateSelection: withUpdateSelection,
      skipHistoryDebounce: skipHistoryDebounce,
      skipEditableCheck: skipEditableCheck,
    );
    if (remember && !isDisposed) _remember();
  }

  /// Whether [transaction] only sets layout values on tables and cells.
  bool _isLayout(Transaction transaction) {
    final ops = transaction.operations;
    if (ops.isEmpty) return false;
    for (final op in ops) {
      if (op is! UpdateOperation) return false;
      if (op.path.isEmpty) {
        // The stale kind described in [apply]; anything else aimed at the
        // page itself is not a measurement.
        if (!op.attributes.keys.every(_layoutKeys.contains)) return false;
        continue;
      }
      final node = document.nodeAtPath(op.path);
      if (node == null ||
          (node.type != TableBlockKeys.type &&
              node.type != TableCellBlockKeys.type)) {
        return false;
      }
      // What the operation changes: the values that differ from the node's
      // now. (`oldAttributes` also lists unrelated attributes of the node,
      // so it says nothing about what is set.)
      for (final entry in op.attributes.entries) {
        if (entry.value != node.attributes[entry.key] &&
            !_layoutKeys.contains(entry.key)) {
          return false;
        }
      }
    }
    return true;
  }

  /// For a column resize, replaces the stale old widths in [transaction]
  /// with the remembered ones. False if it is not one.
  bool _restoreOldWidths(Transaction transaction) {
    final ops = transaction.operations;
    var resized = false;
    for (var i = 0; i < ops.length; i++) {
      final op = ops[i];
      if (op is! UpdateOperation || !op.attributes.containsKey(_width)) {
        continue;
      }
      final node = document.nodeAtPath(op.path);
      if (node == null || node.type != TableCellBlockKeys.type) continue;
      final now = _asDouble(op.attributes[_width]);
      final before = _widths[node.id];
      // The old width is either missing (it equals the new one, so the
      // inverse leaves it out) or already the new one.
      final old = op.oldAttributes[_width];
      if (now == null ||
          before == null ||
          now == before ||
          (old != null && _asDouble(old) != now)) {
        continue;
      }
      ops[i] = UpdateOperation(
        op.path,
        {...op.attributes},
        {...op.oldAttributes, _width: before},
      );
      resized = true;
    }
    return resized;
  }

  void _remember() {
    _widths.clear();
    void walk(Node node) {
      if (node.type == TableCellBlockKeys.type) {
        final w = _asDouble(node.attributes[_width]);
        if (w != null) _widths[node.id] = w;
        return;
      }
      for (final child in node.children) {
        walk(child);
      }
    }

    walk(document.root);
  }

  static double? _asDouble(Object? v) =>
      v is num ? v.toDouble() : double.tryParse('$v');
}
