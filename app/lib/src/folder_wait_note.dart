// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart';

import 'notebook.dart';

/// A thin line across the top of the window, shown exactly while an action
/// waits on a stalled folder ([Notebook.waitingForFolder]). It is not a
/// snackbar, so it never replaces or closes another notice.
class FolderWaitNote extends StatelessWidget {
  const FolderWaitNote({super.key, required this.notebook});

  final Notebook notebook;

  /// The note's text.
  static const String text = 'Waiting for the folder…';

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: notebook.waitingForFolder,
      builder: (context, waiting, _) {
        if (!waiting) return const SizedBox.shrink();
        final m = NotedMetrics.of(context);
        final scheme = Theme.of(context).colorScheme;
        final small = NotedTypography.of(context).small;
        return Semantics(
          container: true,
          liveRegion: true,
          child: DecoratedBox(
            key: const ValueKey('waiting-for-folder'),
            decoration: BoxDecoration(color: NotedColors.of(context).bgSidebar),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: m.space6, vertical: m.space1),
              child: Row(
                children: [
                  SizedBox(
                    width: m.icon * 0.7,
                    height: m.icon * 0.7,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: m.space2),
                  Text(text, style: small.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
