// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pure Dart, like the codec.

/// The "only added on both sides" merge of a note box (and of an AI box,
/// which stores a note document), for `BoxCodec.merge` (0020, 0051).
///
/// [base], [mine] and [theirs] are the stored data of the box
/// (`{"document": {"type": "page", "children": [...]}}`, plus any other
/// top-level keys, such as an AI box's `owner`). Returns the merged data, or
/// null when the merge is not provably "only added": the caller then reports
/// `Conflicted` and the user chooses. When in doubt this returns null.
///
/// What counts as "only added" for one side, relative to [base]. Blocks are
/// the document root's `children`, compared as whole JSON values:
///
/// 1. Every base block is still there, unchanged, in the same order. The side
///    may have inserted any blocks anywhere between them, before the first
///    and after the last (an insert position is a gap between two base
///    blocks, so "different positions" are different gaps).
/// 2. As the one exception, the base's first block may have had text added at
///    its start (a prepend), or its last block text added at its end (an
///    append). Only text runs are added: the block's type, children, every
///    key of its `data` other than `delta`, and every base run (a run's
///    attributes included) are unchanged. Typing at the end of a run that
///    has the same attributes lengthens that run; that is still an append.
///    A block of one side may be extended at one end only, not both.
/// 3. A trailing empty paragraph (no text, no children, no attributes: the
///    blank line a new box starts with, and the one a closed-app AI append
///    drops, `applyAiWrite`) is ignored for the comparison and put back
///    afterwards: it stays if both sides have it or if the base had none and
///    either side added one; it goes if the base had it and either side
///    dropped it.
///
/// Anything else is a change: an edited, deleted, reordered or re-typed base
/// block, changed attributes or block data, text added in the middle, a
/// different root, or another top-level key changed on both sides.
///
/// Merging, where both sides added: at the same gap, mine's blocks go first
/// then theirs. If both sides added exactly the same blocks at a gap, or
/// exactly the same runs at the same end of a block, that is kept once (both
/// sides made the same addition). Both sides adding different text at the
/// same end of the same block is a conflict (the order would be a guess);
/// text at different ends of a block merges (prepended runs, base text,
/// appended runs). A run that grew at the seam with the base text joins it
/// when both are plain `{insert, attributes?}` runs with equal attributes;
/// no other runs are joined or rewritten.
/// Blocks are never rewritten, so an AI box's `noted_ai` marks on blocks an
/// AI added stay on them, and a mark on an extended block keeps its old
/// fingerprint (so it stops counting, as for any edit of that block).
Map<String, Object?>? mergeNoteJson(
  Map<String, Object?> base,
  Map<String, Object?> mine,
  Map<String, Object?> theirs,
) {
  // Other top-level keys: a side that changed one wins over one that didn't.
  final result = <String, Object?>{...mine};
  for (final k in {...base.keys, ...mine.keys, ...theirs.keys}) {
    if (k == 'document') continue;
    final b = base[k], m = mine[k], t = theirs[k];
    if (_eq(m, t) || _eq(t, b)) continue;
    if (!_eq(m, b)) return null;
    if (theirs.containsKey(k)) {
      result[k] = t;
    } else {
      result.remove(k);
    }
  }

  final bd = _root(base), md = _root(mine), td = _root(theirs);
  if (bd == null || md == null || td == null) return null;
  // The root's own type and data, and any other key, must agree.
  for (final k in {...bd.keys, ...md.keys, ...td.keys}) {
    if (k == 'children') continue;
    if (!_eq(bd[k], md[k]) || !_eq(bd[k], td[k])) return null;
  }

  final bAll = _children(bd), mAll = _children(md), tAll = _children(td);
  if (bAll == null || mAll == null || tAll == null) return null;

  // A base that is only a blank paragraph is a block like any other: text
  // typed into it on both sides is two edits of one block.
  final strip = bAll.length > 1;
  final bHad = strip && _endsBlank(bAll);
  final mHad = strip && _endsBlank(mAll);
  final tHad = strip && _endsBlank(tAll);
  final b = strip ? _stripBlank(bAll) : bAll;
  final m = strip ? _stripBlank(mAll) : mAll;
  final t = strip ? _stripBlank(tAll) : tAll;

  final ms = _Side.parse(b, m);
  final ts = _Side.parse(b, t);
  if (ms == null || ts == null) return null;

  final merged = <Object?>[];
  for (var p = 0; p <= b.length; p++) {
    final gm = ms.gaps[p], gt = ts.gaps[p];
    if (gm.isEmpty) {
      merged.addAll(gt);
    } else if (gt.isEmpty || _eq(gm, gt)) {
      merged.addAll(gm);
    } else {
      merged
        ..addAll(gm)
        ..addAll(gt);
    }
    if (p == b.length) break;
    final em = ms.ext[p], et = ts.ext[p];
    // Both extended the same end of the block with different text: the
    // order is a guess ("Total: 507", "Meeting at 3Call Bob"), so ask.
    if (em != null && et != null && em.atEnd == et.atEnd && !_eq(em.ops, et.ops)) {
      return null;
    }
    merged.add(em == null && et == null ? b[p] : _extend(b[p], em, et));
  }

  if (bHad ? (mHad && tHad) : (mHad || tHad)) {
    merged.add(
      mHad
          ? mAll.last
          : tHad
          ? tAll.last
          : bAll.last,
    );
  }
  if (merged.isEmpty) merged.add(_blankParagraph());

  result['document'] = {...md, 'children': merged};
  return result;
}

