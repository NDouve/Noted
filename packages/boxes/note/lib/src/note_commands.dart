// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart';

import 'math_input.dart';

/// Ids of the note module's commands.
abstract final class NoteCommands {
  static const String insertTable = 'noted.note.insertTable';
  static const String insertEquation = 'noted.note.insertEquation';
}

/// A note editor that the note module's commands can insert into.
abstract interface class NoteCommandTarget {
  /// The editor has keyboard focus, so a command acts at its caret.
  bool get canInsert;

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

/// The note module's commands (Box API 0.4): insert a table and insert an
/// equation, both at the caret of the focused note.
List<Command> noteCommands(CommandHost host) {
  bool canInsert() => NoteCommandFocus.active.value?.canInsert ?? false;
  return [
    Command(
      id: NoteCommands.insertTable,
      label: 'Insert table',
      icon: Icons.table_view,
      enabled: canInsert,
      listenable: NoteCommandFocus.active,
      invoke: () => NoteCommandFocus.active.value?.insertTable(),
    ),
    Command(
      id: NoteCommands.insertEquation,
      label: 'Insert equation',
      icon: Icons.functions,
      enabled: canInsert,
      listenable: NoteCommandFocus.active,
      invoke: () => NoteCommandFocus.active.value?.insertEquation(),
    ),
  ];
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
