// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:noted/src/device_storage.dart';

import 'support/io_trace.dart';

/// `flutter test` reports Android as the platform; run tests as desktop
/// unless one picks a platform (see [testsDefaultToDesktop]).
///
/// With `NOTED_IO_TRACE=1` the file operations of every test are traced, so a
/// sharing violation reports what else touched the file (see [ioTraceEnabled]).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  testsDefaultToDesktop = true;
  // Global, not a zone override: the tests run in zones of the test runner's,
  // which a zone override set here does not reach.
  if (ioTraceEnabled) IOOverrides.global = TracingIoOverrides();
  await testMain();
}
