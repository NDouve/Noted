// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

/// A scrolling [child] that shows a rule and a soft shade along its bottom
/// edge while more content continues below, so a long panel does not look cut
/// off (the same cue as the settings panel's).
class AiScrollCue extends StatefulWidget {
  const AiScrollCue({super.key, required this.child});

  final Widget child;

  @override
  State<AiScrollCue> createState() => _AiScrollCueState();
}

class _AiScrollCueState extends State<AiScrollCue> {
  bool _more = false;

  bool _update(ScrollMetrics metrics, int depth) {
    // Only this panel's own scroll view, not a nested scrollable's.
    if (depth != 0) return false;
    final more = metrics.extentAfter > 0.5;
    if (more != _more) {
      // Notifications can arrive during layout.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && more != _more) setState(() => _more = more);
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _update(n.metrics, n.depth),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) => _update(n.metrics, n.depth),
        child: Stack(
          children: [
            SingleChildScrollView(child: widget.child),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  key: const ValueKey('ai-scroll-cue'),
                  opacity: _more ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [scheme.surface.withValues(alpha: 0), scheme.shadow.withValues(alpha: 0.12)],
                      ),
                    ),
                    child: const SizedBox(height: 16),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
