// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

/// Runs the body at once and records every call; a test can refuse calls.
class RecordingCoordinator implements StorageCoordinator {
  final List<CoordinatedWrite> calls = [];

  /// When set, `coordinate` throws it without starting the body.
  Object? refuse;

  /// Runs inside the call, before the body (a fake daemon's work).
  Future<void> Function(CoordinatedWrite write)? beforeBody;

  @override
  Future<T> coordinate<T>(
    CoordinatedWrite write,
    Future<T> Function() body,
  ) async {
    // A call made from inside another call's body is a nested hook: the
    // primitives must reach each other only through uncoordinated forms.
    if (Zone.current[#notedCoordinating] == true) {
      throw StateError('re-entrant coordinated call: $write');
    }
    calls.add(write);
    final r = refuse;
    if (r != null) throw r;
    return runZoned(() async {
      await beforeBody?.call(write);
      return body();
    }, zoneValues: {#notedCoordinating: true});
  }
}

/// The real path of the system temp folder, where every test folder is made.
String get tempRoot => Directory.systemTemp.resolveSymbolicLinksSync();

/// Runs [suite] twice: with nothing registered, and with a pass-through
/// coordinator registered for the whole temp folder.
void runWithAndWithoutCoordinator(void Function() suite) {
  group('without a coordinator', suite);
  group('with a pass-through coordinator', () {
    final c = RecordingCoordinator();
    setUpAll(() => registerCoordinator(tempRoot, c));
    tearDownAll(() => unregisterCoordinator(tempRoot));
    suite();
    test('the coordinator was used', () => expect(c.calls, isNotEmpty));
  });
}
