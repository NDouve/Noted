// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;

import 'app_settings.dart';
import 'notebook.dart';
import 'settings_panel.dart';

/// After the first load: tells the user, once, which pages were "Whole page"
/// in an older version and are no longer open to every AI because of what
/// they inherit, with a button per page that opens its Page settings.
///
/// Shown at most once per device (`aiAccessNoteShown` in the settings), and
/// not at all when no page is affected.
Future<void> showAiAccessNoteIfNeeded(
  BuildContext context,
  Notebook notebook,
  AppSettings settings,
) async {
  if (settings.aiAccessNoteShown) return;
  // Wait for a launch where the settings file was readable and every folder
  // was there, so the note is never based on a part of the notebook.
  if (!settings.canRememberNotes || !notebook.everythingReadable) return;
  final ids = notebook.pagesThatLostAiAccess();
  if (ids.isEmpty) return;
  settings.aiAccessNoteShown = true;
  await showDialog<void>(
    context: context,
    builder: (context) => _AiAccessNote(notebook: notebook, ids: ids),
  );
}

class _AiAccessNote extends StatelessWidget {
  const _AiAccessNote({required this.notebook, required this.ids});

  final Notebook notebook;
  final List<String> ids;

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      key: const ValueKey('ai-access-note'),
      title: const Text('Some pages are no longer open to AI'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          // Changing a page's access in its settings updates its row here.
          child: ListenableBuilder(
            listenable: notebook,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'These pages were set to Whole page. AI access now has three levels '
                  '(Open, Privileged, Guarded), and these pages follow what their binder or '
                  'parent page allows, which is stricter.',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                SizedBox(height: m.space3),
                for (final id in ids)
                  if (notebook.pageTitleOf(id) != null)
                    Row(
                      key: ValueKey('ai-access-note-$id'),
                      children: [
                        Expanded(
                          child: Text(
                            '${notebook.pageTitleOf(id) ?? 'Untitled page'} · ${notebook.aiAccessFor(id).value.label}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          key: ValueKey('ai-access-note-open-$id'),
                          onPressed: () =>
                              showPageSettings(context, notebook, id),
                          child: const Text('Page settings'),
                        ),
                      ],
                    ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('ai-access-note-close'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
