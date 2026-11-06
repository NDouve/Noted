// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:noted_auth/noted_auth.dart' show AuthState;
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;

import 'microsoft_account.dart';

/// Taps on the about line that uncover the Microsoft account entry.
const int aboutTapsToReveal = 5;

/// "About Noted", with the preview Microsoft sign-in hidden behind five taps
/// on the first line. Only offered in a build that has a client id.
Future<void> showAboutNoted(BuildContext context, MicrosoftAccount microsoft) =>
    showDialog<void>(
      context: context,
      builder: (context) => AboutNotedDialog(microsoft: microsoft),
    );

class AboutNotedDialog extends StatefulWidget {
  const AboutNotedDialog({super.key, required this.microsoft});

  final MicrosoftAccount microsoft;

  @override
  State<AboutNotedDialog> createState() => _AboutNotedDialogState();
}

class _AboutNotedDialogState extends State<AboutNotedDialog> {
  int _taps = 0;

  void _tap() {
    if (++_taps >= aboutTapsToReveal) widget.microsoft.reveal();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('About Noted'),
      content: SizedBox(
        width: 380,
        child: ListenableBuilder(
          listenable: widget.microsoft,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                key: const ValueKey('about-line'),
                behavior: HitTestBehavior.opaque,
                onTap: _tap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Noted, an open-source notebook',
                    style: text.bodyMedium,
                  ),
                ),
              ),
              if (widget.microsoft.revealed)
                _MicrosoftSection(microsoft: widget.microsoft),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('about-close'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _MicrosoftSection extends StatelessWidget {
  const _MicrosoftSection({required this.microsoft});

  final MicrosoftAccount microsoft;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = NotedMetrics.of(context);
    final state = microsoft.state;
    final status = switch (state) {
      AuthState.signedOut => 'Signed out',
      AuthState.signedIn =>
        'Signed in as ${microsoft.displayName ?? 'your Microsoft account'}',
      AuthState.signInAgain => 'Sign in again',
    };
    final busy = microsoft.busy;
    return Column(
      key: const ValueKey('ms-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        Text('Microsoft account (preview)', style: theme.textTheme.titleSmall),
        SizedBox(height: m.space1),
        Text(
          busy ? 'Waiting for the browser…' : status,
          key: const ValueKey('ms-status'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (state == AuthState.signInAgain && !busy)
          Padding(
            padding: EdgeInsets.only(top: m.space1),
            child: Text(
              'Microsoft needs you to sign in again.',
              key: const ValueKey('ms-sign-in-again-note'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (microsoft.error != null)
          Padding(
            padding: EdgeInsets.only(top: m.space2),
            child: Text(
              microsoft.error!,
              key: const ValueKey('ms-error'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        SizedBox(height: m.space3),
        Row(
          children: [
            if (state != AuthState.signedIn)
              FilledButton(
                key: const ValueKey('ms-sign-in'),
                onPressed: busy ? null : () => unawaited(microsoft.signIn()),
                child: Text(
                  state == AuthState.signInAgain ? 'Sign in again' : 'Sign in',
                ),
              ),
            if (state != AuthState.signedOut) ...[
              if (state != AuthState.signedIn) SizedBox(width: m.space2),
              OutlinedButton(
                key: const ValueKey('ms-sign-out'),
                onPressed: busy ? null : () => unawaited(microsoft.signOut()),
                child: const Text('Sign out'),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
