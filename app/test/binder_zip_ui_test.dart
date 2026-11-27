// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A binder row's menu offers Save as .zip… (design t6 §3), and choosing it
// runs the share.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/binder_zip/binder_zip_flow.dart';

import 'support/shell_world.dart';

void main() {
  testWidgets('the binder row menu shows Save as .zip… after Save as template…, and it saves the binder', (t) async {
    final w = await ShellWorld.open(t);
    final b = await w.addBinderWithPage(t, 'Work');
    await w.settle(t);
    final target = '${w.dir.path}${Platform.pathSeparator}Work.zip';
    var asked = 0;
    binderZipSavePicker = (suggested) async {
      asked++;
      expect(suggested, 'Work.zip');
      return target;
    };

    await t.runAsync(() => t.tap(find.byKey(ValueKey('binder-menu-${b.path}'))));
    await t.pumpAndSettle();
    double y(String label) => t.getTopLeft(find.text(label).last).dy;
    expect(find.text('Save as .zip…'), findsOneWidget);
    expect(y('Save as .zip…'), greaterThan(y('Save as template…')), reason: 'after Save as template…');
    expect(y('Save as .zip…'), lessThan(y('Remove from sidebar')));

    await t.tap(find.text('Save as .zip…'));
    for (var i = 0; i < 200 && find.text('Saved Work.zip.').evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    expect(asked, 1);
    expect(find.text('Saved Work.zip.'), findsOneWidget);
    expect(File(target).existsSync(), isTrue);

    // The right-click menu has it too.
    await t.tapAt(const Offset(900, 1100));
    await t.pumpAndSettle();
    await t.runAsync(() => t.tapAt(t.getCenter(find.byKey(ValueKey('binder-menu-${b.path}'))) - const Offset(60, 0), buttons: kSecondaryButton));
    await t.pumpAndSettle();
    expect(find.text('Save as .zip…'), findsOneWidget);
    await t.tapAt(const Offset(900, 1100));
    await t.pumpAndSettle();
    await w.close(t);
  });
}
