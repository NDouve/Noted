// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/test_watchdog.dart';

void main() {
  // Blocks the isolate for good, as a synchronous retry loop would. Run on
  // request only: `NOTED_WATCHDOG_DEMO=1 NOTED_WATCHDOG_SECONDS=5 flutter test
  // test/watchdog_test.dart`. The watchdog must end the process with code 1.
  test(
    'the watchdog ends a test blocked in a synchronous wait',
    () {
      stepForTest('about to block');
      while (true) {
        sleep(const Duration(milliseconds: 100));
      }
    },
    skip: Platform.environment['NOTED_WATCHDOG_DEMO'] == '1'
        ? false
        : 'on request: set NOTED_WATCHDOG_DEMO=1',
  );
}
