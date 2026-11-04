// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:math';

import 'package:noted_core/noted_core.dart';

// Seeded generators and a comparison for the merge property tests.
//
// Pages are built as page-file text, so they hold what a real file can:
// boxes of two test types, foreign nodes (with an id, without one, and not
// objects at all), a box whose `noted` field is broken, and repeated ids.

/// `test.plain` has no merge (both sides changed: a conflict).
class PlainCodec extends BoxCodec<Object?> {
  const PlainCodec();
  @override
  String get typeId => 'test.plain';
  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.fixed;
  @override
  Object? create() => '';
  @override
  Object? decode(Object? json, int storedVersion) => json;
  @override
  Object? encode(Object? data) => data;
  @override
  String snapshotText(Object? data) => 'snap:${jsonEncode(data)}';
  @override
  AiExposure aiExposure(Object? data) => AiText(jsonEncode(data));
}

/// `test.set` models the drawing box (0041): items merge as a union and the
/// local `origin` is kept.
class SetCodec extends PlainCodec {
  const SetCodec();
  @override
  String get typeId => 'test.set';
  @override
  String snapshotText(Object? data) => 'snap:${jsonEncode((data! as Map)['items'])}'; // not the origin
  @override
  MergeResult<Object?> merge(Object? base, Object? mine, Object? theirs) {
    final m = mine! as Map<String, Object?>;
    final t = theirs! as Map<String, Object?>;
    final items = {...(m['items']! as List), ...(t['items']! as List)}.toList()
      ..sort((a, b) => '$a'.compareTo('$b'));
    return Merged({'origin': m['origin'], 'items': items});
  }
}

CodecRegistry propertyRegistry() => CodecRegistry()
  ..register(const PlainCodec())
  ..register(const SetCodec());

NotedPage pageFrom(List<String> nodes, {String title = 'T', int order = 0}) => readPage(
  '{"nodes":[${nodes.join(',')}],'
  '"noted":{"format":1,"pageId":"p","parentId":null,"title":"$title","order":$order}}',
);

/// The id a node text carries, if it is an object with an `id`.
String? idOfText(String text) => RegExp(r'^\{"id":"([^"]+)"').firstMatch(text)?.group(1);

bool isBoxText(String text) => text.contains('"noted":{"type"');

/// A seeded generator of pages and of edits to them.
class PageGen {
  PageGen(int seed) : r = Random(seed);

  final Random r;
  int _tok = 0;

  /// A revision or data token; never 16 hex digits, so it can't be mistaken
  /// for an id the merge generated.
  String tok() => 'k${++_tok}';

  bool chance(int n, int of) => r.nextInt(of) < n;

  /// A box. By default it sits in one of three columns, so boxes often
  /// overlap; pass [x] to place it.
  String box(
    String id, {
    String? type,
    String? rev,
    String? baseRev,
    Object? data,
    int? x,
    int y = 0,
    bool? fixedHeight,
  }) {
    type ??= r.nextBool() ? 'test.plain' : 'test.set';
    data ??= type == 'test.set'
        ? {
            'origin': [r.nextInt(5), r.nextInt(5)],
            'items': [tok()],
          }
        : tok();
    final snap = 'snap:${jsonEncode(type == 'test.set' ? (data as Map)['items'] : data)}';
    final fixed = (fixedHeight ?? chance(1, 4)) ? ',"fixedHeight":true' : '';
    return '{"id":"$id","type":"text","x":${x ?? r.nextInt(3) * 60},"y":$y,'
        '"width":100,"height":50,"text":${jsonEncode(snap)}$fixed,'
        '"noted":{"type":"$type","v":1,"rev":"${rev ?? tok()}"'
        '${baseRev == null ? '' : ',"baseRev":"$baseRev"'},"data":${jsonEncode(data)}}}';
  }

  /// A node Noted doesn't own, or a broken box: with an id. [anonymous]
  /// also allows a node without an id (the reader makes one up from its
  /// position) and a node that isn't an object.
  String foreign(String id, {bool anonymous = false}) {
    switch (r.nextInt(anonymous ? 4 : 2)) {
      case 0:
        return '{"id":"$id","type":"text","x":0,"y":0,"width":50,"height":50,"text":"${tok()}"}';
      case 1:
        return '{"id":"$id","noted":{"broken":true},"x":0,"y":0,"width":50,"height":50,"t":"${tok()}"}';
      case 2:
        return '{"t":"${tok()}"}';
      default:
        return '${++_tok}';
    }
  }

  /// The node texts of a page. An id repeats now and then.
  List<String> nodes({int max = 6, bool foreignNodes = true}) {
    final out = <String>[];
    final n = r.nextInt(max + 1);
    for (var i = 0; i < n; i++) {
      final id = out.isNotEmpty && chance(1, 12) ? 'n${r.nextInt(i)}' : 'n$i';
      out.add(foreignNodes && chance(1, 4) ? foreign(id, anonymous: true) : box(id));
    }
    return out;
  }

