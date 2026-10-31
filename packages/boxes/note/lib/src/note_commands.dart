// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:noted_canvas/noted_canvas.dart';

import 'math_input.dart';

/// Ids of the note module's commands.
abstract final class NoteCommands {
  static const String insertTable = 'noted.note.insertTable';
  static const String insertEquation = 'noted.note.insertEquation';
  static const String insertDateTime = 'noted.note.insertDateTime';
  static const String paragraph = 'noted.note.style.paragraph';
  static const String heading1 = 'noted.note.style.heading1';
  static const String heading2 = 'noted.note.style.heading2';
  static const String heading3 = 'noted.note.style.heading3';
  static const String bold = 'noted.note.bold';
  static const String italic = 'noted.note.italic';
  static const String underline = 'noted.note.underline';
  static const String strikethrough = 'noted.note.strikethrough';
  static const String highlight = 'noted.note.highlight';
  static const String bulletedList = 'noted.note.bulletedList';
  static const String numberedList = 'noted.note.numberedList';
  static const String checkList = 'noted.note.checkList';
  static const String outdent = 'noted.note.outdent';
  static const String indent = 'noted.note.indent';
  static const String clearFormatting = 'noted.note.clearFormatting';

  /// The heading command for [level] 1 to 3.
  static String heading(int level) => 'noted.note.style.heading$level';
}

/// A note editor that the note module's commands can insert into.
abstract interface class NoteCommandTarget {
  /// The editor has keyboard focus, so a command acts at its caret.
  bool get canInsert;

  /// The editor, while [canInsert]; the formatting commands act on its
  /// selection.
  EditorState? get commandEditor;

  /// Inserts a table at the caret, as the slash menu's Table item does.
  Future<void> insertTable();

  /// Inserts an equation at the caret, as the slash menu's Equation item
  /// does (it asks for the formula).
  Future<void> insertEquation();
}

/// Which note editor has keyboard focus, if any. The note module's commands
/// act on it and are enabled only while there is one.
///
/// Shared by all canvases: keyboard focus is one per app.
abstract final class NoteCommandFocus {
  static final ValueNotifier<NoteCommandTarget?> active = ValueNotifier(null);

  /// Counts changes to the focused editor's selection and text, so the
  /// formatting commands re-read whether they are checked.
  static final ValueNotifier<int> edits = ValueNotifier(0);

  /// [target]'s selection or text changed.
  static void edited(NoteCommandTarget target) {
    if (!identical(active.value, target)) return;
    // A selection can change during a frame (layout); listeners (a toolbar)
    // are told after it.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => edits.value++);
    } else {
      edits.value++;
    }
  }

  /// [target] gained or lost focus.
  static void report(NoteCommandTarget target, {required bool focused}) {
    if (focused) {
      active.value = target;
    } else if (identical(active.value, target)) {
      active.value = null;
    }
  }

  /// [target] is going away. Clears it after the current frame: this runs
  /// while the widget tree is being torn down, when listeners (a toolbar)
  /// can't be rebuilt.
  static void release(NoteCommandTarget target) {
    if (!identical(active.value, target)) return;
    scheduleMicrotask(() {
      if (identical(active.value, target)) active.value = null;
    });
  }
}

