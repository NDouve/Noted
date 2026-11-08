// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;

import 'onedrive_folder_picker.dart';
import 'onedrive_sync.dart';

/// The OneDrive folder in the hidden Microsoft section of About (mobile, signed
/// in): choose the folder once, then its status and *Check now*.
class OneDriveSection extends StatelessWidget {
  const OneDriveSection({super.key, required this.sync});

  final OneDriveSync sync;

  Future<void> _choose(BuildContext context) async {
    final picked = await pickOneDriveFolder(context, sync.folders);
    if (picked != null) await sync.choose(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = NotedMetrics.of(context);
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final chosen = sync.chosen;
        final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        final issues = sync.issues.length;
        return Column(
          key: const ValueKey('od-section'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: m.space3),
            Text('OneDrive folder', style: theme.textTheme.titleSmall),
            SizedBox(height: m.space1),
            if (chosen != null) ...[
              Text(chosen.path, key: const ValueKey('od-path'), style: theme.textTheme.bodyMedium),
              SizedBox(height: m.space1),
            ],
            if (chosen != null || sync.chosenUnreadable || sync.hasProblem)
              Text(sync.statusLine, key: const ValueKey('od-status'), style: muted),
            if (sync.canChoose) ...[
              SizedBox(height: m.space2),
              FilledButton(
                key: const ValueKey('od-choose'),
                onPressed: () => unawaited(_choose(context)),
                child: const Text('Choose OneDrive folder'),
              ),
            ],
            if (chosen != null) ...[
              SizedBox(height: m.space2),
              Row(
                children: [
                  OutlinedButton(
                    key: const ValueKey('od-check-now'),
                    onPressed: sync.checking ? null : () => unawaited(sync.checkNow()),
                    child: const Text('Check now'),
                  ),
                  if (issues > 0) ...[
                    SizedBox(width: m.space2),
                    TextButton(
                      key: const ValueKey('od-issues'),
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(builder: (_) => OneDriveIssuesPage(sync: sync)),
                      ),
                      child: Text(issues == 1 ? '1 issue' : '$issues issues'),
                    ),
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

/// What the pull left alone, as a plain list of path and reason.
class OneDriveIssuesPage extends StatelessWidget {
  const OneDriveIssuesPage({super.key, required this.sync});

  final OneDriveSync sync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = NotedMetrics.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('OneDrive issues')),
      body: ListenableBuilder(
        listenable: sync,
        builder: (context, _) {
          final issues = sync.issues;
          if (issues.isEmpty) {
            return Center(child: Text('Nothing is left alone.', key: const ValueKey('od-no-issues'), style: theme.textTheme.bodyMedium));
          }
          return ListView(
            padding: EdgeInsets.all(m.space3),
            children: [
              for (final i in issues)
                Padding(
                  padding: EdgeInsets.only(bottom: m.space3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(i.path, style: theme.textTheme.bodyMedium),
                      Text(
                        i.reason,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
