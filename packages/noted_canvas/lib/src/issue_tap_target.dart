// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

/// A click target for an issue warning (the corner icon, a box's chip): it
/// takes keyboard focus (Enter and Space activate it), shows a focus ring and
/// tells assistive technology what it does.
class IssueTapTarget extends StatefulWidget {
  const IssueTapTarget({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
    this.circle = false,
  });

  final String label;
  final VoidCallback onTap;
  final Widget child;

  /// The focus ring is a circle rather than a pill.
  final bool circle;

  @override
  State<IssueTapTarget> createState() => _IssueTapTargetState();
}

class _IssueTapTargetState extends State<IssueTapTarget> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final ring = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      focusable: true,
      focused: _focused,
      label: widget.label,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
              borderRadius: widget.circle ? null : BorderRadius.circular(999),
              border: _focused ? Border.all(color: ring, width: 2) : null,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
