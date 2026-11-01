// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart'
    show NotedMetrics, notedDestructiveButtonStyle;
import 'package:noted_core/noted_core.dart';

import 'ai_box_access.dart';
import 'ai_focus_ring.dart';

/// Box header → connections: the box's codes (approved or not), the Writer
/// permission, the Ask before each write and closed-app write switches, and
/// the activity list.
Future<void> showAiConnectionsDialog(
  BuildContext context,
  AiBoxAccess access,
  String boxId,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => AiConnectionsDialog(access: access, boxId: boxId),
  );
}

/// The most activity entries listed (newest first).
const int aiActivityShown = 100;

String _two(int n) => n.toString().padLeft(2, '0');

String _date(DateTime t) {
  final d = t.toLocal();
  return '${d.year}-${_two(d.month)}-${_two(d.day)}';
}

String _dateTime(DateTime t) {
  final d = t.toLocal();
  return '${_date(t)} ${_two(d.hour)}:${_two(d.minute)}';
}

String _sentence(String s) {
  final t = s.replaceAll('_', ' ');
  return t.isEmpty ? t : '${t[0].toUpperCase()}${t.substring(1)}';
}

/// The name of a Writer permission choice and its one-line explanation.
(String, String) aiPermissionText(AiWriterPermission p) => switch (p) {
  AiWriterPermission.append => (
    'Append only',
    'The AI can add text at the end of this box.',
  ),
  AiWriterPermission.edit => (
    'Edit',
    'Append, and change text the AI wrote itself.',
  ),
  AiWriterPermission.full => (
    'Full',
    'Also replace the whole box and delete its text.',
  ),
};

/// The wording of a code's approval.
String aiApprovalLabel(AiCode c) =>
    c.approved == null ? 'Not approved yet' : 'Approved ${_date(c.approved!)}';

/// The wording of a code's role.
String aiRoleLabel(AiCode c) => switch (c.role) {
  AiCodeRole.writer => 'Writer',
  AiCodeRole.reader => 'Reader',
  null => 'Unknown role',
};

class AiConnectionsDialog extends StatefulWidget {
  const AiConnectionsDialog({super.key, required this.access, required this.boxId});

  final AiBoxAccess access;
  final String boxId;

  @override
  State<AiConnectionsDialog> createState() => _AiConnectionsDialogState();
}

class _AiConnectionsDialogState extends State<AiConnectionsDialog> {
  AiBoxAccess get access => widget.access;
  String get boxId => widget.boxId;

  // Why the last change could not be made, for the user.
  String? _error;

