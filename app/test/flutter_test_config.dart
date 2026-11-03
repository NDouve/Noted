// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:noted/src/device_storage.dart';

/// `flutter test` reports Android as the platform; run tests as desktop
/// unless one picks a platform (see [testsDefaultToDesktop]).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  testsDefaultToDesktop = true;
  await testMain();
}
