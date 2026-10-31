// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

/// How much longer to let real file IO run in widget tests on a CI runner
/// (GitHub Actions sets `CI=true`), whose disk is much slower than a
/// development machine's. Tests alternate the test clock with short real
/// delays so IO started from a frame can finish; on CI those delays were
/// sometimes too short and a different test failed each run.
final int realIoScale = Platform.environment['CI'] == 'true' ? 4 : 1;

/// A real delay of [ms] milliseconds, scaled by [realIoScale].
Future<void> realIoPause(int ms) =>
    Future<void>.delayed(Duration(milliseconds: ms * realIoScale));