  /// Runs a change of the store; a failure shows in the panel (a generic
  /// message, never a path).
  Future<void> _run(Future<void> Function() change) async {
    try {
      await change();
      if (mounted && _error != null) setState(() => _error = null);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is StateError ? e.message : 'Could not save the change.');
      }
    }
  }

  Future<void> _revoke(BuildContext context, AiCode c) async {
    final label = c.label.isEmpty ? 'this connection' : c.label;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Revoke $label?'),
        content: const Text('This chat can no longer read or write this box.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            key: const ValueKey('ai-revoke-confirm'),
            style: notedDestructiveButtonStyle(context),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (ok ?? false) await _run(() => access.revoke(c.id));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Connections'),
      content: SizedBox(
        width: 520,
        child: ListenableBuilder(
          listenable: access,
          builder: (context, _) => SingleChildScrollView(child: _body(context)),
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('ai-connections-close'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _body(BuildContext context) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final now = DateTime.now();
    final codes = access.connections(boxId);
    final activity = access.activity(boxId).reversed.take(aiActivityShown).toList();
    final problem = access.problem;
    final ask = access.askBeforeWrite(boxId);
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (problem != null) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline_rounded, size: m.icon, color: scheme.onSurfaceVariant),
              SizedBox(width: m.space2),
              Expanded(
                child: Text(
                  problem,
                  key: const ValueKey('ai-problem'),
                  style: text.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            ],
          ),
          SizedBox(height: m.space3),
        ],
        if (_error != null) ...[
          Text(
            _error!,
            key: const ValueKey('ai-change-error'),
            style: text.bodySmall?.copyWith(color: scheme.error),
          ),
          SizedBox(height: m.space3),
        ],
        if (codes.isEmpty)
          Text(
            'No chats are connected to this box yet. '
            'Use Connect a chat in the box header.',
            key: const ValueKey('ai-no-codes'),
            style: muted,
          )
        else
          for (final c in codes) _codeRow(context, c, now),
        SizedBox(height: m.space2),
        _permission(context),
        SizedBox(height: m.space2),
        FocusVisibleRing(
          child: SwitchListTile(
            key: const ValueKey('ai-ask-switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Ask before each write'),
            subtitle: Text(
              'Noted asks you to allow every write to this box.',
              style: muted,
            ),
            value: ask,
            onChanged: (v) => _run(() async {
              // Turning Ask on also turns closed-app writes off, so turning
              // Ask off later doesn't silently bring them back.
              if (v) await access.setClosedWrites(boxId, false);
              await access.setAskBeforeWrite(boxId, v);
            }),
          ),
        ),
        FocusVisibleRing(
          child: SwitchListTile(
            key: const ValueKey('ai-closed-switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Allow writes while Noted is closed (no approval)'),
            subtitle: Text(
              ask
                  ? 'Not available while Ask before each write is on.'
                  : 'While Noted is closed, the AI writes without asking you, '
                        'within the Writer permission above.',
              key: const ValueKey('ai-closed-note'),
              style: ask ? muted : muted?.copyWith(color: scheme.error),
            ),
            value: access.closedWrites(boxId),
            onChanged: ask ? null : (v) => _run(() => access.setClosedWrites(boxId, v)),
          ),
        ),
        SizedBox(height: m.space2),
        Text('Activity', style: text.titleSmall),
        SizedBox(height: m.space1),
        if (activity.isEmpty)
          Text('Nothing yet.', key: const ValueKey('ai-no-activity'), style: muted)
        else
          for (var i = 0; i < activity.length; i++) _activityRow(context, i, activity[i]),
      ],
    );
  }

  Widget _permission(BuildContext context) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final current = access.writerPermission(boxId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Writer permission', style: text.titleSmall),
        for (final p in AiWriterPermission.values)
          MergeSemantics(
            child: Semantics(
              inMutuallyExclusiveGroup: true,
              checked: p == current,
              child: FocusVisibleRing(
                child: ListTile(
                  key: ValueKey('ai-permission-${p.wire}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    p == current
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: m.icon,
                    color: scheme.onSurfaceVariant,
                  ),
                  title: Text(aiPermissionText(p).$1),
                  subtitle: Text(aiPermissionText(p).$2, style: muted),
                  onTap: () => _run(() => access.setWriterPermission(boxId, p)),
                ),
              ),
            ),
          ),
        if (current == AiWriterPermission.edit)
          Padding(
            padding: EdgeInsets.only(top: m.space1),
            child: Text(
              "Text the AI wrote stays the AI's even if you bold or tick it, "
              'so the AI may replace it. Once you change a block\'s words or '
              'type, it is yours and the AI can\'t replace it.',
              key: const ValueKey('ai-permission-edit-note'),
              style: muted,
            ),
          ),
      ],
    );
  }

  Widget _codeRow(BuildContext context, AiCode c, DateTime now) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final expired = c.isExpired(now);
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final facts = [
      aiRoleLabel(c),
      'Created ${_date(c.created)}',
      c.lastUsed == null ? 'Never used' : 'Last used ${_dateTime(c.lastUsed!)}',
      if (c.expires != null && !expired) 'Expires ${_date(c.expires!)}',
    ].join(' · ');
    return Padding(
      padding: EdgeInsets.only(bottom: m.space3),
      child: Column(
        key: ValueKey('ai-code-${c.id}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.key_rounded, size: m.icon, color: scheme.onSurfaceVariant),
              SizedBox(width: m.space2),
              Expanded(
                child: Text(
                  c.label.isEmpty ? 'Unnamed connection' : c.label,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (expired)
                Padding(
                  padding: EdgeInsets.only(right: m.space2),
                  child: Text('Expired', key: ValueKey('ai-expired-${c.id}'), style: muted),
                ),
              IconButton(
                key: ValueKey('ai-revoke-${c.id}'),
                tooltip: 'Revoke',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.block_rounded, size: m.icon, color: scheme.onSurfaceVariant),
                onPressed: () => _revoke(context, c),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(left: m.icon + m.space2),
            child: Text(facts, key: ValueKey('ai-facts-${c.id}'), style: muted),
          ),
          if (!expired)
            Padding(
              padding: EdgeInsets.only(left: m.icon + m.space2),
              child: Text(
                aiApprovalLabel(c),
                key: ValueKey('ai-approval-${c.id}'),
                style: muted,
              ),
            ),
        ],
      ),
    );
  }

  Widget _activityRow(BuildContext context, int index, AiActivityEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final style = text.bodySmall;
    final what = [
      _sentence(e.op),
      if (e.app.isNotEmpty) e.app,
      if (e.label.isNotEmpty) e.label,
      if (e.extra['closed'] == true) 'while Noted was closed',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        key: ValueKey('ai-activity-$index'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _dateTime(e.time),
            style: style?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(what, style: style)),
          const SizedBox(width: 8),
          Text(
            e.ok ? 'OK' : _sentence(e.result),
            style: style?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
