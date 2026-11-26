// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// A `storedReadObserver` that records reads of page files only (a path that
/// ends in `.canvas`). The routed read also reports the attachments and the
/// set-aside files that the checked primitives read, which the page-read
/// counts of these tests are not about.
void Function(String path) pageReadsInto(List<String> into) => (path) {
  if (path.endsWith('.canvas')) into.add(path);
};
