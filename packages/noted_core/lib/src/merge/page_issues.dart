// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../box_api/box_codec.dart';
import '../box_api/codec_registry.dart';
import '../model/bounds.dart';
import '../model/ids.dart';
import '../model/page.dart';

/// Whether [a] and [b] share a rectangle of positive area. Edges that only
/// touch don't overlap.
bool boundsOverlap(Bounds a, Bounds b) =>
    a.x < b.right &&
    b.x < a.right &&
    a.y < b.bottom &&
    b.y < a.bottom &&
    a.width > 0 &&
    a.height > 0 &&
    b.width > 0 &&
    b.height > 0;

/// The nodes of [nodes] that [side] couldn't see in their place: those it
/// doesn't have, or has with other bounds. A box arriving from [side] that
/// overlaps one of these landed by surprise; overlapping a box [side] has in
/// the same place was the other device's own doing.
List<CanvasNode> nodesUnseenBy(Iterable<CanvasNode> nodes, NotedPage side) {
  return [
    for (final n in nodes)
      if (side.node(n.id)?.bounds != n.bounds) n,
  ];
}

/// Marks [arriving], a box that came from the other side of a merge, as
/// landed if its bounds overlap any of [existing] (the nodes already on the
/// page). The marker takes the arriving version's device and time when it
/// has them, else [mergeTime] (ms since the epoch). A box that doesn't
/// overlap anything, or already carries a marker, is returned as it is;
/// nodes without bounds never count.
BoxRecord markLandedIfOverlapping(
  BoxRecord arriving,
  Iterable<CanvasNode> existing, {
  required int mergeTime,
}) {
  if (arriving.landed != null || arriving.noted.containsKey('landed')) {
    return arriving;
  }
  final b = arriving.bounds;
  for (final n in existing) {
    final nb = n.bounds;
    if (nb == null || n.id == arriving.id) continue;
    if (boundsOverlap(b, nb)) {
      return arriving.withLanded(
        BoxLanded(at: arriving.editedAt ?? mergeTime, device: arriving.device),
      );
    }
  }
  return arriving;
}

/// What is wrong with a box, to be settled by the user.
enum PageIssueKind {
  /// The box arrived from another device and landed on top of another box.
  landed,

  /// Both sides changed the box; the other version is recorded.
  conflict,

  /// The other side deleted the box while this one edited it.
  deleteConflict,

  /// A conflict on a box this device can't open: settled without decoding it.
  unreadableConflict,
}

/// One issue on one box of a page, until the user resolves it.
final class PageIssue {
  const PageIssue({
    required this.boxId,
    required this.kind,
    this.conflict,
    this.landed,
    this.otherPlaceable = false,
  });

  /// Whether the recorded other version is a Noted box that [keepOther] and
  /// [placeBoth] can use. False for a deletion, for landed, and when the
  /// recorded node isn't a Noted box (offer only keep mine then).
  final bool otherPlaceable;

  final String boxId;
  final PageIssueKind kind;

  /// The conflict record this issue is about (the box's first recorded one);
  /// null for [PageIssueKind.landed].
  final BoxConflict? conflict;

  /// The landed marker; set for [PageIssueKind.landed].
  final BoxLanded? landed;

  @override
  bool operator ==(Object other) =>
      other is PageIssue &&
      other.boxId == boxId &&
      other.kind == kind &&
      other.conflict == conflict &&
      other.landed == landed &&
      other.otherPlaceable == otherPlaceable;

  @override
  int get hashCode =>
      Object.hash(boxId, kind, conflict, landed, otherPlaceable);
}

/// The issues on [page], in reading order: top to bottom, then left to right
/// by the box's top-left corner, ties by id.
///
/// A box yields one issue for its conflicts (about the first recorded one;
/// once that is resolved the next shows) and, separately, one for a `landed`
/// marker. The conflict comes first, then landed. [canOpen] says whether this
/// device can open the box's module; a conflict on a box it can't open is
/// [PageIssueKind.unreadableConflict]. Boxes are never decoded here.
List<PageIssue> pageIssues(
  NotedPage page, {
  required bool Function(BoxRecord) canOpen,
}) {
  final boxes = [
    for (final n in page.nodes)
      if (n is BoxRecord && (n.isConflicted || n.landed != null)) n,
  ];
  boxes.sort((a, b) {
    final c = a.bounds.y.compareTo(b.bounds.y);
    if (c != 0) return c;
    final d = a.bounds.x.compareTo(b.bounds.x);
    return d != 0 ? d : a.id.compareTo(b.id);
  });
  final out = <PageIssue>[];
  for (final box in boxes) {
    final conflicts = box.conflicts;
    if (conflicts.isNotEmpty) {
      final c = conflicts.first;
      out.add(
        PageIssue(
          boxId: box.id,
          kind: c.deleted
              ? PageIssueKind.deleteConflict
              : canOpen(box)
              ? PageIssueKind.conflict
              : PageIssueKind.unreadableConflict,
          conflict: c,
          otherPlaceable:
              c.node != null &&
              readNode(c.node!, fallbackId: box.id) is BoxRecord,
        ),
      );
    }
    final l = box.landed;
    if (l != null) {
      out.add(PageIssue(boxId: box.id, kind: PageIssueKind.landed, landed: l));
    }
  }
  return out;
}

