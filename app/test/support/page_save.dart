// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:noted_core/noted_core.dart';

/// Writes a page file the way a test's "somebody else wrote it" step needs: to
/// a temporary file renamed over whatever is at the page's path, with no
/// coordination and no check. `PageStore.save` was removed (it had no
/// production caller, and a blind replace is not a primitive); production code
/// publishes with `saveNew` and replaces with `saveIfUnchanged`.
Future<void> savePageDirect(PageStore store, NotedPage page) async {
  final path = store.pathFor(page.id);
  final tmp = File('$path.tmp');
  await tmp.writeAsString(writePage(page), flush: true);
  await tmp.rename(path);
}

extension PageStoreTestSave on PageStore {
  Future<void> save(NotedPage page) => savePageDirect(this, page);
}