Map<String, Object?> _blankParagraph() => {
  'type': 'paragraph',
  'data': {'delta': <Object?>[]},
};

Map<String, Object?>? _root(Map<String, Object?> json) {
  final d = json['document'];
  if (d is! Map) return null;
  return {for (final e in d.entries) e.key.toString(): e.value};
}

List<Object?>? _children(Map<String, Object?> root) {
  final c = root['children'];
  return c is List ? c.cast<Object?>() : null;
}

/// A paragraph with no text, no children and nothing in `data` but a `delta`
/// of empty runs.
bool _isBlank(Object? block) {
  if (block is! Map) return false;
  if (block['type'] != 'paragraph') return false;
  if (block.keys.any((k) => k != 'type' && k != 'data' && k != 'children')) {
    return false;
  }
  final kids = block['children'];
  if (kids != null && !(kids is List && kids.isEmpty)) return false;
  final data = block['data'];
  if (data is! Map) return false;
  if (data.keys.any((k) => k != 'delta')) return false;
  final delta = data['delta'];
  if (delta is! List) return false;
  for (final op in delta) {
    if (op is! Map) return false;
    final text = op['insert'];
    if (text is! String || text.isNotEmpty) return false;
    final a = op['attributes'];
    if (a is Map && a.isNotEmpty) return false;
  }
  return true;
}

bool _endsBlank(List<Object?> blocks) =>
    blocks.isNotEmpty && _isBlank(blocks.last);

List<Object?> _stripBlank(List<Object?> blocks) =>
    _endsBlank(blocks) ? blocks.sublist(0, blocks.length - 1) : blocks;

/// How one side relates to the base blocks: what it inserted in each gap
/// (`gaps[p]` goes before base block `p`; `gaps[base.length]` at the end) and
/// the text it added to the first or last base block.
final class _Side {
  _Side(this.gaps, this.ext);

  final List<List<Object?>> gaps;

  /// By base block index.
  final Map<int, _Ext> ext;

  /// Null if [side] is not [base] with only additions (see [mergeNoteJson]).
  static _Side? parse(List<Object?> base, List<Object?> side) {
    final gaps = <List<Object?>>[];
    final ext = <int, _Ext>{};
    var i = 0;
    for (var p = 0; p < base.length; p++) {
      // The base block itself, unchanged: the first equal block from here.
      var j = -1;
      for (var k = i; k < side.length; k++) {
        if (_eq(side[k], base[p])) {
          j = k;
          break;
        }
      }
      if (j >= 0) {
        gaps.add(side.sublist(i, j));
        i = j + 1;
        continue;
      }
      // Else the first and the last base block may have grown.
      _Ext? found;
      var at = -1;
      for (var k = i; k < side.length && found == null; k++) {
        if (p == base.length - 1) {
          found = _Ext.of(base[p], side[k], atEnd: true);
        }
        if (found == null && p == 0) {
          found = _Ext.of(base[p], side[k], atEnd: false);
        }
        if (found != null) at = k;
      }
      if (found == null) return null;
      gaps.add(side.sublist(i, at));
      ext[p] = found;
      i = at + 1;
    }
    gaps.add(side.sublist(i));
    return _Side(gaps, ext);
  }
}

/// Runs added to one end of a block's `delta`.
final class _Ext {
  _Ext(this.ops, {required this.atEnd});

  final List<Object?> ops;
  final bool atEnd;

  /// What [side] added at one end of [base]'s text, or null if it did
  /// anything else to the block.
  static _Ext? of(Object? base, Object? side, {required bool atEnd}) {
    if (base is! Map || side is! Map) return null;
    final bData = base['data'], sData = side['data'];
    if (bData is! Map || sData is! Map) return null;
    for (final k in {...base.keys, ...side.keys}) {
      if (k != 'data' && !_eq(base[k], side[k])) return null;
    }
    for (final k in {...bData.keys, ...sData.keys}) {
      if (k != 'delta' && !_eq(bData[k], sData[k])) return null;
    }
    final bo = bData['delta'], so = sData['delta'];
    if (bo is! List || so is! List) return null;
    final extra = _extra(bo.cast<Object?>(), so.cast<Object?>(), atEnd);
    if (extra == null || extra.isEmpty) return null;
    for (final op in extra) {
      if (op is! Map || op['insert'] is! String) return null;
    }
    return _Ext(extra, atEnd: atEnd);
  }
}

