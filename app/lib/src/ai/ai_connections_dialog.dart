// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics, notedDestructiveButtonStyle;
import 'package:noted_core/noted_core.dart' show AiConnectionInfo;

import '../app_settings.dart';

/// Gear menu → AI connections: the list, with add, rename and revoke.
Future<void> showAiConnectionsDialog(BuildContext context, AppSettings settings) {
  return showDialog<void>(
    context: context,
    builder: (context) => AiConnectionsDialog(settings: settings),
  );
}

class AiConnectionsDialog extends StatefulWidget {
  const AiConnectionsDialog({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<AiConnectionsDialog> createState() => _AiConnectionsDialogState();
}

enum _Stage { list, naming, token }

class _AiConnectionsDialogState extends State<AiConnectionsDialog> {
  final TextEditingController _name = TextEditingController();
  _Stage _stage = _Stage.list;

  // Why the last change could not be saved.
  String? _error;

  @override
  void initState() {
    super.initState();
    // Another Noted on this computer may have changed the list.
    widget.settings.refreshAiConnections();
  }

  // The new token, only while it is on screen. It is dropped when the dialog
  // moves on; Noted keeps just its hash.
  String? _token;
  bool _copied = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final String token;
    try {
      token = await widget.settings.addAiConnection(name);
    } on SettingsSaveException catch (e) {
      // Nothing was saved, so there is no token to show.
      if (mounted) setState(() => _error = e.message);
      return;
    }
    if (!mounted) return;
    setState(() {
      _error = null;
      _token = token;
      _copied = false;
      _stage = _Stage.token;
    });
  }

  void _done() {
    setState(() {
      _token = null;
      _error = null;
      _name.clear();
      _stage = _Stage.list;
    });
  }

  Future<void> _copy() async {
    final token = _token;
    if (token == null) return;
    await Clipboard.setData(ClipboardData(text: token));
    if (mounted) setState(() => _copied = true);
  }

  Future<void> _rename(AiConnectionInfo c) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(initial: c.name),
    );
    if (name != null) _saving(() => widget.settings.renameAiConnection(c.id, name));
  }

  void _saving(void Function() change) {
    try {
      change();
      if (_error != null) setState(() => _error = null);
    } on SettingsSaveException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _revoke(AiConnectionInfo c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Revoke ${_label(c)}?'),
        content: Text(
          '${_label(c)} can no longer read its boxes or write. '
          'Its boxes keep their text and become yours.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          OutlinedButton(
            key: const ValueKey('ai-revoke-confirm'),
            style: notedDestructiveButtonStyle(context),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if ((ok ?? false) && mounted) _saving(() => widget.settings.revokeAiConnection(c.id));
  }

  static String _label(AiConnectionInfo c) => c.name.isEmpty ? 'Unnamed connection' : c.name;

  static String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  @override
  Widget build(BuildContext context) {
    // The token is shown once: a click outside or Escape must not close it.
    return PopScope(
      canPop: _stage != _Stage.token,
      child: switch (_stage) {
        _Stage.list => _list(context),
        _Stage.naming => _naming(context),
        _Stage.token => _tokenShown(context),
      },
    );
  }

  Widget? _errorText(BuildContext context) => _error == null
      ? null
      : Text(
          _error!,
          key: const ValueKey('ai-error'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        );

  Widget _list(BuildContext context) {
    final m = NotedMetrics.of(context);
    return AlertDialog(
      title: const Text('AI connections'),
      content: SizedBox(
        width: 440,
        child: ValueListenableBuilder<List<AiConnectionInfo>>(
          valueListenable: widget.settings.aiConnections,
          builder: (context, list, _) {
            final error = _errorText(context);
            if (list.isEmpty) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('No AI connections yet. Add one to let an AI app write into its own AI boxes.'),
                  ?error,
                ],
              );
            }
            return ListView(
              shrinkWrap: true,
              children: [
                ?error,
                for (final c in list)
                  ListTile(
                    key: ValueKey('ai-connection-${c.id}'),
                    dense: true,
                    leading: Icon(Icons.key_rounded, size: m.icon),
                    title: Text(_label(c), overflow: TextOverflow.ellipsis),
                    subtitle: Text('Created ${_date(c.createdAt)}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: ValueKey('ai-rename-${c.id}'),
                          tooltip: 'Rename',
                          icon: Icon(Icons.edit_rounded, size: m.icon),
                          onPressed: () => _rename(c),
                        ),
                        IconButton(
                          key: ValueKey('ai-revoke-${c.id}'),
                          tooltip: 'Revoke',
                          icon: Icon(Icons.block_rounded, size: m.icon),
                          onPressed: () => _revoke(c),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('ai-add'),
          onPressed: () => setState(() => _stage = _Stage.naming),
          child: const Text('Add'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }

  Widget _naming(BuildContext context) {
    return AlertDialog(
      title: const Text('Add an AI connection'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('ai-name'),
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'Claude Code'),
              onSubmitted: (_) => _create(),
            ),
            if (_error != null) ...[
              SizedBox(height: NotedMetrics.of(context).space2),
              ?_errorText(context),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _done, child: const Text('Cancel')),
        FilledButton(key: const ValueKey('ai-create'), onPressed: _create, child: const Text('Create')),
      ],
    );
  }

  Widget _tokenShown(BuildContext context) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Token'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: EdgeInsets.all(m.space3),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(m.radiusMd),
              ),
              child: SelectableText(
                _token ?? '',
                key: const ValueKey('ai-token'),
                style: text.bodyMedium?.copyWith(fontFamily: 'monospace'),
              ),
            ),
            SizedBox(height: m.space2),
            Text('Copy it now: Noted won\'t show it again.', style: text.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          key: const ValueKey('ai-copy'),
          onPressed: _copy,
          icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded, size: m.icon),
          label: Text(_copied ? 'Copied' : 'Copy'),
        ),
        FilledButton(key: const ValueKey('ai-token-done'), onPressed: _done, child: const Text('Done')),
      ],
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() => Navigator.pop(context, _name.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename connection'),
      content: SizedBox(
        width: 380,
        child: TextField(
          key: const ValueKey('ai-rename-name'),
          controller: _name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (_) => _save(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('ai-rename-save'), onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
