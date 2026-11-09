// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The field and order rules of the page merge, shared by [mergePage] and by the
// replay of a landed page (recordLostEdits). Not exported.

import '../json/raw_json.dart';
import '../model/page.dart';

/// Per field: theirs if mine is unchanged from base, else mine.
RawObject mergeFields(
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

PageMeta mergeMeta(PageMeta base, PageMeta mine, PageMeta theirs) {
  final fields = mergeFields(
    base.fields,
    mine.fields,
    theirs.fields,
    skip: const {'pageId', 'format'},
  );
  if (identical(fields, mine.fields)) return mine;
  return PageMeta.tryRead(fields) ?? mine;
}

RawObject mergeTop(RawObject base, RawObject mine, RawObject theirs) =>
    mergeFields(base, mine, theirs, skip: const {'nodes', 'noted'});

/// Whether [a] and [b] hold the same fields, whatever their order.
bool sameFields(RawObject a, RawObject b) {
  final keys = <String>{
    for (final (k, _) in a.entries) k,
    for (final (k, _) in b.entries) k,
  };
  return keys.every((k) => a[k] == b[k]);
}

bool sameIds(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Puts the nodes of [out] whose ids are in [common] in the order [order]
/// (the ids of [common], in the wanted order). Each node that isn't common
/// follows the nearest common node before it in [out] (its anchor) and moves
/// with it; nodes before the first common node stay first. The nodes after the
/// last common node (the newest boxes, on top) stay last, after every common
/// node (0132).
void reorderLike(List<CanvasNode> out, Set<String> common, List<String> order) {
  final byId = {for (final n in out) n.id: n};
  final atStart = <CanvasNode>[];
  final after = <String, List<CanvasNode>>{};
  String? anchor;
  for (final n in out) {
    if (common.contains(n.id)) {
      anchor = n.id;
    } else if (anchor == null) {
      atStart.add(n);
    } else {
      (after[anchor] ??= []).add(n);
    }
  }
  final last = anchor;
  out
    ..clear()
    ..addAll(atStart);
  for (final id in order) {
    out.add(byId[id]!);
    if (id != last) out.addAll(after[id] ?? const []);
  }
  if (last != null) out.addAll(after[last] ?? const []);
}
