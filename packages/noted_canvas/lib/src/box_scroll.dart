// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Wrap a box's internally scrolling content in this.
///
/// Inside a box the wheel scrolls the box, but Ctrl+wheel must still zoom
/// the canvas. Flutter's scrollables claim the wheel whatever the modifier
/// keys, so the physics here refuse scrolling while Ctrl is held.
class BoxScrollScope extends StatelessWidget {
  const BoxScrollScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context);
    return ScrollConfiguration(
      behavior: behavior.copyWith(
        physics: _YieldToCanvasZoom(parent: behavior.getScrollPhysics(context)),
      ),
      child: child,
    );
  }
}

class _YieldToCanvasZoom extends ScrollPhysics {
  const _YieldToCanvasZoom({super.parent});

  @override
  _YieldToCanvasZoom applyTo(ScrollPhysics? ancestor) =>
      _YieldToCanvasZoom(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) =>
      !HardwareKeyboard.instance.isControlPressed &&
      super.shouldAcceptUserOffset(position);
}
