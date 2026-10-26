// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart'
    show NotedMenuDivider, NotedMenuHeading, NotedMenuItem, NotedMetrics;

import 'note_codec.dart';
import 'note_theme.dart';
import 'table_formulas.dart';

/// The menu on the handle of a table row or column.
///
/// It replaces appflowy's, which cannot be configured: its "duplicate" item
/// calls a static function that gives the caller no way to know which row or
/// column was copied, so the formulas of the copy could not be shifted
/// without guessing. The items are the same as appflowy's (insert before,
/// insert after, delete, duplicate, background color, clear) with the same
/// labels; only "duplicate" goes through [TableFormulas.duplicate], and the
/// background colors are a short list taken from the theme.
TableBlockComponentMenuBuilder tableMenuBuilder(
  TableFormulas formulas,
  ColorScheme scheme,
) =>
    (node, editor, position, dir, menuShown, menuHidden) => Card(
      elevation: 3,
      child: _Handle(
        node: node,
        editor: editor,
        formulas: formulas,
        scheme: scheme,
        position: position,
        dir: dir,
        onOpened: menuShown,
        onClosed: menuHidden,
      ),
    );

enum _Action { before, after, delete, duplicate, clear }

/// A background color choice; a null role removes the color.
final class _Fill {
  const _Fill(this.label, this.role);
  final String label;
  final FillRole? role;
}

class _Handle extends StatelessWidget {
  const _Handle({
    required this.node,
    required this.editor,
    required this.formulas,
    required this.scheme,
    required this.position,
    required this.dir,
    required this.onOpened,
    required this.onClosed,
  });

  final Node node;
  final EditorState editor;
  final TableFormulas formulas;
  final ColorScheme scheme;
  final int position;
  final TableDirection dir;
  final VoidCallback? onOpened;
  final VoidCallback? onClosed;

  bool get _col => dir == TableDirection.col;

  /// The choices. A color is stored as its theme role ([TableFill]), not as
  /// the color it has now, so it follows the theme.
  List<_Fill> get _fills => [
    const _Fill('No color', null),
    for (final (label, role) in [
      ('Accent', FillRole.accent),
      ('Secondary', FillRole.secondary),
      ('Tertiary', FillRole.tertiary),
      ('Alert', FillRole.alert),
    ])
      _Fill(label, role),
  ];

  void _select(Object choice) {
    onClosed?.call();
    if (editor.isDisposed || node.parent == null) return;
    switch (choice) {
      case _Action.before:
        TableActions.add(node, position, editor, dir);
      case _Action.after:
        TableActions.add(node, position + 1, editor, dir);
      case _Action.delete:
        TableActions.delete(node, position, editor, dir);
      case _Action.duplicate:
        formulas.duplicate(node, position, dir);
      case _Action.clear:
        TableActions.clear(node, position, editor, dir);
      case _Fill(:final role):
        TableActions.setBgColor(
          node,
          position,
          editor,
          role == null ? null : TableFill.encode(role),
          dir,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppFlowyEditorL10n.current;
    NotedMenuItem<Object> item(
      Object value,
      String text,
      IconData icon, {
      bool destructive = false,
    }) => NotedMenuItem<Object>(
      value: value,
      label: text,
      icon: icon,
      destructive: destructive,
    );
    Widget swatch(_Fill f) => Container(
      width: NotedMetrics.of(context).icon,
      height: NotedMetrics.of(context).icon,
      decoration: BoxDecoration(
        color: f.role == null ? null : fillColor(scheme, f.role!),
        shape: BoxShape.circle,
        border: Border.all(color: scheme.outline),
      ),
    );
    final icon = _col
        ? Transform.rotate(
            angle: math.pi / 2,
            child: const Icon(Icons.drag_indicator_rounded),
          )
        : const Icon(Icons.drag_indicator_rounded);
    return PopupMenuButton<Object>(
      key: ValueKey('table-handle-${dir.name}-$position'),
      tooltip: '',
      padding: EdgeInsets.zero,
      onOpened: onOpened,
      onCanceled: onClosed,
      onSelected: _select,
      itemBuilder: (_) => [
        item(
          _Action.before,
          _col ? l10n.colAddBefore : l10n.rowAddBefore,
          _col ? Icons.first_page_rounded : Icons.vertical_align_top_rounded,
        ),
        item(
          _Action.after,
          _col ? l10n.colAddAfter : l10n.rowAddAfter,
          _col ? Icons.last_page_rounded : Icons.vertical_align_bottom_rounded,
        ),
        item(
          _Action.delete,
          _col ? l10n.colRemove : l10n.rowRemove,
          Icons.delete_outline_rounded,
          destructive: true,
        ),
        item(
          _Action.duplicate,
          _col ? l10n.colDuplicate : l10n.rowDuplicate,
          Icons.content_copy_rounded,
        ),
        const NotedMenuDivider(),
        NotedMenuHeading(l10n.backgroundColor),
        for (final f in _fills)
          NotedMenuItem<Object>(
            value: f,
            label: f.label,
            leading: swatch(f),
          ),
        const NotedMenuDivider(),
        item(
          _Action.clear,
          _col ? l10n.colClear : l10n.rowClear,
          Icons.clear_rounded,
        ),
      ],
      child: MouseRegion(cursor: SystemMouseCursors.click, child: icon),
    );
  }
}
