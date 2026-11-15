// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/services.dart';

/// A caption button of the custom Windows title bar.
enum CaptionButton { none, minimize, maximize, close }

/// The window state the native runner reports while the custom frame is on.
class WindowFrameState {
  const WindowFrameState({
    this.maximized = false,
    this.active = true,
    this.hovered = CaptionButton.none,
    this.pressed = CaptionButton.none,
    this.dpi = 96,
  });

  final bool maximized;
  final bool active;
  final CaptionButton hovered;
  final CaptionButton pressed;
  final int dpi;

  factory WindowFrameState.fromMap(Map<Object?, Object?> map) {
    CaptionButton button(Object? v) => CaptionButton.values.firstWhere(
      (b) => b.name == v,
      orElse: () => CaptionButton.none,
    );
    return WindowFrameState(
      maximized: map['maximized'] == true,
      active: map['active'] != false,
      hovered: button(map['hovered']),
      pressed: button(map['pressed']),
      dpi: map['dpi'] is int ? map['dpi'] as int : 96,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WindowFrameState &&
      other.maximized == maximized &&
      other.active == active &&
      other.hovered == hovered &&
      other.pressed == pressed &&
      other.dpi == dpi;

  @override
  int get hashCode => Object.hash(maximized, active, hovered, pressed, dpi);
}

/// The Windows runner's custom title bar, over the `noted/window` channel.
///
/// The frame is off until [enable] is called: before that the window is a
/// normal captioned window. Every call is a no-op where there is no native
/// side (other platforms, tests without a fake channel).
class WindowChannel {
  WindowChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('noted/window') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;

  /// Latest state from the runner (the default until it reports).
  WindowFrameState state = const WindowFrameState();

  /// Called when the runner reports a new [state].
  void Function(WindowFrameState state)? onState;

  /// Called when a non-client mouse button goes down (a title-bar drag, a
  /// caption button or the window menu): close menus as on a click-away.
  void Function()? onNcPointerDown;

  Future<void> _onCall(MethodCall call) async {
    if (call.method == 'state' && call.arguments is Map) {
      state = WindowFrameState.fromMap(call.arguments as Map<Object?, Object?>);
      onState?.call(state);
    } else if (call.method == 'ncPointerDown') {
      onNcPointerDown?.call();
    }
  }

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      // No native runner side.
    }
  }

  /// Turns the custom frame on (or off). Call before the first frame to avoid
  /// a flash of the native caption.
  Future<void> enable([bool enabled = true]) =>
      _invoke('enable', {'enabled': enabled});

  /// Reports, in logical pixels in the client area, where the caption buttons
  /// and the interactive title-bar controls are. Everything else in the top
  /// 40 px is the draggable caption.
  Future<void> setCaptionRects({
    Rect? minimize,
    Rect? maximize,
    Rect? close,
    List<Rect> interactive = const [],
  }) {
    List<double> rect(Rect r) => [r.left, r.top, r.right, r.bottom];
    return _invoke('setCaptionRects', {
      'buttons': {
        if (minimize != null) 'minimize': rect(minimize),
        if (maximize != null) 'maximize': rect(maximize),
        if (close != null) 'close': rect(close),
      },
      'interactive': [for (final r in interactive) rect(r)],
    });
  }

  Future<void> minimize() => _invoke('minimize');

  Future<void> toggleMaximize() => _invoke('toggleMaximize');

  /// Posts WM_CLOSE, so the normal exit checks run.
  Future<void> close() => _invoke('close');

  /// Asks the runner for its state and stores it in [state].
  Future<WindowFrameState> refreshState() async {
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getState',
      );
      if (map != null) state = WindowFrameState.fromMap(map);
    } on MissingPluginException {
      // No native runner side.
    }
    return state;
  }

  void dispose() => _channel.setMethodCallHandler(null);
}
