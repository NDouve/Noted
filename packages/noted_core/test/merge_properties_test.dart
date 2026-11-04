// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

import 'support/page_gen.dart';

// Properties of the merges over seeded generated pages (fixed seeds, so the
// same pages every run). "Same" is [canon]: equal once what is asymmetric by
// design is taken out. See support/page_gen.dart, which also says what the
// generator keeps out of the way and why.
//
// Each property was shown to fail when the merger is deliberately broken
// (run 2026-11-03-01); the mutation, applied to the source and restored, and
// the tests that then failed:
//
//   three-way, theirs-only boxes dropped          unchanged base; swap; foreign-both; order
//   three-way, always mine's content              unchanged base; swap; foreign-both
//   three-way, always mine's geometry             unchanged base; swap
//   three-way, theirs-only nodes appended         unchanged base; swap
//   three-way, a conflict keeps theirs for some   swap; foreign-both
//   three-way, identical boxes reported conflicted  self
//   three-way, identical foreign node kept twice  self; unchanged base; swap; foreign-both
//   three-way, theirs' order not taken            unchanged base; swap (reorder); order
//   copy, concurrent edit keeps the copy          copy swap
//   copy, copy-only nodes dropped                 copy swap
//   copy, original newer takes the copy           older version; copy swap
//   copy, identical nodes compared as different   copy self; older version
//   writer not idempotent                         both byte-stable tests

/// Seeds 1..[runs] for each property; a failure names its seed.
const runs = 400;

final codecs = propertyRegistry();

PageMerge three(NotedPage b, NotedPage m, NotedPage t) =>
    mergePage(b, m, t, codecs, theirsTime: 5000);

PageMerge copyMerge(NotedPage o, NotedPage c) => mergeConflictCopy(o, c, codecs, copyTime: 5000);

/// The pages of one run as text, for a failure message.
String dump(Map<String, List<String>> pages) =>
    pages.entries.map((e) => '${e.key}:\n  ${e.value.join('\n  ')}').join('\n');

void forSeeds(void Function(int seed, PageGen g) body) {
  for (var seed = 1; seed <= runs; seed++) {
    body(seed, PageGen(seed));
  }
}

final _hex16 = RegExp(r'^[0-9a-f]{16}$');

/// Fails with the nodes that differ if [a] and [b] are not the same page.
/// With [ordered] false the order of the nodes is left out, except that the
/// nodes of [base] must come in the same order in both, and the nodes each of
/// [sides] has (its base nodes and its additions) in the order that side has;
/// with [reordered], the base nodes only have to be in the same order in both.
void same(
  NotedPage a,
  NotedPage b,
  int seed,
  Map<String, List<String>> pages, {
  bool ordered = true,
  NotedPage? base,
  List<NotedPage> sides = const [],
  bool reordered = false,
}) {
  final x = canon(a, ordered: ordered).split('\n');
  final y = canon(b, ordered: ordered).split('\n');
  final lines = <String>[];
  if (ordered) {
    for (var i = 0; i < x.length || i < y.length; i++) {
      final p = i < x.length ? x[i] : '(none)';
      final q = i < y.length ? y[i] : '(none)';
      if (p != q) lines.add('line $i\n    $p\n    $q');
    }
  } else {
    for (final p in x.where((l) => !y.contains(l))) {
      lines.add('only in the first\n    $p');
    }
    for (final q in y.where((l) => !x.contains(l))) {
      lines.add('only in the second\n    $q');
    }
  }
  if (lines.isNotEmpty) fail('seed $seed differs\n  ${lines.join('\n  ')}\n${dump(pages)}');
  // A node kept because one side deleted it and the other changed it is put
  // after its neighbour on the side that changed it, so where it lands among
  // the nodes mine added or kept depends on which side is mine.
  bool keptFromDelete(CanvasNode n) => n is BoxRecord && n.conflicts.any((c) => c.deleted);
  final skip = {
    for (final p in [a, b])
      for (final n in p.nodes)
        if (keptFromDelete(n)) n.id,
    // A node one side deleted that is kept for the other side's change, which
    // need not be a box that can be flagged.
    if (base != null)
      for (final n in base.nodes)
        if (sides.any((s) => s.node(n.id) == null)) n.id,
  };
  List<String> order(NotedPage p, Set<String> ids) => [
    for (final n in p.nodes)
      if (ids.contains(n.id) && !skip.contains(n.id)) n.id,
  ];
  void sameOrder(NotedPage of, String what) {
    final ids = {for (final n in of.nodes) n.id};
    final want = order(of, ids);
    for (final r in [a, b]) {
      final got = order(r, ids);
      if (got.join() != want.where(got.contains).join()) {
        fail('seed $seed: $what are in another order\n  want $want\n  got $got\n${dump(pages)}');
      }
    }
  }

  if (base != null && reordered) {
    final ids = {for (final n in base.nodes) n.id};
    expect(order(a, ids), order(b, ids), reason: 'seed $seed: the base nodes are in another order\n${dump(pages)}');
  } else if (base != null) {
    sameOrder(base, 'the base nodes');
  }
  for (var i = 0; i < sides.length && !reordered; i++) {
    sameOrder(sides[i], 'the nodes of side $i');
  }
}

