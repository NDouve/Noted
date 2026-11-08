// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'ai/ai_access_service.dart';
import 'device_storage.dart';
import 'notebook.dart';
import 'page_location.dart';

/// Opens the settings panel of page [pageId] (the "Page settings" button in
/// the page header): Background, Images and files, AI access and the box
/// types allowed. Each setting shows what the page inherits and from where,
/// and offers an exemption of its own.
Future<void> showPageSettings(BuildContext context, Notebook notebook, String pageId) =>
    showDialog<void>(
      context: context,
      builder: (context) => SettingsPanel.page(notebook: notebook, pageId: pageId),
    );

/// Opens the settings panel of the binder in folder [binderPath] (the
/// "Binder settings" button on the binder). A binder sets values; it has no
/// exemptions.
Future<void> showBinderSettings(BuildContext context, Notebook notebook, String binderPath) =>
    showDialog<void>(
      context: context,
      builder: (context) => SettingsPanel.binder(notebook: notebook, binderPath: binderPath),
    );

/// The days a new code lasts, 0 for never.
const List<int> settingsExpiryDays = [0, 1, 7, 30];

/// What the panel calls a box type.
String boxTypeName(String typeId) => switch (typeId) {
  'noted.note' => 'Note boxes',
  'noted.drawing' => 'Drawing boxes',
  'noted.image' => 'Image boxes',
  'noted.file' => 'File boxes',
  aiBoxTypeId => 'AI boxes',
  _ => typeId,
};

/// What the panel says after converting a page's attachments [to] one way:
/// how many changed, the files kept in the folder for their size, and the
/// boxes left as they were because they changed while it ran.
String conversionNotice(AttachmentConversion r, AttachmentStorage to) {
  final n = r.changed;
  final again = switch (to) {
    AttachmentStorage.embedded => 'Embed attachments',
    AttachmentStorage.folder => 'Move attachments to folder',
  };
  final s = r.skipped.length;
  final parts = [
    // Nothing changed and something failed: the failure is the news.
    if (n > 0 || r.failed == 0)
    switch (to) {
      AttachmentStorage.embedded => 'Embedded $n ${n == 1 ? 'attachment' : 'attachments'}',
      AttachmentStorage.folder => 'Moved $n ${n == 1 ? 'attachment' : 'attachments'} to the folder',
    },
    if (r.overLimit.isNotEmpty) 'Kept in the folder (over 5 MB): ${r.overLimit.join(', ')}',
    if (r.failed > 0)
      switch (to) {
        AttachmentStorage.embedded =>
          '${r.failed == 1 ? '1 attachment' : '${r.failed} attachments'} could not be embedded and '
              '${r.failed == 1 ? 'stays' : 'stay'} in the folder. Try Embed attachments again later',
        AttachmentStorage.folder =>
          '${r.failed == 1 ? '1 attachment' : '${r.failed} attachments'} could not be moved to the folder and '
              '${r.failed == 1 ? 'stays' : 'stay'} in the page. Try Move attachments to folder again later',
      },
    if (s > 0)
      '${s == 1 ? '1 box' : '$s boxes'} changed while this ran and ${s == 1 ? 'was' : 'were'} '
          'left as ${s == 1 ? 'it was' : 'they were'}; press $again again',
  ];
  // A full stop between parts, and at the end, only where the part before
  // doesn't end in one already (a file name may).
  final text = StringBuffer();
  for (final (i, p) in parts.indexed) {
    if (i > 0) text.write(parts[i - 1].endsWith('.') ? ' ' : '. ');
    text.write(p);
  }
  return parts.last.endsWith('.') ? '$text' : '$text.';
}

String _two(int n) => n.toString().padLeft(2, '0');

String _date(DateTime t) {
  final d = t.toLocal();
  return '${d.year}-${_two(d.month)}-${_two(d.day)}';
}

