// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../search/search_query.dart';

/// The state of "Find on page" as a box module sees it (Box API 0.6).
///
/// While the find bar is open the host gives each box this value, so a
/// module that wants to can mark the matches inside its own content. It is
/// optional: a module that ignores it still gets a frame around the box
/// from the canvas.
///
/// The module matches against its own text snapshot, with [query]: the core
/// never tells it where in its data a match is, and never reads that data.
final class BoxFind {
  const BoxFind({
    required this.query,
    this.currentBoxId,
    this.currentOccurrence = 0,
  });

  /// What is being looked for.
  final SearchQuery query;

  /// The box that holds the current match, or null if none does.
  final String? currentBoxId;

  /// Which match of the current box is current, counting the matches of
  /// `query.rangesIn(snapshot)` from 0.
  final int currentOccurrence;

  @override
  bool operator ==(Object other) =>
      other is BoxFind &&
      other.query == query &&
      other.currentBoxId == currentBoxId &&
      other.currentOccurrence == currentOccurrence;

  @override
  int get hashCode => Object.hash(query, currentBoxId, currentOccurrence);
}
