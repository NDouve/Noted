// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Switching theme writes settings.json's "theme" and nothing else (task 6):
// no page or binder file is rewritten, and a box keeps its stored content.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted_canvas/noted_canvas.dart';

import 'support/shell_world.dart';

Map<String, (List<int>, DateTime)> _snapshot(Directory root) => {
  for (final e in root.listSync(recursive: true).whereType<File>())
    if (!e.path.endsWith('settings.json')) e.path: (e.readAsBytesSync(), e.lastModifiedSync()),
};

void main() {
  testWidgets(
    'Light, Precision, Follow system: no page or binder file is written and the content is the same',
    (t) async {
      final w = await ShellWorld.open(t);
      await w.addNote(t, 'n', 'hello');
      await t.runAsync(() => w.nb.flush());
      final b = await w.addBinderWithPage(t, 'Work');
      await t.runAsync(() => w.nb.flush());
      await w.settle(t);
      final before = await t.runAsync(() async => _snapshot(w.dir));
      final page = w.nb.current!.page;
      expect(b.path, isNotEmpty);

      Brightness shown() => Theme.of(t.element(find.byType(Scaffold).first)).brightness;
      for (final theme in [ThemeSetting.dark, ThemeSetting.system, ThemeSetting.light]) {
        w.settings.theme = theme;
        await t.pumpAndSettle();
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      w.settings.theme = ThemeSetting.dark;
      await t.pumpAndSettle();
      expect(shown(), Brightness.dark);
      // The dark canvas draws the outline-control token.
      expect(
        NotedColors.of(t.element(find.byType(Scaffold).first)).outlineControl,
        DesignColors.dark.outlineControl,
      );
      await t.runAsync(() => w.nb.flush());
      final after = await t.runAsync(() async => _snapshot(w.dir));
      expect(after!.keys, before!.keys);
      for (final k in before.keys) {
        expect(after[k]!.$1, before[k]!.$1, reason: k);
        expect(after[k]!.$2, before[k]!.$2, reason: '$k was not rewritten');
      }
      expect(identical(w.nb.current!.page, page), isTrue, reason: 'the page model is untouched');
      expect(w.settings.theme, ThemeSetting.dark);
      await w.close(t);
    },
  );
}
