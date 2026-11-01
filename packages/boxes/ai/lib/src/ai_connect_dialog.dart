// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;
import 'package:noted_core/noted_core.dart';

import 'ai_box_access.dart';
import 'ai_focus_ring.dart';

/// Box header → Connect a chat: choose Writer or Reader, name the connection
/// (and optionally let it expire), then show its code once.
Future<void> showAiConnectDialog(BuildContext context, AiBoxAccess access, String boxId) {
  return showDialog<void>(
    context: context,
    builder: (context) => AiConnectDialog(access: access, boxId: boxId),
  );
}

enum _Stage { role, details, code }

/// The days a new code lasts, 0 for never.
const List<int> aiExpiryDays = [0, 1, 7, 30];

String _expiryLabel(int days) => switch (days) {
  0 => 'None',
  1 => '1 day',
  _ => '$days days',
};

class AiConnectDialog extends StatefulWidget {
  const AiConnectDialog({super.key, required this.access, required this.boxId});

  final AiBoxAccess access;
  final String boxId;

  @override
  State<AiConnectDialog> createState() => _AiConnectDialogState();
}

class _AiConnectDialogState extends State<AiConnectDialog> {
  final TextEditingController _label = TextEditingController();
  _Stage _stage = _Stage.role;
  AiCodeRole _role = AiCodeRole.writer;
  int _days = 0;
  bool _busy = false;
  String? _error;

  // The code, only while it is on screen; Noted keeps just its hash.
  String? _code;
  String _codeLabel = '';
  bool _copied = false;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  void _choose(AiCodeRole role) => setState(() {
    _role = role;
    _error = null;
    _stage = _Stage.details;
  });

  Future<void> _create() async {
    final label = _label.text.trim();
    if (label.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final String code;
    try {
      code = await widget.access.connect(
        widget.boxId,
        role: _role,
        label: label,
        expires: _days == 0 ? null : DateTime.now().add(Duration(days: _days)),
      );
    } catch (e) {
      // Nothing was issued, so there is no code to show.
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is StateError ? e.message : 'Could not create the code.';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _code = code;
      _codeLabel = label;
      _copied = false;
      _stage = _Stage.code;
    });
  }

  Future<void> _copy() async {
    final code = _code;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) setState(() => _copied = true);
  }

  void _done() {
    // Drop the code with the dialog.
    _code = null;
    Navigator.pop(context);
  }

  AiCode? _currentWriter() {
    for (final c in widget.access.connections(widget.boxId)) {
      if (c.role == AiCodeRole.writer && !c.isRevoked) return c;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // The code is shown once: a click outside or Escape must not close it.
    return PopScope(
      canPop: _stage != _Stage.code && !_busy,
      child: switch (_stage) {
        _Stage.role => _roleStage(context),
        _Stage.details => _detailsStage(context),
        _Stage.code => _codeStage(context),
      },
    );
  }

  Widget _roleTile(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String title,
    required String body,
    required AiCodeRole role,
  }) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    return FocusVisibleRing(
      radius: m.radiusMd,
      child: ListTile(
        key: key,
        shape: RoundedRectangleBorder(
          borderRadius: m.borderMd,
          side: BorderSide(color: scheme.outlineVariant),
        ),
        leading: Icon(icon, size: m.icon, color: scheme.onSurfaceVariant),
        title: Text(title),
        subtitle: Text(body),
        onTap: () => _choose(role),
      ),
    );
  }

  Widget _roleStage(BuildContext context) {
    final m = NotedMetrics.of(context);
    return AlertDialog(
      title: const Text('Connect a chat'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _roleTile(
              context,
              key: const ValueKey('ai-role-writer'),
              icon: Icons.edit_note_rounded,
              title: 'Writer',
              body: 'Reads this box and writes into it. A box has one Writer.',
              role: AiCodeRole.writer,
            ),
            SizedBox(height: m.space2),
            _roleTile(
              context,
              key: const ValueKey('ai-role-reader'),
              icon: Icons.visibility_outlined,
              title: 'Reader',
              body: 'Reads this box only. A box can have any number of Readers.',
              role: AiCodeRole.reader,
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }

  Widget _detailsStage(BuildContext context) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final writer = _role == AiCodeRole.writer ? _currentWriter() : null;
    final isWriter = _role == AiCodeRole.writer;
    final problem = widget.access.problem;
    return AlertDialog(
      title: Text(isWriter ? 'Connect a Writer' : 'Connect a Reader'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('ai-label'),
                controller: _label,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Label',
                  hintText: 'Feedback – work chat',
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _create(),
              ),
              SizedBox(height: m.space4),
              Text('Expires', style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              SizedBox(height: m.space1),
              Wrap(
                spacing: m.space2,
                children: [
                  for (final d in aiExpiryDays)
                    ChoiceChip(
                      key: ValueKey('ai-expiry-$d'),
                      label: Text(_expiryLabel(d)),
                      selected: _days == d,
                      onSelected: (_) => setState(() => _days = d),
                    ),
                ],
              ),
              if (writer != null) ...[
                SizedBox(height: m.space4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded, size: m.icon, color: scheme.onSurfaceVariant),
                    SizedBox(width: m.space2),
                    Expanded(
                      child: Text(
                        'This box already has a Writer'
                        '${writer.label.isEmpty ? '' : ' (${writer.label})'}. '
                        'It stops working when you connect this one.',
                        key: const ValueKey('ai-writer-warning'),
                        style: text.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
              if (problem != null) ...[
                SizedBox(height: m.space2),
                Text(
                  problem,
                  key: const ValueKey('ai-problem'),
                  style: TextStyle(color: scheme.error),
                ),
              ],
              if (_error != null) ...[
                SizedBox(height: m.space2),
                Text(
                  _error!,
                  key: const ValueKey('ai-error'),
                  style: TextStyle(color: scheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('ai-connect-back'),
          onPressed: _busy ? null : () => setState(() => _stage = _Stage.role),
          child: const Text('Back'),
        ),
        FilledButton(
          key: const ValueKey('ai-connect-create'),
          onPressed: _label.text.trim().isEmpty || _busy || problem != null ? null : _create,
          child: const Text('Create code'),
        ),
      ],
    );
  }

  Widget _codeStage(BuildContext context) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text('Code for $_codeLabel', key: const ValueKey('ai-code-title')),
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
                _code ?? '',
                key: const ValueKey('ai-code'),
                style: text.bodyMedium?.copyWith(fontFamily: 'monospace'),
              ),
            ),
            SizedBox(height: m.space2),
            Text(
              'Copy it now: Noted shows it only once. '
              'It works only on this computer.',
              key: const ValueKey('ai-code-note'),
              style: text.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          key: const ValueKey('ai-copy'),
          onPressed: _copy,
          icon: Icon(
            _copied ? Icons.check_rounded : Icons.copy_rounded,
            size: m.icon,
            color: scheme.onSurfaceVariant,
          ),
          label: Text(_copied ? 'Copied' : 'Copy'),
        ),
        FilledButton(
          key: const ValueKey('ai-code-done'),
          onPressed: _done,
          child: const Text('Done'),
        ),
      ],
    );
  }
}
