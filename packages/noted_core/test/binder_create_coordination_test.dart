// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// BinderStore.create makes the binder folder through coordinated() (R5.4, N4):
// once, as a write on the folder that holds it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

import 'support/coordination_support.dart';

void main() {
  late Directory root;
  late RecordingCoordinator c;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_bcreate');
    c = RecordingCoordinator();
    registerCoordinator(tempRoot, c);
  });
  tearDown(() async {
    unregisterCoordinator(tempRoot);
    await root.delete(recursive: true);
  });

  String norm(String p) => p.replaceAll(r'\', '/');

  test('the folder create is one coordinated write on the parent, made before the publish', () async {
    final parent = root.resolveSymbolicLinksSync();
    final store = BinderStore(Directory('$parent/New binder'));
    final r = await store.create(Binder.create(title: 'x', color: binderPalette.first));
    expect(r, BinderCreated.created);
    final first = c.calls.first;
    expect(first.intents, hasLength(1));
    expect(first.intents.single.kind, CoordinationKind.write);
    expect(norm(first.intents.single.path), norm(parent));
    expect(
      c.calls.where((w) => w.intents.length == 1 && norm(w.intents.single.path) == norm(parent)),
      hasLength(1),
    );
  });

  test('a refusal makes no folder and is a StorageBusy', () async {
    final parent = root.resolveSymbolicLinksSync();
    c.refuse = StorageBusy(StorageBusyReason.coordination, [parent]);
    final store = BinderStore(Directory('$parent/New binder'));
    await expectLater(
      store.create(Binder.create(title: 'x', color: binderPalette.first)),
      throwsA(isA<StorageBusy>()),
    );
    expect(Directory('$parent/New binder').existsSync(), isFalse);
  });

  test('an existing folder costs no coordinated call for the create', () async {
    final parent = root.resolveSymbolicLinksSync();
    Directory('$parent/B').createSync();
    final store = BinderStore(Directory('$parent/B'));
    await store.create(Binder.create(title: 'x', color: binderPalette.first));
    expect(
      c.calls.where((w) => w.intents.length == 1 && w.intents.single.kind == CoordinationKind.write && norm(w.intents.single.path) == norm(parent)),
      isEmpty,
    );
  });
}
