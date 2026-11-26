// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show ExportFormat;

/// Asks which of [formats] to export the box [boxLabel] in; the first is
/// chosen. Null if cancelled.
Future<ExportFormat?> showExportFormatDialog(
  BuildContext context, {
  required String boxLabel,
  required List<ExportFormat> formats,
}) => showDialog<ExportFormat>(
  context: context,
  builder: (context) => ExportFormatDialog(boxLabel: boxLabel, formats: formats),
);

class ExportFormatDialog extends StatefulWidget {
  const ExportFormatDialog({super.key, required this.boxLabel, required this.formats});

  final String boxLabel;
  final List<ExportFormat> formats;

  @override
  State<ExportFormatDialog> createState() => _ExportFormatDialogState();
}

class _ExportFormatDialogState extends State<ExportFormatDialog> {
  late ExportFormat _format = widget.formats.first;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('export-dialog'),
      title: const Text('Export'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.boxLabel, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Text('Format', style: Theme.of(context).textTheme.labelLarge),
            for (final f in widget.formats)
              ListTile(
                key: ValueKey('export-format-${f.id}'),
                dense: true,
                leading: Icon(
                  _format == f ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                ),
                title: Text(f.label),
                selected: _format == f,
                onTap: () => setState(() => _format = f),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('export-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('export-ok'),
          onPressed: () => Navigator.pop(context, _format),
          child: const Text('Export'),
        ),
      ],
    );
  }
}

/// Asks "Replace [name]?". True to replace.
Future<bool> showReplaceDialog(BuildContext context, String name) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('export-replace-dialog'),
        title: Text('Replace $name?', maxLines: 2, overflow: TextOverflow.ellipsis),
        content: const Text('A file with this name is already there. It is replaced only if it is unchanged.'),
        actions: [
          TextButton(
            key: const ValueKey('export-replace-cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('export-replace-ok'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    ) ??
    false;

/// Asks "Put back [name]?": an earlier export left the old file at [aside].
/// True to put it back.
Future<bool> showPutBackDialog(BuildContext context, String name, String aside) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('export-putback-dialog'),
        title: Text('Put back $name?', maxLines: 2, overflow: TextOverflow.ellipsis),
        content: Text('It is kept as $aside.'),
        actions: [
          TextButton(
            key: const ValueKey('export-putback-cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('export-putback-ok'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Put back'),
          ),
        ],
      ),
    ) ??
    false;
