// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;

import 'notebook.dart';

/// On quit: if edits are waiting in the recovery folder, tells the user so.
/// Resolves when the notice is dismissed (or at once if there is nothing to
/// say, or no window to show it in); quitting is never refused.
Future<void> showRecoveryNoticeOnExit(Notebook notebook, GlobalKey<NavigatorState> navigator) async {
  final listing = await notebook.pendingRecovery();
  final pages = listing.entries.length;
  final problems = listing.problems;
  if (pages == 0 && problems.isEmpty) return;
  final context = navigator.currentContext;
  if (context == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('recovery-exit-notice'),
      title: const Text('Some edits are not saved yet'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pages > 0)
              Text(
                pages == 1
                    ? "1 page couldn't be saved because its folder is unavailable. "
                          'It is kept safely and will be saved automatically when the folder is back.'
                    : "$pages pages couldn't be saved because their folder is unavailable. "
                          'They are kept safely and will be saved automatically when the folder is back.',
              ),
            if (problems.isNotEmpty) ...[
              if (pages > 0) SizedBox(height: NotedMetrics.of(context).space3),
              const Text("Can't open:"),
              for (final p in problems) Text(p, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('recovery-exit-ok'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Quit'),
        ),
      ],
    ),
  );
}
