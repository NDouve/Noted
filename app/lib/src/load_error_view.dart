// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart';

/// Shown in place of the page when the notebook's first load failed or is
/// taking too long (see `Notebook.loadChecked`): what went wrong, and Retry.
class LoadErrorView extends StatelessWidget {
  const LoadErrorView({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    final type = NotedTypography.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(m.space6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Noted can't open your notes.", key: const ValueKey('load-error-title'), style: type.bodyStrong),
              SizedBox(height: m.space2),
              SelectableText(
                '$error',
                key: const ValueKey('load-error-text'),
                style: type.body.copyWith(color: scheme.error),
              ),
              SizedBox(height: m.space4),
              FilledButton(
                key: const ValueKey('load-error-retry'),
                autofocus: true,
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
