// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../box_api/codec_registry.dart';
import '../model/ids.dart';
import '../model/page.dart';
import 'page_merge.dart';

/// The file names a sync client may have renamed [fileName] from, when it
/// keeps both copies of a file changed on two machines (unverified naming):
/// OneDrive appends a hyphen and the computer name before the extension, and
/// a number if that name is taken, e.g. `3f2a-DESKTOP-4QK2N8L.canvas` or
/// `3f2a-DESKTOP-4QK2N8L-1.canvas`.
///
/// Returns the candidate original file names, the shortest stem first. Every
/// hyphen in the stem may start the suffix, since page ids and computer names
/// can both hold hyphens; the caller checks which candidate exists and holds
/// the same page. Empty if [fileName] doesn't have the shape.
List<String> conflictCopyOriginalNames(String fileName, {String extension = '.canvas'}) {
  if (!fileName.endsWith(extension)) return const [];
  final stem = fileName.substring(0, fileName.length - extension.length);
  final suffix = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$');
  final out = <String>[];
  for (var i = 1; i < stem.length - 1; i++) {
    if (stem[i] != '-') continue;
    if (!suffix.hasMatch(stem.substring(i + 1))) continue;
    out.add('${stem.substring(0, i)}$extension');
  }
  return out;
}

/// Merges a sync client's conflict copy of a page into the [original] page
/// file (same page id), box by box.
///
/// There is no common base, so what each side did to a box is derived from
/// content revisions (0020). Per box:
///
/// - identical, or the same `rev`: the original is kept.
/// - the copy's `baseRev` is the original's `rev`: the copy edited it further,
///   so the copy's box is taken.
/// - the original's `baseRev` is the copy's `rev`: the original is newer and
///   kept.
/// - otherwise both changed: without a base the box codec can't merge, so the
///   original is kept and the copy's version is recorded in the box's
///   `conflicts` (at [copyTime], ms since the epoch).
///
/// A box only one side has is kept (without a base there is no telling it
/// was deleted). Recorded conflicts of both sides are combined. Geometry
/// follows the content choice. The page header and other top-level fields are
/// the original's. [codecs] is unused for now and kept so the signature can
/// grow a codec-level merge.
PageMerge mergeConflictCopy(
  NotedPage original,
  NotedPage copy,
  CodecRegistry codecs, {
  required int copyTime,
}) {
  final copyById = {for (final n in copy.nodes) n.id: n};
  final originalIds = {for (final n in original.nodes) n.id};
  final conflicted = <String>{};
  final out = <CanvasNode>[];

  for (final o in original.nodes) {
    final c = copyById[o.id];
    if (c == null || o.toRaw() == c.toRaw()) {
      out.add(o);
      continue;
    }
    if (o is BoxRecord && c is BoxRecord) {
      final (node, isConflict) = _mergeBox(o, c, copyTime);
      out.add(node);
      if (isConflict) conflicted.add(o.id);
    } else if (o is BoxRecord) {
      // The copy's node isn't a Noted box: keep it as a conflicting version.
      out.add(o.withConflict(BoxConflict.other(node: c.toRaw(), at: copyTime)));
      conflicted.add(o.id);
    } else {
      // A node Noted doesn't own differs: keep both, nothing is dropped.
      out.add(o);
      final extra = switch (c) {
        ForeignNode() => c.copyWithId(newId()),
        BoxRecord() => c.withId(newId()),
      };
      if (extra != null) out.add(extra);
    }
  }

  // Nodes only the copy has, placed after the node that precedes them there.
  for (var i = 0; i < copy.nodes.length; i++) {
    final c = copy.nodes[i];
    if (originalIds.contains(c.id)) continue;
    var at = 0;
    for (var j = i - 1; j >= 0; j--) {
      final k = out.indexWhere((n) => n.id == copy.nodes[j].id);
      if (k >= 0) {
        at = k + 1;
        break;
      }
    }
    out.insert(at, c);
  }

  final merged = NotedPage.fromParts(original.top, original.meta, out);
  return PageMerge(merged, conflicted);
}

(BoxRecord, bool) _mergeBox(BoxRecord o, BoxRecord c, int copyTime) {
  var r = o;
  var isConflict = false;
  final bothRev = o.rev != null && c.rev != null;
  if (bothRev && o.rev == c.rev) {
    // Same content.
  } else if (c.baseRev != null && c.baseRev == o.rev) {
    r = c; // the copy is newer
  } else if (o.baseRev != null && o.baseRev == c.rev) {
    // the original is newer
  } else if (!bothRev && _sameContent(o, c)) {
    // No revisions to go by, but the content is the same.
  } else {
    isConflict = true;
  }

  // Conflicts already recorded on either side are all kept.
  final want = <BoxConflict>[...r.conflicts];
  for (final x in (identical(r, o) ? c : o).conflicts) {
    if (!want.contains(x)) want.add(x);
  }
  if (isConflict) {
    final other = BoxConflict.other(node: c.toRaw(), at: copyTime);
    if (!want.any((x) => x.node == other.node)) want.add(other);
  }
  if (want.length != r.conflicts.length) r = r.withConflicts(want);
  return (r, isConflict);
}

bool _sameContent(BoxRecord x, BoxRecord y) =>
    x.typeId == y.typeId &&
    x.dataVersion == y.dataVersion &&
    x.data == y.data &&
    x.snapshotText == y.snapshotText;

/// Checks, on the page read back from disk, that the merge of [copy] into
/// [original] lost nothing: every node id of both sides is there, and for each
/// box both sides have, the saved content is one side's version and the other
/// is either its ancestor (by revision) or recorded in the box's `conflicts`.
///
/// Returns null if all is well, otherwise what is missing.
String? verifyConflictCopyMerge(NotedPage onDisk, NotedPage original, NotedPage copy) {
  final copyById = {for (final n in copy.nodes) n.id: n};
  for (final side in [original, copy]) {
    for (final n in side.nodes) {
      if (onDisk.node(n.id) == null) return 'node ${n.id} is missing';
    }
  }
  for (final o in original.nodes) {
    final c = copyById[o.id];
    if (c == null || o.toRaw() == c.toRaw()) continue;
    if (o is! BoxRecord || c is! BoxRecord) continue; // checked by id only
    final d = onDisk.node(o.id);
    if (d is! BoxRecord) return 'box ${o.id} is no longer a box';
    bool isVersion(BoxRecord x) => x.rev != null ? d.rev == x.rev : _sameContent(d, x);
    bool covered(BoxRecord x) =>
        isVersion(x) ||
        d.conflicts.any((k) => k.node == x.toRaw()) ||
        (x.rev != null && d.baseRev == x.rev);
    if (!isVersion(o) && !isVersion(c)) return 'box ${o.id} holds neither version';
    if (!covered(o) || !covered(c)) return 'a version of box ${o.id} was lost';
  }
  return null;
}
