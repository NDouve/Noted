// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

/// Arrow up/down (and Shift+arrow) that work on a zoomed canvas.
///
/// appflowy's own vertical movement mixes screen and page units: it takes
/// the caret's position on screen but its height, block padding and 1 px
/// search step from the unscaled page, and its document-wide hit test
/// (`selectionService.getPositionInOffset`) finds blocks by unscaled sizes
/// too. Zoomed out, a point just above a line resolves to a line or more
/// away, so the caret bounces between two lines. These commands probe in
/// screen pixels scaled by the measured zoom, find the block from its real
/// on-screen rectangle, and let that block map the point to a position.
final List<CommandShortcutEvent> noteCommandShortcuts = [
  for (final e in standardCommandShortcutEvents)
    if (!_replaced.contains(e.key)) e,
  _escape,
  _vertical(moveCursorUpCommand, up: true, extend: false),
  _vertical(moveCursorDownCommand, up: false, extend: false),
  _vertical(moveCursorUpSelectCommand, up: true, extend: true),
  _vertical(moveCursorDownSelectCommand, up: false, extend: true),
];

final Set<String> _replaced = {
  exitEditingCommand.key,
  moveCursorUpCommand.key,
  moveCursorDownCommand.key,
  moveCursorUpSelectCommand.key,
  moveCursorDownSelectCommand.key,
};

CommandShortcutEvent _vertical(
  CommandShortcutEvent original, {
  required bool up,
  required bool extend,
}) => original.copyWith(
  handler: (editorState) {
    final selection = editorState.selection;
    if (selection == null) return KeyEventResult.ignored;
    final to = moveCaretVertically(editorState, selection.end, up: up);
    if (to == null) return KeyEventResult.ignored;
    editorState.updateSelectionWithReason(
      extend ? selection.copyWith(end: to) : Selection.collapsed(to),
      reason: SelectionUpdateReason.uiEvent,
    );
    return KeyEventResult.handled;
  },
);

/// The position one line above or below [from], at the same horizontal
/// position, whatever the canvas zoom. On the first or last line it moves to
/// the start or end of that line, as appflowy does.
Position? moveCaretVertically(
  EditorState editorState,
  Position from, {
  required bool up,
}) {
  final caret = caretOnScreen(editorState, from);
  if (caret == null) return null;
  final (rect, scale) = caret;
  final edge = up ? rect.top : rect.bottom;
  // One page pixel on screen, searching up to three lines of page distance:
  // enough to cross block padding between paragraphs.
  final step = math.max(scale, 0.25);
  final maxDistance = math.max(rect.height / scale * 3, 60.0) * scale;
  final blocks = _blocksOnScreen(editorState);
  for (var d = step; d <= maxDistance; d += step) {
    final probe = Offset(rect.left, up ? edge - d : edge + d);
    final p = _positionAt(blocks, probe);
    if (p == null || p == from) continue;
    // Accept only a position on another line, not a neighbour on this one.
    final found = caretOnScreen(editorState, p);
    if (found == null) continue;
    final other = found.$1;
    final onAnotherLine = up
        ? other.center.dy < rect.top
        : other.center.dy > rect.bottom;
    if (onAnotherLine) return p;
  }
  final node = editorState.document.nodeAtPath(from.path);
  final length = node?.delta?.length;
  if (length == null) return from;
  return up
      ? Position(path: from.path)
      : Position(path: from.path, offset: length);
}

/// Every text block with its rectangle on screen, in document order.
List<(Node, Rect)> _blocksOnScreen(EditorState editorState) {
  final out = <(Node, Rect)>[];
  void walk(Node node) {
    final box = node.renderBox;
    if (node.selectable != null && box != null && box.attached && box.hasSize) {
      out.add((
        node,
        MatrixUtils.transformRect(
          box.getTransformTo(null),
          Offset.zero & box.size,
        ),
      ));
    }
    node.children.forEach(walk);
  }

  editorState.document.root.children.forEach(walk);
  return out;
}

/// The position under [point]: in the innermost block whose band contains
/// its height. Nested blocks come after their parent in document order.
Position? _positionAt(List<(Node, Rect)> blocks, Offset point) {
  Node? hit;
  for (final (node, rect) in blocks) {
    if (point.dy >= rect.top && point.dy < rect.bottom) hit = node;
  }
  return hit?.selectable?.getPositionInOffset(point);
}

/// The caret's rectangle on screen and the zoom it is drawn at, measured
/// from the caret's own block so it is right at any canvas zoom.
(Rect, double)? caretOnScreen(EditorState editorState, Position position) {
  final selectable = editorState.document.nodeAtPath(position.path)?.selectable;
  if (selectable == null) return null;
  final local = selectable.getCursorRectInPosition(
    position,
    shiftWithBaseOffset: true,
  );
  if (local == null || local.height <= 0) return null;
  final topLeft = selectable.localToGlobal(
    local.topLeft,
    shiftWithBaseOffset: true,
  );
  final bottomRight = selectable.localToGlobal(
    local.bottomRight,
    shiftWithBaseOffset: true,
  );
  final rect = Rect.fromPoints(topLeft, bottomRight);
  return (rect, rect.height / local.height);
}

/// Escape in a note editor.
///
/// appflowy's own Escape clears the selection and consumes the key, which
/// kept focus in the editor. Here the editor answers Escape only when it has
/// something of its own to close: a range selection, which is what shows its
/// floating selection toolbar (clearing the selection closes it). Anything
/// else that can be open (the `/` menu, a table handle menu, a dialog) has
/// its own focus scope or route and takes the key before it reaches the
/// editor. With nothing to close the key is ignored, so it bubbles to the
/// canvas's `canvas.escape`, which leaves the editor.
final CommandShortcutEvent _escape = exitEditingCommand.copyWith(
  handler: (editorState) {
    final selection = editorState.selection;
    if (selection == null || selection.isCollapsed) {
      return KeyEventResult.ignored;
    }
    editorState.selection = null;
    return KeyEventResult.handled;
  },
);
