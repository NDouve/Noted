// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/testing.dart';

const _words = [
  'meeting', 'project', 'budget', 'schedule', 'review', 'design', 'notes',
  'draft', 'research', 'idea', 'résumé', 'café', 'Straße', 'über', 'task',
  'deadline', 'customer', 'feedback', 'roadmap', 'prototype', 'canvas',
  'binder', 'page', 'sketch', 'diagram', 'equation', 'table', 'column',
  'revenue', 'forecast', 'quarter', 'summary', 'action', 'owner', 'status',
  'risk', 'decision', 'update', 'agenda', 'minutes', 'travel', 'invoice',
];

String _paragraph(Random r, int words) =>
    List.generate(words, (_) => _words[r.nextInt(_words.length)]).join(' ');

/// A note box's snapshot as the note module writes it: several lines, a
/// table row with cells joined by ` | `, an equation.
String _snapshot(Random r) {
  final lines = <String>[
    for (var i = 0; i < 3 + r.nextInt(4); i++) _paragraph(r, 8 + r.nextInt(14)),
    '${_paragraph(r, 2)} | ${_paragraph(r, 1)} | ${r.nextInt(1000)}',
    r'$$x^2 + y^2 = z^2$$',
  ];
  return lines.join('\n');
}

void main() {
  test('500 pages of 20 boxes: queries find what a scan of every box finds (time printed)', () {
    final r = Random(7);
    final index = SearchIndex();
    // Every box's text, folded, per page: the reference a scan is checked against.
    final folded = <List<String>>[];
    final build = Stopwatch()..start();
    for (var p = 0; p < 500; p++) {
      var page = NotedPage.create(PageMeta.create(id: 'page$p', title: 'Page $p', order: p));
      final pageText = <String>[];
      folded.add(pageText);
      for (var b = 0; b < 20; b++) {
        final text = _snapshot(r);
        pageText.add(foldString(text));
        page = page.insertNode(
          BoxRecord.create(
            id: 'b$p-$b',
            typeId: 'noted.note',
            dataVersion: 1,
            bounds: Bounds(0, b * 100.0, 300, 80),
            data: const RawJson.trusted('{}'),
            snapshotText: text,
            rev: 'r',
          ),
        );
      }
      index.setPage(page, 'loc${p % 5}');
    }
    build.stop();
    expect(index.pageCount, 500);
    expect(index.boxCount, 10000);

    // Each query with the folded pieces a box's text must all contain.
    final queries = <String, List<String>>{
      'budget': ['budget'],
      'cafe review': ['cafe', 'review'],
      '"action owner"': ['action owner'],
      'strasse uber': ['strasse', 'uber'],
      'zzzznotfound': ['zzzznotfound'],
      'meeting project budget': ['meeting', 'project', 'budget'],
      'x': ['x'],
    };
    final times = <int>[];
    var hitCount = 0;
    for (var round = 0; round < 3; round++) {
      for (final q in queries.entries) {
        resetSearchBoxesExamined();
        final sw = Stopwatch()..start();
        final hits = index.search(SearchQuery.parse(q.key));
        sw.stop();
        times.add(sw.elapsedMilliseconds);
        hitCount += hits.length;
        // The work: no box is compared more than once per query. (There is no
        // pruning, so a query examines every indexed box; the bound catches a
        // search that repeats work, such as a second pass over the boxes.)
        expect(
          searchBoxesExamined,
          lessThanOrEqualTo(index.boxCount),
          reason: 'boxes examined for "${q.key}"',
        );
        expect(searchBoxesExamined, greaterThan(0));
        // The counts a scan of every box gives: the pages with a match, and
        // the boxes with one. A search that skipped or repeated work would
        // differ; the time is printed below, not asserted.
        var pages = 0;
        var boxes = 0;
        for (final page in folded) {
          final n = page.where((t) => q.value.every(t.contains)).length;
          if (n > 0) pages++;
          boxes += n;
        }
        expect(hits, hasLength(pages), reason: 'pages for "${q.key}"');
        expect(
          hits.fold<int>(0, (n, h) => n + h.boxes.length),
          boxes,
          reason: 'boxes for "${q.key}"',
        );
      }
    }
    // Searching changes nothing in the index.
    expect(index.pageCount, 500);
    expect(index.boxCount, 10000);
    times.sort();
    final median = times[times.length ~/ 2];
    // Printed so a run shows the numbers (they are not logged by the app).
    // ignore: avoid_print
    print(
      'search benchmark: build ${build.elapsedMilliseconds} ms; '
      'queries min ${times.first} / median $median / max ${times.last} ms; '
      '$hitCount page hits',
    );
    expect(hitCount, greaterThan(0));
  });
}
