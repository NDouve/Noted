// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The row of an attachment's other iCloud version and its one action (R5.8).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_tree_view.dart';
import 'package:noted_core/noted_core.dart';

import 'support/icloud_world.dart';

void main() {
  testWidgets('"Keep it in iCloud" hides the row until the version changes', (t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final w = IcloudWorld();
    late String path;
    late String name;
    late Notebook nbAny;
    await t.runAsync(() async {
      await w.init();
      final f = await w.picked();
      final nb = nbAny = w.notebook(f);
      await nb.load();
      name = '${contentHash(utf8.encode('good'))}.png';
      path = w.write('p1.assets/$name', 'good').path;
      w.channel.addVersion(path, utf8.encode('some other bytes'));
      await f.landVersions([path]);
    });
    addTearDown(() => t.runAsync(w.dispose));
    await t.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: nbAny, builder: (context, _) => PageTreeView(notebook: nbAny)))));
    await t.pump();
    final row = find.text('iCloud holds another version of $name');
    final keep = find.text('Keep it in iCloud');
    expect(row, findsOneWidget);
    expect(keep, findsOneWidget);
    await t.tap(keep);
    await t.pump();
    expect(row, findsNothing);
    expect(keep, findsNothing);
    // The version changes: the row is back.
    await t.runAsync(() async {
      w.channel.addVersion(path, utf8.encode('yet another'));
      await w.folders.first.landVersions([path]);
    });
    await t.pump();
    expect(row, findsOneWidget);
    expect(keep, findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}
