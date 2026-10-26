// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../box_api/box_codec.dart';
import '../box_api/codec_registry.dart';
import '../json/raw_json.dart';
import '../model/bounds.dart';
import '../model/page.dart';

/// One undoable page-level change: a box moved, resized, added or removed,
/// or a module's own edit to a box's content.
///
/// Text edits inside a note box are undone by its editor, not here. Each
/// change knows how to revert itself and returns its own inverse, so the
/// same objects serve undo and redo.
sealed class PageChange {
  const PageChange();

  /// Records that a node was added. Reverting removes it again.
  const factory PageChange.added(String id) = _Added;

  /// Records that [node] was removed from [index]. Reverting puts it back.
  const factory PageChange.removed(CanvasNode node, int index) = _Removed;

  /// Records that a box's bounds (and whether its height is fixed) changed
  /// from [before] and [fixedHeightBefore]. Reverting restores both; content
  /// edits made since are kept.
  const factory PageChange.bounds(
    String id,
    Bounds before, {
    bool fixedHeightBefore,
  }) = _BoundsChanged;

  /// Records a module's edit to a box's content as a diff. Reverting applies
  /// [undo] through the box's codec and, if given, restores [boundsBefore].
  const factory PageChange.content(
    String id,
    BoxEdit undo, {
    Bounds? boundsBefore,
  }) = _ContentChanged;

  /// Records that [before] was replaced, in place, by another version of the
  /// same node (for example when a conflict is resolved). Reverting puts
  /// [before] back.
  const factory PageChange.replaced(CanvasNode before) = _Replaced;

  /// Several changes made together, undone together. [changes] are in the
  /// order they were made.
  const factory PageChange.group(List<PageChange> changes) = _Group;

  /// Records that the page background was changed from [before], the stored
  /// `background` value (null: none). Reverting restores exactly that text;
  /// the other header fields are kept as they are now.
  const factory PageChange.background(RawJson? before) = _BackgroundChanged;

  /// Reverts this change on [page]. Returns null if the change no longer
  /// applies, for example because its box is gone.
  (NotedPage, PageChange)? revert(NotedPage page, CodecRegistry codecs);
}

final class _BackgroundChanged extends PageChange {
  const _BackgroundChanged(this.before);

  final RawJson? before;

  @override
  (NotedPage, PageChange)? revert(NotedPage page, CodecRegistry codecs) => (
    page.withMeta(page.meta.withRawBackground(before)),
    PageChange.background(page.meta.rawBackground),
  );
}

final class _Replaced extends PageChange {
  const _Replaced(this.before);

  final CanvasNode before;

  @override
  (NotedPage, PageChange)? revert(NotedPage page, CodecRegistry codecs) {
    final current = page.node(before.id);
    if (current == null) return null;
    return (page.replaceNode(before), PageChange.replaced(current));
  }
}

final class _Group extends PageChange {
  const _Group(this.changes);

  final List<PageChange> changes;

  @override
  (NotedPage, PageChange)? revert(NotedPage page, CodecRegistry codecs) {
    var p = page;
    final inverses = <PageChange>[];
    for (final c in changes.reversed) {
      final r = c.revert(p, codecs);
      if (r == null) continue;
      p = r.$1;
      inverses.add(r.$2);
    }
    if (inverses.isEmpty) return null;
    return (p, PageChange.group(inverses));
  }
}

final class _Added extends PageChange {
  const _Added(this.id);

  final String id;

  @override
  (NotedPage, PageChange)? revert(NotedPage page, CodecRegistry codecs) {
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
  (NotedPage, PageChange)? revert(NotedPage page, CodecRegistry codecs) {
    if (page.indexOf(node.id) >= 0) return null;
    return (page.insertNode(node, index), PageChange.added(node.id));
  }
}

final class _BoundsChanged extends PageChange {
  const _BoundsChanged(this.id, this.before, {this.fixedHeightBefore = false});

  final String id;
  final Bounds before;
  final bool fixedHeightBefore;

  @override
  (NotedPage, PageChange)? revert(NotedPage page, CodecRegistry codecs) {
    final n = page.node(id);
    if (n is! BoxRecord) return null;
    return (
      page.replaceNode(n.withBounds(before).withFixedHeight(fixedHeightBefore)),
      PageChange.bounds(id, n.bounds, fixedHeightBefore: n.fixedHeight),
    );
  }
}

final class _ContentChanged extends PageChange {
  const _ContentChanged(this.id, this.undo, {this.boundsBefore});

  final String id;
  final BoxEdit undo;
  final Bounds? boundsBefore;

  @override
  (NotedPage, PageChange)? revert(NotedPage page, CodecRegistry codecs) {
    final n = page.node(id);
    if (n is! BoxRecord) return null;
    final live = codecs.resolve(n);
    final codec = codecs.codecFor(n.typeId);
    if (live is! LiveBox || codec == null) return null;
    final (data, redo) = undo.apply(live.data);
    var next = commitBox(n, codec, data);
    if (boundsBefore != null) next = next.withBounds(boundsBefore!);
    return (
      page.replaceNode(next),
      PageChange.content(id, redo, boundsBefore: boundsBefore == null ? null : n.bounds),
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

  /// Forgets the record of adding [id], and any later changes to it. Used
  /// when an empty box is discarded, so undo doesn't stop on a no-op. Safe
  /// because no other change can depend on a box that was never filled.
  void forgetAdded(String id) {
    final i = _undo.lastIndexWhere((c) => c is _Added && c.id == id);
    if (i < 0) return;
    _undo.removeAt(i);
    _undo.removeWhere(
      (c) => (c is _BoundsChanged && c.id == id) || (c is _ContentChanged && c.id == id),
    );
  }

  /// Undoes the latest change that still applies. Returns null if none does.
  /// Content changes are replayed through [codecs].
  NotedPage? undo(NotedPage page, CodecRegistry codecs) =>
      _step(page, codecs, _undo, _redo);

  NotedPage? redo(NotedPage page, CodecRegistry codecs) =>
      _step(page, codecs, _redo, _undo);

  NotedPage? _step(
    NotedPage page,
    CodecRegistry codecs,
    List<PageChange> from,
    List<PageChange> to,
  ) {
    while (from.isNotEmpty) {
      final result = from.removeLast().revert(page, codecs);
      if (result == null) continue;
      to.add(result.$2);
      return result.$1;
    }
    return null;
  }
}
