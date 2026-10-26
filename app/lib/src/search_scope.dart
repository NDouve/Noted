// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:noted_core/noted_core.dart';

/// A page the search can read: where it lives and how to load it through its
/// store (the same loading the rest of the app uses).
class SearchablePage {
  const SearchablePage(this.id, this.location, this.load);

  final String id;

  /// The key of the folder or binder holding the page.
  final String location;

  /// Reads the page's file. Throws if it can't be read.
  final Future<NotedPage> Function() load;
}

/// Something the search could not look in, and why.
class NotSearched {
  const NotSearched(this.name, this.reason);

  /// A folder, a binder or a page file.
  final String name;
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is NotSearched && other.name == name && other.reason == reason;

  @override
  int get hashCode => Object.hash(name, reason);
}

/// What the notebook offers to search right now: every page that can be
/// read, and what has to be skipped (unavailable folders, damaged binders,
/// page files that can't be read).
class SearchScope {
  const SearchScope(this.pages, this.skipped);

  final List<SearchablePage> pages;
  final List<NotSearched> skipped;
}
