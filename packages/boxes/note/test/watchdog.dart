// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';

/// Runs [body], failing the whole test run if it doesn't finish in [limit].
///
/// A test timeout can't catch an app that freezes in a synchronous loop: the
/// loop never yields, so the timer behind the timeout never runs. The
/// watchdog runs in its own isolate, with its own event loop, and exits the
/// test process with an error when the limit passes.
Future<void> withWatchdog(
  WidgetTester tester,
  String name,
  Duration limit,
  Future<void> Function() body,
) async {
  final isolate = await tester.runAsync(
    () => Isolate.spawn(_watch, (name, limit.inMilliseconds)),
  );
  try {
    await body();
  } finally {
    isolate?.kill(priority: Isolate.immediate);
  }
}

void _watch((String, int) args) {
  final (name, ms) = args;
  Timer(Duration(milliseconds: ms), () {
    stderr.writeln(
      'WATCHDOG: "$name" did not finish within $ms ms. The code under test '
      'is stuck (the app would freeze here). Failing the run.',
    );
    exit(1);
  });
}
