// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;
import 'package:noted_core/noted_core.dart' show UnreadablePage;

import 'notebook.dart';
import 'recovery_store.dart' show RecoveryListing;

/// How long quitting waits to list the recovery entries before giving up.
const recoveryListingTimeout = Duration(seconds: 3);

/// On quit: if edits are waiting in the recovery folder, tells the user so.
/// Resolves when the notice is dismissed (or at once if there is nothing to
/// say, or no window to show it in); quitting is never refused.
Future<void> showRecoveryNoticeOnExit(
  Notebook notebook,
  GlobalKey<NavigatorState> navigator, {
  Duration listingTimeout = recoveryListingTimeout,
}) async {
  // A recovery or page folder on an unresponsive drive must not hold up
  // quitting: past the timeout nothing is assumed, and the notice says so.
  final RecoveryListing? listing = await notebook
      .pendingRecovery()
      .then<RecoveryListing?>((l) => l)
      .timeout(listingTimeout, onTimeout: () => null);
  // The abandoned listing may still finish settling its temp files; its result
  // is ignored. The in-memory notices are known without the drive.
  if (listing == null) return _showCouldNotCheck(navigator, _rows(notebook.recoveryOwnDamaged));
  final pages = {for (final e in listing.entries) e.pageId}.length;
  // The same files and reasons as the sidebar's "Can't open" list.
  final problems = _rows([...listing.damaged, ...notebook.recoveryOwnDamaged]);
  final landedLeft = notebook.landedEntryLeft;
  if (pages == 0 && problems.isEmpty && !landedLeft) return;
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
                    ? "1 page couldn't be saved yet. "
                          'It is kept safely and will be saved automatically when its folder is available.'
                    : "$pages pages couldn't be saved yet. "
                          'They are kept safely and will be saved automatically when their folder is available.',
              ),
            if (landedLeft) ...[
              if (pages > 0) SizedBox(height: NotedMetrics.of(context).space3),
              const Text(
                'One recovered page may show boxes you deleted since: its kept copy was saved '
                'but could not be removed.',
                key: ValueKey('recovery-exit-landed'),
              ),
            ],
            if (problems.isNotEmpty) ...[
              if (pages > 0 || landedLeft) SizedBox(height: NotedMetrics.of(context).space3),
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

/// The notice for a listing that did not finish in time: recovery could not be
/// checked. Nothing is touched; edits kept in the recovery folder stay there.
/// [problems] are the notices held in memory only, which would be lost at quit.
Future<void> _showCouldNotCheck(
  GlobalKey<NavigatorState> navigator,
  List<String> problems,
) async {
  final context = navigator.currentContext;
  if (context == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('recovery-exit-unchecked'),
      title: const Text('Recovery could not be checked'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Noted couldn't check for unsaved edits because a folder didn't respond. "
              'Recovery files on disk are left as they are and are checked again the next time Noted starts.',
            ),
            if (problems.isNotEmpty) ...[
              SizedBox(height: NotedMetrics.of(context).space3),
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

/// "name: reason" rows, as in the sidebar's "Can't open" list.
List<String> _rows(List<UnreadablePage> damaged) => [
  for (final u in damaged) '${u.path.split(RegExp(r'[\\/]')).last}: ${u.reason}',
];
