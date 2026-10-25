// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../box_api/box_codec.dart';
import '../box_api/codec_registry.dart';
import '../json/raw_json.dart';
import '../model/ids.dart';
import '../model/page.dart';

/// The outcome of [mergePage].
final class PageMerge {
  const PageMerge(this.page, this.conflictedIds);

  /// The merged page.
  final NotedPage page;

  /// Boxes that this merge marked conflicted (0020): their other version is
  /// recorded in the box's `conflicts`.
  final Set<String> conflictedIds;
}

/// Three-way merge of a page that changed on disk while it was open (0020).
///
/// [base] is the page as last read from or written to disk by this app,
/// [mine] the page in memory and [theirs] the new file; [theirsTime] is when
/// [theirs] was saved (ms since the epoch). Per node:
///
/// - Content (data, version, snapshot, `rev`): the side that changed wins; if
///   both changed, the box's codec merges them when this device can run it,
///   otherwise the box is conflicted: mine is kept and the other version is
///   recorded in its `conflicts`.
/// - Geometry and fixed height: last write wins. Theirs is taken when mine is
///   unchanged; if both changed, mine is kept (the next save is the later
///   write).
/// - Added on one side: kept. Removed on one side: removed if the other side
///   is unchanged, otherwise the changed box is kept and flagged `deleted`.
/// - Page header and other top-level fields: per field, theirs if mine is
///   unchanged, else mine.
///
/// Nodes this device can't run, and nodes Noted doesn't own, are never
/// decoded. Anything that ends up unchanged is the original node, so it is
/// written back verbatim.
PageMerge mergePage(
  NotedPage base,
  NotedPage mine,
  NotedPage theirs,
  CodecRegistry codecs, {
  required int theirsTime,
}) {
  final baseById = {for (final n in base.nodes) n.id: n};
  final theirsById = {for (final n in theirs.nodes) n.id: n};
  final mineIds = {for (final n in mine.nodes) n.id};
  final conflicted = <String>{};
  final out = <CanvasNode>[];

  for (final m in mine.nodes) {
    final b = baseById[m.id];
    final t = theirsById[m.id];
    if (t == null) {
      if (b == null) {
        out.add(m); // added here
        continue;
      }
      if (_same(b, m)) continue; // removed there, unchanged here
      if (m is BoxRecord) {
        out.add(m.withConflict(BoxConflict.deleted(at: theirsTime)));
        conflicted.add(m.id);
      } else {
        out.add(m);
      }
      continue;
    }
    if (m is BoxRecord && t is BoxRecord && (b == null || b is BoxRecord)) {
      final (node, isConflict) = _mergeBox(b as BoxRecord?, m, t, codecs, theirsTime);
      out.add(node);
      if (isConflict) conflicted.add(m.id);
      continue;
    }
    // Nodes that can't be compared by revision: compare the text.
    if (_same(m, t) || (b != null && _same(b, t))) {
      out.add(m);
    } else if (b != null && _same(b, m)) {
      out.add(t);
    } else if (m is BoxRecord) {
      out.add(m.withConflict(BoxConflict.other(node: t.toRaw(), at: theirsTime)));
      conflicted.add(m.id);
    } else {
      // Both changed a node Noted doesn't own: keep mine and keep theirs as
      // a copy beside it, so nothing is lost.
      out.add(m);
      final copy = t is ForeignNode ? t.copyWithId(newId()) : null;
      if (copy != null) out.add(copy);
    }
  }

  // Nodes only theirs has: new there, or removed here.
  for (var i = 0; i < theirs.nodes.length; i++) {
    final t = theirs.nodes[i];
    if (mineIds.contains(t.id)) continue;
    final b = baseById[t.id];
    CanvasNode add = t;
    if (b != null) {
      if (_same(b, t)) continue; // removed here, unchanged there
      if (t is BoxRecord) {
        add = t.withConflict(BoxConflict.deleted(at: theirsTime));
        conflicted.add(t.id);
      }
    }
    var at = 0;
    for (var j = i - 1; j >= 0; j--) {
      final k = out.indexWhere((n) => n.id == theirs.nodes[j].id);
      if (k >= 0) {
        at = k + 1;
        break;
      }
    }
    out.insert(at, add);
  }

  final merged = NotedPage.fromParts(
    _mergeTop(base.top, mine.top, theirs.top),
    _mergeMeta(base.meta, mine.meta, theirs.meta),
    out,
  );
  return PageMerge(merged, conflicted);
}

