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

/// Fails with the nodes that differ if [a] and [b] are not the same page.
/// With [ordered] false the order of the nodes is left out, except that the
/// nodes of [base] must come in the same order in both.
void same(
  NotedPage a,
  NotedPage b,
  int seed,
  Map<String, List<String>> pages, {
  bool ordered = true,
  NotedPage? base,
}) {
  final x = canon(a, ordered: ordered).split('\n');
  final y = canon(b, ordered: ordered).split('\n');
  final lines = <String>[];
  for (var i = 0; i < x.length || i < y.length; i++) {
    final p = i < x.length ? x[i] : '(none)';
    final q = i < y.length ? y[i] : '(none)';
    if (p != q) lines.add('line $i\n    $p\n    $q');
  }
  if (lines.isNotEmpty) fail('seed $seed differs\n  ${lines.join('\n  ')}\n${dump(pages)}');
  if (base != null) {
    // A node kept because one side deleted it and the other changed it is
    // put after its neighbour on the side that changed it, so where it lands
    // among the nodes mine added or kept depends on which side is mine.
    bool keptFromDelete(CanvasNode n) => n is BoxRecord && n.conflicts.any((c) => c.deleted);
    final ids = {for (final n in base.nodes) n.id}
      ..removeAll([for (final p in [a, b]) for (final n in p.nodes) if (keptFromDelete(n)) n.id]);
    List<String> order(NotedPage p) => [
      for (final n in p.nodes)
        if (ids.contains(n.id)) n.id,
    ];
    expect(order(a), order(b), reason: 'seed $seed: the base nodes are in another order\n${dump(pages)}');
  }
}

void main() {
  test('the generated pages reach every case the properties are about', () {
    var conflicts = 0, deletes = 0, codecMerges = 0, copies = 0, moves = 0;
    final hex = RegExp(r'^[0-9a-f]{16}$');
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
          if (hex.hasMatch(n.rev ?? '')) codecMerges++;
          if (b.node(n.id) is BoxRecord && n.bounds != (b.node(n.id)! as BoxRecord).bounds) moves++;
        }
        if (hex.hasMatch(n.id)) copies++;
      }
    });
    expect([conflicts, deletes, codecMerges, copies, moves], everyElement(greaterThan(20)));
  });

  group('three-way merge', () {
    test('mine and theirs swapped give the same page', () {
      forSeeds((seed, g) {
        final base = g.nodes();
        final moved = <int>{}, foreign = <int>{};
        final mine = g.mutate(base, prefix: 'm', movedBy: moved, foreignBy: foreign, place: Place.back);
        final theirs = g.mutate(base, prefix: 't', noMove: moved, noForeign: foreign, place: Place.front);
        final b = pageFrom(base), m = pageFrom(mine), t = pageFrom(theirs);
        same(
          three(b, m, t).page,
          three(b, t, m).page,
          seed,
          {'base': base, 'mine': mine, 'theirs': theirs},
          ordered: false,
          base: b,
        );
      });
    });

    test('both changing a node Noted does not own keeps both versions either way', () {
      var kept = 0;
      forSeeds((seed, g) {
        final base = g.nodes();
        final mine = g.mutate(base, prefix: 'm', deletes: false, moves: false);
        final theirs = g.mutate(base, prefix: 't', deletes: false, moves: false);
        final b = pageFrom(base), m = pageFrom(mine), t = pageFrom(theirs);
        // Which side keeps the id differs, so compare without the ids.
        List<String> bare(NotedPage p) =>
            canon(p, ordered: false).replaceAll(RegExp(r'"id":"[^"]*"'), '"id":"_"').split('\n')..sort();
        final x = bare(three(b, m, t).page), y = bare(three(b, t, m).page);
        if (x.join('\n') != y.join('\n')) {
          fail('seed $seed differs\n${x.join('\n')}\n--\n${y.join('\n')}\n${dump({'base': base, 'mine': mine, 'theirs': theirs})}');
        }
        if (x.length > pageFrom(mine).nodes.length + 1) kept++;
      });
      expect(kept, greaterThan(0), reason: 'the generator never made both sides change a foreign node');
    });

    test('merging a page with itself gives the page', () {
      forSeeds((seed, g) {
        final base = g.nodes();
        final a = g.mutate(base, prefix: 'a');
        final b = pageFrom(base), p = pageFrom(a);
        final merge = three(b, p, p);
        expect(writePage(merge.page), writePage(p), reason: 'seed $seed\n${dump({'base': base, 'a': a})}');
        expect(merge.conflictedIds, isEmpty, reason: 'seed $seed');
      });
    });

    test('an unchanged base merged with b gives b', () {
      forSeeds((seed, g) {
        final base = g.nodes();
        final other = g.mutate(base, prefix: 'b');
        final b = pageFrom(base), o = pageFrom(other);
        final pages = {'base': base, 'b': other};
        same(three(b, b, o).page, o, seed, pages); // nothing changed here
        same(three(b, o, b).page, o, seed, pages); // nothing changed there
      });
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
        final mine = g.mutate(base, prefix: 'o', foreignEdits: false, moves: false, deletes: false, place: Place.back);
        final theirs = g.mutate(base, prefix: 'c', foreignEdits: false, moves: false, deletes: false, place: Place.front);
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
