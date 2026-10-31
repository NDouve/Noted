// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_commands.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

class _Actions implements PageTreeActions {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

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

  test('Off by default; pages pass their setting down; a page can override it', () async {
    final a = nb.currentId!;
    final sub = await nb.createPage(parentId: a);
    final subsub = await nb.createPage(parentId: sub);
    expect(nb.aiSettingFor(a), AiSetting.off);
    await nb.setAiSetting(a, AiSetting.wholePage);
    expect(nb.aiSettingFor(sub), AiSetting.wholePage);
    expect(nb.aiSettingFor(subsub), AiSetting.wholePage);
    expect(nb.ownAiSetting(sub), isNull);
    expect(nb.inheritedAiSetting(sub), AiSetting.wholePage);

    await nb.setAiSetting(sub, AiSetting.boxOnly);
    expect(nb.aiSettingFor(sub), AiSetting.boxOnly);
    expect(nb.aiSettingFor(subsub), AiSetting.boxOnly, reason: 'from the nearer parent');
    await nb.setAiSetting(subsub, AiSetting.off);
    expect(nb.aiSettingFor(subsub), AiSetting.off);
    await nb.setAiSetting(sub, null);
    expect(nb.aiSettingFor(sub), AiSetting.wholePage);
    await nb.flush();

    final stored = readPage(File('${pages.path}/$a.canvas').readAsStringSync()).meta;
    expect(stored.aiSetting, AiSetting.wholePage);
    expect(File('${pages.path}/$a.canvas').readAsStringSync(), contains('"ai":"page"'));
    expect(readPage(File('${pages.path}/$sub.canvas').readAsStringSync()).meta.rawAiSetting, isNull);
  });

  test('a binder sets it for its pages', () async {
    final binder = await nb.addBinder((await Directory('${root.path}/B').create()).path);
    final p = await nb.createPage(binderPath: binder.path);
    expect(nb.aiSettingFor(p), AiSetting.off);
    await nb.setBinderAiSetting(binder.path, AiSetting.boxOnly);
    expect(nb.aiSettingFor(p), AiSetting.boxOnly);
    expect(nb.inheritedAiSetting(p), AiSetting.boxOnly);
    expect(File('${root.path}/B/$binderFileName').readAsStringSync(), contains('"ai":"box"'));
    await nb.setBinderAiSetting(binder.path, null);
    expect(nb.aiSettingFor(p), AiSetting.off);
    expect(File('${root.path}/B/$binderFileName').readAsStringSync(), isNot(contains('"ai"')));
  });

  test('an unknown value is kept and read as following the parent', () async {
    final a = nb.currentId!;
    await nb.flush();
    final f = File('${pages.path}/$a.canvas');
    f.writeAsStringSync(f.readAsStringSync().replaceFirst('"pageId"', '"ai":"everything","pageId"'));
    final nb2 = Notebook(PageStore(pages), buildModules(), saveDelay: Duration.zero);
    await nb2.load();
    expect(nb2.aiSettingFor(a), AiSetting.off);
    await nb2.rename(a, 'Renamed');
    await nb2.flush();
    nb2.dispose();
    expect(f.readAsStringSync(), contains('"ai":"everything"'));
  });

  test('the page menu shows the inherited value; the binder menu the app default', () async {
    final a = nb.currentId!;
    final sub = await nb.createPage(parentId: a);
    await nb.setAiSetting(a, AiSetting.wholePage);
    final r = pageCommands(nb, nb.tree[sub]!, _Actions());
    expect(r[AppCommands.aiInherit]!.label, 'Same as parent (Whole page)');
    expect(r[AppCommands.aiInherit]!.checked, isTrue);
    expect(r[AppCommands.aiId(AiSetting.boxOnly)]!.checked, isFalse);
    await r.invoke(AppCommands.aiId(AiSetting.boxOnly));
    expect(nb.ownAiSetting(sub), AiSetting.boxOnly);
    expect(pageCommands(nb, nb.tree[a]!, _Actions())[AppCommands.aiInherit]!.label, 'Same as parent (Off)');

    final binder = await nb.addBinder((await Directory('${root.path}/C').create()).path);
    final b = binderCommands(nb, binder, _Actions());
    expect(b[AppCommands.binderAiDefault]!.label, 'App default (Off)');
    expect(b[AppCommands.binderAiDefault]!.checked, isTrue);
    await b.invoke(AppCommands.binderAiId(AiSetting.wholePage));
    expect(nb.binders.single.binder!.aiSetting, AiSetting.wholePage);
  });
}
