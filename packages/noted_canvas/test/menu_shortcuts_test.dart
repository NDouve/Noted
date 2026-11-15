// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// What a menu shows as a command's shortcut, and the macOS-only alternates of
// Undo and Redo.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

class _Target implements CanvasCommandTarget {
  _Target(this.controller);
  @override
  final CanvasController controller;
  @override
  CanvasToolSelection get tools => _tools;
  final CanvasToolSelection _tools = CanvasToolSelection();
  @override
  AttachmentStore? get attachments => null;
  @override
  Offset? get viewCentre => null;
  @override
  bool get isReadOnly => false;
  @override
  double get scale => 1;
  @override
  void zoomBy(double factor) {}
  @override
  void zoomTo(double scale) {}
  @override
  void fitAll() {}
  @override
  bool get isFindOpen => false;
  @override
  void openFind() {}
  @override
  void closeFind() {}
  @override
  void stepFind(int delta) {}
  @override
  void focusCanvas() {}
  @override
  Future<bool> pasteFiles() async => false;
  @override
  Future<void> insertFiles(List<IncomingFile> files, {Offset? at}) async {}
}

void main() {
  CommandRegistry registry() {
    final c = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)),
      ModuleRegistry(),
    );
    addTearDown(c.dispose);
    return CommandRegistry()..registerAll(buildCanvasCommands(_Target(c)));
  }

  test('menuShortcutLabel writes meta as Cmd; shortcutLabel keeps Meta', () {
    const s = SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true);
    expect(menuShortcutLabel(s), 'Cmd+Shift+Z');
    expect(shortcutLabel(s), 'Shift+Meta+Z');
  });

  test('Windows and Linux: the menu shows the command shortcut; Undo has no meta alternate', () {
    final r = registry();
    addTearDown(r.dispose);
    expect(menuShortcutFor(r['canvas.undo']!, platform: TargetPlatform.windows), 'Ctrl+Z');
    expect(menuShortcutFor(r['canvas.redo']!, platform: TargetPlatform.linux), 'Ctrl+Y');
    expect(r['canvas.undo']!.alternateShortcuts.any((a) => a.meta), isFalse);
    expect(r['canvas.redo']!.alternateShortcuts.any((a) => a.meta), isFalse);
  });

  test('macOS: the menu shows the meta alternate, or nothing, never a Ctrl label', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final r = registry();
    addTearDown(r.dispose);
    String? at(String id) => menuShortcutFor(r[id]!);
    expect(at('canvas.undo'), 'Cmd+Z');
    expect(at('canvas.redo'), 'Cmd+Shift+Z');
    expect(r['canvas.redo']!.alternateShortcuts.any((a) => a.meta && a.trigger == LogicalKeyboardKey.keyY), isTrue);
    expect(at('canvas.paste'), 'Cmd+V');
    expect(at('canvas.find'), 'Cmd+F');
    expect(at('canvas.bringForward'), 'Cmd+]');
    expect(at('canvas.delete'), 'Delete');
    expect(at('canvas.findNext'), 'F3');
    expect(at('canvas.zoomIn'), isNull);
    expect(at('canvas.zoomReset'), isNull);
  });

  test('Paste is labelled as what it pastes', () {
    final r = registry();
    addTearDown(r.dispose);
    expect(r['canvas.paste']!.label, 'Paste image or file');
  });
}
