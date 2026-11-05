// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:url_launcher/url_launcher.dart';

/// The link at [position], with the range of text it covers in its block,
/// or null if there is none.
({String href, int start, int end})? linkAt(EditorState editor, Position position) {
  final delta = editor.getNodeAtPath(position.path)?.delta;
  if (delta == null) return null;
  var offset = 0;
  final ops = delta.whereType<TextInsert>().toList();
  for (var i = 0; i < ops.length; i++) {
    final op = ops[i];
    final end = offset + op.length;
    final href = op.attributes?[AppFlowyRichTextKeys.href];
    // The caret just after a link's last character still counts as in it.
    if (href is String && position.offset >= offset && position.offset <= end && (position.offset < end || i == ops.length - 1 || ops[i + 1].attributes?[AppFlowyRichTextKeys.href] != href)) {
      var start = offset;
      var stop = end;
      // Neighbouring runs with the same link (split by other styles).
      var o = offset;
      for (var j = i - 1; j >= 0 && ops[j].attributes?[AppFlowyRichTextKeys.href] == href; j--) {
        o -= ops[j].length;
        start = o;
      }
      o = end;
      for (var j = i + 1; j < ops.length && ops[j].attributes?[AppFlowyRichTextKeys.href] == href; j++) {
        o += ops[j].length;
        stop = o;
      }
      return (href: href, start: start, end: stop);
    }
    offset = end;
  }
  return null;
}

/// The link every character of [selection] has, or null.
String? linkOfSelection(EditorState editor, Selection selection) {
  if (selection.isCollapsed) return linkAt(editor, selection.start)?.href;
  final nodes = editor.getNodesInSelection(selection);
  String? found;
  final all = nodes.allSatisfyInSelection(selection, (delta) {
    return delta.everyAttributes((a) {
      final h = a[AppFlowyRichTextKeys.href];
      if (h is! String) return false;
      found ??= h;
      return h == found;
    });
  });
  return all ? found : null;
}

/// [text] as a link target: as typed if it has a scheme (`https:`,
/// `mailto:`, `file:`) or if it is a path (a share, `/home/...`, a drive),
/// otherwise as an https address. Null if empty.
String? normalizeLink(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(t) || _looksLikePath(t)) return t;
  return 'https://$t';
}

/// What the link dialog decided.
sealed class LinkChoice {
  const LinkChoice();
}

final class SetLink extends LinkChoice {
  const SetLink(this.url);
  final String url;
}

final class RemoveLink extends LinkChoice {
  const RemoveLink();
}

/// Inserts or edits the link on [editor]'s selection (Ctrl+K): asks for the
/// address, with a Remove link button when there is one already.
///
/// With a bare caret inside a link, the whole link is edited; with a bare
/// caret elsewhere, the address is inserted as linked text.
Future<void> editLinkIn(BuildContext context, EditorState editor) async {
  var selection = editor.selection?.normalized;
  if (selection == null) return;
  if (selection.isCollapsed) {
    final at = linkAt(editor, selection.start);
    if (at != null) {
      selection = Selection(
        start: Position(path: selection.start.path, offset: at.start),
        end: Position(path: selection.start.path, offset: at.end),
      );
    }
  }
  final current = linkOfSelection(editor, selection);
  final choice = await showLinkDialog(context, initial: current ?? '', canRemove: current != null);
  if (editor.isDisposed) return;
  // The dialog had the focus: give the editor back its selection.
  editor.updateSelectionWithReason(selection, reason: SelectionUpdateReason.uiEvent);
  switch (choice) {
    case null:
      return;
    case RemoveLink():
      await editor.formatDelta(selection, {AppFlowyRichTextKeys.href: null});
    case SetLink(:final url):
      if (selection.isCollapsed) {
        final node = editor.getNodeAtPath(selection.start.path);
        if (node == null || node.delta == null) return;
        final transaction = editor.transaction
          ..insertText(node, selection.startIndex, url, attributes: {AppFlowyRichTextKeys.href: url})
          ..afterSelection = Selection.collapsed(
            Position(path: selection.start.path, offset: selection.startIndex + url.length),
          );
        await editor.apply(transaction);
      } else {
        await editor.formatDelta(selection, {AppFlowyRichTextKeys.href: url});
      }
  }
}

/// Opens [url] in the system's browser or default app ([linkOpener]).
Future<void> openLink(String url, {BuildContext? context}) {
  _askContext = context;
  return linkOpener(url);
}

// The context for a question before opening; [_launch] takes it at once.
BuildContext? _askContext;

/// What opens a link; tests replace it.
Future<void> Function(String url) linkOpener = _launch;

final RegExp _controlChars = RegExp(r'[\x00-\x1f\x7f-\x9f]');

