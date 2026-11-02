// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/notebook.dart';

import 'real_io.dart';

/// Lets every save of [nb] finish inside a widget test, before teardown.
///
/// A save that starts inside the test's fake-time zone (the autosave timer
/// fires there) can't finish from `runAsync`: its callbacks wait for that
/// zone's microtasks, so `await nb.flush()` from `runAsync` waited forever and
/// once hung CI for the whole test timeout. This advances fake time past the
/// autosave delay and alternates it with short real delays so the file IO can
/// complete, until the notebook reports nothing unsaved. It is bounded: if a
/// save is still stuck after [limit] the test fails and names it.
Future<void> settleSaves(
  WidgetTester tester,
  Notebook nb, {
  Duration limit = const Duration(seconds: 20),
}) async {
  final clock = Stopwatch()..start();
  while (nb.unsavedDescription != null) {
    if (clock.elapsed > limit) {
      fail('A save did not finish within $limit: ${nb.unsavedDescription}.');
    }
    await tester.pump(nb.saveDelay + const Duration(milliseconds: 1));
    await tester.runAsync(() => realIoPause(30));
  }
  // Nothing is pending now, so this only waits for work that has finished.
  await tester.runAsync(
    () => nb.flush().timeout(
      limit,
      onTimeout: () => throw TestFailure('Notebook.flush() did not finish within $limit.'),
    ),
  );
}