bool _same(CanvasNode a, CanvasNode b) => a.toRaw() == b.toRaw();

(CanvasNode, bool) _mergeBox(
  BoxRecord? b,
  BoxRecord m,
  BoxRecord t,
  CodecRegistry codecs,
  int theirsTime,
) {
  if (m.toRaw() == t.toRaw()) return (m, false);

  bool contentDiffers(BoxRecord x, BoxRecord y) {
    if (x.rev != y.rev) return true;
    if (x.rev != null) return false;
    return x.typeId != y.typeId ||
        x.dataVersion != y.dataVersion ||
        x.data != y.data ||
        x.snapshotText != y.snapshotText;
  }

  final mineChanged = b == null ? contentDiffers(m, t) : contentDiffers(m, b);
  final theirsChanged = b == null ? mineChanged : contentDiffers(t, b);

  BoxRecord r;
  var isConflict = false;
  if (!theirsChanged) {
    r = m;
  } else if (!mineChanged) {
    r = t;
  } else {
    final merged = _mergeContent(b, m, t, codecs);
    if (merged != null) {
      r = merged;
    } else {
      r = m;
      isConflict = true;
    }
  }

  // Geometry and fixed height: last write wins.
  final bb = b?.bounds;
  r = r.withBounds(bb != null && m.bounds == bb ? t.bounds : m.bounds);
  r = r.withFixedHeight(b != null && m.fixedHeight == b.fixedHeight ? t.fixedHeight : m.fixedHeight);

  // The conflicts field is core-owned: a three-way choice like the rest.
  final mc = m.conflicts;
  final tc = t.conflicts;
  final bc = b?.conflicts ?? const <BoxConflict>[];
  final List<BoxConflict> want;
  if (_sameList(mc, bc)) {
    want = tc;
  } else if (_sameList(tc, bc)) {
    want = mc;
  } else {
    want = [
      ...mc,
      for (final c in tc)
        if (!mc.contains(c)) c,
    ];
  }
  if (!_sameList(want, r.conflicts)) r = r.withConflicts(want);

  if (isConflict) {
    final other = BoxConflict.other(node: t.toRaw(), at: theirsTime);
    if (!r.conflicts.any((c) => c.node == other.node)) r = r.withConflict(other);
  }
  return (r, isConflict);
}

bool _sameList(List<BoxConflict> a, List<BoxConflict> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Merges the content of a box both sides changed, through its codec; null
/// if this device can't or the codec reports a conflict.
BoxRecord? _mergeContent(BoxRecord? b, BoxRecord m, BoxRecord t, CodecRegistry codecs) {
  if (b == null || b.typeId != m.typeId || t.typeId != m.typeId) return null;
  final codec = codecs.codecFor(m.typeId);
  if (codec == null) return null;
  final rb = codecs.resolve(b);
  final rm = codecs.resolve(m);
  final rt = codecs.resolve(t);
  if (rb is! LiveBox || rm is! LiveBox || rt is! LiveBox) return null;
  try {
    final result = codec.merge(rb.data, rm.data, rt.data);
    if (result is Merged<Object?>) return commitBox(m, codec, result.data);
  } on Object {
    return null;
  }
  return null;
}

/// Per field: theirs if mine is unchanged from base, else mine.
RawObject _mergeFields(
  RawObject base,
  RawObject mine,
  RawObject theirs, {
  Set<String> skip = const {},
}) {
  var out = mine;
  final keys = <String>{
    for (final (k, _) in theirs.entries) k,
    for (final (k, _) in base.entries) k,
  };
  for (final k in keys) {
    if (skip.contains(k)) continue;
    if (mine[k] != base[k]) continue; // mine changed: keep mine
    final tv = theirs[k];
    if (tv == mine[k]) continue;
    out = tv == null ? out.remove(k) : out.set(k, tv);
  }
  return out;
}

PageMeta _mergeMeta(PageMeta base, PageMeta mine, PageMeta theirs) {
  final fields = _mergeFields(
    base.fields,
    mine.fields,
    theirs.fields,
    skip: const {'pageId', 'format'},
  );
  if (identical(fields, mine.fields)) return mine;
  return PageMeta.tryRead(fields) ?? mine;
}

RawObject _mergeTop(RawObject base, RawObject mine, RawObject theirs) =>
    _mergeFields(base, mine, theirs, skip: const {'nodes', 'noted'});
