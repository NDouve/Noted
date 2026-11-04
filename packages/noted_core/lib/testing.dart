// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Counters for tests that bound work by counting it. Not part of the
/// library the app uses.
library;

export 'src/format/page_format.dart' show pageParseCount, resetPageParseCount;
export 'src/search/search_index.dart'
    show searchBoxesExamined, resetSearchBoxesExamined;