/// The runs [s] adds at the end (or start) of [bo], or null.
List<Object?>? _extra(List<Object?> bo, List<Object?> s, bool atEnd) {
  if (bo.isEmpty) return List.of(s);
  final k = bo.length;
  if (s.length < k) return null;
  final off = atEnd ? 0 : s.length - k;
  // The base runs are all there, then (or before) the added ones.
  if (_eq(s.sublist(off, off + k), bo)) {
    return atEnd ? s.sublist(k) : s.sublist(0, off);
  }
  // The run at the joint grew: same attributes, longer text.
  final ji = atEnd ? k - 1 : 0;
  for (var n = 0; n < k; n++) {
    if (n != ji && !_eq(s[off + n], bo[n])) return null;
  }
  final b = bo[ji], o = s[off + ji];
  if (b is! Map || o is! Map) return null;
  final bt = b['insert'], ot = o['insert'];
  if (bt is! String || ot is! String || ot.length <= bt.length) return null;
  if (!_plain(b) || !_plain(o)) return null;
  if (!_joinable(b) || !_eq(_attrs(b), _attrs(o))) return null;
  final grew = atEnd ? ot.startsWith(bt) : ot.endsWith(bt);
  if (!grew) return null;
  final rest = atEnd
      ? ot.substring(bt.length)
      : ot.substring(0, ot.length - bt.length);
  final run = <String, Object?>{'insert': rest, 'attributes': ?_attrs(o)};
  return atEnd
      ? [run, ...s.sublist(k)]
      : [...s.sublist(0, s.length - k), run];
}

Map<Object?, Object?>? _attrs(Map<Object?, Object?> op) {
  final a = op['attributes'];
  return a is Map && a.isNotEmpty ? a : null;
}

/// Whether [op]'s text may be joined with a neighbour: not an inline
/// equation (U+FFFC, or a formula attribute).
bool _joinable(Map<Object?, Object?> op) {
  final t = op['insert'];
  if (t is! String || t.contains('￼')) return false;
  final a = op['attributes'];
  return !(a is Map && a.containsKey('formula'));
}

/// [base] with the runs [mine] and [theirs] added (null for none).
Map<String, Object?> _extend(Object? base, _Ext? mine, _Ext? theirs) {
  final block = base! as Map;
  final data = block['data']! as Map;
  final delta = (data['delta']! as List).cast<Object?>();
  List<Object?> add(bool atEnd) {
    final x = (mine != null && mine.atEnd == atEnd) ? mine.ops : <Object?>[];
    final y = (theirs != null && theirs.atEnd == atEnd)
        ? theirs.ops
        : <Object?>[];
    return _eq(x, y) ? x : [...x, ...y];
  }

  final pre = add(false), post = add(true);
  final runs = <Object?>[...pre, ...delta, ...post];
  // Join only at the two seams between base runs and added runs.
  if (post.isNotEmpty && delta.isNotEmpty) {
    _joinAt(runs, pre.length + delta.length - 1);
  }
  if (pre.isNotEmpty && delta.isNotEmpty) _joinAt(runs, pre.length - 1);
  return {
    for (final e in block.entries) e.key.toString(): e.value,
    'data': {
      for (final e in data.entries) e.key.toString(): e.value,
      'delta': runs,
    },
  };
}

/// Joins `runs[i]` and `runs[i + 1]` into one run when both are exactly
/// `{insert, attributes?}` with equal attributes and plain text; otherwise
/// leaves them as they are (no unknown key or odd attribute is dropped).
void _joinAt(List<Object?> runs, int i) {
  final a = runs[i], b = runs[i + 1];
  if (a is! Map || b is! Map || !_plain(a) || !_plain(b)) return;
  if (!_joinable(a) || !_joinable(b) || !_eq(_attrs(a), _attrs(b))) return;
  runs[i] = <String, Object?>{
    'insert': '${a['insert']}${b['insert']}',
    'attributes': ?_attrs(a),
  };
  runs.removeAt(i + 1);
}

bool _plain(Map<Object?, Object?> op) =>
    op.keys.every((k) => k == 'insert' || k == 'attributes') &&
    (op['attributes'] == null || op['attributes'] is Map);

/// Deep equality of JSON values (maps by key, whatever their order).
bool _eq(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || !_eq(e.value, b[e.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_eq(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
