// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

/// Shows the focus of a list tile in [child] the way the design system does
/// (a 2px accent outline) and only while the keyboard is driving focus
/// (focus-visible): the tile's own focus fill, which looks like a selection,
/// is switched off, and a click or tap shows nothing.
class FocusVisibleRing extends StatefulWidget {
  const FocusVisibleRing({super.key, required this.child, this.radius = 8});

  final Widget child;
  final double radius;

  @override
  State<FocusVisibleRing> createState() => _FocusVisibleRingState();
}

class _FocusVisibleRingState extends State<FocusVisibleRing> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_modeChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_modeChanged);
    super.dispose();
  }

  void _modeChanged(FocusHighlightMode _) {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _focused && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) => setState(() => _focused = f),
      child: Theme(
        data: theme.copyWith(focusColor: Colors.transparent),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            border: visible ? Border.all(color: theme.colorScheme.primary, width: 2) : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
