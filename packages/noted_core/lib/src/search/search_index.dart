// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../model/page.dart';
import 'search_query.dart';
import 'text_folding.dart';

/// A box that matched a search.
final class BoxHit {
  const BoxHit({
    required this.boxId,
    required this.typeId,
    required this.text,
    required this.ranges,
  });

  final String boxId;
  final String typeId;

  /// The box's text snapshot.
  final String text;

  /// Where the query is in [text].
  final List<SearchRange> ranges;

  /// An excerpt around the first match.
  SearchSnippet snippet({int radius = 40}) =>
      snippetOf(text, ranges, radius: radius);
}

/// The boxes of one page that matched a search.
final class PageHits {
  const PageHits({
    required this.pageId,
    required this.location,
    required this.boxes,
    this.title = '',
    this.titleRanges = const [],
  });

  final String pageId;

  /// Where the page is kept (a key the caller chose when it added the page).
  final String location;

  /// In the page's own box order. Empty when only the title matched.
  final List<BoxHit> boxes;

  /// The page's title as stored in its header.
  final String title;

  /// Where the query is in [title]; empty if the title did not match. A
  /// title matches when it holds every term of the query by itself: title
  /// words and box words are never mixed for one match.
  final List<SearchRange> titleRanges;

  bool get titleMatched => titleRanges.isNotEmpty;

  /// Total matches on the page (title and boxes).
  int get matchCount =>
      boxes.fold(titleRanges.length, (n, b) => n + b.ranges.length);
}

class _IndexedBox {
  _IndexedBox(this.id, this.typeId, this.text) : folded = foldText(text);

  final String id;
  final String typeId;
  final String text;
  final FoldedText folded;
}

class _IndexedPage {
  _IndexedPage(this.location, this.title, this.boxes)
    : foldedTitle = foldText(title);

  final String location;
  final String title;
  final FoldedText foldedTitle;
  final List<_IndexedBox> boxes;
}

/// An in-memory index of the text snapshots of the boxes of many pages.
///
/// It reads one thing from a box: [BoxRecord.snapshotText], the text the
/// box's module produced for it through the Box API (0035). It never looks
/// at a box's data, so a box of a type this build doesn't support, or an
/// encrypted one, is searched (or not) exactly as its module made it, and
/// is never parsed. A box with an empty snapshot (a drawing) is not
/// indexed.
///
/// The index lives in memory only. It has no way to write itself anywhere,
/// and nothing here logs.
final class SearchIndex {
  final Map<String, _IndexedPage> _pages = {};

  /// Page ids in the index.
  Iterable<String> get pageIds => _pages.keys;

  int get pageCount => _pages.length;

  /// Boxes with text in the index.
  int get boxCount => _pages.values.fold(0, (n, p) => n + p.boxes.length);

  bool containsPage(String pageId) => _pages.containsKey(pageId);

  /// The location [pageId] was added with, or null.
  String? locationOf(String pageId) => _pages[pageId]?.location;

  /// Adds [page], or replaces what the index had of it. [location] is any
  /// key that lets the caller drop a whole folder or binder at once
  /// ([removeLocation]).
  void setPage(NotedPage page, String location) {
    final boxes = <_IndexedBox>[];
    for (final node in page.nodes) {
      if (node is! BoxRecord) continue;
      final text = node.snapshotText;
      if (text.trim().isEmpty) continue;
      boxes.add(_IndexedBox(node.id, node.typeId, text));
    }
    _pages[page.id] = _IndexedPage(location, page.meta.title, boxes);
  }

  void removePage(String pageId) => _pages.remove(pageId);

  /// Drops every page that was added with [location].
  void removeLocation(String location) =>
      _pages.removeWhere((_, p) => p.location == location);

  void clear() => _pages.clear();

  /// The pages whose title holds every term of [query], or with at least one
  /// box that does. Pages matched by title come first; within each group the
  /// pages are in the order they were first added.
  List<PageHits> search(SearchQuery query) {
    if (query.isEmpty) return const [];
    final titled = <PageHits>[];
    final result = <PageHits>[];
    for (final entry in _pages.entries) {
      final page = entry.value;
      var titleRanges = const <SearchRange>[];
      if (page.title.isNotEmpty &&
          query.matchesFolded(page.foldedTitle.text)) {
        titleRanges = query.rangesInFolded(page.foldedTitle) ?? const [];
      }
      List<BoxHit>? hits;
      for (final box in entry.value.boxes) {
        if (!query.matchesFolded(box.folded.text)) continue;
        final ranges = query.rangesInFolded(box.folded);
        if (ranges == null || ranges.isEmpty) continue;
        (hits ??= []).add(
          BoxHit(
            boxId: box.id,
            typeId: box.typeId,
            text: box.text,
            ranges: ranges,
          ),
        );
      }
      if (hits != null || titleRanges.isNotEmpty) {
        (titleRanges.isNotEmpty ? titled : result).add(
          PageHits(
            pageId: entry.key,
            location: page.location,
            boxes: hits ?? const [],
            title: page.title,
            titleRanges: titleRanges,
          ),
        );
      }
    }
    return [...titled, ...result];
  }
}
