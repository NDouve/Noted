// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The automated hands-on checklist. Run from `app/`:
//
//     flutter test integration_test -d windows
//
// See docs/testing/checklist-coverage.md. All suites are in this one entry
// point so that the app is built and started once.

import 'package:integration_test/integration_test.dart';

import 'suites/canvas_suite.dart';
import 'suites/folders_binders_suite.dart';
import 'suites/notes_suite.dart';
import 'suites/page_tree_suite.dart';
import 'suites/search_suite.dart';
import 'suites/templates_suite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  pageTreeSuite();
  foldersBindersSuite();
  notesSuite();
  templatesSuite();
  canvasSuite();
  searchSuite();
}
