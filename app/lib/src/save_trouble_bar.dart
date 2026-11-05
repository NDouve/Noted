// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedColors, NotedMetrics, NotedTypography;

import 'notebook.dart';
import 'save_trouble.dart';

/// The bar above the open page when its saves are in trouble (R-1 v5):
///
/// - the page couldn't be saved but its edits are kept in recovery (a bar with
///   Retry, Save a copy elsewhere… and Discard changes);
/// - the save and recovery both failed (a warning that doesn't fade or close,
///   with the checked cause; clicking it shows the advice);
/// - a read-only preview of kept changes that haven't landed yet.
class SaveTroubleBar extends StatefulWidget {
  const SaveTroubleBar({super.key, required this.notebook});

  final Notebook notebook;

  @override
  State<SaveTroubleBar> createState() => _SaveTroubleBarState();
}

class _SaveTroubleBarState extends State<SaveTroubleBar> {
  bool _expanded = false;

  Notebook get _nb => widget.notebook;

  Future<void> _run(Future<String?> Function() action) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final done = await action();
      if (done != null && done.isNotEmpty) {
        messenger?.hideCurrentSnackBar();
        messenger?.showSnackBar(SnackBar(content: Text(done), showCloseIcon: true));
      }
    } on NotebookException catch (e) {
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(e.message),
          persist: e.needsAction,
          showCloseIcon: e.needsAction,
          duration: const Duration(seconds: 10),
        ),
      );
    }
  }

  Widget _button(String key, String label, VoidCallback onPressed) => TextButton(
    key: ValueKey(key),
    onPressed: onPressed,
    child: Text(label),
  );

  @override
  Widget build(BuildContext context) {
    final t = _nb.trouble;
    if (!t.isTrouble) return const SizedBox.shrink();
    final m = NotedMetrics.of(context);
    final colors = NotedColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final small = NotedTypography.of(context).small.copyWith(color: scheme.onSurface);
    final bold = small.copyWith(fontWeight: FontWeight.w600);
    final loud = t.kind == TroubleKind.recoveryFailing;
    final text = switch (t.kind) {
      TroubleKind.failing => "Couldn't save this page: ${t.reason}.",
      TroubleKind.recoveryFailing =>
        "Noted can't save anything on this computer. Your changes to \"${t.title}\" exist only on screen.",
      TroubleKind.preview =>
        "Changes kept in local recovery haven't been saved to this page yet: ${t.reason}.",
      TroubleKind.saved => '',
    };
    final actions = <Widget>[
      _button('save-trouble-retry', 'Retry', () => unawaited(_run(() async {
        await _nb.retrySave();
        return null;
      }))),
      if (t.canSaveCopy)
        _button('save-trouble-copy', 'Save a copy elsewhere…', () => unawaited(_run(_nb.saveCopyElsewhere))),
      if (t.kind != TroubleKind.failing)
        _button('save-trouble-text', 'Copy page text', () => unawaited(_run(() async {
          await _nb.copyPageText();
          return 'Copied the text of the page.';
        }))),
      if (t.kind == TroubleKind.failing)
        _button('save-trouble-discard', 'Discard changes', () => unawaited(_run(() async {
          await _nb.discardChanges();
          return null;
        }))),
      if (t.kind == TroubleKind.preview && t.canDiscardKept)
        _button('save-trouble-discard-kept', 'Discard kept changes', () => unawaited(_run(() async {
          await _nb.discardKept();
          return null;
        }))),
    ];
    return Semantics(
      container: true,
      liveRegion: true,
      child: DecoratedBox(
        key: const ValueKey('save-trouble-bar'),
        decoration: BoxDecoration(color: loud ? scheme.errorContainer : colors.conflictSoft),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: m.space6, vertical: m.space2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                key: const ValueKey('save-trouble-expand'),
                onTap: loud ? () => setState(() => _expanded = !_expanded) : null,
                child: Row(
                  children: [
                    Icon(
                      loud ? Icons.error_outline_rounded : Icons.save_outlined,
                      size: m.icon,
                      color: loud ? scheme.onErrorContainer : scheme.onSurface,
                    ),
                    SizedBox(width: m.space2),
                    Flexible(child: Text(text, style: loud ? bold : small)),
                    if (loud) ...[
                      SizedBox(width: m.space2),
                      Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: m.icon),
                    ],
                  ],
                ),
              ),
              if (loud && t.reason.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: m.space1, left: m.icon + m.space2),
                  child: Text(t.reason, key: const ValueKey('save-trouble-cause'), style: small),
                ),
              if (loud && _expanded && t.advice.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: m.space1, left: m.icon + m.space2),
                  child: Text(t.advice, key: const ValueKey('save-trouble-advice'), style: small),
                ),
              Wrap(spacing: m.space2, children: actions),
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks [q] in a dialog on the window of [navigator]. Cancel is the default
/// button and the filled one (0134); true means the user chose the other.
Future<bool> showTroubleQuestion(GlobalKey<NavigatorState> navigator, UserQuestion q, String title) async {
  final context = navigator.currentContext;
  if (context == null || !context.mounted) return false;
  final (heading, body, yes) = switch (q) {
    UserQuestion.leaveAndLose => (
      'Your changes will be lost',
      'Noted could not save "$title" or keep your changes in recovery. If you leave now they are lost. '
          'You can cancel and use Save a copy elsewhere or Copy page text first.',
      'Leave and lose the changes',
    ),
    UserQuestion.deleteKept => (
      'Delete this page?',
      'This page has changes that couldn\'t be saved. Delete them too?',
      'Delete them too',
    ),
    UserQuestion.discardKept => (
      'Discard kept changes?',
      'The changes kept for "$title" can\'t be saved to the page. Discarding them can\'t be undone.',
      'Discard kept changes',
    ),
  };
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: ValueKey('trouble-question-${q.name}'),
      title: Text(heading),
      content: Text(body),
      actions: [
        TextButton(
          key: const ValueKey('trouble-question-yes'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(yes),
        ),
        FilledButton(
          key: const ValueKey('trouble-question-cancel'),
          autofocus: true,
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
  return answer ?? false;
}

/// The notice shown for about 30 seconds after leaving a page whose edits went
/// to recovery.
SnackBar keptNoticeBar(KeptNotice n, VoidCallback show) => SnackBar(
  key: const ValueKey('kept-notice'),
  duration: const Duration(seconds: 30),
  showCloseIcon: true,
  content: Text(
    'Couldn\'t save "${n.title}" (${n.reason}). Your changes are kept in local recovery and will be saved '
    'when it works again.',
  ),
  action: SnackBarAction(label: 'Show', onPressed: show),
);
