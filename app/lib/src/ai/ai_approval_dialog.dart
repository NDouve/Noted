// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;

import 'ai_link_authority.dart';

/// Shows the question (app, read or write, label; then Allow or Deny) in the app window and
/// returns the answer. Nothing is allowed without a window, so it answers
/// false if there is none. The dialog closes itself when the request stops
/// waiting ([AiApprovalRequest.expired]).
Future<bool> showAiApprovalDialog(GlobalKey<NavigatorState> navigator, AiApprovalRequest request) async {
  final context = navigator.currentContext;
  if (context == null || !context.mounted) return false;
  final answer = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AiApprovalDialog(request: request),
  );
  return answer ?? false;
}

class AiApprovalDialog extends StatefulWidget {
  const AiApprovalDialog({super.key, required this.request});

  final AiApprovalRequest request;

  @override
  State<AiApprovalDialog> createState() => _AiApprovalDialogState();
}

class _AiApprovalDialogState extends State<AiApprovalDialog> {
  @override
  void initState() {
    super.initState();
    unawaited(
      widget.request.expired.then((_) {
        // Only this dialog's own route, never whatever is on top of it.
        if (!mounted) return;
        final route = ModalRoute.of(context);
        if (route != null) Navigator.of(context).removeRoute(route, false);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final space = NotedMetrics.of(context).space3;
    return AlertDialog(
      key: const ValueKey('ai-approval-dialog'),
      title: Text(r.perWrite ? 'Allow this write?' : 'Allow this AI connection?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.message, key: const ValueKey('ai-approval-message')),
          if (r.preview != null) ...[
            SizedBox(height: space),
            Text(
              r.preview!,
              key: const ValueKey('ai-approval-preview'),
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: [
        // Both are secondary buttons: Allow is not the heavier choice.
        OutlinedButton(
          key: const ValueKey('ai-approval-deny'),
          // A stray Enter must not allow a request nobody expected.
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Deny'),
        ),
        OutlinedButton(
          key: const ValueKey('ai-approval-allow'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Allow'),
        ),
      ],
    );
  }
}
