// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  PageMeta meta(String id) => PageMeta.create(id: id, title: id, order: 0);

  test('values are written as off, box and page; anything else follows the parent', () {
    expect(AiSetting.values.map((s) => s.value), ['off', 'box', 'page']);
    expect(AiSetting.parse('box'), AiSetting.boxOnly);
    expect(AiSetting.parse('all'), isNull);
    expect(defaultAiSetting, AiSetting.off);
  });

  test('stored in the page header, cleared by null, unknown values kept', () {
    final m = meta('p').withAiSetting(AiSetting.wholePage);
    expect(writePage(NotedPage.create(m)), contains('"ai":"page"'));
    expect(readPage(writePage(NotedPage.create(m))).meta.aiSetting, AiSetting.wholePage);
    expect(identical(m.withAiSetting(AiSetting.wholePage), m), isTrue);
    expect(m.withAiSetting(null).rawAiSetting, isNull);
    final odd = readPage(writePage(NotedPage.create(meta('q'))).replaceFirst('"pageId"', '"ai":"all","pageId"'));
    expect(odd.meta.aiSetting, isNull);
    expect(writePage(odd), contains('"ai":"all"'));
  });

  test('inheritance: nearest own choice, then the binder, then Off', () {
    final page = meta('a').withAiSetting(AiSetting.wholePage);
    final box = meta('b').withAiSetting(AiSetting.boxOnly);
    final none = meta('c');
    final binder = Binder.create(title: 'B', color: binderPalette.first).withAiSetting(AiSetting.boxOnly);
    expect(effectiveAiSetting([none]), AiSetting.off);
    expect(effectiveAiSetting([none, page]), AiSetting.wholePage);
    expect(effectiveAiSetting([box, page]), AiSetting.boxOnly);
    expect(effectiveAiSetting([none], binder: binder), AiSetting.boxOnly);
    expect(effectiveAiSetting([page], binder: binder), AiSetting.wholePage);
    expect(Binder.parse(binder.write()).aiSetting, AiSetting.boxOnly);
    expect(binder.withAiSetting(null).aiSetting, isNull);
  });
}
