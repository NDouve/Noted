// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The load predicate of the File menu (task 6, N5): File is on only once the
// first load has succeeded. A failed first load, then a Retry that hangs (no
// error and no success), leaves File off; when the Retry succeeds File turns on.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'support/settle_saves.dart';

/// A store whose first scan fails or hangs, as a device folder can.
class _FlakyStore extends PageStore {
  _FlakyStore(super.directory);

  Object? failWith;
  Completer<void>? hangOn;

  @override
  Future<List<PageEntry>> scan({bool createFolder = true, bool sweep = true, bool stamps = false, void Function(String path)? afterFileRead}) async {
    if (failWith case final e?) throw e;
    if (hangOn case final h?) await h.future;
    return super.scan(createFolder: createFolder, sweep: sweep, stamps: stamps, afterFileRead: afterFileRead);
  }
}

bool _on(WidgetTester t, String id) =>
    t.widget<MenuItemButton>(find.byKey(ValueKey('menu-$id'))).onPressed != null;

Future<void> _frames(WidgetTester t, [int n = 3]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 50));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
}

void main() {
  testWidgets(
    'a failed first load, then a Retry that hangs, leaves File off; its success turns File on',
    (t) async {
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      late Directory dir;
      late _FlakyStore store;
      late Notebook nb;
      await t.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('noted_load_predicate');
        store = _FlakyStore(Directory('${dir.path}/pages')..createSync());
        nb = Notebook(store, buildModules(), saveDelay: Duration.zero);
        store.failWith = const FileSystemException('disk said no');
        await nb.loadChecked();
      });
      await t.pumpWidget(NotedApp(notebook: nb));
      await _frames(t);
      expect(find.byKey(const ValueKey('load-error-text')), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('menu-top-File')));
      await _frames(t);
      expect(_on(t, 'app.page.new'), isFalse, reason: 'the first load failed');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(t);

      // A Retry that hangs: no error any more, and no success yet.
      store.failWith = null;
      final hang = store.hangOn = Completer<void>();
      await t.tap(find.byKey(const ValueKey('load-error-retry')));
      await _frames(t);
      expect(nb.loadError, isNull);
      await t.tap(find.byKey(const ValueKey('menu-top-File')));
      await _frames(t);
      expect(
        _on(t, 'app.page.new'),
        isFalse,
        reason: 'a hanging Retry is neither an error nor a success',
      );

      // The Retry succeeds: File turns on while the menu is open.
      hang.complete();
      for (var i = 0; i < 60 && !_on(t, 'app.page.new'); i++) {
        await _frames(t, 1);
      }
      expect(_on(t, 'app.page.new'), isTrue);

      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpWidget(const SizedBox());
      await settleSaves(t, nb);
      await t.runAsync(() async {
        nb.dispose();
        await dir.delete(recursive: true);
      });
    },
  );
}
