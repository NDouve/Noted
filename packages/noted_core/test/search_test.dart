// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

BoxRecord box(
  String id,
  String snapshot, {
  String type = 'noted.note',
  String data = '"x"',
}) => BoxRecord.create(
  id: id,
  typeId: type,
  dataVersion: 1,
  bounds: const Bounds(0, 0, 100, 40),
  // Deliberately not a valid document: search must never look at it.
  data: RawJson.trusted(data),
  snapshotText: snapshot,
  rev: 'r',
);

NotedPage page(String id, List<BoxRecord> boxes) {
  var p = NotedPage.create(PageMeta.create(id: id, title: id, order: 0));
  for (final b in boxes) {
    p = p.insertNode(b);
  }
  return p;
}

bool matches(String query, String text) =>
    SearchQuery.parse(query).rangesIn(text) != null;

List<String> found(String query, String text) {
  final r = SearchQuery.parse(query).rangesIn(text);
  return [for (final x in r ?? <SearchRange>[]) text.substring(x.start, x.end)];
}

void main() {
  group('folding', () {
    test('case', () {
      expect(foldString('HeLLo WORLD'), 'hello world');
      expect(matches('HELLO', 'hello there'), isTrue);
    });

    test('Latin diacritics', () {
      expect(foldString('éèêë àáâãäå ñ ç ü ö ø đ ł ž ő'), 'eeee aaaaaa n c u o o d l z o');
      expect(foldString('ÉCOLE Ünïcödé'), 'ecole unicode');
      expect(matches('cafe', 'Un café noir'), isTrue);
      expect(matches('café', 'Un cafe noir'), isTrue);
    });

    test('ligatures and sharp s', () {
      expect(foldString('Straße'), 'strasse');
      expect(foldString('ẞ'), 'ss');
      expect(foldString('Æther œuvre þing'), 'aether oeuvre thing');
      expect(foldString('ﬁnal ﬂow'), 'final flow');
      expect(matches('strasse', 'Hauptstraße'), isFalse, reason: 'whole word');
      expect(matches('strasse', 'Die Straße ist lang'), isTrue);
      expect(matches('straße', 'Die STRASSE ist lang'), isTrue);
    });

    test('decomposed accents, Vietnamese, Greek and Cyrillic', () {
      expect(foldString('é'), 'e');
      expect(foldString('Việt Nam'), 'viet nam');
      expect(foldString('Ελλάδα ΣΟΦΟΣ σοφός'), 'ελλαδα σοφοσ σοφοσ');
      expect(foldString('Ёлка Й'), 'елка и');
    });

    test('typographic quotes, dashes, white space and zero-width', () {
      expect(foldString('don’t'), "don't");
      expect(foldString('a–b'), 'a-b');
      expect(foldString('a b\tc'), 'a b c');
      expect(foldString('a​b­c'), 'abc');
      expect(foldString('a\nb'), 'a\nb');
    });

    test('positions map back to the original text', () {
      final f = foldText('Straße');
      expect(f.text, 'strasse');
      expect(f.originalIndex(0), 0);
      expect(f.originalIndex(5), 4);
      expect(f.originalIndex(6), 5);
      expect(f.originalIndex(f.text.length), 6);
      expect(found('strasse', 'Die Straße ist'), ['Straße']);
      expect(found('cafe', 'un café noir'), ['café']);
    });

    test('ASCII text needs no map', () {
      expect(foldText('Plain Text').origin, isNull);
    });
  });

  group('matching', () {
    test('whole words only', () {
      expect(matches('cat', 'the cat sat'), isTrue);
      expect(matches('cat', 'category'), isFalse);
      expect(matches('cat', 'concat'), isFalse);
      expect(matches('cat', 'cat.'), isTrue);
      expect(matches('cat', '(cat)'), isTrue);
      expect(matches('cat', 'cat_x'), isTrue, reason: '_ separates words');
      expect(matches('x2', 'x2y'), isFalse);
      expect(matches('12', 'abc12'), isFalse);
      expect(matches('12', 'abc 12'), isTrue);
    });

    test('an occurrence inside a longer word does not hide a real one', () {
      expect(found('cat', 'category cat concat'), ['cat']);
    });

    test('several words are ANDed, in any order', () {
      expect(matches('red green', 'green and red'), isTrue);
      expect(matches('red green', 'only red here'), isFalse);
      expect(matches('red green', 'redgreen'), isFalse);
      expect(found('red green', 'green and red and green'), ['green', 'red', 'green']);
    });

    test('a quoted phrase matches its words next to each other', () {
      expect(matches('"red green"', 'a red green b'), isTrue);
      expect(matches('"red green"', 'a green red b'), isFalse);
      expect(matches('"red green"', 'red  green'), isTrue, reason: 'white space runs');
      expect(matches('"red green"', 'red, green'), isFalse);
      expect(matches('"red green"', 'red\ngreen'), isFalse, reason: 'not over a line');
      expect(matches('"red gre"', 'red green'), isFalse, reason: 'whole words');
      expect(matches('"ed green"', 'red green'), isFalse);
      expect(matches('"RED Gréen"', 'red green'), isTrue);
    });

    test('a phrase and words together', () {
      expect(matches('"red green" blue', 'blue red green'), isTrue);
      expect(matches('"red green" blue', 'red green'), isFalse);
      expect(matches('"red green" blue', 'green red blue'), isFalse);
    });

    test('an unclosed quote takes the rest as a phrase', () {
      expect(matches('"red green', 'red green'), isTrue);
      expect(matches('"red green', 'green red'), isFalse);
    });

    test('symbols in a term', () {
      expect(matches('c++', 'I like c++ a lot'), isTrue);
      expect(matches(r'$x^2$', r'see $x^2$ here'), isTrue);
      expect(matches('3.14', 'pi is 3.14.'), isTrue);
    });

    test('empty and blank queries match nothing', () {
      expect(SearchQuery.parse('').isEmpty, isTrue);
      expect(SearchQuery.parse('   ').isEmpty, isTrue);
      expect(SearchQuery.parse('""').isEmpty, isTrue);
      expect(matches('', 'anything'), isFalse);
    });

    test('ranges are ascending and overlaps merge', () {
      final q = SearchQuery.parse('red "red green"');
      final r = q.rangesIn('red green and red')!;
      expect(r, [const SearchRange(0, 9), const SearchRange(14, 17)]);
    });

    test('termRangesIn marks terms without requiring all of them', () {
      final q = SearchQuery.parse('red blue');
      expect(q.rangesIn('only red'), isNull);
      expect(q.termRangesIn('only red'), [const SearchRange(5, 8)]);
    });

    test('queries compare by their terms', () {
      expect(SearchQuery.parse('a b'), SearchQuery.parse('B  A'));
      expect(SearchQuery.parse('a b') == SearchQuery.parse('a'), isFalse);
    });

    test('snippets cut around the first match and keep highlights', () {
      final text = '${'lorem ipsum ' * 10}needle ${'dolor sit ' * 10}';
      final r = SearchQuery.parse('needle').rangesIn(text)!;
      final s = snippetOf(text, r, radius: 20);
      expect(s.text.startsWith('…'), isTrue);
      expect(s.text.endsWith('…'), isTrue);
      expect(s.highlights, hasLength(1));
      expect(s.text.substring(s.highlights.single.start, s.highlights.single.end), 'needle');
      expect(snippetOf('a\nneedle b', [const SearchRange(2, 8)]).text, 'a needle b');
    });
  });

  group('index', () {
    test('finds boxes by their snapshot and reports page and box', () {
      final index = SearchIndex()
        ..setPage(page('p1', [box('a', 'Hello world'), box('b', 'nothing')]), 'loc1')
        ..setPage(page('p2', [box('c', 'Hello again')]), 'loc2');
      final hits = index.search(SearchQuery.parse('hello'));
      expect(hits.map((h) => h.pageId), ['p1', 'p2']);
      expect(hits.first.boxes.map((b) => b.boxId), ['a']);
      expect(hits.first.location, 'loc1');
      expect(hits.first.matchCount, 1);
      expect(hits.first.boxes.first.snippet().text, 'Hello world');
    });

    test('the AND is per box, not per page', () {
      final index = SearchIndex()
        ..setPage(page('p1', [box('a', 'red'), box('b', 'green')]), 'l');
      expect(index.search(SearchQuery.parse('red green')), isEmpty);
      index.setPage(page('p1', [box('a', 'red'), box('b', 'green red')]), 'l');
      expect(index.search(SearchQuery.parse('red green')).single.boxes.single.boxId, 'b');
    });

    test('setPage replaces, removePage and removeLocation drop', () {
      final index = SearchIndex()
        ..setPage(page('p1', [box('a', 'alpha')]), 'l1')
        ..setPage(page('p2', [box('a', 'alpha')]), 'l1')
        ..setPage(page('p3', [box('a', 'alpha')]), 'l2');
      expect(index.pageCount, 3);
      index.setPage(page('p1', [box('a', 'beta')]), 'l1');
      expect(index.search(SearchQuery.parse('alpha')).map((h) => h.pageId), ['p2', 'p3']);
      expect(index.search(SearchQuery.parse('beta')).map((h) => h.pageId), ['p1']);
      index.removePage('p2');
      expect(index.containsPage('p2'), isFalse);
      index.removeLocation('l1');
      expect(index.pageIds, ['p3']);
      expect(index.locationOf('p3'), 'l2');
      index.clear();
      expect(index.pageCount, 0);
    });

    test('boxes without text (drawings) are not indexed', () {
      final index = SearchIndex()
        ..setPage(
          page('p', [
            box('d', '', type: 'noted.drawing'),
            box('s', '  \n ', type: 'noted.drawing'),
            box('n', 'text'),
          ]),
          'l',
        );
      expect(index.boxCount, 1);
      expect(index.search(SearchQuery.parse('drawing')), isEmpty);
    });

    test('unsupported box types are searched by snapshot and never parsed', () {
      // The data is not valid for any module; a type this build doesn't know
      // and a future encrypted box look the same to the index.
      final weird = box('x', 'secret-free snapshot words', type: 'future.vault', data: '[1,2');
      final index = SearchIndex()..setPage(page('p', [weird]), 'l');
      expect(index.search(SearchQuery.parse('snapshot')).single.boxes.single.typeId, 'future.vault');
      expect(index.search(SearchQuery.parse('garbage')), isEmpty);
    });

    test('foreign (non-Noted) nodes are not indexed', () {
      final foreign = ForeignNode.read(
        const RawJson.trusted('{"id":"f","type":"text","text":"foreign words","x":0,"y":0,"width":10,"height":10}'),
        fallbackId: 'f',
      );
      final index = SearchIndex()
        ..setPage(NotedPage.create(PageMeta.create(id: 'p', title: 'p', order: 0)).insertNode(foreign), 'l');
      expect(index.boxCount, 0);
    });

    test('accent and case folding apply to the stored text', () {
      final index = SearchIndex()..setPage(page('p', [box('a', 'Crème Brûlée')]), 'l');
      final hits = index.search(SearchQuery.parse('creme brulee'));
      final r = hits.single.boxes.single.ranges;
      expect(hits.single.boxes.single.text.substring(r.first.start, r.first.end), 'Crème');
    });
  });

  group('page titles', () {
    NotedPage titled(String id, String title, List<BoxRecord> boxes) {
      var p = NotedPage.create(PageMeta.create(id: id, title: title, order: 0));
      for (final b in boxes) {
        p = p.insertNode(b);
      }
      return p;
    }

    test('a title is matched with the same rules as boxes', () {
      final index = SearchIndex()
        ..setPage(titled('p1', 'Café Budget', []), 'l')
        ..setPage(titled('p2', 'Budgets', []), 'l');
      final hits = index.search(SearchQuery.parse('CAFE'));
      expect(hits.single.pageId, 'p1');
      expect(hits.single.boxes, isEmpty);
      expect(hits.single.title, 'Café Budget');
      expect(hits.single.titleRanges, [const SearchRange(0, 4)]);
      expect(hits.single.matchCount, 1);
      // Whole words only.
      expect(index.search(SearchQuery.parse('budget')).map((h) => h.pageId), ['p1']);
      // AND and phrases.
      expect(index.search(SearchQuery.parse('budget cafe')).single.pageId, 'p1');
      expect(index.search(SearchQuery.parse('"cafe budget"')).single.pageId, 'p1');
      expect(index.search(SearchQuery.parse('"budget cafe"')), isEmpty);
    });

    test('title words and box words are not mixed', () {
      final index = SearchIndex()
        ..setPage(titled('p1', 'Plan', [box('a', 'budget')]), 'l');
      expect(index.search(SearchQuery.parse('plan budget')), isEmpty);
      final both = index.search(SearchQuery.parse('plan')).single;
      expect(both.titleMatched, isTrue);
      expect(both.boxes, isEmpty);
    });

    test('a page can match by title and by boxes', () {
      final index = SearchIndex()
        ..setPage(titled('p1', 'Budget', [box('a', 'the budget')]), 'l');
      final h = index.search(SearchQuery.parse('budget')).single;
      expect(h.titleMatched, isTrue);
      expect(h.boxes.single.boxId, 'a');
      expect(h.matchCount, 2);
    });

    test('title-matched pages come first, insertion order kept in each group', () {
      final index = SearchIndex()
        ..setPage(titled('a', 'Other', [box('x', 'budget')]), 'l')
        ..setPage(titled('b', 'Budget two', []), 'l')
        ..setPage(titled('c', 'More', [box('x', 'budget')]), 'l')
        ..setPage(titled('d', 'Budget one', [box('x', 'budget')]), 'l');
      expect(index.search(SearchQuery.parse('budget')).map((h) => h.pageId), [
        'b',
        'd',
        'a',
        'c',
      ]);
    });

    test('rename reindexes, removal and empty titles', () {
      final index = SearchIndex()..setPage(titled('p', 'Old name', []), 'l');
      expect(index.search(SearchQuery.parse('old')), hasLength(1));
      index.setPage(titled('p', 'New name', []), 'l');
      expect(index.search(SearchQuery.parse('old')), isEmpty);
      expect(index.search(SearchQuery.parse('new')), hasLength(1));
      index.setPage(titled('p', '', []), 'l');
      expect(index.search(SearchQuery.parse('new')), isEmpty);
      index.setPage(titled('p', 'Name', []), 'l');
      index.removePage('p');
      expect(index.search(SearchQuery.parse('name')), isEmpty);
    });
  });
}
