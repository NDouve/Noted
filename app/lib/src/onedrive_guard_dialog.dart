// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;
import 'package:noted_sync/noted_sync.dart' show GuardQuestion;

/// "OneDrive says N pages were removed." with the list. True: remove them
/// here too. False: keep them here. Null never happens (the dialog can't be
/// dismissed without an answer).
Future<bool?> showOneDriveGuardDialog(BuildContext context, GuardQuestion question) =>
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => OneDriveGuardDialog(question: question),
    );

class OneDriveGuardDialog extends StatelessWidget {
  const OneDriveGuardDialog({super.key, required this.question});

  final GuardQuestion question;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = NotedMetrics.of(context);
    final n = question.paths.length;
    return AlertDialog(
      key: const ValueKey('onedrive-guard'),
      title: Text(
        n == 1 ? 'OneDrive says 1 page was removed.' : 'OneDrive says $n pages were removed.',
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in question.paths)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: m.space1 / 2),
                      child: Text(p, style: theme.textTheme.bodySmall),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('onedrive-guard-keep'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Keep them here'),
        ),
        FilledButton(
          key: const ValueKey('onedrive-guard-remove'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Remove them here too'),
        ),
      ],
    );
  }
}
