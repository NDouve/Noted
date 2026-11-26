// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:test_api/hooks.dart' show TestHandle;

// A watchdog for the whole app test run. The per-test timeout (`dart_test.yaml`)
// is a timer on the test's own event loop, so a test blocked in a synchronous
// wait never sees it fire. The watchdog isolate has its own loop. Every test
// file's process starts one (from `flutter_test_config.dart`); each test
// reports its start, and the watchdog pings the test isolate every second.
// A slow test that still answers is left to its own timeout. The watchdog
// fires only when a test has run for three minutes AND the test isolate has
// not answered a ping for the last 30 seconds: it prints what it knows and
// exits the process with code 1.
//
// What it can print: the test's name, its last step (see [stepForTest]) and
// how long ago that was. It can not print the blocked isolate's stack: that
// needs the VM service (`package:vm_service`, which the app does not use).
// The last step says how far the test got.
//
// `NOTED_WATCHDOG_SECONDS` sets the test limit (default 180),
// `NOTED_WATCHDOG_BLOCKED_SECONDS` how long without an answer (default 30, at
// most the test limit), `NOTED_WATCHDOG=0` turns it off. A test file's setUpAll
// and tearDownAll are covered too: a test stays current until the next starts.

SendPort? _toWatchdog;

/// Whether the watchdog fails the run: the test has run for [limit] and its
/// isolate has not answered a ping for [blocked]. Either alone is not enough:
/// a slow test that keeps answering is left to its own timeout, and a short
/// silence is only a busy moment.
bool shouldFire({
  required Duration testElapsed,
  required Duration sinceLastAnswer,
  required Duration limit,
  required Duration blocked,
}) => testElapsed >= limit && sinceLastAnswer >= blocked;

/// Records that the running test reached [step]; the watchdog prints the last
/// one when it fires. Cheap (one message), a no-op when the watchdog is off.
void stepForTest(String step) => _toWatchdog?.send(('step', step));

/// Starts the watchdog isolate and registers the per-test hooks. Call once per
/// test file, from `testExecutable`, before the tests are registered.
Future<void> startTestWatchdog() async {
  if (Platform.environment['NOTED_WATCHDOG'] == '0') return;
  final seconds =
      int.tryParse(Platform.environment['NOTED_WATCHDOG_SECONDS'] ?? '') ?? 180;
  final blocked = min(
    seconds,
    int.tryParse(
          Platform.environment['NOTED_WATCHDOG_BLOCKED_SECONDS'] ?? '',
        ) ??
        30,
  );
  final handshake = ReceivePort();
  // The watchdog's pings come here; each is answered with the same message
  // back, which only happens while this isolate's event loop runs.
  final pings = ReceivePort();
  await Isolate.spawn(_watch, (
    handshake.sendPort,
    pings.sendPort,
    seconds,
    blocked,
  ));
  final port = await handshake.first as SendPort;
  pings.listen((Object? m) => (m! as SendPort).send(('alive', '')));
  _toWatchdog = port;

  setUpAll(() {
    port.send(('start', '(setUpAll of the file)'));
  });
  setUp(() {
    port.send(('start', TestHandle.current.name));
  });
  tearDownAll(() {
    port.send(('end', ''));
  });
}

void _watch((SendPort, SendPort, int, int) args) {
  final (reply, pings, seconds, blockedSeconds) = args;
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);

  String? test;
  var step = '(no step logged)';
  final started = Stopwatch();
  final stepped = Stopwatch();
  final silent = Stopwatch()..start(); // since the last answer

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
      case 'alive':
        silent
          ..reset()
          ..start();
      case 'end':
        test = null;
        started.stop();
    }
  });

  Timer.periodic(const Duration(seconds: 1), (_) {
    pings.send(inbox.sendPort);
    final name = test;
    if (name == null ||
        !shouldFire(
          testElapsed: started.elapsed,
          sinceLastAnswer: silent.elapsed,
          limit: Duration(seconds: seconds),
          blocked: Duration(seconds: blockedSeconds),
        )) {
      return;
    }
    stderr.writeln(
      'WATCHDOG: test "$name" has run for ${started.elapsed.inSeconds} s '
      '(limit $seconds s) and its isolate has not answered for '
      '${silent.elapsed.inSeconds} s: it is blocked, probably in a synchronous '
      'wait.\n'
      'WATCHDOG: last step: $step (${stepped.elapsed.inSeconds} s ago).\n'
      "WATCHDOG: the blocked isolate's stack is not available here (it needs "
      'the VM service). Failing the run.',
    );
    exit(1);
  });
}
