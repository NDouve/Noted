// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/test_watchdog.dart';

final bool _demo = Platform.environment['NOTED_WATCHDOG_DEMO'] == '1';

void main() {
  // Blocks the isolate for good, as a synchronous retry loop would. It runs
  // only in the child process of the test below (or on request:
  // `NOTED_WATCHDOG_DEMO=1 NOTED_WATCHDOG_SECONDS=5 flutter test
  // test/watchdog_test.dart`).
  test('the demo: blocked in a synchronous wait', () {
    stepForTest('about to block');
    while (true) {
      sleep(const Duration(milliseconds: 100));
    }
  }, skip: _demo ? false : 'on request: set NOTED_WATCHDOG_DEMO=1');

  // A slow test that still answers is not killed, however long it takes.
  test('a slow test that yields is left alone', () async {
    await Future<void>.delayed(const Duration(seconds: 4));
  }, skip: _demo ? 'the child process runs the demo only' : false);

  // The demo, run as a child `flutter test`: the watchdog must end it with
  // exit code 1 and say why on stderr.
  test(
    'the watchdog ends a test blocked in a synchronous wait',
    () async {
      final r = await Process.run(
        'flutter',
        ['test', 'test/watchdog_test.dart', '--plain-name', 'the demo'],
        runInShell: true,
        environment: {
          'NOTED_WATCHDOG_DEMO': '1',
          'NOTED_WATCHDOG_SECONDS': '5',
          'NOTED_WATCHDOG_BLOCKED_SECONDS': '3',
        },
      );
      final out = '${r.stdout}\n${r.stderr}';
      expect(
        out,
        contains('WATCHDOG: test "the demo: blocked in a synchronous wait"'),
      );
      expect(out, contains('last step: about to block'));
      expect(r.exitCode, isNot(0));
    },
    skip: _demo ? 'the child process runs the demo only' : false,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