String _dateTime(DateTime t) => '${_date(t)} ${_two(t.toLocal().hour)}:${_two(t.toLocal().minute)}';

String _expiryLabel(int days) => switch (days) {
  0 => 'None',
  1 => '1 day',
  _ => '$days days',
};

String _sentence(String s) {
  final t = s.replaceAll('_', ' ');
  return t.isEmpty ? t : '${t[0].toUpperCase()}${t.substring(1)}';
}

/// The settings of one page or one binder, as a dialog.
class SettingsPanel extends StatefulWidget {
  const SettingsPanel.page({super.key, required this.notebook, required String this.pageId})
    : binderPath = null;

  const SettingsPanel.binder({super.key, required this.notebook, required String this.binderPath})
    : pageId = null;

  final Notebook notebook;
  final String? pageId;
  final String? binderPath;

  bool get isPage => pageId != null;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  Notebook get nb => widget.notebook;
  AiAccessService? get ai => nb.aiAccess;
  String? get _pid => widget.pageId;
  String? get _path => widget.binderPath;

  // Why the last change could not be made, and a note about the last
  // conversion of attachments.
  String? _error;
  String? _notice;

  BinderSection? get _section {
    for (final b in nb.binders) {
      if (b.path == _path) return b;
    }
    return null;
  }

  bool get _readOnly {
    final id = _pid;
    if (id != null) return nb.isReadOnlyPage(id);
    final s = _section;
    return s == null || !s.available || nb.isPullOnlyLocation(s.path);
  }

  // Why it is read-only, when it is a pull-only location.
  bool get _pullOnly {
    final id = _pid;
    if (id != null) return nb.isPullOnlyPage(id);
    final p = _path;
    return p != null && nb.isPullOnlyLocation(p);
  }