/// The note module's commands (Box API 0.4), all acting on the focused note:
/// insert a table, an equation or the date and time at the caret; the
/// paragraph style (body text, headings 1 to 3); bold, italic, underline,
/// strikethrough and highlight; bulleted, numbered and check lists; outdent
/// and indent; and clear formatting.
///
/// They are enabled only while a note editor has focus. The keys shown in
/// tooltips are the editor's own: the editor handles them while it has
/// focus.
List<Command> noteCommands(CommandHost host) {
  bool canInsert() => NoteCommandFocus.active.value?.canInsert ?? false;
  final state = Listenable.merge([
    NoteCommandFocus.active,
    NoteCommandFocus.edits,
  ]);
  EditorState? editor() => NoteCommandFocus.active.value?.commandEditor;

  Command style(String id, String label, String text, String type, {int? level}) =>
      Command(
        id: id,
        label: label,
        icon: Icons.text_fields_rounded,
        text: () => text,
        enabled: canInsert,
        checked: () {
          final e = editor();
          return e != null && _blockIs(e, type, level: level);
        },
        listenable: state,
        invoke: () async {
          final e = editor();
          if (e != null) await _setBlock(e, type, level: level);
        },
      );

  Command mark(String id, String label, IconData icon, String key, LogicalKeyboardKey k) =>
      Command(
        id: id,
        label: label,
        icon: icon,
        shortcut: SingleActivator(k, control: true),
        enabled: canInsert,
        checked: () {
          final e = editor();
          return e != null && _hasMark(e, key);
        },
        listenable: state,
        invoke: () => editor()?.toggleAttribute(key),
      );

  Command list(String id, String label, IconData icon, String type) => Command(
    id: id,
    label: label,
    icon: icon,
    enabled: canInsert,
    checked: () {
      final e = editor();
      return e != null && _blockIs(e, type);
    },
    listenable: state,
    invoke: () async {
      final e = editor();
      if (e == null) return;
      await _setBlock(e, _blockIs(e, type) ? ParagraphBlockKeys.type : type);
    },
  );

  Command shortcut(String id, String label, IconData icon, CommandShortcutEvent event,
          {SingleActivator? key}) =>
      Command(
        id: id,
        label: label,
        icon: icon,
        shortcut: key,
        enabled: canInsert,
        listenable: NoteCommandFocus.active,
        invoke: () {
          final e = editor();
          if (e != null) event.handler(e);
        },
      );

  return [
    style(NoteCommands.paragraph, 'Body text', 'Normal', ParagraphBlockKeys.type),
    for (final level in [1, 2, 3])
      style(
        NoteCommands.heading(level),
        'Heading $level',
        'H$level',
        HeadingBlockKeys.type,
        level: level,
      ),
    mark(NoteCommands.bold, 'Bold', Icons.format_bold_rounded,
        AppFlowyRichTextKeys.bold, LogicalKeyboardKey.keyB),
    mark(NoteCommands.italic, 'Italic', Icons.format_italic_rounded,
        AppFlowyRichTextKeys.italic, LogicalKeyboardKey.keyI),
    mark(NoteCommands.underline, 'Underline', Icons.format_underlined_rounded,
        AppFlowyRichTextKeys.underline, LogicalKeyboardKey.keyU),
    Command(
      id: NoteCommands.strikethrough,
      label: 'Strikethrough',
      icon: Icons.format_strikethrough_rounded,
      shortcut: const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true),
      enabled: canInsert,
      checked: () {
        final e = editor();
        return e != null && _hasMark(e, AppFlowyRichTextKeys.strikethrough);
      },
      listenable: state,
      invoke: () => editor()?.toggleAttribute(AppFlowyRichTextKeys.strikethrough),
    ),
    // The editor's own highlight (Ctrl+Shift+H): it applies to selected
    // text.
    shortcut(
      NoteCommands.highlight,
      'Highlight',
      Icons.highlight_rounded,
      toggleHighlightCommand,
      key: const SingleActivator(LogicalKeyboardKey.keyH, control: true, shift: true),
    ),
    list(NoteCommands.bulletedList, 'Bulleted list',
        Icons.format_list_bulleted_rounded, BulletedListBlockKeys.type),
    list(NoteCommands.numberedList, 'Numbered list',
        Icons.format_list_numbered_rounded, NumberedListBlockKeys.type),
    list(NoteCommands.checkList, 'Check list', Icons.checklist_rounded,
        TodoListBlockKeys.type),
    shortcut(NoteCommands.outdent, 'Outdent', Icons.format_indent_decrease_rounded,
        outdentCommand,
        key: const SingleActivator(LogicalKeyboardKey.tab, shift: true)),
    shortcut(NoteCommands.indent, 'Indent', Icons.format_indent_increase_rounded,
        indentCommand,
        key: const SingleActivator(LogicalKeyboardKey.tab)),
    Command(
      id: NoteCommands.clearFormatting,
      label: 'Clear formatting',
      icon: Icons.format_clear_rounded,
      enabled: canInsert,
      listenable: NoteCommandFocus.active,
      invoke: () async {
        final e = editor();
        if (e == null) return;
        await e.formatDelta(e.selection, {for (final k in _clearedKeys) k: null});
      },
    ),
    Command(
      id: NoteCommands.insertDateTime,
      label: 'Insert date and time',
      icon: Icons.event_rounded,
      text: () => 'Date & time',
      enabled: canInsert,
      listenable: NoteCommandFocus.active,
      invoke: () => editor()?.insertTextAtCurrentSelection(
        formatDateTime(DateTime.now()),
      ),
    ),
    Command(
      id: NoteCommands.insertTable,
      label: 'Insert table',
      icon: Icons.table_view_rounded,
      text: () => 'Table',
      enabled: canInsert,
      listenable: NoteCommandFocus.active,
      invoke: () => NoteCommandFocus.active.value?.insertTable(),
    ),
    Command(
      id: NoteCommands.insertEquation,
      label: 'Insert equation',
      icon: Icons.functions_rounded,
      text: () => 'Equation',
      enabled: canInsert,
      listenable: NoteCommandFocus.active,
      invoke: () => NoteCommandFocus.active.value?.insertEquation(),
    ),
  ];
}

