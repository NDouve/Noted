// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Wrap a box's internally scrolling content in this.
///
/// Inside a box the wheel and a two-finger touchpad scroll move the box's
/// content, not the canvas; Ctrl+wheel and pinch still zoom the canvas.
/// - Flutter's scrollables claim the wheel whatever the modifier keys, so
///   the physics here refuse scrolling while Ctrl is held.
/// - A touchpad scroll arrives as pan/zoom events, which nothing arbitrates
///   between nested widgets, so this claims the gesture ([TrackpadClaims])
///   when the content can scroll.
class BoxScrollScope extends StatelessWidget {
  const BoxScrollScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context);
    return Listener(
      onPointerPanZoomStart: (e) {
        if (_canScroll(context)) TrackpadClaims.claim(e.pointer);
      },
      child: ScrollConfiguration(
        behavior: behavior.copyWith(
          physics: _YieldToCanvasZoom(
            parent: behavior.getScrollPhysics(context),
          ),
        ),
        child: child,
      ),
    );
  }

  /// Whether a scrollable inside has anywhere to scroll.
  static bool _canScroll(BuildContext context) {
    var found = false;
    void visit(Element e) {
      if (found) return;
      if (e is StatefulElement && e.state is ScrollableState) {
        final p = (e.state as ScrollableState).position;
        if (p.hasContentDimensions && p.maxScrollExtent > p.minScrollExtent) {
          found = true;
          return;
        }
      }
      e.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return found;
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

/// Touchpad gestures a box has taken for itself.
///
/// A two-finger touchpad scroll arrives as pan/zoom events, not pointer
/// signals, so Flutter's pointer signal resolver doesn't decide who handles
/// it, and the canvas would pan while a box scrolls. Pointer events reach
/// the deepest widget first, so a box that scrolls claims the gesture when
/// it starts; the canvas then only zooms (pinch) for that gesture and
/// releases the claim when it ends.
abstract final class TrackpadClaims {
  static final Set<int> _claimed = {};

  static void claim(int pointer) => _claimed.add(pointer);

  static bool isClaimed(int pointer) => _claimed.contains(pointer);

  static void release(int pointer) => _claimed.remove(pointer);
}