  Future<void> _run(Future<void> Function() change) async {
    try {
      await change();
      if (mounted && _error != null) setState(() => _error = null);
    } on NotebookException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on AiAccessException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isPage ? 'Page settings' : 'Binder settings';
    return AlertDialog(
      key: const ValueKey('settings-panel'),
      title: Text(title),
      content: SizedBox(
        width: 560,
        child: ListenableBuilder(
          listenable: Listenable.merge([nb, ?ai]),
          builder: (context, _) => _ScrollCue(child: _body(context)),
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('settings-close'),
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
    if (widget.isPage && nb.pageTitleOf(_pid!) == null || !widget.isPage && _section == null) {
      return Text('This is no longer available.', style: text.bodySmall);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_readOnly) ...[
          Text(
            _pullOnly ? Notebook.pullOnlyMessage : 'Read-only: changes are off until this is available again.',
            key: const ValueKey('settings-read-only'),
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          SizedBox(height: m.space3),
        ],
        if (_error != null) ...[
          Text(
            _error!,
            key: const ValueKey('settings-error'),
            style: text.bodySmall?.copyWith(color: scheme.error),
          ),
          SizedBox(height: m.space3),
        ],
        if (widget.isPage) ...[_location(context), _divider(m), _background(context), _divider(m)],
        _imagesAndFiles(context),
        _divider(m),
        _aiAccess(context),
        _divider(m),
        _boxTypes(context),
      ],
    );
  }

  Widget _divider(NotedMetrics m) => Padding(
    padding: EdgeInsets.symmetric(vertical: m.space4),
    child: const Divider(height: 1),
  );

  // Pieces ---------------------------------------------------------------------

  Widget _heading(BuildContext context, String title) =>
      Text(title, style: Theme.of(context).textTheme.titleSmall);

  Widget _muted(BuildContext context, String text, {Key? key}) => Text(
    text,
    key: key,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );

  Widget _chips(BuildContext context, List<Widget> chips) =>
      Wrap(spacing: NotedMetrics.of(context).space2, runSpacing: NotedMetrics.of(context).space1, children: chips);

  Widget _chip(
    String key,
    String label, {
    required bool selected,
    required VoidCallback? onTap,
    String? tooltip,
  }) {
    final chip = ChoiceChip(
      key: ValueKey(key),
      label: Text(label, softWrap: true, maxLines: 4, overflow: TextOverflow.visible),
      selected: selected,
      onSelected: onTap == null ? null : (_) => onTap(),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
  }

  String _sourceName(ConfigSource s) => switch (s.kind) {
    ConfigSourceKind.own => 'this page',
    ConfigSourceKind.page => 'the parent page "${nb.pageTitleOf(s.pageId!) ?? 'Untitled page'}"',
    ConfigSourceKind.binder => 'the binder',
    ConfigSourceKind.appDefault => 'the app default',
  };

  // "Same as binder (Privileged)": the choice to follow what is inherited.
  String _inheritLabel(ConfigSource s, String value) => switch (s.kind) {
    ConfigSourceKind.page => 'Same as parent ($value)',
    ConfigSourceKind.binder => 'Same as binder ($value)',
    ConfigSourceKind.appDefault || ConfigSourceKind.own => 'App default ($value)',
  };

  // "Privileged (keep even if the binder changes)": an own choice equal to
  // what is inherited, so it is not mistaken for "Same as ...".
  String _pinLabel(ConfigSource s, String value) => switch (s.kind) {
    ConfigSourceKind.page => '$value (keep even if the parent changes)',
    ConfigSourceKind.binder => '$value (keep even if the binder changes)',
    ConfigSourceKind.appDefault || ConfigSourceKind.own => '$value (keep even if the app default changes)',
  };

  // Location -------------------------------------------------------------------

  Widget _location(BuildContext context) {
    final m = NotedMetrics.of(context);
    final id = _pid!;
    final folder = pageFolderPath(nb, id);
    final binder = nb.binderOfPage(id);
    String? binderTitle;
    if (binder != null) {
      for (final b in nb.binders) {
        if (b.path == binder) binderTitle = (b.binder?.title.trim().isEmpty ?? true) ? b.path : b.title;
      }
    }
    // A subpage is stored beside its parent page.
    final parentId = nb.treeOfPage(id).parentIdOf(id);
    final parentTitle = parentId == null ? null : nb.pageTitleOf(parentId);
    final canPick = nb.pickFolder != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, 'Location'),
        SizedBox(height: m.space1),
        if (binderTitle != null) ...[
          _muted(
            context,
            'In the binder "$binderTitle". Its page files are in this folder:',
            key: const ValueKey('settings-location-binder'),
          ),
          SizedBox(height: m.space1),
        ] else if (parentId != null)
          _muted(
            context,
            'Same as its parent page'
            '${parentTitle == null || parentTitle.isEmpty ? '' : ' "$parentTitle"'}. The file is in this folder:',
            key: const ValueKey('settings-location-parent'),
          )
        else
          _muted(context, 'This page\'s file is in this folder:'),
        SizedBox(height: m.space1),
        SelectableText(
          folder ?? 'Not found on this device',
          key: const ValueKey('settings-location-path'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        // Copies of this binder beside it (found by its id): not used.
        if (binder != null)
          for (final other in nb.binderAlsoIn(binder)) ...[
            SizedBox(height: m.space1),
            _muted(
              context,
              'Also in $other (not used)',
              key: ValueKey('settings-location-also-$other'),
            ),
            if (!isMobilePlatform)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: ValueKey('settings-location-also-show-$other'),
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text('Show other copy'),
                  onPressed: () => _showFolder(other),
                ),
              ),
          ],
        SizedBox(height: m.space2),
        Wrap(
          spacing: m.space2,
          children: [
            if (!isMobilePlatform)
              OutlinedButton.icon(
                key: const ValueKey('settings-location-show'),
                icon: const Icon(Icons.folder_open_rounded),
                label: Text(showFolderLabel()),
                onPressed: folder == null ? null : () => _showFolder(folder),
              ),
            if (canPick)
              OutlinedButton.icon(
                key: const ValueKey('settings-location-move'),
                icon: const Icon(Icons.drive_file_move_rounded),
                label: const Text('Move to folder…'),
                onPressed: _readOnly ? null : _moveToFolder,
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _showFolder(String folder) async {
    final ok = await showFolderInFileManager(folder);
    if (mounted) {
      setState(
        () => _error = ok ? null : "Couldn't open $folder. It may be on another device or not available now.",
      );
    }
  }

  Future<void> _moveToFolder() => _run(() async {
    final path = await nb.pickFolder?.call();
    if (path == null) return;
    await nb.moveToFolder(_pid!, path);
  });

  // Background -----------------------------------------------------------------

  Widget _background(BuildContext context) {
    final id = _pid!;
    // A page that isn't open can be changed too: the notebook loads it,
    // changes its header and saves it (0074).
    final current = nb.backgroundOf(id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, 'Background'),
        SizedBox(height: NotedMetrics.of(context).space1),
        _muted(context, 'Drawn behind this page only; it is not inherited.'),
        SizedBox(height: NotedMetrics.of(context).space2),
        _chips(context, [
          for (final b in PageBackground.values)
            _chip(
              'settings-bg-${b.name}',
              pageBackgroundLabel(b),
              selected: current == b,
              onTap: _readOnly ? null : () => _run(() => nb.setBackground(id, b)),
            ),
        ]),
      ],
    );
  }

  // Images and files -------------------------------------------------------------

  Widget _imagesAndFiles(BuildContext context) {
    final m = NotedMetrics.of(context);
    final id = _pid;
    final Widget choices;
    final String now;
    if (id != null) {
      final own = nb.ownAttachmentStorage(id);
      final (value, source) = nb.inheritedAttachmentStorageFor(id);
      final effective = nb.attachmentStorageFor(id);
      now = own == null
          ? '${effective.label}, from ${_sourceName(source)}'
          : '${effective.label}, set on this page';
      choices = _chips(context, [
        _chip(
          'settings-att-inherit',
          _inheritLabel(source, value.label),
          selected: own == null,
          onTap: _readOnly ? null : () => _run(() => nb.setAttachmentStorage(id, null)),
        ),
        for (final s in AttachmentStorage.values)
          _chip(
            'settings-att-${s.value}',
            s.label,
            selected: own == s,
            onTap: _readOnly ? null : () => _run(() => nb.setAttachmentStorage(id, s)),
          ),
      ]);
    } else {
      final value = _section?.binder?.attachmentStorage ?? AttachmentStorage.folder;
      now = value.label;
      choices = _chips(context, [
        for (final s in AttachmentStorage.values)
          _chip(
            'settings-att-${s.value}',
            s.label,
            selected: value == s,
            onTap: _readOnly ? null : () => _run(() => nb.setBinderAttachmentStorage(_path!, s)),
          ),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, 'Images and files'),
        SizedBox(height: m.space1),
        _muted(context, 'Where images and files are stored: $now.', key: const ValueKey('settings-att-now')),
        SizedBox(height: m.space2),
        choices,
        if (id != null) ...[
          SizedBox(height: m.space2),
          Wrap(
            spacing: m.space2,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('settings-att-embed'),
                icon: const Icon(Icons.move_down_rounded),
                label: const Text('Embed attachments'),
                onPressed: _readOnly ? null : () => _convert(AttachmentStorage.embedded),
              ),
              OutlinedButton.icon(
                key: const ValueKey('settings-att-to-folder'),
                icon: const Icon(Icons.drive_folder_upload_rounded),
                label: const Text('Move attachments to folder'),
                onPressed: _readOnly ? null : () => _convert(AttachmentStorage.folder),
              ),
            ],
          ),
          if (_notice != null) ...[
            SizedBox(height: m.space1),
            _muted(context, _notice!, key: const ValueKey('settings-att-notice')),
          ],
        ],
      ],
    );
  }

  Future<void> _convert(AttachmentStorage to) => _run(() async {
    final r = await nb.convertAttachments(_pid!, to);
    if (mounted) setState(() => _notice = conversionNotice(r, to));
  });

  // AI access ----------------------------------------------------------------------

  Widget _aiAccess(BuildContext context) {
    final m = NotedMetrics.of(context);
    final id = _pid;
    final List<Widget> chips;
    final String now;
    final AiAccess effective;
    if (id != null) {
      final own = nb.ownAiAccess(id);
      final inherited = nb.inheritedAiAccessFor(id);
      final eff = nb.aiAccessFor(id);
      effective = eff.value;
      now = '${eff.value.label}, ${eff.source == ConfigSource.own ? 'set on this page' : 'from ${_sourceName(eff.source)}'}';
      chips = [
        _chip(
          'settings-ai-inherit',
          _inheritLabel(inherited.source, inherited.value.label),
          selected: own == null,
          onTap: _readOnly ? null : () => _run(() => nb.setAiAccess(id, null)),
        ),
        // The value equal to the inherited one is a pin: it stays when the
        // parent, binder or default changes, so it is labelled as that.
        for (final s in nb.allowedOwnAiAccessFor(id))
          _chip(
            'settings-ai-${s.value}',
            s == inherited.value ? _pinLabel(inherited.source, s.label) : s.label,
            selected: own == s,
            onTap: _readOnly ? null : () => _run(() => nb.setAiAccess(id, s)),
          ),
      ];
    } else {
      final own = nb.binderAiAccess(_path!);
      effective = own ?? defaultAiAccess;
      now = own == null ? '${defaultAiAccess.label}, the app default' : '${own.label}, set on this binder';
      chips = [
        _chip(
          'settings-ai-inherit',
          'App default (${defaultAiAccess.label})',
          selected: own == null,
          onTap: _readOnly ? null : () => _run(() => nb.setBinderAiAccess(_path!, null)),
        ),
        for (final s in AiAccess.values)
          _chip(
            'settings-ai-${s.value}',
            s == defaultAiAccess ? _pinLabel(ConfigSource.appDefault, s.label) : s.label,
            selected: own == s,
            onTap: _readOnly ? null : () => _run(() => nb.setBinderAiAccess(_path!, s)),
          ),
      ];
    }
    final service = ai;
    final target = _codeTarget();
    final hasCodes = service != null && target != null && service.codesFor(target.kind!, target.id).isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, 'AI access'),
        SizedBox(height: m.space1),
        _muted(
          context,
          'Open: any AI using Noted can read it. Privileged: only a chat with a code can. '
          'Guarded: no AI can. An AI writes only in its own AI box.',
        ),
        SizedBox(height: m.space1),
        _muted(context, 'Now: $now.', key: const ValueKey('settings-ai-now')),
        SizedBox(height: m.space2),
        _chips(context, chips),
        if (service != null && target != null && (effective == AiAccess.privileged || hasCodes)) ...[
          SizedBox(height: m.space4),
          _CodesSection(
            key: ValueKey('settings-codes-${target.id}'),
            service: service,
            target: target,
            subject: widget.isPage ? 'this page' : 'this binder',
            run: _run,
          ),
        ],
      ],
    );
  }

  AiCodeTarget? _codeTarget() {
    final id = _pid;
    if (id != null) return AiCodeTarget.page(id);
    final b = _section?.binder;
    return b == null ? null : AiCodeTarget.binder(b.id);
  }

  // Box types allowed --------------------------------------------------------------

  Widget _boxTypes(BuildContext context) {
    final m = NotedMetrics.of(context);
    final types = nb.switchableBoxTypes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, 'Box types allowed'),
        SizedBox(height: m.space1),
        _muted(
          context,
          widget.isPage
              ? 'A box type that is not allowed shows its boxes read-only and can not be added here. '
                    'Nothing is deleted. A page can only tighten what its parent and binder allow.'
              : 'A box type that is not allowed shows its boxes read-only on this binder’s pages. '
                    'Nothing is deleted. A page can tighten this further.',
        ),
        SizedBox(height: m.space2),
        if (types.isEmpty) _muted(context, 'No box types can be switched here.'),
        for (final t in types) _typeRow(context, t),
      ],
    );
  }

  Widget _typeRow(BuildContext context, String t) {
    final m = NotedMetrics.of(context);
    final id = _pid;
    final Widget choices;
    if (id != null) {
      final inherited = nb.inheritedBoxTypeFor(id, t);
      final own = nb.ownBoxType(id, t);
      if (!inherited.allowed) {
        choices = _muted(
          context,
          'Not allowed (set by ${_sourceName(inherited.source!)})',
          key: ValueKey('settings-type-$t-inherited'),
        );
      } else {
        choices = _chips(context, [
          _chip(
            'settings-type-$t-allowed',
            'Allowed',
            selected: own != false,
            onTap: _readOnly ? null : () => _run(() => nb.setBoxType(id, t, null)),
          ),
          _chip(
            'settings-type-$t-off',
            'Not allowed here',
            selected: own == false,
            onTap: _readOnly ? null : () => _run(() => nb.setBoxType(id, t, false)),
          ),
        ]);
      }
    } else {
      final own = nb.binderBoxType(_path!, t);
      choices = _chips(context, [
        _chip(
          'settings-type-$t-allowed',
          'Allowed',
          selected: own != false,
          onTap: _readOnly ? null : () => _run(() => nb.setBinderBoxType(_path!, t, null)),
        ),
        _chip(
          'settings-type-$t-off',
          'Not allowed here',
          selected: own == false,
          onTap: _readOnly ? null : () => _run(() => nb.setBinderBoxType(_path!, t, false)),
        ),
      ]);
    }
    return Padding(
      padding: EdgeInsets.only(bottom: m.space2),
      // Beside the name when there is room for the chips; under it on a narrow
      // panel, where chips squeezed next to the name would clip their labels.
      child: LayoutBuilder(
        builder: (context, c) => c.maxWidth < 360
            ? Column(
                key: ValueKey('settings-type-$t'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(boxTypeName(t)),
                  SizedBox(height: m.space1),
                  choices,
                ],
              )
            : Row(
                key: ValueKey('settings-type-$t'),
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(width: 130, child: Text(boxTypeName(t))),
                  Expanded(child: choices),
                ],
              ),
      ),
    );
  }
}