void main() {
  test('the generated pages reach every case the properties are about', () {
    var conflicts = 0, deletes = 0, codecMerges = 0, copies = 0, moves = 0, reordered = 0;
    forSeeds((seed, g) {
      final base = g.nodes();
      final mine = g.mutate(base, prefix: 'm');
      final theirs = g.mutate(base, prefix: 't');
      final b = pageFrom(base);
      final merge = three(b, pageFrom(mine), pageFrom(theirs));
      for (final n in merge.page.nodes) {
        if (n is BoxRecord) {
          if (n.conflicts.any((c) => !c.deleted)) conflicts++;
          if (n.conflicts.any((c) => c.deleted)) deletes++;
          if (_hex16.hasMatch(n.rev ?? '')) codecMerges++;
          if (b.node(n.id) is BoxRecord && n.bounds != (b.node(n.id)! as BoxRecord).bounds) moves++;
        }
        if (_hex16.hasMatch(n.id)) copies++;
      }
      final ids = [for (final n in b.nodes) n.id];
      final inTheirs = [for (final n in pageFrom(theirs).nodes) if (ids.contains(n.id)) n.id];
      if (inTheirs.join() != ids.where(inTheirs.contains).join()) reordered++;
    });
    expect([conflicts, deletes, codecMerges, copies, moves, reordered], everyElement(greaterThan(20)));
  });

  group('three-way merge', () {
    test('mine and theirs swapped give the same page', () {
      forSeeds((seed, g) {
        final base = g.nodes();
        final moved = <int>{}, foreign = <int>{}, changed = <int>{};
        final mine = g.mutate(base, prefix: 'm', movedBy: moved, foreignBy: foreign, changedBy: changed, reorders: false, place: Place.back);
        final theirs = g.mutate(base, prefix: 't', noMove: moved, noForeign: foreign, noFlip: changed, reorders: false, place: Place.front);
        // Different header fields: each side's edit is kept.
        final b = pageFrom(base);
        final m = pageFrom(mine, title: g.chance(1, 2) ? 'T' : 'Mine');
        final t = pageFrom(theirs, order: g.r.nextInt(3));
        same(
          three(b, m, t).page,
          three(b, t, m).page,
          seed,
          {'base': base, 'mine': mine, 'theirs': theirs},
          ordered: false,
          base: b,
          sides: [m, t],
        );
      });
    });

    test('one side reordering the nodes gives the same page whichever side it is', () {
      forSeeds((seed, g) {
        final base = g.nodes();
        final moved = <int>{}, foreign = <int>{}, changed = <int>{};
        final mine = g.mutate(base, prefix: 'm', movedBy: moved, foreignBy: foreign, changedBy: changed, place: Place.back);
        final theirs = g.mutate(base, prefix: 't', noMove: moved, noForeign: foreign, noFlip: changed, reorders: false, place: Place.front);
        final b = pageFrom(base), m = pageFrom(mine), t = pageFrom(theirs);
        same(
          three(b, m, t).page,
          three(b, t, m).page,
          seed,
          {'base': base, 'mine': mine, 'theirs': theirs},
          ordered: false,
          base: b,
          reordered: true,
          sides: [m, t],
        );
      });
    });

    test('both changing a node Noted does not own keeps both versions either way', () {
      var copies = 0;
      forSeeds((seed, g) {
        final base = g.nodes();
        // A box turned into a foreign node, or back, is the next test.
        final mine = g.mutate(base, prefix: 'm', deletes: false, moves: false, reorders: false, flips: false);
        final theirs = g.mutate(base, prefix: 't', deletes: false, moves: false, reorders: false, flips: false);
        final b = pageFrom(base), m = pageFrom(mine), t = pageFrom(theirs);
        // Which side keeps the id differs, so compare without the ids.
        List<String> bare(NotedPage p) =>
            canon(p, ordered: false).replaceAll(RegExp(r'"id":"[^"]*"'), '"id":"_"').split('\n')..sort();
        final merged = three(b, m, t).page;
        final x = bare(merged), y = bare(three(b, t, m).page);
        if (x.join('\n') != y.join('\n')) {
          fail('seed $seed differs\n${x.join('\n')}\n--\n${y.join('\n')}\n${dump({'base': base, 'mine': mine, 'theirs': theirs})}');
        }
        // A copy under a new id (16 hex digits) of a node both sides changed.
        copies += merged.nodes.where((n) => n is ForeignNode && _hex16.hasMatch(n.id)).length;
      });
      expect(copies, greaterThan(20), reason: 'the generator rarely made both sides change a foreign node');
    });

    test('a node changed into or from a node Noted does not own keeps both sides (0128)', () {
      var mixed = 0;
      forSeeds((seed, g) {
        final base = g.nodes();
        final mine = g.mutate(base, prefix: 'm', deletes: false, moves: false, reorders: false);
        final theirs = g.mutate(base, prefix: 't', deletes: false, moves: false, reorders: false);
        final b = pageFrom(base), m = pageFrom(mine), t = pageFrom(theirs);
        Map<String, String> byId(List<String> l) => {
          for (final x in l)
            if (idOfText(x) != null) idOfText(x)!: x,
        };
        final bt = byId(base), mt = byId(mine), tt = byId(theirs);
        final tokens = RegExp(r'k\d+');
        for (final (x, y) in [(m, t), (t, m)]) {
          final text = writePage(three(b, x, y).page);
          for (final id in bt.keys) {
            final p = mt[id], q = tt[id];
            if (p == null || q == null || p == bt[id] || q == bt[id] || p == q) continue;
            if (isBoxText(p) == isBoxText(q)) continue;
            mixed++;
            for (final k in {...tokens.allMatches(p), ...tokens.allMatches(q)}.map((m) => m.group(0)!)) {
              if (bt[id]!.contains('"$k"')) continue;
              expect(text, contains('"$k"'), reason: 'seed $seed: $id lost $k\n${dump({'base': base, 'mine': mine, 'theirs': theirs})}');
            }
          }
        }
      });
      expect(mixed, greaterThan(20));
    });

    test('merging a page with itself gives the page', () {
      forSeeds((seed, g) {
        final base = g.nodes();
        final a = g.mutate(base, prefix: 'a');
        final b = pageFrom(base), p = pageFrom(a, title: 'Edited', order: g.r.nextInt(3));
        final merge = three(b, p, p);
        expect(writePage(merge.page), writePage(p), reason: 'seed $seed\n${dump({'base': base, 'a': a})}');
        expect(merge.conflictedIds, isEmpty, reason: 'seed $seed');
      });
    });

    test('an unchanged base merged with b gives b', () {
      forSeeds((seed, g) {
        final base = g.nodes();
        final other = g.mutate(base, prefix: 'b');
        final b = pageFrom(base), o = pageFrom(other, title: g.chance(1, 2) ? 'T' : 'Edited', order: g.r.nextInt(3));
        final pages = {'base': base, 'b': other};
        same(three(b, b, o).page, o, seed, pages); // nothing changed here
        same(three(b, o, b).page, o, seed, pages); // nothing changed there
      });
    });

    test('an order changed only there is taken; changed on both sides, mine stays', () {
      NotedPage page(List<String> ids) => pageFrom([for (final id in ids) PageGen(1).box(id, x: 0)]);
      List<String> ids(NotedPage p) => [for (final n in p.nodes) n.id];
      final base = page(['a', 'b', 'c']);
      final theirs = page(['c', 'a', 'b']);
      final mine = page(['b', 'a', 'c']);
      expect(ids(three(base, base, theirs).page), ['c', 'a', 'b']);
      expect(ids(three(base, theirs, base).page), ['c', 'a', 'b']);
      expect(ids(three(base, mine, theirs).page), ['b', 'a', 'c']);
      // A node added by mine and one removed by theirs don't hinder it.
      final other = page(['c', 'a']);
      expect(ids(three(base, page(['a', 'b', 'c', 'x']), other).page), ['c', 'a', 'x']);
    });
  });

  group('conflict-copy merge', () {
    test('a page merged with itself is the page', () {
      forSeeds((seed, g) {
        final a = g.nodes();
        final p = pageFrom(a);
        expect(writePage(copyMerge(p, p).page), writePage(p), reason: 'seed $seed\n${dump({'a': a})}');
      });
    });

    test('an older version of the original adds nothing', () {
      forSeeds((seed, g) {
        final base = g.nodes();
        // The copy can't hold a node the original deleted (the merge keeps a
        // node only one side has), or a node Noted doesn't own, changed.
        final newer = g.mutate(base, prefix: 'o', deletes: false, foreignEdits: false);
        final o = pageFrom(newer), c = pageFrom(base);
        expect(writePage(copyMerge(o, c).page), writePage(o), reason: 'seed $seed\n${dump({'base': base, 'newer': newer})}');
      });
    });

    test('the original and the copy swapped give the same page', () {
      forSeeds((seed, g) {
        final base = g.nodes();
        final mine = g.mutate(base, prefix: 'o', foreignEdits: false, moves: false, deletes: false, reorders: false, place: Place.back);
        final theirs = g.mutate(base, prefix: 'c', foreignEdits: false, moves: false, deletes: false, reorders: false, place: Place.front);
        final o = pageFrom(mine), c = pageFrom(theirs);
        same(
          copyMerge(o, c).page,
          copyMerge(c, o).page,
          seed,
          {'original': mine, 'copy': theirs},
          ordered: false,
          base: pageFrom(base),
        );
      });
    });
  });

  group('page file', () {
    test('write, read, write is byte-stable', () {
      forSeeds((seed, g) {
        final base = g.nodes();
        final text = writePage(pageFrom(base));
        expect(writePage(readPage(text)), text, reason: 'seed $seed\n${dump({'p': base})}');
      });
    });

    test('merged pages are byte-stable too', () {
      forSeeds((seed, g) {
        final base = g.nodes();
        final mine = g.mutate(base, prefix: 'm', spread: false);
        final theirs = g.mutate(base, prefix: 't', spread: false);
        final pages = {'base': base, 'mine': mine, 'theirs': theirs};
        for (final merged in [
          three(pageFrom(base), pageFrom(mine), pageFrom(theirs)).page,
          copyMerge(pageFrom(mine), pageFrom(theirs)).page,
        ]) {
          final text = writePage(merged);
          expect(writePage(readPage(text)), text, reason: 'seed $seed\n${dump(pages)}');
        }
      });
    });
  });
}
