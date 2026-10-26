// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

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
  test('500 pages of 20 boxes: a query takes under 300 ms', () {
    final r = Random(7);
    final index = SearchIndex();
    final build = Stopwatch()..start();
    for (var p = 0; p < 500; p++) {
      var page = NotedPage.create(PageMeta.create(id: 'page$p', title: 'Page $p', order: p));
      for (var b = 0; b < 20; b++) {
        page = page.insertNode(
          BoxRecord.create(
            id: 'b$p-$b',
            typeId: 'noted.note',
            dataVersion: 1,
            bounds: Bounds(0, b * 100.0, 300, 80),
            data: const RawJson.trusted('{}'),
            snapshotText: _snapshot(r),
            rev: 'r',
          ),
        );
      }
      index.setPage(page, 'loc${p % 5}');
    }
    build.stop();
    expect(index.pageCount, 500);
    expect(index.boxCount, 10000);

    final queries = [
      'budget',
      'cafe review',
      '"action owner"',
      'strasse uber',
      'zzzznotfound',
      'meeting project budget',
      'x',
    ];
    final times = <int>[];
    var hitCount = 0;
    for (var round = 0; round < 3; round++) {
      for (final text in queries) {
        final sw = Stopwatch()..start();
        final hits = index.search(SearchQuery.parse(text));
        sw.stop();
        times.add(sw.elapsedMilliseconds);
        hitCount += hits.length;
      }
    }
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
    expect(median, lessThan(300));
  });
}
