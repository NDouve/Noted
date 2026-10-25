// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../model/bounds.dart';
import '../model/page.dart';

/// One undoable page-level change: a box moved, resized, added or removed.
///
/// Text edits inside a box are undone by the box's own editor, not here.
/// Each change knows how to revert itself and returns its own inverse, so the
/// same objects serve undo and redo.
sealed class PageChange {
  const PageChange();

  /// Records that a node was added. Reverting removes it again.
  const factory PageChange.added(String id) = _Added;

  /// Records that [node] was removed from [index]. Reverting puts it back.
  const factory PageChange.removed(CanvasNode node, int index) = _Removed;

  /// Records that a box's bounds changed from [before]. Reverting restores
  /// [before]; content edits made since are kept.
  const factory PageChange.bounds(String id, Bounds before) = _BoundsChanged;

  /// Reverts this change on [page]. Returns null if the change no longer
  /// applies, for example because its box is gone.
  (Page, PageChange)? revert(Page page);
}

final class _Added extends PageChange {
  const _Added(this.id);

  final String id;

  @override
  (Page, PageChange)? revert(Page page) {
    final i = page.indexOf(id);
    if (i < 0) return null;
    return (page.removeNode(id), PageChange.removed(page.nodes[i], i));
  }
}

final class _Removed extends PageChange {
  const _Removed(this.node, this.index);

  final CanvasNode node;
  final int index;

  @override
  (Page, PageChange)? revert(Page page) {
    if (page.indexOf(node.id) >= 0) return null;
    return (page.insertNode(node, index), PageChange.added(node.id));
  }
}

final class _BoundsChanged extends PageChange {
  const _BoundsChanged(this.id, this.before);

  final String id;
  final Bounds before;

  @override
  (Page, PageChange)? revert(Page page) {
    final n = page.node(id);
    if (n is! BoxRecord) return null;
    return (
      page.replaceNode(n.withBounds(before)),
      PageChange.bounds(id, n.bounds),
    );
  }
}

/// Page-level undo and redo stacks.
///
/// Held in memory only and dropped with the page. Undo history never
/// persists (invariant 3 forbids persisted undo for encrypted content, and
/// Prototype 1 doesn't persist any).
final class PageHistory {
  PageHistory({this.limit = 200});

  final int limit;
  final List<PageChange> _undo = [];
  final List<PageChange> _redo = [];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void record(PageChange change) {
    _undo.add(change);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
  }

  /// Forgets the record of adding [id] if it is the latest change. Used when
  /// an empty box is discarded, so undo doesn't stop on a no-op.
  void forgetAdded(String id) {
    final last = _undo.isEmpty ? null : _undo.last;
    if (last is _Added && last.id == id) _undo.removeLast();
  }

  /// Undoes the latest change that still applies. Returns null if none does.
  Page? undo(Page page) => _step(page, _undo, _redo);

  Page? redo(Page page) => _step(page, _redo, _undo);

  Page? _step(Page page, List<PageChange> from, List<PageChange> to) {
    while (from.isNotEmpty) {
      final result = from.removeLast().revert(page);
      if (result == null) continue;
      to.add(result.$2);
      return result.$1;
    }
    return null;
  }
}
