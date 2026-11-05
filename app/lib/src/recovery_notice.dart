// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;

import 'notebook.dart';
import 'recovery_store.dart' show RecoveryListing;

/// On quit: if edits are waiting in the recovery folder, tells the user so.
/// Resolves when the notice is dismissed (or at once if there is nothing to
/// say, or no window to show it in); quitting is never refused.
Future<void> showRecoveryNoticeOnExit(Notebook notebook, GlobalKey<NavigatorState> navigator) async {
  // A recovery folder that can't be listed does not stop the rest: the pages whose
  // edits are held in memory are known without it.
  var listing = const RecoveryListing([], []);
  var pages = 0;
  var checked = true;
  try {
    listing = await notebook.pendingRecovery();
    pages = await notebook.pendingRecoveryPages();
  } on Object catch (e) {
    debugPrint('Checking the recovery folder on exit failed: $e');
    checked = false;
  }
  // The same files and reasons as the sidebar's "Can't open" list.
  final damaged = [...listing.damaged, ...notebook.recoveryOwnDamaged];
  final problems = [
    for (final u in damaged) '${u.path.split(RegExp(r'[\\/]')).last}: ${u.reason}',
  ];
  final lost = notebook.unsavedPageCount;
  if (pages == 0 && problems.isEmpty && lost == 0 && checked) return;
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
                    ? "1 page couldn't be saved. "
                          'It is kept safely and will be saved automatically when that works again.'
                    : "$pages pages couldn't be saved. "
                          'They are kept safely and will be saved automatically when that works again.',
              ),
            if (lost > 0) ...[
              if (pages > 0) SizedBox(height: NotedMetrics.of(context).space3),
              Text(
                lost == 1
                    ? "1 page couldn't be saved or kept. Its latest edits will be lost if you quit."
                    : "$lost pages couldn't be saved or kept. Their latest edits will be lost if you quit.",
              ),
            ],
            if (!checked) ...[
              if (pages > 0 || lost > 0) SizedBox(height: NotedMetrics.of(context).space3),
              const Text("The recovery folder couldn't be read, so edits kept in it couldn't be checked."),
            ],
            if (problems.isNotEmpty) ...[
              if (pages > 0 || lost > 0) SizedBox(height: NotedMetrics.of(context).space3),
              const Text("Can't open:"),
              for (final p in problems) Text(p, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('recovery-exit-ok'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Quit'),
        ),
      ],
    ),
  );
}
