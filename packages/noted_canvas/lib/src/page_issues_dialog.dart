// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noted_core/noted_core.dart';

import 'canvas_controller.dart';
import 'noted_colors.dart';
import 'noted_theme.dart';
import 'page_ai_merge.dart';

/// Formats [ms] (since the epoch) as local `YYYY-MM-DD HH:MM`.
String formatConflictTime(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// Which pages the user silenced the issue sequence on, for one app run. The
/// issues themselves stay in the page file; this only says the sequence isn't
/// shown again when the page is opened again during this run.
class IssueSilence {
  final Set<String> _pages = {};

  bool isSilenced(String pageId) => _pages.contains(pageId);

  void silence(String pageId) => _pages.add(pageId);

  void clear(String pageId) => _pages.remove(pageId);
}

/// How the issue dialog ended.
enum IssueDialogEnd {
  /// Nothing is left to settle, or the box's own choice closed it.
  finished,

  /// "Place it": the landed box should be shown selected for moving.
  placed,

  /// Closed with Silence or Esc.
  silenced,
}

/// Shows the page's issues one after another (Next / Previous, "n of m"), or,
/// with [onlyBox], just that box's (run 2026-11-01-04). Each issue has its
/// explanation and its choices; each choice is one undo step.
///
/// [onPlace] is told which landed box the user chose to place, after the
/// dialog closed.
Future<IssueDialogEnd> showPageIssues(
  BuildContext context,
  CanvasController controller, {
  Set<String> disallowedTypes = const {},
  PageAiMerge? aiMerge,
  String? onlyBox,
  void Function(String boxId)? onPlace,
}) async {
  final end = await showDialog<IssueDialogEnd>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PageIssuesDialog(
      controller: controller,
      disallowedTypes: disallowedTypes,
      aiMerge: aiMerge,
      onlyBox: onlyBox,
      onPlace: onPlace,
    ),
  );
  return end ?? IssueDialogEnd.silenced;
}

enum _AiPhase { idle, waiting, proposal, failed }

/// The issue dialog's content. Public so tests can place it directly.
class PageIssuesDialog extends StatefulWidget {
  const PageIssuesDialog({
    super.key,
    required this.controller,
    this.disallowedTypes = const {},
    this.aiMerge,
    this.onlyBox,
    this.onPlace,
  });

  final CanvasController controller;

  /// Types the page disallows: their boxes are settled from snapshots, as for
  /// a module the device can't run (0035).
  final Set<String> disallowedTypes;

  /// The page AI's help, or null for none.
  final PageAiMerge? aiMerge;

  /// Show only this box's issues.
  final String? onlyBox;

  final void Function(String boxId)? onPlace;

  @override
  State<PageIssuesDialog> createState() => _PageIssuesDialogState();
}

class _PageIssuesDialogState extends State<PageIssuesDialog> {
  int _index = 0;

  _AiPhase _ai = _AiPhase.idle;
  String? _aiKey;
  AiMergeProposal? _proposal;
  String? _aiError;

  CanvasController get _c => widget.controller;
  bool get _single => widget.onlyBox != null;

  List<PageIssue> _issues() => [
    for (final i in _c.issues(disallowedTypes: widget.disallowedTypes))
      if (widget.onlyBox == null || i.boxId == widget.onlyBox) i,
  ];

