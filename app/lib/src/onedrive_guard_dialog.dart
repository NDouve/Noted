// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;
import 'package:noted_sync/noted_sync.dart' show GuardQuestion;

/// A guard dialog on screen: [answer] completes with true (remove them here
/// too) or false (keep them here), or with null when [close] took it away
/// because its question changed or went. System Back and a tap outside do
/// nothing, so a question is never left unanswered by accident.
class GuardPrompt {
  GuardPrompt._(this._navigator, this._route, this.answer);

  final NavigatorState _navigator;
  final DialogRoute<bool> _route;
  final Future<bool?> answer;

  /// Takes the dialog away without an answer.
  void close() {
    if (_route.isActive) _navigator.removeRoute(_route);
  }
}

/// "OneDrive says N pages were removed." with the list.
GuardPrompt showOneDriveGuardDialog(BuildContext context, GuardQuestion question) {
  final navigator = Navigator.of(context);
  final route = DialogRoute<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => OneDriveGuardDialog(question: question),
  );
  final answer = navigator.push<bool>(route);
  return GuardPrompt._(navigator, route, answer);
}

class OneDriveGuardDialog extends StatefulWidget {
  const OneDriveGuardDialog({super.key, required this.question});

  final GuardQuestion question;

  @override
  State<OneDriveGuardDialog> createState() => _OneDriveGuardDialogState();
}

class _OneDriveGuardDialogState extends State<OneDriveGuardDialog> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = NotedMetrics.of(context);
    final n = widget.question.paths.length;
    // System Back must not close it: only a button answers.
    return PopScope(
      canPop: false,
      child: AlertDialog(
        key: const ValueKey('onedrive-guard'),
        title: Text(n == 1 ? 'OneDrive says 1 page was removed.' : 'OneDrive says $n pages were removed.'),
        content: SizedBox(
          width: 380,
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: ListView(
              controller: _scroll,
              shrinkWrap: true,
              children: [
                for (final p in widget.question.paths)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: m.space1 / 2),
                    child: Text(p, style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          // The destructive choice is the secondary button, in the error colour;
          // keeping is the filled, safe default.
          OutlinedButton(
            key: const ValueKey('onedrive-guard-remove'),
            style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove them here too'),
          ),
          FilledButton(
            key: const ValueKey('onedrive-guard-keep'),
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep them here'),
          ),
        ],
      ),
    );
  }
}
