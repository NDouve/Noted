// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/notebook.dart';

import 'notebook_folder.dart';

/// Lets all the work of [nb] finish inside a widget test, before teardown: the
/// saves and also the reads and file checks (see `notebook_folder.dart`).
///
/// A save that starts inside the test's fake-time zone (the autosave timer
/// fires there) can't finish from `runAsync`: its callbacks wait for that
/// zone's microtasks, so `await nb.flush()` from `runAsync` waited forever and
/// once hung CI for the whole test timeout. [settleNotebooks] advances fake
/// time past the autosave delay and alternates it with short real delays so
/// the file IO can complete. It is bounded: if work is still running after
/// [limit] the test fails and names it.
Future<void> settleSaves(
  WidgetTester tester,
  Notebook nb, {
  Duration limit = const Duration(seconds: 20),
}) => settleNotebooks(tester: tester, notebooks: [nb], limit: limit);
