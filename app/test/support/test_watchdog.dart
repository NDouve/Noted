// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:test_api/hooks.dart' show TestHandle;

// A watchdog for the whole app test run. The per-test timeout (`dart_test.yaml`)
// is a timer on the test's own event loop, so a test blocked in a synchronous
// wait never sees it fire. The watchdog isolate has its own loop: every test
// file's process starts one (from `flutter_test_config.dart`), each test
// reports its start and end, and when one test has run for three minutes the
// watchdog prints what it knows and exits the process with code 1.
//
// What it can print: the test's name, its last step (see [stepForTest]) and
// how long ago that was. It can not print the blocked isolate's stack: that
// needs the VM service (`package:vm_service`, which is not a dependency of
// the app). The last step says how far the test got.
//
// `NOTED_WATCHDOG_SECONDS` sets the limit (default 180), `NOTED_WATCHDOG=0`
// turns it off.

SendPort? _toWatchdog;

/// Records that the running test reached [step]; the watchdog prints the last
/// one when it fires. Cheap (one message), a no-op when the watchdog is off.
void stepForTest(String step) => _toWatchdog?.send(('step', step));

/// Starts the watchdog isolate and registers the per-test hooks. Call once per
/// test file, from `testExecutable`, before the tests are registered.
Future<void> startTestWatchdog() async {
  if (Platform.environment['NOTED_WATCHDOG'] == '0') return;
  final seconds =
      int.tryParse(Platform.environment['NOTED_WATCHDOG_SECONDS'] ?? '') ?? 180;
  final handshake = ReceivePort();
  await Isolate.spawn(_watch, (handshake.sendPort, seconds));
  final port = await handshake.first as SendPort;
  _toWatchdog = port;

  setUp(() {
    port.send(('start', TestHandle.current.name));
  });
  tearDown(() {
    port.send(('end', ''));
  });
}

void _watch((SendPort, int) args) {
  final (reply, seconds) = args;
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);

  String? test;
  var step = '(no step logged)';
  final started = Stopwatch();
  final stepped = Stopwatch();

  inbox.listen((Object? m) {
    final (kind, text) = m! as (String, String);
    switch (kind) {
      case 'start':
        test = text;
        step = '(no step logged)';
        started
          ..reset()
          ..start();
        stepped
          ..reset()
          ..start();
      case 'step':
        step = text;
        stepped
          ..reset()
          ..start();
      case 'end':
        test = null;
        started.stop();
    }
  });

  Timer.periodic(const Duration(seconds: 1), (_) {
    final name = test;
    if (name == null || started.elapsed.inSeconds < seconds) return;
    stderr.writeln(
      'WATCHDOG: test "$name" has run for ${started.elapsed.inSeconds} s '
      '(limit $seconds s) and its isolate is not responding: it is blocked, '
      'probably in a synchronous wait.\n'
      'WATCHDOG: last step: $step (${stepped.elapsed.inSeconds} s ago).\n'
      'WATCHDOG: the blocked isolate\'s stack is not available here (it needs '
      'the VM service). Failing the run.',
    );
    exit(1);
  });
}