  /// [text] with new content on top of its revision (a box), or another
  /// foreign node.
  String editContent(String text) {
    final id = idOfText(text);
    final m = RegExp(r'"noted":\{"type":"([^"]+)","v":1,"rev":"([^"]+)"').firstMatch(text);
    if (id == null || m == null) return text;
    final data = jsonDecode(RegExp(r'"data":(.*)\}\}$').firstMatch(text)!.group(1)!);
    final next = m.group(1) == 'test.set'
        ? {
            'origin': [r.nextInt(5), r.nextInt(5)],
            'items': [...(data as Map)['items'] as List, tok()],
          }
        : tok();
    final x = int.parse(RegExp(r'"x":(-?\d+)').firstMatch(text)!.group(1)!);
    final fixed = text.contains('"fixedHeight":true');
    return box(id, type: m.group(1), rev: tok(), baseRev: m.group(2), data: next, x: x, fixedHeight: fixed);
  }

  /// [text] moved.
  String moved(String text) {
    assert(isBoxText(text));
    return text.replaceFirst(RegExp(r'"y":-?\d+'), '"y":${10 + r.nextInt(5) * 10}');
  }

  /// [base] changed by one side: per node, left alone, deleted, given new
  /// content, or moved; and some nodes added (ids start with [prefix]).
  ///
  /// What the merges decide by design, not by the property, is kept out:
  /// - last write wins for position is asymmetric (mine is kept when both
  ///   moved): a node in [noMove] is not moved, and the ones moved are added
  ///   to [movedBy];
  /// - when both sides change a node Noted doesn't own, or one side turns a
  ///   node into one (0128, below), which side keeps the
  ///   id is asymmetric: a foreign node in [noForeign] is left alone, and the
  ///   ones changed are added to [foreignBy]; [foreignEdits] false leaves
  ///   them all alone;
  /// - a node whose id the reader made up (no id, not an object, or a repeated
  ///   id) is never changed or deleted, and an addition goes after the last of
  ///   them: its id is its position, so a merge couldn't tell it from another
  ///   node;
  /// - two nodes added at the same place on both sides come out mine first,
  ///   an order that depends on which side is mine: a test that swaps the
  ///   sides puts one side's additions at the [Place.front] and the other's
  ///   at the [Place.back];
  /// - when both sides reordered the nodes, mine's order is kept: [reorders]
  ///   false leaves the order alone (a side may swap two nodes with ids of
  ///   their own);
  /// - a node that one side changed into a node Noted doesn't own, or the
  ///   other way (0128), is kept either as a conflict record on the box or as
  ///   a copy under a new id, by which side is mine: it counts as a foreign
  ///   edit ([foreignBy], [noForeign], [foreignEdits]); the side that did not
  ///   turn it must not have changed the node in any way ([changedBy], [noFlip]),
  ///   or the merge would see a box edit against a node Noted does not own; and [flips] false
  ///   leaves it out;
  /// - a conflict-copy merge keeps the original's position whichever side moved
  ///   the box: [moves] false leaves every box in place;
  /// - a box one side has and the other deleted is kept by a conflict-copy
  ///   merge, and marked landed if it overlaps another, which only the copy's
  ///   side gets: [deletes] false there;
  /// - an added box sits far from every other ([spread]): the merge marks a
  ///   box that arrives on top of another as landed, which only the arriving
  ///   side gets.
  List<String> mutate(
    List<String> base, {
    required String prefix,
    Set<int> noMove = const {},
    Set<int> noForeign = const {},
    Set<int> noFlip = const {},
    Set<int>? changedBy,
    Set<int>? movedBy,
    Set<int>? foreignBy,
    bool deletes = true,
    bool foreignEdits = true,
    bool spread = true,
    bool moves = true,
    bool reorders = true,
    bool flips = true,
    Place place = Place.anywhere,
  }) {
    final ids = [for (final t in base) idOfText(t)];
    final counts = <String?, int>{};
    for (final id in ids) {
      counts[id] = (counts[id] ?? 0) + 1;
    }
    bool pinned(int i) => ids[i] == null || counts[ids[i]]! > 1;
    final out = <String>[];
    var lastPinned = -1;
    for (var i = 0; i < base.length; i++) {
      final t = base[i];
      final op = r.nextInt(8);
      if (pinned(i)) {
        out.add(t);
        lastPinned = out.length - 1;
      } else if (noForeign.contains(i)) {
        out.add(t); // the other side changed what kind of node it is, or its foreign content
      } else if (op == 0 && deletes) {
        changedBy?.add(i);
        // deleted
      } else if (op <= 4 && !isBoxText(t)) {
        if (foreignEdits && !noForeign.contains(i)) {
          if (flips && !noFlip.contains(i) && chance(1, 3)) {
            foreignBy?.add(i);
            out.add(box(ids[i]!)); // a node Noted doesn't own becomes a box
            continue;
          }
          foreignBy?.add(i);
          out.add(foreign(ids[i]!));
        } else {
          out.add(t);
        }
      } else if (op == 5 && flips && foreignEdits && !noFlip.contains(i)) {
        changedBy?.add(i);
        foreignBy?.add(i);
        out.add(foreign(ids[i]!)); // a box becomes a node Noted doesn't own
      } else if (op == 1 || op == 2) {
        changedBy?.add(i);
        out.add(editContent(t));
      } else if ((op == 3 || op == 4) && moves && !noMove.contains(i)) {
        movedBy?.add(i);
        changedBy?.add(i);
        out.add(moved(t));
      } else {
        out.add(t);
      }
    }
    if (reorders && chance(1, 3)) {
      // Two nodes with ids of their own change places.
      final own = [
        for (var i = 0; i < out.length; i++)
          if (idOfText(out[i]) != null && out.where((o) => idOfText(o) == idOfText(out[i])).length == 1) i,
      ];
      if (own.length >= 2) {
        final i = own[r.nextInt(own.length)];
        final j = own[r.nextInt(own.length)];
        final t = out[i];
        out[i] = out[j];
        out[j] = t;
      }
    }
    for (var i = r.nextInt(3); i > 0; i--) {
      final at = switch (place) {
        Place.anywhere => lastPinned + 1 + r.nextInt(out.length - lastPinned),
        Place.front => lastPinned + 1,
        Place.back => out.length,
      };
      final id = '$prefix${++_tok}';
      out.insert(at, chance(1, 4) ? foreign(id) : box(id, x: spread ? 1000 + _tok * 200 : null));
    }
    return out;
  }
}

