// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

/// A coordinator for tests: it runs every call's body at once and records the
/// call, except the ones [refuse] says to refuse, which throw a [StorageBusy]
/// without starting the body.
///
/// A call made from inside another call's body is a nested hook, which the
/// design forbids (R5.4), so it throws.
class ScriptedCoordinator implements StorageCoordinator {
  final List<CoordinatedWrite> calls = [];

  /// Which calls to refuse; null refuses none.
  bool Function(CoordinatedWrite write)? refuse;

  @override
  Future<T> coordinate<T>(
    CoordinatedWrite write,
    Future<T> Function() body,
  ) async {
    if (Zone.current[#notedScripted] == true) {
      throw StateError('re-entrant coordinated call: $write');
    }
    calls.add(write);
    if (refuse?.call(write) ?? false) {
      throw StorageBusy(StorageBusyReason.coordination, [
        for (final i in write.intents) i.path,
      ]);
    }
    return runZoned(body, zoneValues: {#notedScripted: true});
  }

  /// The calls that name [path] (compared as given), with any kind.
  List<CoordinatedWrite> callsOn(String path) => [
    for (final c in calls)
      if (c.intents.any((i) => i.path == path)) c,
  ];
}

/// Registers [c] for [root] (resolved) until the test ends.
void registerScripted(Directory root, ScriptedCoordinator c) {
  final real = root.resolveSymbolicLinksSync();
  registerCoordinator(real, c);
  addTearDown(() => unregisterCoordinator(real));
}

/// Whether [w] is one write on [path] (a folder create or remove), the two
/// compared with `/` for every separator.
bool isOneWriteOn(CoordinatedWrite w, String path) =>
    w.intents.length == 1 &&
    w.intents.single.kind == CoordinationKind.write &&
    w.intents.single.path.replaceAll(r'\', '/') == path.replaceAll(r'\', '/');
