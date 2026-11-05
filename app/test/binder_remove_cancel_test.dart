// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Remove from sidebar records the binder's id as removed before its first
// await (so a discovery pass can't list it again meanwhile). When the user
// declines to leave the open page (its save and its recovery both fail) the
// binder stays listed, and what the call recorded must be undone.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'support/trouble_world.dart';

void main() {
  late TroubleWorld w;

  setUp(() async {
    w = TroubleWorld();
    await w.init();
  });

  tearDown(() => w.dispose());

  Map<String, Object?> saved() => jsonDecode(w.settings.readAsStringSync()) as Map<String, Object?>;

  // A notebook with a binder (id [id]) whose open page can neither be saved
  // nor kept in recovery.
  Future<(Notebook, String)> stuckBinder(String id) async {
    final dir = await Directory('${w.root.path}/Bind').create();
    await BinderStore(dir).create(Binder.create(title: 'Bind', id: id, color: binderPalette.first));
    final nb = w.make();
    await nb.load();
    final section = await nb.addBinder(dir.path);
    final page = await nb.createPage(binderPath: section.path);
    await nb.flush();
    await nb.open(page);
    await w.rec.parent.create(recursive: true);
    File(w.rec.path).writeAsStringSync('in the way');
    nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
    w.storeFor(Directory(section.path)).failWith = accessDenied();
    await nb.flush();
    return (nb, section.path);
  }

  const id = 'a000000000000001';

  test('declining to leave the page keeps the binder listed, its id recorded and not removed', () async {
    final (nb, path) = await stuckBinder(id);
    nb.questioner = (q, t) async => false; // keep the page
    await expectLater(nb.removeBinder(path), throwsA(isA<LeaveCancelled>()));
    expect(nb.binders.map((b) => b.path), [path]);
    // A settings write afterwards, and a restart, see it as it was.
    final extra = await Directory('${w.root.path}/extra').create();
    await nb.addStandaloneFolder(extra.path);
    expect((saved()['binderIds'] as Map)[path], id);
    expect(saved()['removedBinders'] ?? const [], isEmpty);
    // A copy of the binder elsewhere is still refused as a copy of a listed one.
    final copy = await Directory('${w.root.path}/Copy').create();
    File('$path/$binderFileName').copySync('${copy.path}/$binderFileName');
    await expectLater(nb.addBinder(copy.path), throwsA(isA<NotebookException>()));
    expect(nb.binders, hasLength(1));
    w.storeFor(Directory(path)).failWith = null;
    File(w.rec.path).deleteSync();
    await nb.flush();
    final again = w.make();
    await again.load();
    await again.discoveryIdle;
    expect(again.binders.map((b) => b.path), [path]);
    expect((saved()['binderIds'] as Map)[path], id);
    expect(saved()['removedBinders'] ?? const [], isEmpty);
  });

  test('control: when the removal goes through, the id is remembered as removed', () async {
    final (nb, path) = await stuckBinder(id);
    w.storeFor(Directory(path)).failWith = null;
    File(w.rec.path).deleteSync();
    await nb.removeBinder(path);
    expect(nb.binders, isEmpty);
    expect(saved()['removedBinders'], [id]);
    expect(saved()['binderIds'], isEmpty);
  });

  test('two overlapping removes, the first declined and the second confirmed: the id ends up removed', () async {
    final (nb, path) = await stuckBinder(id);
    var asked = 0;
    nb.questioner = (q, t) async {
      asked++;
      if (asked == 1) return false; // the first remove is declined at once...
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return true; // ...the second, still waiting, is confirmed
    };
    final first = nb.removeBinder(path);
    final second = nb.removeBinder(path);
    Object? firstError;
    try {
      await first;
    } on Object catch (e) {
      firstError = e;
    }
    await second;
    expect(asked, greaterThan(0));
    expect(firstError == null || firstError is LeaveCancelled, isTrue);
    expect(nb.binders, isEmpty, reason: 'the confirmed remove went through');
    expect(saved()['removedBinders'], [id]);
    expect(saved()['binderIds'], isEmpty);
  });
}
