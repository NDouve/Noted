// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show DesignMetrics;

/// How another box type marks some of the note blocks it shows (for
/// example the AI box marks blocks an AI wrote). Opt-in: the note box itself
/// uses none.
final class NoteBlockMark {
  const NoteBlockMark({
    required this.dataKey,
    required this.isMarked,
    required this.color,
  });

  /// A top-level block is only a candidate while its data has this key; the
  /// check is cheap, [isMarked] runs only for those blocks.
  final String dataKey;

  /// Whether the block, given as JSON (`type`, `data`, `children`), is
  /// marked. Must not change the map.
  final bool Function(Map<String, Object?> block) isMarked;

  /// The color of the thin bar drawn at the left of a marked block.
  final Color Function(BuildContext context) color;
}

/// Options for [NoteEditorView]. The defaults are the plain note box.
final class NoteEditorOptions {
  const NoteEditorOptions({this.blockMark, this.beforeCommit});

  /// Marks some top-level blocks, in the editor and in the light view alike.
  /// The mark is drawn beside the block and takes no room.
  final NoteBlockMark? blockMark;

  /// Runs on the document JSON (`{"document": {...}}`) just before the
  /// editor commits it. Returns the JSON to commit; it must not change the
  /// map it is given (that is the editor's live data), but may return a
  /// copy.
  final Map<String, Object?> Function(Map<String, Object?> document)?
  beforeCommit;
}

/// Wraps [child], a top-level block, with the mark of [mark] while it is
/// marked. Listens to [node], so typing ends the mark at once.
class MarkedBlock extends StatefulWidget {
  const MarkedBlock({
    super.key,
    required this.node,
    required this.mark,
    required this.child,
  });

  final Node node;
  final NoteBlockMark mark;
  final Widget child;

  @override
  State<MarkedBlock> createState() => _MarkedBlockState();
}

class _MarkedBlockState extends State<MarkedBlock> {
  @override
  void initState() {
    super.initState();
    widget.node.addListener(_changed);
  }

  @override
  void didUpdateWidget(MarkedBlock old) {
    super.didUpdateWidget(old);
    if (old.node != widget.node) {
      old.node.removeListener(_changed);
      widget.node.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.node.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// A copy of [n] as JSON, without touching it (`Node.toJson` hands out
  /// the live attributes).
  Map<String, Object?> _json(Node n) => {
    'type': n.type,
    'data': Map<String, Object?>.of(n.attributes),
    if (n.children.isNotEmpty) 'children': [for (final c in n.children) _json(c)],
  };

  @override
  Widget build(BuildContext context) {
    final mark = widget.mark;
    if (!widget.node.attributes.containsKey(mark.dataKey) ||
        !mark.isMarked(_json(widget.node))) {
      return widget.child;
    }
    return Stack(
      clipBehavior: Clip.none,
      // The block gets the constraints it would get without the mark.
      fit: StackFit.passthrough,
      children: [
        widget.child,
        Positioned(
          left: -DesignMetrics.space1 - 2,
          top: 2,
          bottom: 2,
          width: 2,
          child: IgnorePointer(
            child: DecoratedBox(
              key: const ValueKey('note-block-mark'),
              decoration: BoxDecoration(
                color: mark.color(context),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
