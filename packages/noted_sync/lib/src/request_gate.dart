// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'clock.dart';

/// The gate every request of one client goes through: at most [maxInFlight]
/// at once, and a shared pause after 429 and 503. The pause is the server's
/// `Retry-After`; without one it is 2 s, doubling up to 5 min until a request
/// gets through ([reset]).
class RequestGate {
  RequestGate({required this.clock, this.maxInFlight = 4});

  final int maxInFlight;
  final Clock clock;

  static const Duration _firstBackoff = Duration(seconds: 2);
  static const Duration _maxBackoff = Duration(minutes: 5);

  int _inFlight = 0;
  final List<Completer<void>> _slotWaiters = [];
  DateTime? _pausedUntil;
  Duration? _backoff;

  /// A request got an answer that wasn't a throttle: the back-off starts over.
  void reset() => _backoff = null;

  /// The wait a `Retry-After` header asks for (seconds or an HTTP date), or
  /// null when it has none or isn't understood.
  Duration? retryAfter(String? v) {
    if (v == null) return null;
    final s = int.tryParse(v.trim());
    if (s != null) return Duration(seconds: s < 0 ? 0 : s);
    try {
      final d = HttpDate.parse(v).difference(clock.now().toUtc());
      return d.isNegative ? Duration.zero : d;
    } catch (_) {
      return null;
    }
  }

  /// All requests wait: for [wait], or the next step of the back-off.
  void pause(Duration? wait) {
    final Duration d;
    if (wait != null) {
      d = wait;
    } else {
      final doubled = _backoff == null ? _firstBackoff : _backoff! * 2;
      _backoff = doubled > _maxBackoff ? _maxBackoff : doubled;
      d = _backoff!;
    }
    final until = clock.now().add(d);
    if (_pausedUntil == null || until.isAfter(_pausedUntil!)) {
      _pausedUntil = until;
    }
  }

  Future<void> _waitPause() async {
    while (true) {
      final until = _pausedUntil;
      if (until == null) return;
      final left = until.difference(clock.now());
      if (left <= Duration.zero) {
        _pausedUntil = null;
        return;
      }
      await clock.delay(left);
    }
  }

  /// Waits out a pause and takes a slot; pair every call with [leave].
  Future<void> enter() async {
    while (true) {
      await _waitPause();
      if (_inFlight >= maxInFlight) {
        final c = Completer<void>();
        _slotWaiters.add(c);
        await c.future;
        continue;
      }
      _inFlight++;
      // A pause may have started while this waited; it applies to all.
      final until = _pausedUntil;
      if (until != null && until.isAfter(clock.now())) {
        leave();
        continue;
      }
      return;
    }
  }

  void leave() {
    _inFlight--;
    if (_slotWaiters.isNotEmpty) _slotWaiters.removeAt(0).complete();
  }
}
