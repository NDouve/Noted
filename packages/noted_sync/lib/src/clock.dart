// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Time for the sync code, so tests can run throttling waits and the 30 s
/// delete rule without waiting.
abstract class Clock {
  DateTime now();

  /// Completes after [d] has passed on this clock.
  Future<void> delay(Duration d);
}

class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();

  @override
  Future<void> delay(Duration d) => Future<void>.delayed(d);
}
