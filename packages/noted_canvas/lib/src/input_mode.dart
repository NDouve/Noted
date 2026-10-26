// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Whether the last pointer input was touch. Controls grow to `touch-target`
/// (44px) and rows and menu items to 40px while it is true (see
/// `docs/design/README.md`, "Dense but touchable").
///
/// One process-wide instance, [InputModeNotifier.instance], is updated by an
/// [InputModeScope] at the top of the widget tree. The app rebuilds its theme
/// from it (`notedThemeData(brightness, touch: ...)`), so every widget that
/// reads `NotedMetrics` follows.
class InputModeNotifier extends ValueNotifier<bool> {
  InputModeNotifier([super.touch = false]);

  /// The shared instance.
  static final InputModeNotifier instance = InputModeNotifier();

  /// Records the kind of device behind the last pointer event: touch is
  /// touch; a mouse, trackpad, stylus or anything else is not.
  void onPointer(PointerDeviceKind kind) {
    value = kind == PointerDeviceKind.touch;
  }
}

/// Watches every pointer event below it and keeps [notifier] up to date.
/// Put it above the navigator so menus and dialogs are covered.
class InputModeScope extends StatelessWidget {
  const InputModeScope({super.key, this.notifier, required this.child});

  /// Defaults to [InputModeNotifier.instance].
  final InputModeNotifier? notifier;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final n = notifier ?? InputModeNotifier.instance;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => n.onPointer(e.kind),
      onPointerHover: (e) => n.onPointer(e.kind),
      child: child,
    );
  }
}