/// A scrolling [child] that shows a rule and a soft shade along its bottom
/// edge while more content continues below, so a long panel does not look cut
/// off.
class _ScrollCue extends StatefulWidget {
  const _ScrollCue({required this.child});

  final Widget child;

  @override
  State<_ScrollCue> createState() => _ScrollCueState();
}

class _ScrollCueState extends State<_ScrollCue> {
  bool _more = false;

  bool _update(ScrollMetrics metrics) {
    final more = metrics.extentAfter > 0.5;
    if (more != _more) {
      // Notifications can arrive during layout.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && more != _more) setState(() => _more = more);
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _update(n.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) => _update(n.metrics),
        child: Stack(
          children: [
            SingleChildScrollView(child: widget.child),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  key: const ValueKey('settings-scroll-cue'),
                  opacity: _more ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [scheme.surface.withValues(alpha: 0), scheme.shadow.withValues(alpha: 0.12)],
                      ),
                    ),
                    child: const SizedBox(height: 16),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The codes of a page or binder (Privileged access): the list with each
/// code's approval, Connect a chat, and the activity.
class _CodesSection extends StatelessWidget {
  const _CodesSection({
    super.key,
    required this.service,
    required this.target,
    required this.subject,
    required this.run,
  });

  final AiAccessService service;
  final AiCodeTarget target;
  final String subject;
  final Future<void> Function(Future<void> Function()) run;

  Future<void> _revoke(BuildContext context, AiCode c) async {
    final label = c.label.isEmpty ? 'this connection' : c.label;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Revoke $label?'),
        content: Text('This chat can no longer read $subject.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          OutlinedButton(
            key: const ValueKey('settings-revoke-confirm'),
            style: notedDestructiveButtonStyle(context),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (ok ?? false) await run(() => service.revoke(c.id));
  }

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    // Lighter than the section headings (titleSmall): smaller, muted.
    final sub = text.labelMedium?.copyWith(color: scheme.onSurfaceVariant);
    final kind = target.kind!;
    final now = DateTime.now();
    final codes = service.codesFor(kind, target.id);
    final activity = service.activityFor(kind, target.id).reversed.take(30).toList();
    final problem = service.problem;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Codes', key: const ValueKey('settings-codes-heading'), style: sub),
            TextButton.icon(
              key: const ValueKey('settings-connect'),
              icon: Icon(Icons.add_link_rounded, size: m.icon, color: scheme.onSurfaceVariant),
              label: const Text('Connect a chat (Reader)'),
              onPressed: problem != null
                  ? null
                  : () => showDialog<void>(
                      context: context,
                      builder: (context) => _ConnectDialog(service: service, target: target),
                    ),
            ),
          ],
        ),
        if (problem != null)
          Text(problem, key: const ValueKey('settings-codes-problem'), style: text.bodySmall?.copyWith(color: scheme.error)),
        if (codes.isEmpty)
          Text(
            'No chats have a code for $subject yet.',
            key: const ValueKey('settings-no-codes'),
            style: muted,
          )
        else
          for (final c in codes) _codeRow(context, c, now),
        SizedBox(height: m.space2),
        Text('Activity', key: const ValueKey('settings-activity-heading'), style: sub),
        SizedBox(height: m.space1),
        if (activity.isEmpty)
          Text('Nothing yet.', key: const ValueKey('settings-no-activity'), style: muted)
        else
          for (var i = 0; i < activity.length; i++) _activityRow(context, i, activity[i]),
      ],
    );
  }

  Widget _codeRow(BuildContext context, AiCode c, DateTime now) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final revoked = c.isRevoked;
    final expired = !revoked && c.isExpired(now);
    final facts = [
      switch (c.role) {
        AiCodeRole.reader => 'Reader',
        AiCodeRole.writer => 'Writer',
        null => 'Unknown role',
      },
      'Created ${_date(c.created)}',
      c.lastUsed == null ? 'Never used' : 'Last used ${_dateTime(c.lastUsed!)}',
      if (c.expires != null && !expired && !revoked) 'Expires ${_date(c.expires!)}',
    ].join(' · ');
    return Padding(
      padding: EdgeInsets.only(top: m.space2),
      child: Column(
        key: ValueKey('settings-code-${c.id}'),
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
                  child: Text('Expired', key: ValueKey('settings-expired-${c.id}'), style: muted),
                ),
              if (!revoked)
                IconButton(
                  key: ValueKey('settings-revoke-${c.id}'),
                  tooltip: 'Revoke',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.block_rounded, size: m.icon, color: scheme.onSurfaceVariant),
                  onPressed: () => _revoke(context, c),
                ),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(left: m.icon + m.space2),
            child: Text(facts, key: ValueKey('settings-facts-${c.id}'), style: muted),
          ),
          Padding(
            padding: EdgeInsets.only(left: m.icon + m.space2),
            child: Text(
              revoked
                  ? (c.revoked == null ? 'Revoked' : 'Revoked ${_date(c.revoked!)}')
                  : c.approved == null
                  ? 'Not approved yet'
                  : 'Approved ${_date(c.approved!)}',
              key: ValueKey(revoked ? 'settings-revoked-${c.id}' : 'settings-approval-${c.id}'),
              style: muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _activityRow(BuildContext context, int index, AiActivityEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall;
    final what = [
      _sentence(e.op),
      if (e.app.isNotEmpty) e.app,
      if (e.label.isNotEmpty) e.label,
      if (e.extra['closed'] == true) 'while Noted was closed',
      if (e.extra['revoked'] == true) 'code revoked',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        key: ValueKey('settings-activity-$index'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_dateTime(e.time), style: style?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(width: 8),
          Expanded(child: Text(what, style: style)),
          const SizedBox(width: 8),
          Text(e.ok ? 'OK' : _sentence(e.result), style: style?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

enum _Stage { details, code }

/// Connect a chat (Reader) to a page or binder: a label and an optional
/// expiry, then the code, shown once with Copy.
class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog({required this.service, required this.target});

  final AiAccessService service;
  final AiCodeTarget target;

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  final TextEditingController _label = TextEditingController();
  _Stage _stage = _Stage.details;
  int _days = 0;
  bool _busy = false;
  bool _copied = false;
  String? _error;

  // The code, only while it is on screen; Noted keeps just its hash.
  String? _code;
  String _codeLabel = '';

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final label = _label.text.trim();
    if (label.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final code = await widget.service.issue(
        widget.target,
        role: AiCodeRole.reader,
        label: label,
        expires: _days == 0 ? null : DateTime.now().add(Duration(days: _days)),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _code = code;
        _codeLabel = label;
        _stage = _Stage.code;
      });
    } on AiAccessException catch (e) {
      // Nothing was issued, so there is no code to show.
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  Future<void> _copy() async {
    final code = _code;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // The code is shown once: a click outside or Escape must not close it.
    return PopScope(
      canPop: _stage != _Stage.code && !_busy,
      child: _stage == _Stage.details
          ? AlertDialog(
              title: const Text('Connect a chat'),
              content: SizedBox(
                width: 440,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'A Reader can read everything this code covers. It can not write.',
                        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      SizedBox(height: m.space3),
                      TextField(
                        key: const ValueKey('settings-code-label'),
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
                          for (final d in settingsExpiryDays)
                            ChoiceChip(
                              key: ValueKey('settings-code-expiry-$d'),
                              label: Text(_expiryLabel(d)),
                              selected: _days == d,
                              onSelected: (_) => setState(() => _days = d),
                            ),
                        ],
                      ),
                      if (_error != null) ...[
                        SizedBox(height: m.space2),
                        Text(
                          _error!,
                          key: const ValueKey('settings-code-error'),
                          style: TextStyle(color: scheme.error),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const ValueKey('settings-code-create'),
                  onPressed: _label.text.trim().isEmpty || _busy ? null : _create,
                  child: const Text('Create code'),
                ),
              ],
            )
          : AlertDialog(
              title: Text('Code for $_codeLabel', key: const ValueKey('settings-code-title')),
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
                        key: const ValueKey('settings-code'),
                        style: text.bodyMedium?.copyWith(fontFamily: 'monospace'),
                      ),
                    ),
                    SizedBox(height: m.space2),
                    Text(
                      'Copy it now: Noted shows it only once. It works only on this computer.',
                      key: const ValueKey('settings-code-note'),
                      style: text.bodySmall,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton.icon(
                  key: const ValueKey('settings-code-copy'),
                  onPressed: _copy,
                  icon: Icon(
                    _copied ? Icons.check_rounded : Icons.copy_rounded,
                    size: m.icon,
                    color: scheme.onSurfaceVariant,
                  ),
                  label: Text(_copied ? 'Copied' : 'Copy'),
                ),
                FilledButton(
                  key: const ValueKey('settings-code-done'),
                  onPressed: () {
                    // Drop the code with the dialog.
                    _code = null;
                    Navigator.pop(context);
                  },
                  child: const Text('Done'),
                ),
              ],
            ),
    );
  }
}
