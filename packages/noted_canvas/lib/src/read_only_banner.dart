// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import 'noted_colors.dart';
import 'noted_theme.dart';

/// The banner across the top of a read-only page (BoxFrame guidelines): a
/// `conflict-soft` bar with `small` text that says why the page is read-only
/// and that edits are paused.
class ReadOnlyBanner extends StatelessWidget {
  const ReadOnlyBanner({super.key, required this.reason});

  /// Why the page is read-only, as a sentence.
  final String reason;

  /// The second half of the message.
  static const String paused = 'Edits are paused.';

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    final colors = NotedColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final small = NotedTypography.of(context).small;
    return Semantics(
      container: true,
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(color: colors.conflictSoft),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: m.space6,
            vertical: m.space2,
          ),
          child: Row(
            children: [
              Icon(Icons.lock_outline_rounded, size: m.icon, color: scheme.onSurface),
              SizedBox(width: m.space2),
              Flexible(
                child: Text(reason, style: small.copyWith(color: scheme.onSurface)),
              ),
              SizedBox(width: m.space2),
              Text(
                paused,
                style: small.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
