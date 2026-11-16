// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

import 'canvas_context_menu.dart';
import 'noted_colors.dart';
import 'noted_theme.dart';

/// Slots in the ring, 60 degrees apart, clockwise from the top.
const int radialSlots = 6;

/// A slot's visual and its padded target (the target is what takes a tap).
const Size radialSlotSize = Size(132, 32);
const Size radialSlotTarget = Size(132, 40);

/// The Cancel button in the middle of the ring (its target).
const Size radialCancelSize = Size(68, 36);

/// The room the ring's main menu needs round its centre.
const Size radialBounds = Size(380, 284);

/// The safety margin kept between the ring's bounds and the canvas edge.
const double radialMargin = 8;

/// The slot index the keyboard holds when it is on Cancel.
const int radialCancel = -1;

/// The centre of slot [i] on a ring of [radius] round [centre]: 60 degrees
/// apart, slot 0 at the top, clockwise.
Offset radialSlotCentre(Offset centre, double radius, int i) {
  final a = i * math.pi / 3;
  return centre + Offset(math.sin(a), -math.cos(a)) * radius;
}

/// The ring's centre for a menu pointed at [anchor]: the anchor, clamped so the
/// 380 x 284 bounds stay inside [within] inset by 8; null if they don't fit
/// (the caller then shows the list). The world target doesn't move with it.
Offset? radialCentre(Offset anchor, Rect within) {
  final room = within.deflate(radialMargin);
  final halfW = radialBounds.width / 2;
  final halfH = radialBounds.height / 2;
  if (room.width < radialBounds.width || room.height < radialBounds.height) {
    return null;
  }
  return Offset(
    anchor.dx.clamp(room.left + halfW, room.right - halfW).toDouble(),
    anchor.dy.clamp(room.top + halfH, room.bottom - halfH).toDouble(),
  );
}

/// The ring: six fixed slots (a missing one stays blank) and Cancel in the
/// middle.
class RadialMenuView extends StatelessWidget {
  const RadialMenuView._({
    required this.centre,
    required this.radius,
    required this.slots,
    required this.at,
    required this.keyboard,
    required this.onRun,
    required this.onCancel,
    required this.onHover,
  });

  /// The ring for [slots] (six, null for an empty one), or null if it doesn't
  /// fit [within]. [at] is the slot the keyboard is on ([radialCancel] for
  /// Cancel).
  static Widget? maybe(
    BuildContext context, {
    required List<ContextEntry?> slots,
    required Offset anchor,
    required Rect within,
    required int? at,
    required bool keyboard,
    required void Function(ContextEntry e) onRun,
    required VoidCallback onCancel,
    required void Function(int slot) onHover,
  }) {
    final centre = radialCentre(anchor, within);
    if (centre == null) return null;
    return RadialMenuView._(
      centre: centre,
      radius: NotedMetrics.of(context).contextRingRadius,
      slots: slots,
      at: at,
      keyboard: keyboard,
      onRun: onRun,
      onCancel: onCancel,
      onHover: onHover,
    );
  }

  final Offset centre;
  final double radius;
  final List<ContextEntry?> slots;
  final int? at;
  final bool keyboard;
  final void Function(ContextEntry e) onRun;
  final VoidCallback onCancel;
  final void Function(int slot) onHover;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      role: SemanticsRole.menu,
      label: 'Context menu',
      // A Material gives the text its base style (no fallback underline).
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          key: const ValueKey('radial-menu'),
          children: [
            for (final (i, e) in slots.indexed)
              if (e != null)
                Positioned.fromRect(
                  rect: Rect.fromCenter(
                    center: radialSlotCentre(centre, radius, i),
                    width: radialSlotTarget.width,
                    height: radialSlotTarget.height,
                  ),
                  child: _Pill(
                    tapKey: ValueKey('radial-${e.command.id}'),
                    text: e.text,
                    size: radialSlotSize,
                    enabled: e.enabled,
                    destructive: e.destructive,
                    lit: at == i,
                    outlined: at == i && keyboard,
                    onTap: () => onRun(e),
                    onHover: () => onHover(i),
                  ),
                ),
            Positioned.fromRect(
              rect: Rect.fromCenter(
                center: centre,
                width: radialCancelSize.width,
                height: radialCancelSize.height,
              ),
              child: _Pill(
                tapKey: const ValueKey('ring-cancel'),
                text: 'Cancel',
                size: radialCancelSize,
                enabled: true,
                destructive: false,
                lit: at == radialCancel,
                outlined: at == radialCancel && keyboard,
                onTap: onCancel,
                onHover: () => onHover(radialCancel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One slot or Cancel: a [size] visual centred in its (padded) target. The
/// label is shortened to fit but the semantics keep it whole.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.tapKey,
    required this.text,
    required this.size,
    required this.enabled,
    required this.destructive,
    required this.lit,
    required this.outlined,
    required this.onTap,
    required this.onHover,
  });

  final Key tapKey;
  final String text;
  final Size size;
  final bool enabled;
  final bool destructive;
  final bool lit;
  final bool outlined;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final colors = NotedColors.of(context);
    final type = NotedTypography.of(context);
    final on = enabled;
    final active = lit && on;
    final fg = !on
        ? colors.textDisabled
        : active
        ? scheme.primary
        : destructive
        ? scheme.error
        : scheme.onSurface;
    return Semantics(
      button: true,
      role: SemanticsRole.menuItem,
      selected: lit,
      enabled: on,
      label: text,
      excludeSemantics: true,
      onTap: on ? onTap : null,
      child: MouseRegion(
        onHover: (_) => onHover(),
        child: GestureDetector(
          key: tapKey,
          behavior: HitTestBehavior.opaque,
          onTap: on ? onTap : null,
          child: Center(
            child: DecoratedBox(
              key: outlined ? const ValueKey('context-focus') : null,
              decoration: BoxDecoration(
                color: active ? scheme.primaryContainer : scheme.surface,
                borderRadius: m.borderMd,
                border: Border.all(
                  color: outlined ? scheme.primary : colors.outlineControl,
                  width: outlined ? 2 : 1,
                ),
              ),
              child: SizedBox.fromSize(
                size: size,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      text,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: type.label.copyWith(
                        color: fg,
                        fontWeight: active ? FontWeight.w700 : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
