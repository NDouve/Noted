// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Dependency-free on purpose: the MCP server may import `format/` but not
// `merge/`, and the table of provider conflict-copy names belongs to both.

/// The suffixes a sync provider adds before the extension when it keeps both
/// copies of a file changed on two machines (all unverified except where
/// noted). Each matches at the end of a stem:
///
/// - ` (<n>)`: Drive for desktop.
/// - ` (conflicted copy [<words> ]<yyyy-mm-dd> <hhmmss>)`: Nextcloud (the
///   documented example is `mydata (conflicted copy 2018-04-10 093612).txt`).
/// - `_conflict-<yyyymmdd>-<hhmmss>`: older ownCloud.
/// - ` <n>`: Finder-style (unverified, I2). iCloud for Windows' own naming is
///   unverified (I3) and has no rule of its own; a name of these shapes is
///   covered.
/// - `-<alnum[_-]*>`: OneDrive's `-<HOST>[-<n>]` and Noted's own
///   `-conflict-`, `-recovered-`, `-undo-`, `-remote-`, `-NOTED-MCP-`,
///   `-icloud-` and `-gdrive-` names. Every hyphen may start it, since page
///   ids and computer names hold hyphens.
final List<RegExp> _spaceSuffixes = [
  RegExp(r' \(\d+\)$'),
  RegExp(r' \(conflicted copy (?:[^()]+ )?\d{4}-\d{2}-\d{2} \d{6}\)$'),
  RegExp(r'_conflict-\d{8}-\d{6}$'),
  RegExp(r' \d+$'),
];

final RegExp _hyphenTail = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$');

/// Every stem [stem] may have been renamed from, with each combination of
/// trailing suffixes stripped (see the table above), shortest first and
/// without repeats. `<id>-HOST (1)` yields `<id>-HOST` and `<id>`, so the
/// original is still found when the middle file is missing. Empty if no suffix
/// matches. The caller keeps the first candidate that exists and holds the
/// same page id.
List<String> conflictCopyOriginalStems(String stem) {
  final seen = <String>{};
  void walk(String s) {
    for (final re in _spaceSuffixes) {
      final m = re.firstMatch(s);
      if (m == null || m.start < 1) continue;
      final next = s.substring(0, m.start);
      if (seen.add(next)) walk(next);
    }
    for (var i = 1; i < s.length - 1; i++) {
      if (s[i] != '-' || !_hyphenTail.hasMatch(s.substring(i + 1))) continue;
      final next = s.substring(0, i);
      if (seen.add(next)) walk(next);
    }
  }

  walk(stem);
  final out = seen.toList();
  // Stable by length, then by value, so the order is the same everywhere.
  out.sort((a, b) => a.length != b.length ? a.length - b.length : a.compareTo(b));
  return out;
}