/// The text styles that Clear formatting removes. Links, formulas and
/// inline equations are content, not formatting, and stay.
final List<String> _clearedKeys = [
  AppFlowyRichTextKeys.bold,
  AppFlowyRichTextKeys.italic,
  AppFlowyRichTextKeys.underline,
  AppFlowyRichTextKeys.strikethrough,
  AppFlowyRichTextKeys.code,
  AppFlowyRichTextKeys.textColor,
  AppFlowyRichTextKeys.backgroundColor,
];

/// The block at the start of the selection has [type] (and heading [level]).
bool _blockIs(EditorState e, String type, {int? level}) {
  final sel = e.selection;
  if (sel == null) return false;
  final node = e.getNodeAtPath(sel.normalized.start.path);
  if (node == null || node.type != type) return false;
  return level == null || node.attributes[HeadingBlockKeys.level] == level;
}

/// Turns the selected blocks that hold text into [type] blocks (with heading
/// [level]), keeping their text, as appflowy's own toolbar does.
Future<void> _setBlock(EditorState e, String type, {int? level}) =>
    e.formatNode(e.selection, (node) {
      if (node.delta == null) return node;
      return node.copyWith(
        type: type,
        attributes: {
          blockComponentDelta: node.delta!.toJson(),
          HeadingBlockKeys.level: ?level,
          if (type == TodoListBlockKeys.type) TodoListBlockKeys.checked: false,
          blockComponentBackgroundColor:
              node.attributes[blockComponentBackgroundColor],
          blockComponentTextDirection: node.attributes[blockComponentTextDirection],
        },
      );
    });

/// The selected text, or at a caret the style the next typed character
/// gets, has [key] set.
bool _hasMark(EditorState e, String key) {
  var sel = e.selection;
  if (sel == null) return false;
  if (sel.isCollapsed) {
    final toggled = e.toggledStyle[key];
    if (toggled != null) return toggled == true;
    if (sel.startIndex == 0) return false;
    sel = sel.copyWith(start: sel.start.copyWith(offset: sel.startIndex - 1));
  }
  final nodes = e.getNodesInSelection(sel);
  if (nodes.every((n) => n.delta == null)) return false;
  return nodes.allSatisfyInSelection(
    sel,
    (delta) => delta.everyAttributes((a) => a[key] == true),
  );
}

/// [t] as Insert date and time writes it: `2026-10-31 14:05`.
String formatDateTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// The slash menu's items don't use the menu they are called from, so
/// running one from a command passes this one, which shows nothing.
final class _NoMenu implements SelectionMenuService {
  const _NoMenu();

  @override
  Alignment get alignment => Alignment.topLeft;
  @override
  Offset get offset => Offset.zero;
  @override
  SelectionMenuStyle get style => SelectionMenuStyle.light;
  @override
  void dismiss() {}
  @override
  Future<void> show() async {}
  @override
  (double?, double?, double?, double?) getPosition() => (null, null, null, null);
}

/// Runs the slash menu's Table item at [editor]'s caret.
void insertTableAtCaret(EditorState editor, BuildContext context) =>
    tableMenuItem.handler(editor, const _NoMenu(), context);

/// Runs the slash menu's Equation item at [editor]'s caret.
void insertEquationAtCaret(EditorState editor, BuildContext context) =>
    mathMenuItem.handler(editor, const _NoMenu(), context);