// Resolutions. Each returns the page with one issue settled and is a no-op
// (the same page) if the box or the conflict isn't there. They work on raw
// nodes, so they never decode a box's data and are safe for unreadable boxes.
// Only the resolved conflict record is removed: others recorded on the box
// remain and show as the next issue.

/// The gap placed between the two boxes by [placeBoth].
const double placeBothGap = 24;

/// [placeBoth] puts the other version below when beside would pass this x.
const double placeBothMaxRight = 2400;

BoxRecord? _box(NotedPage page, String boxId) {
  final n = page.node(boxId);
  return n is BoxRecord ? n : null;
}

BoxConflict? _pick(BoxRecord box, BoxConflict? conflict) {
  final all = box.conflicts;
  if (all.isEmpty) return null;
  if (conflict == null) return all.first;
  return all.contains(conflict) ? conflict : null;
}

List<BoxConflict> _without(BoxRecord box, BoxConflict c) => [
  for (final x in box.conflicts)
    if (x != c) x,
];

/// Keep this version: the recorded other version is dropped.
NotedPage keepMine(NotedPage page, String boxId, {BoxConflict? conflict}) {
  final box = _box(page, boxId);
  if (box == null) return page;
  final c = _pick(box, conflict);
  if (c == null) return page;
  return page.replaceNode(box.withConflicts(_without(box, c)));
}

/// Keep the other version: the recorded other node's content replaces this
/// box's, in the same place in the z-order, keeping this box's bounds and
/// fixed height (the rest of the node is the other's as recorded). Conflicts recorded on the
/// replaced box (apart from the resolved one) stay; a `landed` marker on this
/// box stays. Returns [page] if the record is a deletion or the other node is
/// not a Noted box.
NotedPage keepOther(NotedPage page, String boxId, {BoxConflict? conflict}) {
  final box = _box(page, boxId);
  if (box == null) return page;
  final c = _pick(box, conflict);
  final raw = c?.node;
  if (c == null || raw == null) return page;
  final other = readNode(raw, fallbackId: boxId);
  if (other is! BoxRecord) return page;
  var r = other.id == boxId ? other : other.withId(boxId);
  // Only the content comes from the other node; where the box is and its
  // fixed height stay as this device has them.
  r = r.withBounds(box.bounds).withFixedHeight(box.fixedHeight);
  r = r.withConflicts(_without(box, c));
  final landed = box.landed;
  if (landed != null && r.landed == null) r = r.withLanded(landed);
  return page.replaceNode(r);
}

/// Place both: keep this version and add the other as a new box with a fresh
/// id, just above this one in the z-order. It goes to the right of this box
/// with a [placeBothGap] gap, or below it if that would pass
/// [placeBothMaxRight]. Its own conflicts and `landed` marker are cleared.
/// Returns [page] if the record is a deletion or the other node is not a
/// Noted box.
NotedPage placeBoth(
  NotedPage page,
  String boxId, {
  BoxConflict? conflict,
  double maxRight = placeBothMaxRight,
}) {
  final box = _box(page, boxId);
  if (box == null) return page;
  final c = _pick(box, conflict);
  final raw = c?.node;
  if (c == null || raw == null) return page;
  final other = readNode(raw, fallbackId: boxId);
  if (other is! BoxRecord) return page;
  final size = other.bounds;
  final mine = box.bounds;
  var at = Bounds(mine.right + placeBothGap, mine.y, size.width, size.height);
  if (at.right > maxRight) {
    at = Bounds(mine.x, mine.bottom + placeBothGap, size.width, size.height);
  }
  final added = other
      .withId(newId())
      .withoutConflicts()
      .withoutLanded()
      .withBounds(at);
  final i = page.indexOf(boxId);
  return page
      .replaceNode(box.withConflicts(_without(box, c)))
      .insertNode(added, i + 1);
}

/// Delete conflict, keep the box: the record of the other side's deletion is
/// dropped.
NotedPage keepBox(NotedPage page, String boxId, {BoxConflict? conflict}) =>
    keepMine(page, boxId, conflict: conflict);

/// Delete conflict, delete the box (with whatever else is recorded on it).
NotedPage deleteBox(NotedPage page, String boxId) {
  if (_box(page, boxId) == null) return page;
  return page.removeNode(boxId);
}

/// Accept merged content: commits [data] to the box through [codec] (a new
/// revision, as an edit) and drops the resolved conflict record. Returns
/// [page] if the box or record isn't there or the codec is for another type.
NotedPage acceptMerged(
  NotedPage page,
  String boxId,
  BoxCodec<Object?> codec,
  Object? data, {
  BoxConflict? conflict,
  String? device,
  int? at,
}) {
  final box = _box(page, boxId);
  if (box == null || box.typeId != codec.typeId) return page;
  final c = _pick(box, conflict);
  if (c == null) return page;
  final next = commitBox(
    box,
    codec,
    data,
    device: device,
    at: at,
  ).withConflicts(_without(box, c));
  return page.replaceNode(next);
}

/// Clears the `landed` marker of a box ("Leave it here", or after it moved).
NotedPage clearLanded(NotedPage page, String boxId) {
  final box = _box(page, boxId);
  if (box == null) return page;
  return page.replaceNode(box.withoutLanded());
}
