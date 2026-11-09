// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';

import '../box_api/codec_registry.dart';
import '../json/raw_json.dart';
import '../model/ids.dart';
import '../model/page.dart';
import 'merge_rules.dart';
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
///
/// [forRecovery] is the replay of a kept version (0120: the recovery merge never
/// marks): no new landed marker is set, while one already on either side is
/// kept, and a version recorded in a box's `conflicts` has no `conflicts` of its
/// own (those are combined separately), so a repeat merge doesn't nest.
PageMerge mergeConflictCopy(
  NotedPage original,
  NotedPage copy,
  CodecRegistry codecs, {
  required int copyTime,
  bool forRecovery = false,
}) {
  final copyById = {for (final n in copy.nodes) n.id: n};
  final originalIds = {for (final n in original.nodes) n.id};
  final conflicted = <String>{};
  final held = _heldCopyNodes(original, copy);
  final out = <CanvasNode>[];

  for (final o in original.nodes) {
    final c = copyById[o.id];
    if (c == null || o.toRaw() == c.toRaw()) {
      out.add(o);
      continue;
    }
    if (o is BoxRecord && c is BoxRecord) {
      final (node, isConflict) = _mergeBox(o, c, copyTime, forRecovery);
      out.add(node);
      if (isConflict) conflicted.add(o.id);
    } else if (o is BoxRecord) {
      // The copy's node isn't a Noted box: keep it as a conflicting version.
      // Not again when an earlier merge recorded this node.
      final other = BoxConflict.other(node: c.toRaw(), at: copyTime);
      out.add(o.conflicts.any((x) => x.node == other.node) ? o : o.withConflict(other));
      conflicted.add(o.id);
    } else {
      // A node Noted doesn't own differs: keep both, nothing is dropped.
      out.add(o);
      // Not again if an earlier merge of this copy already kept this version.
      if (!held.contains(c)) {
        out.add(switch (c) {
          // A node that isn't a JSON object can't take an id: kept as it is.
          ForeignNode() => c.copyWithId(newId()) ?? c,
          BoxRecord() =>
            forRecovery
                ? c.withId(newId())
                : markLandedIfOverlapping(c.withId(newId()), [o], mergeTime: copyTime),
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
    if (c is BoxRecord && !forRecovery) c = markLandedIfOverlapping(c, existing, mergeTime: copyTime);
    if (c is ForeignNode && _synthetic(c)) {
      // Its id came from its position or a repeat: on read-back it could take
      // over a node with the same real id, so a JSON object gets a new id.
      // Not again if an earlier merge of this copy already kept it.
      if (held.contains(c)) continue;
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

/// The form in which [c] is recorded in a box's `conflicts`: for a recovery
/// merge without its own `conflicts`, which are combined separately.
RawJson _recordedForm(CanvasNode c, bool forRecovery) =>
    forRecovery && c is BoxRecord && c.conflicts.isNotEmpty ? c.withConflicts(const []).toRaw() : c.toRaw();

(BoxRecord, bool) _mergeBox(BoxRecord o, BoxRecord c, int copyTime, bool forRecovery) {
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
    final other = BoxConflict.other(node: _recordedForm(c, forRecovery), at: copyTime);
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

/// The copy's nodes that an earlier merge of this copy already kept in
/// [original], so the next merge adds nothing for them: a node that differs
/// from the original's foreign node at its id, or has a made-up id (see
/// [_synthetic]), and that [original] holds as it is, with another id (a node
/// of a JSON object), or (a box) by revision or content.
///
/// Counted, not just looked for: a node of [original] that the copy has at the
/// same id is already accounted for, and each other node accounts for at most
/// one copy node, so a copy with more equal nodes than the original keeps the
/// rest. The set holds the nodes themselves (by identity).
Set<CanvasNode> _heldCopyNodes(NotedPage original, NotedPage copy) {
  final nodes = original.nodes;
  final copyById = {for (final n in copy.nodes) n.id: n};
  final originalIds = {for (final n in nodes) n.id};
  final claimed = <int>{
    for (var i = 0; i < nodes.length; i++)
      if (_pairedAt(nodes[i], copyById)) i,
  };
  final held = Set<CanvasNode>.identity();
  bool find(CanvasNode c) {
    for (var i = 0; i < nodes.length; i++) {
      if (claimed.contains(i)) continue;
      final n = nodes[i];
      final same = switch (c) {
        BoxRecord() => n is BoxRecord && (c.rev != null ? n.rev == c.rev : _sameContent(n, c)),
        ForeignNode() => _sameModuloId(n, c),
      };
      if (!same) continue;
      claimed.add(i);
      return true;
    }
    return false;
  }

  for (final o in nodes) {
    final c = copyById[o.id];
    if (c == null || o is BoxRecord || o.toRaw() == c.toRaw()) continue;
    if (find(c)) held.add(c);
  }
  for (final c in copy.nodes) {
    if (originalIds.contains(c.id) || c is! ForeignNode || !_synthetic(c)) continue;
    if (find(c)) held.add(c);
  }
  return held;
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
/// [forRecovery] checks the form [mergeConflictCopy] gives with the same flag.
///
/// Returns null if all is well, otherwise what is missing.
String? verifyConflictCopyMerge(
  NotedPage onDisk,
  NotedPage original,
  NotedPage copy, {
  bool forRecovery = false,
}) {
  final copyById = {for (final n in copy.nodes) n.id: n};
  final originalById = {for (final n in original.nodes) n.id: n};
  final held = _heldCopyNodes(original, copy); // need no node of their own
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
      } else if (!held.contains(c) && !take((d) => _sameModuloId(d, c))) {
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
          !held.contains(c)) {
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
    // A box on disk without a rev can only be matched by its content.
    bool isVersion(BoxRecord x) => x.rev != null && d.rev != null ? d.rev == x.rev : _sameContent(d, x);
    bool covered(BoxRecord x) =>
        isVersion(x) ||
        d.conflicts.any((k) => k.node == _recordedForm(x, forRecovery)) ||
        (x.rev != null && d.baseRev == x.rev);
    if (!isVersion(o) && !isVersion(c)) return 'box ${o.id} holds neither version';
    if (!covered(o) || !covered(c)) return 'a version of box ${o.id} was lost';
  }
  return null;
}

/// Whether [o] is accounted for by the copy's node at its id. Not for a node
/// whose id is made up from its position and whose copy differs: the match is
/// by chance, and another copy node may be its equal.
bool _pairedAt(CanvasNode o, Map<String, CanvasNode> copyById) {
  final c = copyById[o.id];
  if (c == null) return false;
  return o.toRaw() == c.toRaw() || !(o is ForeignNode && _synthetic(o));
}

// ---------------------------------------------------------------------------
// A landed page that was overwritten right after landing (0130, 0124).

/// Whether [a] and [b] are the same version of a box: both revs present and
/// equal, or a rev missing on either side and the same content.
bool _sameVersion(BoxRecord a, BoxRecord b) =>
    a.rev != null && b.rev != null ? a.rev == b.rev : _sameContent(a, b);

/// Whether [x] was edited from [m]'s version.
bool _derivedFrom(BoxRecord x, BoxRecord m) => x.rev != null && m.rev != null && x.baseRev == m.rev;

/// Whether the recorded [node] is [m]'s version (by the revision guards, not
/// by raw text).
bool _nodeIsVersion(RawJson node, BoxRecord m) {
  if (!node.isObject) return false;
  try {
    final b = BoxRecord.tryRead(RawObject.parse(node.text), node);
    return b != null && _sameVersion(b, m);
  } on FormatException {
    return false;
  }
}

/// [m]'s own recorded `conflicts` that [x] lacks, to be combined into [x]
/// without nesting: a version recorded by `node` that [x] doesn't hold and
/// isn't [x]'s own, and a `deleted` flag when [x] has none.
List<BoxConflict> _missingRecords(BoxRecord x, BoxRecord m) {
  final have = x.conflicts;
  final out = <BoxConflict>[];
  for (final c in m.conflicts) {
    if (c.deleted) {
      if (!have.any((k) => k.deleted) && !out.any((k) => k.deleted)) out.add(c);
    } else if (!have.any((k) => k.node == c.node) &&
        !_nodeIsVersion(c.node!, x) &&
        !out.any((k) => k.node == c.node)) {
      out.add(c);
    }
  }
  return out;
}

/// The records [b] holds that [mn] doesn't: those the user settled by hand.
List<BoxConflict> _settledRecords(BoxRecord b, BoxRecord mn) {
  final mine = mn.conflicts;
  return [
    for (final c in b.conflicts)
      if (c.deleted ? !mine.any((k) => k.deleted) : !mine.any((k) => k.node == c.node)) c,
  ];
}

/// [mine]'s nodes the merge kept under another id in [landed] (matched back by
/// version, or by content for a node Noted doesn't own), keyed by that id.
Map<String, CanvasNode> _reidentified(NotedPage mine, NotedPage landed) {
  final mineIds = {for (final n in mine.nodes) n.id};
  final out = <String, CanvasNode>{};
  final claimed = <String>{};
  for (final m in landed.nodes) {
    if (mineIds.contains(m.id)) continue;
    for (final k in mine.nodes) {
      if (claimed.contains(k.id)) continue;
      final at = landed.node(k.id);
      final same = switch (m) {
        BoxRecord() => k is BoxRecord && _sameVersion(k, m) && !(at is BoxRecord && _sameVersion(at, k)),
        ForeignNode() => k is ForeignNode && _sameModuloId(k, m) && at?.toRaw() != k.toRaw(),
      };
      if (!same) continue;
      claimed.add(k.id);
      out[m.id] = k;
      break;
    }
  }
  return out;
}

/// [x] with [add] recorded after what it holds; version records go before any
/// `deleted` record, as the page issues list shows the first one.
BoxRecord _withRecords(BoxRecord x, List<BoxConflict> add) {
  if (add.isEmpty) return x;
  final all = [...x.conflicts, ...add];
  return x.withConflicts([
    for (final c in all)
      if (!c.deleted) c,
    for (final c in all)
      if (c.deleted) c,
  ]);
}

/// The `conflicts` [b] holds (empty when it isn't a box).
List<BoxConflict> _heldRecords(CanvasNode? b) => b is BoxRecord ? b.conflicts : const [];

/// What replay's merge [landed] (of [base], [mine] and a file) lost when
/// another writer replaced the file right after it landed: [now] is the page
/// read back. Returns [now] with everything put right, or [now] itself when
/// nothing is lost, and whether a foreign node [mine] deleted is back (a
/// deletion holds no data, so it stays, and the caller says so).
///
/// A box [mine] changed or added: another writer's deletion of it puts it back,
/// flagged `deleted`; a version of its content that isn't derived from it
/// leaves the other writer's displayed and records it in `conflicts`; one that
/// is the same version or derived from it records nothing. A box [mine]
/// deleted that is back is flagged `deleted`. When [structure], [mine]'s bounds
/// and fixed height, the order of the nodes [mine] reordered, and the header
/// fields [mine] changed are put back the way [mergePage] resolves them. An
/// entry with no base passes `structure: false` (every box would look moved).
/// [at] is when the recorded versions were saved (ms since the epoch). Boxes
/// are compared and copied by their raw text and revisions only; no box data
/// is decoded.
({NotedPage page, bool foreignBack}) recordLostEdits(
  NotedPage base,
  NotedPage mine,
  NotedPage landed,
  NotedPage now, {
  required int at,
  bool structure = true,
}) {
  final held = _heldCopyNodes(now, landed);
  // A node the merge kept under a new id (an entry with no base, over a file
  // holding another node at its id) is still [mine]'s edit.
  final reid = structure ? const <String, CanvasNode>{} : _reidentified(mine, landed);
  final repl = <String, CanvasNode>{};
  final removed = <String>{};
  final beside = <String, List<CanvasNode>>{};
  final restore = <(int, CanvasNode)>[];
  var foreignBack = false;

  for (var i = 0; i < landed.nodes.length; i++) {
    final m = landed.nodes[i];
    final mn = mine.node(m.id) ?? reid[m.id];
    if (mn == null) continue;
    final b = base.node(mn.id);
    if (b != null && b.toRaw() == mn.toRaw()) continue; // not [mine]'s edit
    final x = now.node(m.id);
    switch (m) {
      case BoxRecord():
        if (x == null) {
          restore.add((i, m.conflicts.any((c) => c.deleted) ? m : _withRecords(m, [BoxConflict.deleted(at: at)])));
        } else if (x is BoxRecord) {
          // Records [mine] removed (the user settled the conflict) that are back:
          // a box exactly as in the base is replaced by [mine]'s; otherwise only
          // a flag removed again, a recorded version stays.
          final settled = b is BoxRecord && mn is BoxRecord ? _settledRecords(b, mn) : const <BoxConflict>[];
          var xx = x;
          // A flag counts as back only if it is the settled one itself: a newer
          // deletion by another writer stands.
          bool isSettled(BoxConflict c) => settled.any((s) => s.deleted ? c == s : c.node == s.node);
          if (settled.isNotEmpty && x.conflicts.any(isSettled)) {
            if (x.toRaw() == b!.toRaw()) {
              repl[m.id] = m;
              continue;
            }
            if (settled.any((s) => s.deleted)) {
              xx = x.withConflicts([for (final c in x.conflicts) if (!(c.deleted && isSettled(c))) c]);
            }
          }
          final add = <BoxConflict>[];
          final contentChanged = b is! BoxRecord || mn is! BoxRecord || !_sameVersion(b, mn);
          if (contentChanged && !_sameVersion(xx, m) && !_derivedFrom(xx, m)) {
            final node = m.withoutConflicts().toRaw();
            if (!xx.conflicts.any((c) => c.node == node)) {
              add.add(BoxConflict.other(node: node, at: at, device: m.device));
            }
          }
          add.addAll(_missingRecords(xx, m));
          var r = _withRecords(xx, add);
          if (structure && mn is BoxRecord) {
            final bb = b is BoxRecord ? b : null;
            if (bb == null || mn.bounds != bb.bounds) r = r.withBounds(m.bounds);
            if (bb == null || mn.fixedHeight != bb.fixedHeight) r = r.withFixedHeight(m.fixedHeight);
          }
          if (!identical(r, x)) repl[m.id] = r;
        } else if (!held.contains(m)) {
          beside[m.id] = [m.withId(newId())]; // kept beside the foreign node
        }
      case ForeignNode():
        if (x == null) {
          restore.add((i, m));
        } else if (x is ForeignNode) {
          if (x.toRaw() != m.toRaw() && !held.contains(m)) beside[m.id] = [m.copyWithId(newId()) ?? m];
        } else if (x is BoxRecord) {
          final node = m.toRaw();
          if (!x.conflicts.any((c) => c.node == node)) {
            repl[m.id] = _withRecords(x, [BoxConflict.other(node: node, at: at)]);
          }
        }
    }
  }

  for (final b in base.nodes) {
    if (mine.node(b.id) != null) continue; // [mine] didn't delete it
    final x = repl[b.id] ?? now.node(b.id);
    if (b is BoxRecord && x is BoxRecord) {
      if (b.conflicts.isNotEmpty && x.toRaw() == b.toRaw()) {
        removed.add(b.id); // "Delete it" of a conflicted box, undone as it was: deleted again
      } else if (!x.conflicts.any((c) => c.deleted)) {
        repl[b.id] = _withRecords(x, [BoxConflict.deleted(at: at)]);
      }
    } else if (b is ForeignNode && x is ForeignNode && x.toRaw() == b.toRaw()) {
      foreignBack = true;
    }
  }

  final out = <CanvasNode>[];
  for (final n in now.nodes) {
    if (removed.contains(n.id)) continue;
    out.add(repl[n.id] ?? n);
    out.addAll(beside[n.id] ?? const []);
  }
  for (final (i, r) in restore) {
    var pos = 0;
    for (var j = i - 1; j >= 0; j--) {
      final k = out.indexWhere((n) => n.id == landed.nodes[j].id);
      if (k >= 0) {
        pos = k + 1;
        break;
      }
    }
    out.insert(pos, r);
  }
  var changed = repl.isNotEmpty || removed.isNotEmpty || beside.isNotEmpty || restore.isNotEmpty;

  var top = now.top;
  var meta = now.meta;
  if (structure) {
    // Order: [landed]'s order of the nodes all four pages share, when [mine]
    // reordered them (mergePage: theirs if only theirs reordered, else mine).
    final inOut = {for (final n in out) n.id};
    final inLanded = {for (final n in landed.nodes) n.id};
    final inMine = {for (final n in mine.nodes) n.id};
    final common = {
      for (final n in base.nodes)
        if (inMine.contains(n.id) && inLanded.contains(n.id) && inOut.contains(n.id)) n.id,
    };
    List<String> only(Iterable<CanvasNode> nodes) => [
      for (final n in nodes)
        if (common.contains(n.id)) n.id,
    ];
    final wanted = only(landed.nodes);
    if (!sameIds(only(mine.nodes), only(base.nodes)) &&
        only(out).length == common.length &&
        !sameIds(only(out), wanted)) {
      reorderLike(out, common, wanted);
      changed = true;
    }

    // Header and other top-level fields: [mine]'s where it changed them.
    RawObject lost(RawObject b, RawObject m, RawObject n, Set<String> skip) {
      final merged = mergeFields(b, m, n, skip: skip);
      var next = n;
      for (final k in {
        for (final (k, _) in merged.entries) k,
        for (final (k, _) in n.entries) k,
      }) {
        if (skip.contains(k) || merged[k] == n[k]) continue;
        final v = merged[k];
        next = v == null ? next.remove(k) : next.set(k, v);
      }
      return next;
    }

    final nextTop = lost(base.top, mine.top, now.top, const {'nodes', 'noted'});
    if (!identical(nextTop, now.top)) {
      top = nextTop;
      changed = true;
    }
    final nextFields = lost(base.meta.fields, mine.meta.fields, now.meta.fields, const {'pageId', 'format'});
    if (!identical(nextFields, now.meta.fields)) {
      final m = PageMeta.tryRead(nextFields);
      if (m != null) {
        meta = m;
        changed = true;
      }
    }
  }

  if (!changed) return (page: now, foreignBack: foreignBack);
  return (page: NotedPage.fromParts(top, meta, out), foreignBack: foreignBack);
}

/// The [mine] that replay merges into [theirs], with what the file learned
/// since [base] taken as it is, so that a repeat replay over a conflicted file
/// leaves it as it is (the other writer displayed with [mine] recorded, or
/// [mine] displayed with theirs recorded). "Learned" is a record of
/// `theirs`'s box that `base`'s box doesn't hold, by `node` (a `deleted` flag
/// by kind). A record [base] already held and [mine] lacks is one the user
/// settled offline, so it matches nothing.
///
/// A box of [mine] is replaced by `theirs`'s when a learned record's node is
/// its version, or `theirs`'s box is its version and learned any record (a
/// `deleted` flag included). A learned `deleted` flag on an unrelated version
/// matches nothing. The replacement keeps [mine]'s recorded `conflicts` it
/// lacks (without nesting) and [mine]'s bounds and fixed height where [mine]
/// changed them. A box [mine] removed that `theirs` holds flagged `deleted`
/// (learned) is put in, and a foreign node of [mine] that `theirs` already
/// holds beside its place isn't kept a second time. Returns [mine] itself when
/// nothing matches. Not for an entry without a base: every record would count
/// as learned.
NotedPage settledInFile(NotedPage base, NotedPage mine, NotedPage theirs) {
  final held = _heldCopyNodes(theirs, mine);
  final repl = <String, CanvasNode>{};
  for (final m in mine.nodes) {
    final t = theirs.node(m.id);
    if (t == null) continue;
    if (held.contains(m)) {
      repl[m.id] = t;
      continue;
    }
    if (m is! BoxRecord || t is! BoxRecord) continue;
    final b = base.node(m.id);
    final had = _heldRecords(b);
    final learned = [
      for (final c in t.conflicts)
        if (!had.any((k) => c.deleted ? k.deleted : k.node == c.node)) c,
    ];
    if (learned.isEmpty) continue;
    final match = _sameVersion(t, m) || learned.any((c) => !c.deleted && _nodeIsVersion(c.node!, m));
    if (!match) continue;
    var r = _withRecords(t, _missingRecords(t, m));
    final bb = b is BoxRecord ? b : null;
    if (bb == null || m.bounds != bb.bounds) r = r.withBounds(m.bounds);
    if (bb == null || m.fixedHeight != bb.fixedHeight) r = r.withFixedHeight(m.fixedHeight);
    repl[m.id] = r;
  }

  final out = [for (final n in mine.nodes) repl[n.id] ?? n];
  var added = false;
  for (final b in base.nodes) {
    if (mine.node(b.id) != null) continue;
    final t = theirs.node(b.id);
    if (t is! BoxRecord || b is! BoxRecord) continue;
    if (!t.conflicts.any((c) => c.deleted) || b.conflicts.any((c) => c.deleted)) continue;
    final i = theirs.indexOf(t.id);
    var pos = 0;
    for (var j = i - 1; j >= 0; j--) {
      final k = out.indexWhere((n) => n.id == theirs.nodes[j].id);
      if (k >= 0) {
        pos = k + 1;
        break;
      }
    }
    out.insert(pos, t);
    added = true;
  }
  if (repl.isEmpty && !added) return mine;
  return NotedPage.fromParts(mine.top, mine.meta, out);
}
