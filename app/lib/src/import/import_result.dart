// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Note blocks a converter built, and what it left out ([notices]).
final class BlocksResult {
  const BlocksResult(this.blocks, [this.notices = const []]);

  final List<Map<String, Object?>> blocks;
  final List<String> notices;
}

/// What the conversion isolate returns: either an [error] (the reason that
/// follows the file's name) or the note blocks, grouped for note boxes, with
/// the [notices] to tell the user. Plain data, so it crosses isolates.
final class ConvertedNotes {
  const ConvertedNotes({this.error, this.boxes = const [], this.notices = const []});

  final String? error;

  /// One list of blocks for each note box.
  final List<List<Map<String, Object?>>> boxes;
  final List<String> notices;
}
