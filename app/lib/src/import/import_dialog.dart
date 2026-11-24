// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import 'import_format.dart';

/// What the user chose for one file.
final class ImportDecision {
  const ImportDecision(this.choice, {this.useForAll = false});

  final ImportChoice choice;

  /// The same choice for the rest of the files of this format.
  final bool useForAll;
}

/// Asks how to import the file [fileName] of [format]: its [options], the
/// first enabled one chosen. [more] is how many other files of the same
/// format follow; with any, *Use for all* is offered. Null if cancelled.
Future<ImportDecision?> showImportDialog(
  BuildContext context, {
  required String fileName,
  required List<ImportOption> options,
  int more = 0,
}) => showDialog<ImportDecision>(
  context: context,
  builder: (context) => ImportDialog(fileName: fileName, options: options, more: more),
);

class ImportDialog extends StatefulWidget {
  const ImportDialog({super.key, required this.fileName, required this.options, this.more = 0});

  final String fileName;
  final List<ImportOption> options;
  final int more;

  @override
  State<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<ImportDialog> {
  late ImportChoice? _choice = _first();
  bool _all = false;

  ImportChoice? _first() {
    for (final o in widget.options) {
      if (o.enabled) return o.choice;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('import-dialog'),
      title: Text(widget.fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final o in widget.options)
              ListTile(
                key: ValueKey('import-choice-${o.choice.name}'),
                dense: true,
                enabled: o.enabled,
                leading: Icon(
                  _choice == o.choice ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                ),
                title: Text(o.choice.label),
                subtitle: o.off == null ? null : Text(o.off!),
                selected: _choice == o.choice,
                onTap: o.enabled ? () => setState(() => _choice = o.choice) : null,
              ),
            if (widget.more > 0)
              CheckboxListTile(
                key: const ValueKey('import-use-all'),
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                value: _all,
                title: const Text('Use for all'),
                subtitle: Text('${widget.more} more of this type'),
                onChanged: (v) => setState(() => _all = v ?? false),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('import-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('import-ok'),
          onPressed: _choice == null
              ? null
              : () => Navigator.pop(context, ImportDecision(_choice!, useForAll: _all && widget.more > 0)),
          child: const Text('Import'),
        ),
      ],
    );
  }
}
