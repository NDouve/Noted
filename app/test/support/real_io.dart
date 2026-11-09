// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart' show fail;

/// How much longer to let real file IO run in widget tests on a CI runner
/// (GitHub Actions sets `CI=true`), whose disk is much slower than a
/// development machine's. Tests alternate the test clock with short real
/// delays so IO started from a frame can finish; on CI those delays were
/// sometimes too short and a different test failed each run.
final int realIoScale = Platform.environment['CI'] == 'true' ? 4 : 1;

/// A real delay of [ms] milliseconds, scaled by [realIoScale].
Future<void> realIoPause(int ms) =>
    Future<void>.delayed(Duration(milliseconds: ms * realIoScale));

/// Real time until [done], polled every 10 ms: waits on the condition itself
/// rather than a delay that is long enough on one machine. Fails after
/// [limit] (scaled by [realIoScale]) saying what it waited for.
Future<void> realIoUntil(
  bool Function() done,
  String what, {
  Duration limit = const Duration(seconds: 10),
}) async {
  final end = DateTime.now().add(limit * realIoScale);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