Future<void> _launch(String url) async {
  final context = _askContext ?? _navigatorContext();
  _askContext = null;
  final messenger = context == null ? null : ScaffoldMessenger.maybeOf(context);
  final text = url.trim();
  final uri = Uri.tryParse(text);
  final scheme = uri?.scheme.toLowerCase() ?? '';
  try {
    // Web and mail links go to the system; any other scheme (a program's) asks
    // first. Everything else is a local or network path (a file: link, a
    // drive letter, a share, a bare path): one the system would run is opened
    // only after the user says so.
    final isPath = scheme.isEmpty || scheme == 'file' || scheme.length == 1;
    if (uri != null && !isPath) {
      if (linkSchemeNeedsConfirmation(scheme)) {
        if (context == null || !context.mounted) return;
        if (!await confirmOpenLinkScheme(context, scheme)) return;
      }
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    // A bare word or address (cmd, example.com) is a web address, as the editor
    // treats it; never handed to the system as it is.
    if (scheme.isEmpty && !_looksLikePath(text)) {
      final web = Uri.tryParse('http://$text');
      if (text.isEmpty || web == null || _controlChars.hasMatch(text)) {
        _notice(messenger);
        return;
      }
      await launchUrl(web, mode: LaunchMode.externalApplication);
      return;
    }
    final String path;
    final Uri target;
    if (uri != null && scheme == 'file') {
      path = uri.toFilePath();
      target = uri;
    } else {
      path = text;
      target = Uri.file(text);
    }
    // A name with a control character (NUL, a line break) is not opened: the
    // system may read it differently from what was checked.
    if (_controlChars.hasMatch(path) || _controlChars.hasMatch(_decoded(text))) {
      _notice(messenger);
      return;
    }
    if (needsOpenConfirmation(displayName: path)) {
      if (context == null || !context.mounted) return;
      final shown = path.replaceAll(RegExp(r'[\/]+$'), '').split(RegExp(r'[\/]')).last;
      if (!await confirmOpenRunnable(context, shown)) return;
    }
    await launchUrl(target, mode: LaunchMode.externalApplication);
  } on Object catch (e) {
    debugPrint('Opening $url failed: $e');
    _notice(messenger);
  }
}

// The text with percent escapes decoded; as it is if it does not decode (a
// literal % in a path).
String _decoded(String s) {
  try {
    return Uri.decodeFull(s);
  } on Object {
    return s;
  }
}

bool _looksLikePath(String s) => s.startsWith(r'\') || s.startsWith('//') || s.contains(r'\') || s.startsWith('/');

void _notice(ScaffoldMessengerState? messenger) {
  messenger?.showSnackBar(const SnackBar(content: Text("This link can't be opened.")));
}

/// Asks for a link address. Returns null if cancelled.
Future<LinkChoice?> showLinkDialog(
  BuildContext context, {
  required String initial,
  required bool canRemove,
}) => showDialog<LinkChoice>(
  context: context,
  useRootNavigator: true,
  builder: (_) => _LinkDialog(initial: initial, canRemove: canRemove),
);

class _LinkDialog extends StatefulWidget {
  const _LinkDialog({required this.initial, required this.canRemove});

  final String initial;
  final bool canRemove;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final url = normalizeLink(_controller.text);
    Navigator.of(context).pop(url == null ? (widget.canRemove ? const RemoveLink() : null) : SetLink(url));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.canRemove ? 'Edit link' : 'Insert link'),
      content: SizedBox(
        width: 360,
        child: TextField(
          key: const ValueKey('link-address'),
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(labelText: 'Address', hintText: 'https://example.com'),
          onSubmitted: (_) => _save(),
        ),
      ),
      actions: [
        if (widget.canRemove)
          TextButton(
            key: const ValueKey('link-remove'),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: () => Navigator.of(context).pop(const RemoveLink()),
            child: const Text('Remove link'),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('link-save'), onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// Whether Ctrl (Cmd on macOS) is held: Ctrl+click opens a link.
bool get linkModifierPressed {
  final k = HardwareKeyboard.instance;
  return k.isControlPressed || k.isMetaPressed;
}

/// The image formats pasted beside a note rather than into it.
const Set<String> pastedImageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

/// The images on the clipboard, or none.
Future<List<IncomingFile>> clipboardImages() async {
  try {
    final files = await FileClipboard.read();
    return [
      for (final f in files)
        if (pastedImageExtensions.contains(f.extension)) f,
    ];
  } on Object {
    return const [];
  }
}

/// Routes the editor's own link opening (a click on a link in the editor or in
/// the light view) through [openLink], so a link to a program asks first too.
void installLinkGuard() {
  editorLaunchUrl = (href) async {
    if (href == null) return false;
    final trimmed = href.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return false;
    // The target goes as it is: [openLink] tells a bare word (a web address)
    // from a path (a file, asked about if it runs) itself.
    await openLink(trimmed);
    return true;
  };
}

// A context under a Navigator, for a question when the caller has none.
BuildContext? _navigatorContext() {
  BuildContext? found;
  void visit(Element e) {
    if (found != null) return;
    if (e is StatefulElement && e.state is NavigatorState) {
      found = e;
      return;
    }
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}
