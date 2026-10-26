// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:noted_core/noted_core.dart';

/// A request to open Find on page on a particular page: from the "Search all
/// pages" results, which carry the text that was searched and the match that
/// was clicked.
@immutable
final class FindRequest {
  const FindRequest({
    required this.pageId,
    required this.text,
    this.boxId,
    this.occurrence = 0,
  });

  final String pageId;

  /// What to look for, as typed.
  final String text;

  /// The box whose match should be current; the first match on the page if
  /// null or if the box no longer matches.
  final String? boxId;

  /// Which match of [boxId] (from 0).
  final int occurrence;
}

/// One match of Find on page: the [occurrence]th match in box [boxId]'s
/// text snapshot.
@immutable
final class FindMatch {
  const FindMatch(this.boxId, this.occurrence, this.range);

  final String boxId;
  final int occurrence;

  /// Where the match is in the box's snapshot text.
  final SearchRange range;
}

/// The state of Find on page for one open page (the find bar's model).
///
/// It searches what the page model holds: the text snapshot of each box
/// (`BoxRecord.snapshotText`, kept by the box's module on every commit),
/// never the live editors and never a box's data. Matches are ordered the
/// way a person reads the page: top to bottom, then left to right.
class PageFind extends ChangeNotifier {
  // ignore: prefer_initializing_formals
  PageFind({required NotedPage Function() page, this.onReveal}) : _page = page;

  final NotedPage Function() _page;

  /// Called when the current match changes or is chosen again, so the canvas
  /// can bring its box into view.
  final void Function(String boxId)? onReveal;

  bool _open = false;
  String _text = '';
  SearchQuery _query = SearchQuery.parse('');
  List<FindMatch> _matches = const [];
  int _current = -1;
  final ValueNotifier<BoxFind?> _boxFind = ValueNotifier<BoxFind?>(null);
  int _focusTick = 0;

  /// The find bar is showing.
  bool get isOpen => _open;

  /// What was typed.
  String get text => _text;

  SearchQuery get query => _query;

  /// Every match on the page, in reading order.
  List<FindMatch> get matches => _matches;

  /// The boxes with a match.
  Set<String> get matchedBoxIds => _matchedIds;
  Set<String> _matchedIds = const {};

  /// The index in [matches] of the current match, or -1.
  int get currentIndex => _current;

  FindMatch? get currentMatch => _current < 0 ? null : _matches[_current];

  /// What each box is told (Box API 0.6); null while the bar is closed.
  ValueListenable<BoxFind?> get boxFind => _boxFind;

  /// Rises each time the bar is asked to open, so it takes focus again
  /// (Ctrl+F while it is already open).
  int get focusTick => _focusTick;

  /// Opens the bar. With [text], looks for it; [boxId] and [occurrence] pick
  /// the current match.
  void open({String? text, String? boxId, int occurrence = 0}) {
    _open = true;
    _focusTick++;
    if (text != null) {
      _text = text;
      _query = SearchQuery.parse(text);
    }
    _recompute(boxId: boxId, occurrence: occurrence, reveal: true);
  }

  /// The text in the bar changed.
  void setText(String text) {
    if (text == _text && _open) return;
    _text = text;
    _query = SearchQuery.parse(text);
    _recompute(reveal: true);
  }

  /// Closes the bar and clears every highlight.
  void close() {
    if (!_open) return;
    _open = false;
    _matches = const [];
    _current = -1;
    _boxFind.value = null;
    notifyListeners();
  }

  /// Moves to the next ([delta] 1) or previous (-1) match, wrapping.
  void step(int delta) {
    if (!_open) return;
    // The page may have changed since the last look.
    final keep = currentMatch;
    _recompute(
      boxId: keep?.boxId,
      occurrence: keep?.occurrence ?? 0,
      reveal: false,
      notify: false,
    );
    if (_matches.isEmpty) {
      notifyListeners();
      return;
    }
    _current = (_current + delta) % _matches.length;
    if (_current < 0) _current += _matches.length;
    _publish();
    notifyListeners();
    onReveal?.call(_matches[_current].boxId);
  }

  /// Looks again at the page (its boxes changed), keeping the current match
  /// where it still is.
  void refresh() {
    if (!_open) return;
    final keep = currentMatch;
    _recompute(boxId: keep?.boxId, occurrence: keep?.occurrence ?? 0, reveal: false);
  }

  void _recompute({
    String? boxId,
    int occurrence = 0,
    required bool reveal,
    bool notify = true,
  }) {
    final boxes = <BoxRecord>[
      for (final n in _page().nodes)
        if (n is BoxRecord && n.snapshotText.isNotEmpty) n,
    ];
    boxes.sort((a, b) {
      final ab = a.bounds, bb = b.bounds;
      final dy = ab.y.compareTo(bb.y);
      return dy != 0 ? dy : ab.x.compareTo(bb.x);
    });
    final found = <FindMatch>[];
    if (!_query.isEmpty) {
      for (final box in boxes) {
        final ranges = _query.rangesIn(box.snapshotText);
        if (ranges == null) continue;
        for (var i = 0; i < ranges.length; i++) {
          found.add(FindMatch(box.id, i, ranges[i]));
        }
      }
    }
    _matches = found;
    _matchedIds = {for (final m in found) m.boxId};
    var current = -1;
    if (found.isNotEmpty) {
      current = 0;
      if (boxId != null) {
        final exact = found.indexWhere(
          (m) => m.boxId == boxId && m.occurrence == occurrence,
        );
        final inBox = found.indexWhere((m) => m.boxId == boxId);
        if (exact >= 0) {
          current = exact;
        } else if (inBox >= 0) {
          current = inBox;
        }
      }
    }
    _current = current;
    _publish();
    if (notify) notifyListeners();
    if (reveal && current >= 0) onReveal?.call(found[current].boxId);
  }

  void _publish() {
    if (!_open || _query.isEmpty) {
      _boxFind.value = null;
      return;
    }
    final m = currentMatch;
    _boxFind.value = BoxFind(
      query: _query,
      currentBoxId: m?.boxId,
      currentOccurrence: m?.occurrence ?? 0,
    );
  }

  @override
  void dispose() {
    _boxFind.dispose();
    super.dispose();
  }
}