/// [page] as text with only what is asymmetric by design taken out
/// (maintainer's sign-off, run 2026-11-03-01):
///
/// - device and time stamps: `noted.device`, `noted.at`, and the `device` and
///   `at` of `landed` and of each conflict record;
/// - which side a conflict record calls mine and which theirs: a box that
///   records another version is reduced to the sorted list of all its
///   versions, the kept one and the recorded ones;
/// - the drawing box's local `origin` (0041; here `test.set`'s `origin`);
/// - ids the merge generated ([newId], 16 hex digits) for a node kept under a
///   new id and for the revision of a box a codec merged: each becomes `#`;
/// - the `baseRev` of a box a codec merged (its `rev` is generated): it names
///   mine's revision, one of the two the merge came from, so it depends on
///   which side is mine. This one is not on the maintainer's list: reported.
///
/// Nothing else is normalised: bounds, other revisions, conflicts and the
/// page header are compared as written. The nodes are compared in order
/// unless [ordered] is false, which sorts them: two nodes that land at the
/// same place come out mine first, so their order depends on which side is
/// mine (the tests then check the order of the base's nodes apart).
String canon(NotedPage page, {bool ordered = true}) {
  final doc = jsonDecode(writePage(page)) as Map<String, Object?>;
  final id = RegExp(r'[0-9a-f]{16}');
  final nodes = [
    for (final n in doc.remove('nodes')! as List) jsonEncode(_node(n, top: true)).replaceAll(id, '#'),
  ];
  if (!ordered) nodes.sort();
  return [jsonEncode(doc).replaceAll(id, '#'), ...nodes].join('\n');
}

Object? _node(Object? n, {required bool top}) {
  if (n is! Map<String, Object?>) return n;
  final noted = n['noted'];
  if (noted is! Map<String, Object?>) return n;
  final out = {...n};
  final nn = {...noted};
  out['noted'] = nn;
  nn
    ..remove('device')
    ..remove('at');
  if (RegExp(r'^[0-9a-f]{16}$').hasMatch('${nn['rev']}')) nn.remove('baseRev');
  final data = nn['data'];
  if (nn['type'] == 'test.set' && data is Map<String, Object?>) {
    nn['data'] = {...data}..remove('origin');
  }
  final landed = nn['landed'];
  if (landed is Map<String, Object?>) {
    nn['landed'] = {...landed}
      ..remove('at')
      ..remove('device');
  }
  final conflicts = nn['conflicts'];
  if (conflicts is List) {
    final others = <Object?>[];
    final deleted = <Object?>[];
    for (final c in conflicts) {
      if (c is Map<String, Object?> && c['node'] != null) {
        others.add(_node(c['node'], top: false));
      } else {
        deleted.add(c is Map<String, Object?> ? ({...c}..remove('at')) : c);
      }
    }
    if (others.isNotEmpty && top) {
      nn.remove('conflicts');
      final all = [out, ...others]..sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
      return {'versions': all, 'conflicts': deleted};
    }
    nn['conflicts'] = [
      ...deleted,
      for (final o in others) {'node': o},
    ];
  }
  return out;
}

/// Where [PageGen.mutate] puts the nodes it adds: anywhere after the last
/// node whose id is made up, right after it, or at the end.
enum Place { anywhere, front, back }
