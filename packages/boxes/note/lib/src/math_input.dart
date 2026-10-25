// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

import 'math_blocks.dart';
import 'note_codec.dart';

/// How a user creates equations (blocks and inline), and where tables are
/// offered.
///
/// - Block equation: `/equation` in the slash menu, or `$$` then a space at
///   the start of an empty line.
/// - Inline equation: type `$`, the LaTeX, then `$` again (`$x^2$`). The
///   closing `$` turns the text into an equation. A formula may not start or
///   end with a space, so prices such as "$5 and $10" are left alone.
/// - Table: `/table` in the slash menu (appflowy's own item).

/// `$` closes an inline equation.
final CharacterShortcutEvent inlineMathShortcut = CharacterShortcutEvent(
  key: r'turn $latex$ into an inline equation',
  character: r'$',
  handler: _closeInlineMath,
);

/// A space after `$$` on an empty line turns it into a block equation.
final CharacterShortcutEvent blockMathShortcut = CharacterShortcutEvent(
  key: r'turn $$ into a block equation',
  character: ' ',
  handler: _openBlockMath,
);

/// The slash menu: appflowy's items (text, headings, lists, table, ...) plus
/// the equation block.
final CharacterShortcutEvent noteSlashCommand = customSlashCommand([
  ...standardSelectionMenuItems,
  mathMenuItem,
]);

/// The slash-menu entry for a block equation.
final SelectionMenuItem mathMenuItem = SelectionMenuItem(
  getName: () => 'Equation',
  icon: (editorState, isSelected, style) => SelectionMenuIconWidget(
    icon: Icons.functions,
    isSelected: isSelected,
    style: style,
  ),
  keywords: ['equation', 'math', 'latex', 'formula'],
  handler: (editorState, _, context) async {
    final selection = editorState.selection;
    if (selection == null || !selection.isCollapsed) return;
    final node = editorState.getNodeAtPath(selection.end.path);
    if (node == null || node.delta == null || selection.end.path.length != 1) {
      return;
    }
    await _insertMathBlock(
      editorState,
      node,
      Navigator.of(context, rootNavigator: true).context,
    );
  },
);

/// Replaces [node] (when empty) or follows it with an equation block and a
/// fresh line, then asks for the formula. [dialogContext] has to outlive
/// [node]: the line it came from may be replaced.
Future<void> _insertMathBlock(
  EditorState editor,
  Node node,
  BuildContext dialogContext, {
  bool replaceLine = false,
}) async {
  final path = node.path;
  final replace = replaceLine || (node.delta?.isEmpty ?? false);
  final at = replace ? path : path.next;
  final tx = editor.transaction;
  if (replace) tx.deleteNode(node);
  tx
    ..insertNode(at, mathBlockNode())
    ..insertNode(at.next, paragraphNode())
    ..afterSelection = Selection.collapsed(Position(path: at.next));
  await editor.apply(tx);
  final inserted = editor.getNodeAtPath(at);
  if (inserted != null && dialogContext.mounted) {
    unawaited(editMathBlock(dialogContext, editor, inserted));
  }
}

Future<bool> _openBlockMath(EditorState editor) async {
  final selection = editor.selection;
  if (selection == null || !selection.isCollapsed) return false;
  final node = editor.getNodeAtPath(selection.end.path);
  final delta = node?.delta;
  if (node == null ||
      delta == null ||
      node.type != ParagraphBlockKeys.type ||
      selection.end.path.length != 1 ||
      selection.end.offset != 2 ||
      delta.toPlainText() != r'$$') {
    return false;
  }
  final context = node.context;
  if (context == null) return false;
  // The root navigator outlives the line that is about to be replaced.
  final dialogContext = Navigator.of(context, rootNavigator: true).context;
  await _insertMathBlock(editor, node, dialogContext, replaceLine: true);
  return true;
}

Future<bool> _closeInlineMath(EditorState editor) async {
  final selection = editor.selection;
  if (selection == null || !selection.isCollapsed) return false;
  final node = editor.getNodeAtPath(selection.end.path);
  final delta = node?.delta;
  if (node == null || delta == null) return false;
  final end = selection.end.offset;
  final before = delta.toPlainText().substring(0, end);
  final open = before.lastIndexOf(r'$');
  if (open < 0) return false;
  final formula = before.substring(open + 1);
  // Empty (`$$`), padded with spaces, or containing an equation already: not
  // an equation, so the `$` is typed as is.
  if (formula.isEmpty ||
      formula.trim() != formula ||
      formula.contains(NoteFormat.inlineMathChar)) {
    return false;
  }
  await editor.apply(
    editor.transaction
      ..replaceText(
        node,
        open,
        end - open,
        NoteFormat.inlineMathChar,
        attributes: {NoteFormat.formulaKey: formula},
      )
      ..afterSelection = Selection.collapsed(
        Position(path: node.path, offset: open + 1),
      ),
  );
  return true;
}
