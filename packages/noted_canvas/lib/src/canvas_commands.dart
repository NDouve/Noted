// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'command_host.dart';
import 'commands.dart';

/// Ids of the canvas's own commands.
abstract final class CanvasCommands {
  static const String select = 'canvas.select';
  static const String undo = 'canvas.undo';
  static const String redo = 'canvas.redo';
  static const String delete = 'canvas.delete';
  static const String escape = 'canvas.escape';
  static const String zoomIn = 'canvas.zoomIn';
  static const String zoomOut = 'canvas.zoomOut';
  static const String zoomReset = 'canvas.zoomReset';
  static const String fitAll = 'canvas.fitAll';
}

/// What the canvas's commands act on: the open page canvas.
abstract interface class CanvasCommandTarget implements CommandHost {
  /// The page can't be changed (a read-only page or controller).
  bool get isReadOnly;

  /// The current zoom (1 is 100%).
  double get scale;

  void zoomBy(double factor);
  void zoomTo(double scale);
  void fitAll();

  /// Moves keyboard focus from a box's editor to the canvas.
  void focusCanvas();
}

const double _zoomStep = 1.25;

SingleActivator _key(LogicalKeyboardKey k, {bool ctrl = false, bool shift = false}) =>
    SingleActivator(k, control: ctrl, shift: shift);

/// The canvas's commands for [t]: select, undo, redo, delete, escape, the
/// zoom commands and Fit all, plus one command for each tool of the
/// modules that are on (same id, label, icon and shortcut as the tool,
/// checked while it is the active tool).
///
/// They read [t] when they run, so they stay right as the page changes; the
/// state they show is refreshed from the page controller and the tool
/// selection.
List<Command> buildCanvasCommands(CanvasCommandTarget t) {
  final c = t.controller;
  final tools = t.tools;
  final both = Listenable.merge([c, tools]);
  return [
    Command(
      id: CanvasCommands.select,
      label: 'Select and type',
      icon: Icons.text_fields,
      shortcut: _key(LogicalKeyboardKey.keyV),
      checked: () => tools.active == null,
      listenable: tools,
      invoke: () => tools.select(null),
    ),
    for (final tool in c.modules.tools)
      Command(
        id: tool.id,
        label: tool.label,
        icon: tool.icon,
        shortcut: tool.shortcut == null ? null : _key(tool.shortcut!),
        checked: () => identical(tools.active, tool),
        listenable: tools,
        invoke: () => tools.select(tool),
      ),
    Command(
      id: CanvasCommands.undo,
      label: 'Undo',
      icon: Icons.undo,
      shortcut: _key(LogicalKeyboardKey.keyZ, ctrl: true),
      enabled: () => !t.isReadOnly && c.canUndo,
      listenable: c,
      invoke: c.undo,
    ),
    Command(
      id: CanvasCommands.redo,
      label: 'Redo',
      icon: Icons.redo,
      shortcut: _key(LogicalKeyboardKey.keyY, ctrl: true),
      alternateShortcuts: [_key(LogicalKeyboardKey.keyZ, ctrl: true, shift: true)],
      enabled: () => !t.isReadOnly && c.canRedo,
      listenable: c,
      invoke: c.redo,
    ),
    Command(
      id: CanvasCommands.delete,
      label: 'Delete selected box',
      icon: Icons.delete_outline,
      shortcut: _key(LogicalKeyboardKey.delete),
      alternateShortcuts: [_key(LogicalKeyboardKey.backspace)],
      enabled: () => !t.isReadOnly && c.selectedId != null,
      listenable: c,
      invoke: () {
        final id = c.selectedId;
        if (id != null) c.delete(id);
      },
    ),
    Command(
      id: CanvasCommands.escape,
      label: 'Deselect',
      icon: Icons.deselect,
      shortcut: _key(LogicalKeyboardKey.escape),
      whileEditing: true,
      enabled: () => !t.isReadOnly,
      listenable: both,
      invoke: () {
        // In an editor: back to the canvas. Otherwise the first Escape
        // leaves the tool, the next clears the selection.
        if (c.editingId != null) {
          t.focusCanvas();
        } else if (tools.active != null) {
          tools.select(null);
        } else {
          c.select(null);
        }
      },
    ),
    Command(
      id: CanvasCommands.zoomIn,
      label: 'Zoom in',
      icon: Icons.zoom_in,
      shortcut: _key(LogicalKeyboardKey.equal, ctrl: true),
      alternateShortcuts: [
        _key(LogicalKeyboardKey.equal, ctrl: true, shift: true),
        _key(LogicalKeyboardKey.numpadAdd, ctrl: true),
      ],
      whileEditing: true,
      whileReadOnly: true,
      invoke: () => t.zoomBy(_zoomStep),
    ),
    Command(
      id: CanvasCommands.zoomOut,
      label: 'Zoom out',
      icon: Icons.zoom_out,
      shortcut: _key(LogicalKeyboardKey.minus, ctrl: true),
      alternateShortcuts: [_key(LogicalKeyboardKey.numpadSubtract, ctrl: true)],
      whileEditing: true,
      whileReadOnly: true,
      invoke: () => t.zoomBy(1 / _zoomStep),
    ),
    Command(
      id: CanvasCommands.zoomReset,
      label: 'Zoom to 100%',
      icon: Icons.search,
      shortcut: _key(LogicalKeyboardKey.digit0, ctrl: true),
      alternateShortcuts: [_key(LogicalKeyboardKey.numpad0, ctrl: true)],
      whileEditing: true,
      whileReadOnly: true,
      text: () => '${(t.scale * 100).round()}%',
      invoke: () => t.zoomTo(1),
    ),
    Command(
      id: CanvasCommands.fitAll,
      label: 'Fit all',
      icon: Icons.fit_screen,
      showLabel: true,
      whileReadOnly: true,
      invoke: t.fitAll,
    ),
  ];
}
