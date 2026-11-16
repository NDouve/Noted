// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;

import 'onedrive_folder_picker.dart';
import 'onedrive_section.dart' show OneDriveIssuesPage;
import 'webdav_sync.dart';

/// The WebDAV folder in About (mobile), beside the OneDrive section: the
/// server address, user name and app password, then a folder of the server;
/// once connected, the folder's status, *Check now* and *Disconnect*. The
/// password is never shown again and is kept in the keychain or keystore.
class WebDavSection extends StatefulWidget {
  const WebDavSection({super.key, required this.sync});

  final WebDavSync sync;

  @override
  State<WebDavSection> createState() => _WebDavSectionState();
}

class _WebDavSectionState extends State<WebDavSection> {
  final _address = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    WebDavLogin? login;
    try {
      login = await widget.sync.checkLogin(
        address: _address.text,
        user: _user.text,
        password: _password.text,
      );
      if (!mounted) return;
      final picked = await pickOneDriveFolder(
        context,
        login.source,
        providerName: 'WebDAV',
      );
      if (picked != null && mounted) {
        error = await widget.sync.connect(login, picked);
      }
      if (error == null && picked != null && mounted) _password.clear();
    } on WebDavLoginException catch (e) {
      error = e.message;
    } on Object catch (e) {
      error = explainWebDavError(e);
    } finally {
      login?.close();
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = NotedMetrics.of(context);
    final sync = widget.sync;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final conn = sync.connection;
        final muted = theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );
        final issues = sync.issues.length;
        return Column(
          key: const ValueKey('dav-section'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(),
            Text('WebDAV folder', style: theme.textTheme.titleSmall),
            SizedBox(height: m.space1),
            if (conn != null) ...[
              Text(
                conn.path,
                key: const ValueKey('dav-path'),
                style: theme.textTheme.bodyMedium,
              ),
              SizedBox(height: m.space1),
            ],
            if (conn != null || sync.connectionUnreadable || sync.hasProblem)
              Text(
                sync.statusLine,
                key: const ValueKey('dav-status'),
                style: muted,
              ),
            if (sync.canConnect) ...[
              Text(
                'Pulls a folder from your server. It is read-only here for now.',
                key: const ValueKey('dav-note'),
                style: muted,
              ),
              SizedBox(height: m.space2),
              TextField(
                key: const ValueKey('dav-address'),
                controller: _address,
                enabled: !_busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Server address',
                  hintText: 'https://example.com/dav/',
                ),
              ),
              TextField(
                key: const ValueKey('dav-user'),
                controller: _user,
                enabled: !_busy,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'User name'),
              ),
              TextField(
                key: const ValueKey('dav-password'),
                controller: _password,
                enabled: !_busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'App password'),
              ),
              if (_error != null)
                Padding(
                  padding: EdgeInsets.only(top: m.space2),
                  child: Text(
                    _error!,
                    key: const ValueKey('dav-error'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              SizedBox(height: m.space2),
              FilledButton(
                key: const ValueKey('dav-connect'),
                onPressed: _busy ? null : () => unawaited(_connect()),
                child: Text(
                  _busy ? 'Connecting…' : 'Connect and choose folder',
                ),
              ),
            ],
            if (conn != null) ...[
              SizedBox(height: m.space2),
              Row(
                children: [
                  OutlinedButton(
                    key: const ValueKey('dav-check-now'),
                    onPressed: sync.checking
                        ? null
                        : () => unawaited(sync.checkNow()),
                    child: const Text('Check now'),
                  ),
                  if (issues > 0) ...[
                    SizedBox(width: m.space2),
                    TextButton(
                      key: const ValueKey('dav-issues'),
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => OneDriveIssuesPage(sync: sync),
                        ),
                      ),
                      child: Text(issues == 1 ? '1 issue' : '$issues issues'),
                    ),
                  ],
                  const Spacer(),
                  TextButton(
                    key: const ValueKey('dav-disconnect'),
                    onPressed: () => unawaited(sync.disconnect()),
                    child: const Text('Disconnect'),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}
