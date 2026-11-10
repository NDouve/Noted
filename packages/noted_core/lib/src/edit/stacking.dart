// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../merge/page_issues.dart';
import '../model/page.dart';

/// A change of a node's place in the page's z-order (first is bottom-most).
enum StackMove {
  /// Last in `nodes`: on top of every other node.
  front,

  /// Directly above the next node above it whose bounds overlap its own.
  forward,

  /// Directly below the next node below it whose bounds overlap its own.
  backward,

  /// First in `nodes`: under every other node.
  back,
}

final _positionalId = RegExp(r'^#(node|dup)\d+$');

/// Whether [node] has an id of its own. A node read without an id gets a
/// positional one (`#node<i>`, `#dup<i>`) that follows its place in the
/// list, so it can't be tracked across a reorder.
bool hasOwnId(CanvasNode node) => !_positionalId.hasMatch(node.id);

/// Where node [id] would sit after [move], as its index in the result (counted
/// after the node is taken out of the list), or null if the move would change
/// nothing: the node is missing, has no id of its own, is already there, or
/// (forward and backward) has no overlapping node to pass. Nodes without
/// bounds never count as overlapping. Pure: it reads only ids and bounds, so
/// every node, whatever its type, can be moved and is moved verbatim.
int? stackTarget(NotedPage page, String id, StackMove move) {
  final nodes = page.nodes;
  final i = page.indexOf(id);
  if (i < 0 || !hasOwnId(nodes[i])) return null;
  final last = nodes.length - 1;
  switch (move) {
    case StackMove.front:
      return i == last ? null : last;
    case StackMove.back:
      return i == 0 ? null : 0;
    case StackMove.forward:
      final b = nodes[i].bounds;
      if (b == null) return null;
      for (var j = i + 1; j <= last; j++) {
        final o = nodes[j].bounds;
        // Taking the node out shifts everything above it down by one, so the
        // node `j` ends directly below index `j`.
        if (o != null && boundsOverlap(b, o)) return j;
      }
      return null;
    case StackMove.backward:
      final b = nodes[i].bounds;
      if (b == null) return null;
      for (var j = i - 1; j >= 0; j--) {
        final o = nodes[j].bounds;
        if (o != null && boundsOverlap(b, o)) return j;
      }
      return null;
  }
}
