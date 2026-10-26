// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';

Command _cmd(
  String id, {
  SingleActivator? shortcut,
  bool Function()? enabled,
  bool Function()? checked,
  Listenable? listenable,
  void Function()? onInvoke,
  bool whileEditing = false,
  bool whileReadOnly = false,
}) => Command(
  id: id,
  label: id,
  icon: Icons.circle,
  shortcut: shortcut,
  enabled: enabled,
  checked: checked,
  listenable: listenable,
  whileEditing: whileEditing,
  whileReadOnly: whileReadOnly,
  invoke: onInvoke ?? () {},
);

void main() {
  group('CommandRegistry', () {
    test('registers commands and looks them up by id', () {
      final r = CommandRegistry();
      final a = _cmd('test.a');
      r.register(a);
      r.register(_cmd('test.b'));
      expect(r['test.a'], same(a));
      expect(r['test.missing'], isNull);
      expect(r.commands.map((c) => c.id), ['test.a', 'test.b']);
      r.dispose();
    });

    test('refuses a duplicate id and keeps the first command', () {
      final r = CommandRegistry();
      final a = _cmd('test.a');
      r.register(a);
      expect(() => r.register(_cmd('test.a')), throwsArgumentError);
      expect(r['test.a'], same(a));
      r.dispose();
    });

    test('invoke runs an enabled command and skips a disabled or missing one', () async {
      final r = CommandRegistry();
      var enabled = true;
      var ran = 0;
      r.register(_cmd('test.a', enabled: () => enabled, onInvoke: () => ran++));
      expect(await r.invoke('test.a'), isTrue);
      expect(ran, 1);
      enabled = false;
      expect(await r.invoke('test.a'), isFalse);
      expect(await r.invoke('test.nope'), isFalse);
      expect(ran, 1);
      r.dispose();
    });

    test('registering notifies the registry', () {
      final r = CommandRegistry();
      var n = 0;
      r.addListener(() => n++);
      r.register(_cmd('test.a'));
      expect(n, 1);
      r.dispose();
    });

    test('enabled and checked changes notify the command and the registry once', () {
      final r = CommandRegistry();
      var enabled = true;
      bool? checked = false;
      final c = _cmd('test.a', enabled: () => enabled, checked: () => checked ?? false);
      r.register(c);
      var onCommand = 0;
      var onRegistry = 0;
      c.addListener(() => onCommand++);
      r.addListener(() => onRegistry++);

      c.refresh();
      expect((onCommand, onRegistry), (0, 0), reason: 'nothing changed');

      enabled = false;
      c.refresh();
      expect((onCommand, onRegistry), (1, 1));
      expect(c.enabled, isFalse);

      checked = true;
      r.refresh();
      expect((onCommand, onRegistry), (2, 2));
      expect(c.checked, isTrue);

      r.refresh();
      expect((onCommand, onRegistry), (2, 2), reason: 'no change, no event');
      r.dispose();
    });

    test('a command refreshes itself when a listenable it depends on changes', () {
      final r = CommandRegistry();
      final source = ValueNotifier(false);
      r.register(_cmd('test.a', enabled: () => source.value, listenable: source));
      var n = 0;
      r.addListener(() => n++);
      source.value = true;
      expect(n, 1);
      expect(r['test.a']!.enabled, isTrue);
      r.dispose();
      source.value = false; // after dispose: no listener left, no error
    });

    test('tooltip is the label and the shortcut', () {
      expect(
        Command(
          id: 'a',
          label: 'Pen',
          icon: Icons.edit,
          invoke: () {},
          shortcut: const SingleActivator(LogicalKeyboardKey.keyP),
        ).tooltip,
        'Pen (P)',
      );
      expect(
        Command(
          id: 'b',
          label: 'Redo',
          icon: Icons.redo,
          invoke: () {},
          shortcut: const SingleActivator(
            LogicalKeyboardKey.keyZ,
            control: true,
            shift: true,
          ),
        ).tooltip,
        'Redo (Ctrl+Shift+Z)',
      );
      expect(_cmd('c').tooltip, 'c');
    });
  });

  group('shortcut resolution', () {
    Future<void> press(
      WidgetTester t,
      CommandRegistry r,
      LogicalKeyboardKey key, {
      bool ctrl = false,
      bool shift = false,
      bool editing = false,
      bool readOnly = false,
      required void Function(Command?) result,
    }) async {
      Command? found;
      await t.pumpWidget(
        Focus(
          autofocus: true,
          onKeyEvent: (_, e) {
            // Key-up events resolve to nothing: keep what the key-down found.
            found ??= r.resolve(e, editing: editing, readOnly: readOnly);
            return KeyEventResult.ignored;
          },
          child: const SizedBox(),
        ),
      );
      if (ctrl) await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(key);
      if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      if (ctrl) await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      result(found);
    }

    testWidgets('finds the command for a key and its modifiers', (t) async {
      final r = CommandRegistry()
        ..register(_cmd('t.p', shortcut: const SingleActivator(LogicalKeyboardKey.keyP)))
        ..register(
          _cmd('t.undo', shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, control: true)),
        )
        ..register(
          _cmd(
            't.redo',
            shortcut: const SingleActivator(LogicalKeyboardKey.keyY, control: true),
          ),
        );
      await press(t, r, LogicalKeyboardKey.keyP, result: (c) => expect(c?.id, 't.p'));
      await press(
        t,
        r,
        LogicalKeyboardKey.keyZ,
        ctrl: true,
        result: (c) => expect(c?.id, 't.undo'),
      );
      // Plain Z is not Ctrl+Z, and Ctrl+P is not P.
      await press(t, r, LogicalKeyboardKey.keyZ, result: (c) => expect(c, isNull));
      await press(t, r, LogicalKeyboardKey.keyP, ctrl: true, result: (c) => expect(c, isNull));
      r.dispose();
    });

    testWidgets('alternate shortcuts also trigger the command', (t) async {
      final c = Command(
        id: 't.redo',
        label: 'Redo',
        icon: Icons.redo,
        invoke: () {},
        shortcut: const SingleActivator(LogicalKeyboardKey.keyY, control: true),
        alternateShortcuts: const [
          SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true),
        ],
      );
      final r = CommandRegistry()..register(c);
      await press(
        t,
        r,
        LogicalKeyboardKey.keyZ,
        ctrl: true,
        shift: true,
        result: (found) => expect(found, same(c)),
      );
      r.dispose();
    });

    testWidgets('a disabled command is not resolved', (t) async {
      var enabled = false;
      final r = CommandRegistry()
        ..register(
          _cmd(
            't.del',
            shortcut: const SingleActivator(LogicalKeyboardKey.delete),
            enabled: () => enabled,
          ),
        );
      await press(t, r, LogicalKeyboardKey.delete, result: (c) => expect(c, isNull));
      enabled = true;
      await press(t, r, LogicalKeyboardKey.delete, result: (c) => expect(c?.id, 't.del'));
      r.dispose();
    });

    testWidgets('editing and read-only contexts only resolve commands that allow them', (t) async {
      final r = CommandRegistry()
        ..register(_cmd('t.p', shortcut: const SingleActivator(LogicalKeyboardKey.keyP)))
        ..register(
          _cmd(
            't.zoom',
            shortcut: const SingleActivator(LogicalKeyboardKey.equal, control: true),
            whileEditing: true,
            whileReadOnly: true,
          ),
        );
      await press(
        t,
        r,
        LogicalKeyboardKey.keyP,
        editing: true,
        result: (c) => expect(c, isNull),
      );
      await press(
        t,
        r,
        LogicalKeyboardKey.keyP,
        readOnly: true,
        result: (c) => expect(c, isNull),
      );
      await press(
        t,
        r,
        LogicalKeyboardKey.equal,
        ctrl: true,
        editing: true,
        readOnly: true,
        result: (c) => expect(c?.id, 't.zoom'),
      );
      r.dispose();
    });
  });

  group('toolbar layout data', () {
    test('the default layout lists known ids in groups', () {
      expect(defaultToolbarLayout.first, [
        'canvas.select',
        'noted.drawing.pen',
        'noted.drawing.eraser',
      ]);
      expect(defaultToolbarLayout.last, [
        'canvas.fitAll',
        'canvas.zoomReset',
        'canvas.pageBackground',
        'app.search',
      ]);
    });

    test('reads a layout from JSON, or null for anything else', () {
      expect(
        toolbarLayoutFromJson([
          ['a', 'b'],
          ['c'],
        ]),
        [
          ['a', 'b'],
          ['c'],
        ],
      );
      expect(toolbarLayoutFromJson('nope'), isNull);
      expect(
        toolbarLayoutFromJson([
          ['a', 1],
        ]),
        isNull,
      );
    });

    test('resolving keeps the order and skips unknown ids and empty groups', () {
      final r = CommandRegistry()
        ..registerAll([_cmd('a'), _cmd('b'), _cmd('c', whileReadOnly: true)]);
      final groups = resolveToolbarLayout(r, [
        ['c', 'missing', 'a'],
        ['gone'],
        ['b'],
      ]);
      expect([for (final g in groups) [for (final c in g) c.id]], [
        ['c', 'a'],
        ['b'],
      ]);
      final readOnly = resolveToolbarLayout(r, [
        ['c', 'a'],
        ['b'],
      ], readOnly: true);
      expect([for (final g in readOnly) [for (final c in g) c.id]], [
        ['c'],
      ]);
      r.dispose();
    });
  });
}
