// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory root;
  late Directory pages;
  late Notebook nb;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_ai');
    pages = await Directory('${root.path}/pages').create();
    nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
    );
    await nb.load();
  });

  tearDown(() async {
    await nb.flush();
    nb.dispose();
    await root.delete(recursive: true);
  });

  test('Guarded by default; a top-level page may choose any value; lower pages only tighten', () async {
    final a = nb.currentId!;
    final sub = await nb.createPage(parentId: a);
    final subsub = await nb.createPage(parentId: sub);
    expect(nb.aiAccessFor(a), const EffectiveAiAccess(AiAccess.guarded, ConfigSource.appDefault));
    expect(nb.allowedOwnAiAccessFor(a), AiAccess.values, reason: 'the top of its own chain');

    await nb.setAiAccess(a, AiAccess.open);
    expect(nb.aiAccessFor(a), const EffectiveAiAccess(AiAccess.open, ConfigSource.own));
    expect(nb.aiAccessFor(sub), EffectiveAiAccess(AiAccess.open, ConfigSource.page(a)));
    expect(nb.aiAccessFor(subsub).value, AiAccess.open);
    expect(nb.ownAiAccess(sub), isNull);
    expect(nb.inheritedAiAccessFor(sub).value, AiAccess.open);
    expect(nb.allowedOwnAiAccessFor(sub), AiAccess.values);

    await nb.setAiAccess(sub, AiAccess.privileged);
    expect(nb.aiAccessFor(sub), const EffectiveAiAccess(AiAccess.privileged, ConfigSource.own));
    expect(nb.aiAccessFor(subsub), EffectiveAiAccess(AiAccess.privileged, ConfigSource.page(sub)));
    expect(nb.allowedOwnAiAccessFor(subsub), [AiAccess.privileged, AiAccess.guarded]);

    // A looser own value than the parent's is ignored.
    await nb.setAiAccess(subsub, AiAccess.open);
    expect(nb.aiAccessFor(subsub).value, AiAccess.privileged);
    await nb.setAiAccess(subsub, AiAccess.guarded);
    expect(nb.aiAccessFor(subsub).value, AiAccess.guarded);
    await nb.setAiAccess(sub, null);
    expect(nb.aiAccessFor(sub).value, AiAccess.open);
    await nb.flush();

    expect(File('${pages.path}/$a.canvas').readAsStringSync(), contains('"ai":"open"'));
    expect(readPage(File('${pages.path}/$a.canvas').readAsStringSync()).meta.aiAccess, AiAccess.open);
    expect(readPage(File('${pages.path}/$sub.canvas').readAsStringSync()).meta.rawAiAccess, isNull);
  });

  test('a binder sets it for its pages, which may only tighten', () async {
    final binder = await nb.addBinder((await Directory('${root.path}/B').create()).path);
    final p = await nb.createPage(binderPath: binder.path);
    expect(nb.aiAccessFor(p), const EffectiveAiAccess(AiAccess.guarded, ConfigSource.appDefault));
    expect(nb.allowedOwnAiAccessFor(p), [AiAccess.guarded]);
    await nb.setBinderAiAccess(binder.path, AiAccess.privileged);
    expect(nb.aiAccessFor(p), const EffectiveAiAccess(AiAccess.privileged, ConfigSource.binder));
    expect(nb.allowedOwnAiAccessFor(p), [AiAccess.privileged, AiAccess.guarded]);
    await nb.setAiAccess(p, AiAccess.open);
    expect(nb.aiAccessFor(p).value, AiAccess.privileged, reason: 'a page cannot loosen its binder');
    expect(File('${root.path}/B/$binderFileName').readAsStringSync(), contains('"ai":"privileged"'));
    await nb.setBinderAiAccess(binder.path, null);
    expect(nb.aiAccessFor(p).value, AiAccess.guarded);
    expect(File('${root.path}/B/$binderFileName').readAsStringSync(), isNot(contains('"ai"')));
  });

  test('legacy and unknown stored values read as before and are kept as written', () async {
    final a = nb.currentId!;
    await nb.flush();
    final f = File('${pages.path}/$a.canvas');
    final plain = f.readAsStringSync();
    Future<Notebook> reopen(String value) async {
      f.writeAsStringSync(plain.replaceFirst('"pageId"', '"ai":"$value","pageId"'));
      final n = Notebook(PageStore(pages), buildModules(), saveDelay: Duration.zero);
      await n.load();
      return n;
    }

    for (final (stored, expected) in [
      ('page', AiAccess.open),
      ('off', AiAccess.guarded),
      ('box', AiAccess.guarded),
      ('everything', AiAccess.guarded),
    ]) {
      final n = await reopen(stored);
      expect(n.aiAccessFor(a).value, expected, reason: stored);
      await n.rename(a, 'Renamed $stored');
      await n.flush();
      n.dispose();
      expect(f.readAsStringSync(), contains('"ai":"$stored"'), reason: 'kept as written');
    }
  });

  test('the allowed own values and what is inherited', () async {
    final a = nb.currentId!;
    final sub = await nb.createPage(parentId: a);
    await nb.setAiAccess(a, AiAccess.privileged);
    expect(nb.inheritedAiAccessFor(sub).value, AiAccess.privileged);
    expect(nb.ownAiAccess(sub), isNull);
    expect(nb.allowedOwnAiAccessFor(sub), [AiAccess.privileged, AiAccess.guarded], reason: 'looser: not offered');
    await nb.setAiAccess(sub, AiAccess.guarded);
    expect(nb.ownAiAccess(sub), AiAccess.guarded);
    expect(nb.inheritedAiAccessFor(a).value, AiAccess.guarded, reason: 'nothing above a top-level page');
    expect(nb.allowedOwnAiAccessFor(a), AiAccess.values, reason: 'a top-level page may choose any');

    final binder = await nb.addBinder((await Directory('${root.path}/C').create()).path);
    expect(nb.binderAiAccess(binder.path), isNull, reason: 'the app default, Guarded');
    await nb.setBinderAiAccess(binder.path, AiAccess.open);
    expect(nb.binders.single.binder!.aiAccess, AiAccess.open);
  });
}
