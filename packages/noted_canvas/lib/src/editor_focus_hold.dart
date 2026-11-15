// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';

/// A counter the host holds while it has moved keyboard focus away from a
/// box's editor for a moment (an app menu) and will give it back. Modules read
/// it as `CanvasController.editorFocusHeld`; only the host calls [hold] and
/// [release].
///
/// Each [hold] is matched by one [release]. A release with nothing held, or
/// after [dispose], does nothing.
class EditorFocusHold {
  final ValueNotifier<bool> _held = ValueNotifier(false);
  int _count = 0;
  bool _disposed = false;

  /// True while at least one hold is open.
  ValueListenable<bool> get held => _held;

  /// How many holds are open.
  int get count => _count;

  void hold() {
    if (_disposed) return;
    _count++;
    _held.value = true;
  }

  void release() {
    if (_disposed || _count == 0) return;
    _count--;
    _held.value = _count > 0;
  }

  void dispose() {
    _disposed = true;
    // Nothing is held by a controller that is gone.
    _count = 0;
    _held.value = false;
    _held.dispose();
  }
}
