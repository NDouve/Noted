// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart';

import 'notebook.dart';
import 'save_trouble.dart' show TroubleKind;

/// Height of the status strip under the canvas (ui-spec §1).
const double statusStripHeight = 34;

/// The strip under the canvas: only status the notebook already has. A save
/// trouble, else the reason the page is read-only, else nothing. There is no
/// "saved" state to show (D6), so a healthy page leaves the strip empty.
class StatusStrip extends StatelessWidget {
  const StatusStrip({super.key, required this.notebook});

  final Notebook notebook;

  /// The line for the notebook's current state; null when there is none.
  static String? textFor(Notebook nb) {
    final t = nb.trouble;
    if (t.isTrouble) {
      return switch (t.kind) {
        TroubleKind.failing => "Couldn't save this page",
        TroubleKind.recoveryFailing => 'Changes exist only on screen',
        TroubleKind.preview => "Kept changes haven't been saved to this page",
        TroubleKind.saved => null,
      };
    }
    final why = nb.readOnlyReason;
    return why == null ? null : 'Read-only: $why';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = NotedMetrics.of(context);
    final small = NotedTypography.of(context).small.copyWith(color: scheme.onSurfaceVariant);
    return ListenableBuilder(
      listenable: notebook,
      builder: (context, _) {
        final text = textFor(notebook);
        return SizedBox(
          key: const ValueKey('status-strip'),
          height: statusStripHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface,
              border: Border(top: BorderSide(color: scheme.outline)),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: m.space4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: text == null
                    ? null
                    : Text(
                        text,
                        key: const ValueKey('status-strip-text'),
                        style: small,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}
