// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';

import '../box_api/codec_registry.dart';
import '../json/raw_json.dart';
import '../model/ids.dart';
import '../model/page.dart';
import 'page_issues.dart';
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

/// A file name for a conflict copy of [fileName], in the shape
/// [conflictCopyOriginalNames] recognises: `<stem>-<label>-<unique><extension>`
/// (e.g. `3f2a-conflict-9c1d07ab.canvas`). [fileName] has no folder part.
/// [extension] is the ending kept after the added part ('' for none); it is
/// split off [fileName] first when it ends with it. [label] holds letters and
/// digits only. The result is not checked against existing files: publish it
/// exclusively and ask again (a new random part) when it is taken.
String conflictCopyName(
  String fileName, {
  String label = 'conflict',
  String extension = '.canvas',
  Random? random,
}) {
  assert(RegExp(r'^[A-Za-z0-9]+$').hasMatch(label));
  final hasExt = extension.isNotEmpty && fileName.endsWith(extension);
  final stem = hasExt ? fileName.substring(0, fileName.length - extension.length) : fileName;
  final unique = (random ?? _nameRandom).nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
  return '$stem-$label-$unique${hasExt ? extension : ''}';
}

final Random _nameRandom = Random.secure();

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
/// follows the content choice. A box only the copy has that overlaps a box
/// the copy doesn't have in that place is marked landed; a landed marker on
/// either side's version is kept. The page header and other top-level fields are
/// the original's. A node that isn't a JSON object can't take an id, so when
/// it differs from the other side's at the same place both are kept as they
/// are. [codecs] is unused for now and kept so the signature can
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
      // Not again if an earlier merge of this copy already kept this version.
      if (!_hasVersion(original.nodes, c)) {
        out.add(switch (c) {
          // A node that isn't a JSON object can't take an id: kept as it is.
          ForeignNode() => c.copyWithId(newId()) ?? c,
          BoxRecord() => markLandedIfOverlapping(c.withId(newId()), [o], mergeTime: copyTime),
        });
      }
    }
  }

  // Nodes only the copy has, placed after the node that precedes them there.
  // A box that overlaps a box already on the page is marked landed.
  // (the original's boxes the copy doesn't have, or has elsewhere: ones the
  // copy could see in the same place don't count).
  final existing = nodesUnseenBy(out, copy);
  for (var i = 0; i < copy.nodes.length; i++) {
    var c = copy.nodes[i];
    if (originalIds.contains(c.id)) continue;
    if (c is BoxRecord) c = markLandedIfOverlapping(c, existing, mergeTime: copyTime);
    if (c is ForeignNode && _synthetic(c)) {
      // Its id came from its position or a repeat: on read-back it could take
      // over a node with the same real id, so a JSON object gets a new id.
      // Not again if an earlier merge of this copy already kept it.
      if (_hasVersion(original.nodes, c)) continue;
      c = c.copyWithId(newId()) ?? c;
    }
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

  // The side that did not win, taken before r is rebuilt below (a rebuilt r is
  // a new object, so identity can't be asked later).
  final loser = identical(r, o) ? c : o;

  // Conflicts already recorded on either side are all kept.
  final want = <BoxConflict>[...r.conflicts];
  for (final x in loser.conflicts) {
    if (!want.contains(x)) want.add(x);
  }
  if (isConflict) {
    final other = BoxConflict.other(node: c.toRaw(), at: copyTime);
    if (!want.any((x) => x.node == other.node)) want.add(other);
  }
  if (want.length != r.conflicts.length) r = r.withConflicts(want);

  // The landed marker has no base either: kept when either side has it.
  if (r.landed == null) {
    final l = loser.landed;
    if (l != null) r = r.withLanded(l);
  }
  return (r, isConflict);
}

/// Whether [n] has an id the page reader made up (from its position, or
/// because the id repeats) rather than one in its own `id` field.
bool _synthetic(ForeignNode n) {
  if (!n.raw.isObject) return true;
  try {
    return RawObject.parse(n.raw.text).string('id') != n.id;
  } on FormatException {
    return true;
  }
}

