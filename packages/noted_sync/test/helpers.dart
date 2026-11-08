// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:noted_sync/noted_sync.dart';

/// A clock that moves only when told to. In manual mode a [delay] stays
/// pending until [release].
class FakeClock implements Clock {
  FakeClock({this.manual = false});

  final bool manual;
  DateTime _now = DateTime.utc(2026, 1, 1);
  final List<Duration> delays = [];
  final List<(Duration, Completer<void>)> pending = [];
  void Function(Duration d)? onDelay;

  @override
  DateTime now() => _now;

  @override
  Future<void> delay(Duration d) {
    delays.add(d);
    onDelay?.call(d);
    if (!manual) {
      _now = _now.add(d);
      return Future<void>.value();
    }
    final c = Completer<void>();
    pending.add((d, c));
    return c.future;
  }

  void advance(Duration d) => _now = _now.add(d);

  /// Moves time past every pending delay and lets them finish.
  void release() {
    var most = Duration.zero;
    for (final (d, _) in pending) {
      if (d > most) most = d;
    }
    _now = _now.add(most);
    final all = List.of(pending);
    pending.clear();
    for (final (_, c) in all) {
      c.complete();
    }
  }
}