  String _keyOf(PageIssue i) => '${i.boxId}/${i.kind.name}';

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _cancelAi();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final issues = _issues();
    if (issues.isEmpty) {
      _cancelAi();
      Navigator.of(context).pop(IssueDialogEnd.finished);
      return;
    }
    setState(() => _index = _index.clamp(0, issues.length - 1));
  }

  void _cancelAi() {
    final key = _aiKey;
    if (_ai == _AiPhase.waiting && key != null) {
      final slash = key.indexOf('/');
      widget.aiMerge?.cancel(_c.page.id, key.substring(0, slash));
    }
    _ai = _AiPhase.idle;
    _aiKey = null;
    _proposal = null;
    _aiError = null;
  }

  void _go(int to, List<PageIssue> issues) {
    if (to < 0 || to >= issues.length || to == _index) return;
    setState(() {
      _cancelAi();
      _index = to;
    });
  }

  /// Runs a resolution: whatever the AI was doing is cancelled first.
  void _resolve(void Function() action) {
    setState(_cancelAi);
    action();
    // The controller notified: the dialog moved on or closed in _changed.
  }

  void _ask(PageIssue issue) {
    final merge = widget.aiMerge;
    if (merge == null) return;
    final key = _keyOf(issue);
    setState(() {
      _ai = _AiPhase.waiting;
      _aiKey = key;
      _proposal = null;
      _aiError = null;
    });
    merge.ask(_c.page.id, issue.boxId).then(
      (p) {
        if (!mounted || _aiKey != key || _ai != _AiPhase.waiting) return;
        setState(() {
          _ai = _AiPhase.proposal;
          _proposal = p;
        });
      },
      onError: (Object e) {
        if (!mounted || _aiKey != key || _ai != _AiPhase.waiting) return;
        setState(() {
          _ai = _AiPhase.failed;
          _aiError = 'The page AI did not send a merge. Choose a version instead.';
        });
      },
    );
  }

  void _useProposal(PageIssue issue) {
    final p = _proposal;
    if (p == null) return;
    final ok = _c.resolveWithData(issue.boxId, p.data, conflict: issue.conflict);
    if (!ok) {
      setState(() {
        _ai = _AiPhase.failed;
        _proposal = null;
        _aiError = "The AI's merge could not be used. Choose a version instead.";
      });
    }
  }

  void _silence() => Navigator.of(context).pop(IssueDialogEnd.silenced);

  @override
  Widget build(BuildContext context) {
    final issues = _issues();
    if (issues.isEmpty) return const SizedBox.shrink();
    final index = _index.clamp(0, issues.length - 1);
    final issue = issues[index];
    final box = _c.page.node(issue.boxId);
    if (box is! BoxRecord) return const SizedBox.shrink();
    // A change of issue (after a resolution) drops a request made for another.
    if (_aiKey != null && _aiKey != _keyOf(issue)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(_cancelAi);
      });
    }
    final metrics = NotedMetrics.of(context);
    final title = switch (issue.kind) {
      PageIssueKind.landed => 'A box landed on another box',
      PageIssueKind.conflict => 'Conflicting changes',
      PageIssueKind.deleteConflict => 'Deleted on the other side',
      PageIssueKind.unreadableConflict => 'Conflicting changes in a box this device can’t open',
    };
    final showProposal = _ai == _AiPhase.proposal && _proposal != null;
    final width = MediaQuery.sizeOf(context).width - 120;

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _silence},
      child: Focus(
        autofocus: true,
        child: AlertDialog(
          key: const ValueKey('issues-dialog'),
          clipBehavior: Clip.antiAlias,
          titlePadding: EdgeInsets.zero,
          title: ConflictHeader(
            title: title,
            trailing: Semantics(
              label: 'Issue ${index + 1} of ${issues.length}',
              excludeSemantics: true,
              child: Text(
                '${index + 1} of ${issues.length}',
                key: const ValueKey('issues-count'),
              ),
            ),
          ),
          content: SizedBox(
            width: (showProposal ? 900.0 : 640.0).clamp(280.0, width < 280 ? 280.0 : width),
            child: SingleChildScrollView(child: _body(context, box, issue, showProposal)),
          ),
          actions: [
            TextButton(
              key: const ValueKey('issues-silence'),
              onPressed: _silence,
              child: Tooltip(
                message: 'Take notes now. The issues stay until you settle them.',
                child: Text(_single ? 'Close' : 'Silence'),
              ),
            ),
            SizedBox(width: metrics.space3),
            if (issues.length > 1) ...[
              TextButton(
                key: const ValueKey('issues-previous'),
                onPressed: index > 0 ? () => _go(index - 1, issues) : null,
                child: const Text('Previous'),
              ),
              TextButton(
                key: const ValueKey('issues-next'),
                onPressed: index < issues.length - 1 ? () => _go(index + 1, issues) : null,
                child: const Text('Next'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, BoxRecord box, PageIssue issue, bool showProposal) {
    final metrics = NotedMetrics.of(context);
    final theme = Theme.of(context);
    final id = box.id;
    final c = issue.conflict;

    Widget gap() => SizedBox(height: metrics.space3);

    if (issue.kind == PageIssueKind.landed) {
      final l = issue.landed!;
      final who = l.device == null ? 'another device' : l.device!;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This box arrived from $who while you were away and landed on top '
            'of another box.',
            key: const ValueKey('issue-explanation'),
          ),
          gap(),
          _Side(
            key: const ValueKey('issue-landed-box'),
            label: '$who${l.at > 0 ? ' · ${formatConflictTime(l.at)}' : ''}',
            text: box.snapshotText,
          ),
          gap(),
          Wrap(
            spacing: metrics.space2,
            runSpacing: metrics.space2,
            children: [
              OutlinedButton(
                key: const ValueKey('issue-leave'),
                onPressed: () => _resolve(() => _c.leaveLanded(id)),
                child: const Text('Leave it here'),
              ),
              FilledButton(
                key: const ValueKey('issue-place'),
                onPressed: () {
                  setState(_cancelAi);
                  Navigator.of(context).pop(IssueDialogEnd.placed);
                  widget.onPlace?.call(id);
                },
                child: const Text('Place it'),
              ),
            ],
          ),
        ],
      );
    }

    final deleted = issue.kind == PageIssueKind.deleteConflict;
    final unreadable = issue.kind == PageIssueKind.unreadableConflict;
    final otherNode = c?.node == null ? null : readNode(c!.node!, fallbackId: id);
    final otherText = switch (otherNode) {
      BoxRecord() => otherNode.snapshotText,
      ForeignNode() => otherNode.text ?? '',
      null => '',
    };
    final extra = box.conflicts.length - 1;
    final placeable = issue.otherPlaceable;
    final canAsk =
        issue.kind == PageIssueKind.conflict &&
        placeable &&
        widget.aiMerge?.available(_c.page.id, id) == true;
    final waiting = _ai == _AiPhase.waiting;
    final otherName = c?.device ?? (otherNode is BoxRecord ? otherNode.device : null);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          key: const ValueKey('issue-explanation'),
          deleted
              ? '${otherName ?? 'The other side'} deleted this box while it was '
                    'edited here. Keep it, or delete it too.'
              : unreadable
              ? 'This box was changed on both sides, and this device can’t open '
                    'this kind of box. The versions below are the saved previews. '
                    'Choose one, or keep both.'
              : 'This box was changed on both sides. Choose a version, or keep both.',
        ),
        gap(),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _Side(
                key: const ValueKey('conflict-mine'),
                label: _mineLabel(box),
                text: box.snapshotText,
              ),
            ),
            SizedBox(width: metrics.space3),
            Expanded(
              child: _Side(
                key: const ValueKey('conflict-theirs'),
                label: _theirsLabel(c, otherNode, deleted),
                text: deleted ? '(deleted)' : otherText,
              ),
            ),
            if (showProposal) ...[
              SizedBox(width: metrics.space3),
              Expanded(
                child: _Side(
                  key: const ValueKey('conflict-ai-proposal'),
                  label: _proposal!.by == null
                      ? 'The page AI’s merge (not applied yet)'
                      : 'Proposed by ${_proposal!.by} (not applied yet)',
                  text: _proposal!.markdown,
                ),
              ),
            ],
          ],
        ),
        if (extra > 0)
          Padding(
            padding: EdgeInsets.only(top: metrics.space3),
            child: Text(
              '$extra more version${extra == 1 ? '' : 's'} recorded; '
              '${extra == 1 ? 'it shows' : 'they show'} next.',
            ),
          ),
        if (waiting)
          Padding(
            padding: EdgeInsets.only(top: metrics.space3),
            child: Row(
              key: const ValueKey('conflict-ai-waiting'),
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: metrics.space2),
                const Expanded(
                  child: Text('Waiting for the page AI… Choosing something else cancels the request.'),
                ),
              ],
            ),
          ),
        if (_ai == _AiPhase.failed && _aiError != null)
          Padding(
            padding: EdgeInsets.only(top: metrics.space3),
            child: Text(
              _aiError!,
              key: const ValueKey('conflict-ai-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        gap(),
        Wrap(
          spacing: metrics.space2,
          runSpacing: metrics.space2,
          children: [
            if (deleted) ...[
              OutlinedButton(
                key: const ValueKey('conflict-delete'),
                style: notedDestructiveButtonStyle(context),
                onPressed: () => _resolve(() => _c.resolveDelete(id)),
                child: const Text('Delete it'),
              ),
              FilledButton(
                key: const ValueKey('conflict-keep-mine'),
                onPressed: () => _resolve(() => _c.resolveKeepMine(id, conflict: c)),
                child: const Text('Keep the box'),
              ),
            ] else ...[
              if (canAsk && !showProposal && !waiting)
                OutlinedButton(
                  key: const ValueKey('conflict-ask-ai'),
                  onPressed: () => _ask(issue),
                  child: const Text('Ask the page AI to merge'),
                ),
              if (showProposal)
                FilledButton(
                  key: const ValueKey('conflict-use-ai'),
                  onPressed: () => _useProposal(issue),
                  child: const Text('Use the AI’s merge'),
                ),
              if (showProposal)
                TextButton(
                  key: const ValueKey('conflict-discard-ai'),
                  onPressed: () => setState(_cancelAi),
                  child: const Text('Discard the AI’s merge'),
                ),
              // The other version isn't a Noted box: only keeping this one.
              if (placeable)
                OutlinedButton(
                  key: const ValueKey('conflict-place-both'),
                  onPressed: () => _resolve(() => _c.resolveKeepBoth(id, conflict: c)),
                  child: const Text('Place both'),
                ),
              if (placeable)
                OutlinedButton(
                  key: const ValueKey('conflict-keep-theirs'),
                  onPressed: () => _resolve(() => _c.resolveKeepTheirs(id, conflict: c)),
                  child: const Text('Keep the other version'),
                ),
              if (showProposal)
                OutlinedButton(
                  key: const ValueKey('conflict-keep-mine'),
                  onPressed: () => _resolve(() => _c.resolveKeepMine(id, conflict: c)),
                  child: const Text('Keep this version'),
                )
              else
                FilledButton(
                  key: const ValueKey('conflict-keep-mine'),
                  onPressed: () => _resolve(() => _c.resolveKeepMine(id, conflict: c)),
                  child: const Text('Keep this version'),
                ),
            ],
          ],
        ),
      ],
    );
  }

  String _mineLabel(BoxRecord box) {
    final name = _c.deviceName;
    final at = box.editedAt;
    return 'This device${name == null ? '' : ' ($name)'}'
        '${at == null ? '' : ' · edited ${formatConflictTime(at)}'}';
  }

  String _theirsLabel(BoxConflict? other, CanvasNode? node, bool deleted) {
    final at = other == null
        ? null
        : other.at > 0
        ? other.at
        : (node is BoxRecord ? node.editedAt : null);
    final name = other?.device ?? (node is BoxRecord ? node.device : null) ?? 'Other device';
    final verb = deleted ? 'deleted' : 'saved';
    return '$name${at == null ? '' : ' · $verb ${formatConflictTime(at)}'}';
  }
}

class _Side extends StatelessWidget {
  const _Side({super.key, required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final metrics = NotedMetrics.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelLarge),
        SizedBox(height: metrics.space1),
        Container(
          constraints: const BoxConstraints(minHeight: 80, maxHeight: 320),
          width: double.infinity,
          padding: EdgeInsets.all(metrics.space2),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: metrics.borderSm,
          ),
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
      ],
    );
  }
}

/// The issue view's header: the title on a `conflict-soft` band across the
/// top of the dialog, with [trailing] (the "n of m") at its right.
class ConflictHeader extends StatelessWidget {
  const ConflictHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    return ColoredBox(
      key: const ValueKey('conflict-header'),
      color: NotedColors.of(context).conflictSoft,
      child: Padding(
        padding: EdgeInsets.fromLTRB(m.space6, m.space4, m.space6, m.space4),
        child: SizedBox(
          width: double.infinity,
          child: Row(
            children: [
              Expanded(child: Text(title)),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}