/// Whether [nodes] already hold [c], as it is, or (a node of a JSON object)
/// with another id, or (a box) by revision or content.
bool _hasVersion(List<CanvasNode> nodes, CanvasNode c) {
  for (final n in nodes) {
    if (c is BoxRecord) {
      if (n is BoxRecord && (c.rev != null ? n.rev == c.rev : _sameContent(n, c))) return true;
    } else if (c is ForeignNode && _sameModuloId(n, c)) {
      return true;
    }
  }
  return false;
}

bool _sameModuloId(CanvasNode n, ForeignNode c) =>
    n.toRaw() == c.toRaw() ||
    (c.raw.isObject && n.toRaw().isObject && c.copyWithId(n.id)?.toRaw() == n.toRaw());

bool _sameContent(BoxRecord x, BoxRecord y) =>
    x.typeId == y.typeId &&
    x.dataVersion == y.dataVersion &&
    x.data == y.data &&
    x.snapshotText == y.snapshotText;

/// Checks, on the page read back from disk, that the merge of [copy] into
/// [original] lost nothing: every node of both sides is there, each matched to
/// its own node on disk, and for each box both sides have, the saved content is
/// one side's version and the other is either its ancestor (by revision) or
/// recorded in the box's `conflicts`.
///
/// A node Noted doesn't own is matched by its raw text, since its id may be
/// synthetic (from its position): the original's must be there byte for byte,
/// the copy's may also have a new id written into its `id` field, or be
/// recorded in the `conflicts` of the box that has its id. A box only the copy
/// has (or one the original has as a foreign node) is matched by revision or
/// content, as it may have taken a new id.
///
/// Returns null if all is well, otherwise what is missing.
String? verifyConflictCopyMerge(NotedPage onDisk, NotedPage original, NotedPage copy) {
  final copyById = {for (final n in copy.nodes) n.id: n};
  final originalById = {for (final n in original.nodes) n.id: n};
  final disk = onDisk.nodes;
  final used = <int>{};
  // Claims the first disk node not yet claimed that passes [test].
  bool take(bool Function(CanvasNode d) test) {
    for (var i = 0; i < disk.length; i++) {
      if (used.contains(i) || !test(disk[i])) continue;
      used.add(i);
      return true;
    }
    return false;
  }

  // Boxes first, by id; a node Noted doesn't own is matched by raw text against
  // a disk node of either kind (a repeated box id reads as a foreign node, but
  // once the merge gave it a new id it reads back as a box).
  for (final o in original.nodes) {
    if (o is! ForeignNode && !take((d) => d is BoxRecord && d.id == o.id)) {
      return 'node ${o.id} is missing';
    }
  }
  for (final o in original.nodes) {
    if (o is ForeignNode && !take((d) => d.toRaw() == o.toRaw())) {
      return 'foreign node ${o.id} is missing or changed';
    }
  }
  // A copy node the original already holds in another form (an earlier merge
  // of this copy kept it) needs no node of its own.
  bool held(CanvasNode c, CanvasNode? o) =>
      (o != null || (c is ForeignNode && _synthetic(c))) && _hasVersion(original.nodes, c);
  final boxes = <BoxRecord>[];
  for (final c in copy.nodes) {
    final o = originalById[c.id];
    if (o != null && o.toRaw() == c.toRaw()) continue; // the original's node
    if (c is ForeignNode) {
      if (o is BoxRecord) {
        // Recorded as a conflicting version of the box with its id.
        final d = onDisk.node(o.id);
        if (d is! BoxRecord || !d.conflicts.any((k) => k.node == c.toRaw())) {
          return 'foreign node ${c.id} is missing or changed';
        }
      } else if (!held(c, o) && !take((d) => _sameModuloId(d, c))) {
        return 'foreign node ${c.id} is missing or changed';
      }
    } else if (c is BoxRecord && o is! BoxRecord) {
      // Only the copy has this box, or the original has a foreign node by its
      // id and the box took a new id.
      boxes.add(c);
    }
  }
  // Matched by revision first, so a content match can't take a node a later
  // revision match needs.
  for (final byRev in [true, false]) {
    for (final c in boxes) {
      if ((c.rev != null) != byRev) continue;
      if (!take((d) => d is BoxRecord && (byRev ? d.rev == c.rev : _sameContent(d, c))) &&
          !held(c, originalById[c.id])) {
        return 'box ${c.id} is missing';
      }
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
