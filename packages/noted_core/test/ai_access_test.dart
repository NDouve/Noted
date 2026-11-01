// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  PageMeta meta(String id, [AiAccess? ai]) => PageMeta.create(id: id, title: id, order: 0).withAiAccess(ai);
  Binder binder([AiAccess? ai]) => Binder.create(title: 'B', color: binderPalette.first).withAiAccess(ai);

  // A page header with [raw] (JSON text) stored as its "ai" value.
  PageMeta withRaw(String raw) {
    final text = writePage(NotedPage.create(PageMeta.create(id: 'x', title: 'x', order: 0)));
    return readPage(text.replaceFirst('"pageId"', '"ai":$raw,"pageId"')).meta;
  }

  test('values are open, privileged, guarded, loosest first', () {
    expect(AiAccess.values.map((s) => s.value), ['open', 'privileged', 'guarded']);
    expect(AiAccess.values.map((s) => s.label), ['Open', 'Privileged', 'Guarded']);
    expect(AiAccess.strictest(AiAccess.open, AiAccess.guarded), AiAccess.guarded);
    expect(AiAccess.strictest(AiAccess.guarded, AiAccess.open), AiAccess.guarded);
    expect(defaultAiAccess, AiAccess.guarded);
  });

  test('stored values migrate: page is open, off and box are guarded, unknown is guarded', () {
    expect(AiAccess.parse('open'), AiAccess.open);
    expect(AiAccess.parse('privileged'), AiAccess.privileged);
    expect(AiAccess.parse('guarded'), AiAccess.guarded);
    expect(AiAccess.parse('page'), AiAccess.open);
    expect(AiAccess.parse('off'), AiAccess.guarded);
    expect(AiAccess.parse('box'), AiAccess.guarded);
    expect(AiAccess.parse('all'), AiAccess.guarded);
    expect(AiAccess.parse(3), AiAccess.guarded);
    expect(AiAccess.parse(null), isNull);

    expect(withRaw('"page"').aiAccess, AiAccess.open);
    expect(withRaw('"off"').aiAccess, AiAccess.guarded);
    expect(withRaw('"box"').aiAccess, AiAccess.guarded);
    expect(withRaw('"mystery"').aiAccess, AiAccess.guarded);
    expect(withRaw('null').aiAccess, isNull);
  });

  test('a legacy or unknown value is kept as written until the user picks one', () {
    final legacy = withRaw('"box"');
    expect(legacy.rawAiAccess!.text, '"box"');
    expect(writePage(NotedPage.create(legacy)), contains('"ai":"box"'));
    final odd = withRaw('"mystery"');
    expect(odd.rawAiAccess!.text, '"mystery"');
    expect(writePage(NotedPage.create(odd)), contains('"ai":"mystery"'));
    expect(writePage(NotedPage.create(odd.withAiAccess(AiAccess.open))), contains('"ai":"open"'));
    expect(writePage(NotedPage.create(legacy.withAiAccess(AiAccess.guarded))), contains('"ai":"guarded"'));
  });

  test('stored in the page header and the binder file, cleared by null', () {
    final m = meta('p', AiAccess.privileged);
    expect(writePage(NotedPage.create(m)), contains('"ai":"privileged"'));
    expect(readPage(writePage(NotedPage.create(m))).meta.aiAccess, AiAccess.privileged);
    expect(identical(m.withAiAccess(AiAccess.privileged), m), isTrue);
    expect(m.withAiAccess(null).rawAiAccess, isNull);
    final none = meta('r');
    expect(identical(none.withAiAccess(null), none), isTrue);

    final b = binder(AiAccess.open);
    expect(Binder.parse(b.write()).aiAccess, AiAccess.open);
    expect(b.write(), contains('"ai":"open"'));
    expect(b.withAiAccess(null).aiAccess, isNull);
    expect(b.withAiAccess(null).rawAiAccess, isNull);
    expect(identical(b.withAiAccess(AiAccess.open), b), isTrue);
  });

  test('with nothing chosen anywhere the effective value is Guarded from the app default', () {
    expect(effectiveAiAccess([meta('c')]), const EffectiveAiAccess(AiAccess.guarded, ConfigSource.appDefault));
    expect(effectiveAiAccess([meta('c')], binder: binder()), const EffectiveAiAccess(AiAccess.guarded, ConfigSource.appDefault));
  });

  test('a binder may choose any value; pages under it can only tighten', () {
    final open = binder(AiAccess.open);
    expect(effectiveAiAccess([meta('c')], binder: open), const EffectiveAiAccess(AiAccess.open, ConfigSource.binder));
    expect(
      effectiveAiAccess([meta('c', AiAccess.privileged)], binder: open),
      const EffectiveAiAccess(AiAccess.privileged, ConfigSource.own),
    );
    // A looser choice than the binder's is ignored.
    final privileged = binder(AiAccess.privileged);
    expect(
      effectiveAiAccess([meta('c', AiAccess.open)], binder: privileged),
      const EffectiveAiAccess(AiAccess.privileged, ConfigSource.binder),
    );
    // With no binder value the start is Guarded, which nothing loosens.
    expect(
      effectiveAiAccess([meta('c', AiAccess.open)], binder: binder()),
      const EffectiveAiAccess(AiAccess.guarded, ConfigSource.appDefault),
    );
  });

  test('parent pages tighten down the chain and the source names the page', () {
    final top = meta('top', AiAccess.privileged);
    final mid = meta('mid');
    final leaf = meta('leaf');
    final open = binder(AiAccess.open);
    expect(effectiveAiAccess([leaf, mid, top], binder: open), EffectiveAiAccess(AiAccess.privileged, const ConfigSource.page('top')));
    // A looser own value below is ignored.
    expect(
      effectiveAiAccess([meta('leaf', AiAccess.open), mid, top], binder: open),
      EffectiveAiAccess(AiAccess.privileged, const ConfigSource.page('top')),
    );
    // A stricter own value wins.
    expect(
      effectiveAiAccess([meta('leaf', AiAccess.guarded), mid, top], binder: open),
      const EffectiveAiAccess(AiAccess.guarded, ConfigSource.own),
    );
    // A parent that tightens further.
    expect(
      effectiveAiAccess([leaf, meta('mid', AiAccess.guarded), top], binder: open),
      EffectiveAiAccess(AiAccess.guarded, const ConfigSource.page('mid')),
    );
    // Equal values keep the higher source.
    expect(
      effectiveAiAccess([meta('leaf', AiAccess.privileged), mid, top], binder: open),
      EffectiveAiAccess(AiAccess.privileged, const ConfigSource.page('top')),
    );
  });

  test('a top-level page in no binder may choose any value, and its subpages can only tighten', () {
    expect(effectiveAiAccess([meta('top', AiAccess.open)]), const EffectiveAiAccess(AiAccess.open, ConfigSource.own));
    expect(
      effectiveAiAccess([meta('sub'), meta('top', AiAccess.open)]),
      EffectiveAiAccess(AiAccess.open, const ConfigSource.page('top')),
    );
    expect(
      effectiveAiAccess([meta('sub', AiAccess.privileged), meta('top', AiAccess.open)]),
      const EffectiveAiAccess(AiAccess.privileged, ConfigSource.own),
    );
    expect(
      effectiveAiAccess([meta('sub', AiAccess.open), meta('top', AiAccess.privileged)]),
      EffectiveAiAccess(AiAccess.privileged, const ConfigSource.page('top')),
    );
    // A subpage of a standalone page with nothing chosen above is Guarded and can't loosen.
    expect(
      effectiveAiAccess([meta('sub', AiAccess.open), meta('top')]),
      const EffectiveAiAccess(AiAccess.guarded, ConfigSource.appDefault),
    );
    // A top-level page in a binder is not the top: the binder limits it.
    expect(
      effectiveAiAccess([meta('top', AiAccess.open)], binder: binder(AiAccess.guarded)),
      const EffectiveAiAccess(AiAccess.guarded, ConfigSource.binder),
    );
  });

  test('a page whose recorded parent cannot be found is not the top: it starts from the default', () {
    final orphan = PageMeta.create(id: 'orphan', title: 'o', order: 0, parentId: 'gone').withAiAccess(AiAccess.open);
    expect(effectiveAiAccess([orphan]), const EffectiveAiAccess(AiAccess.guarded, ConfigSource.appDefault));
    final tight = PageMeta.create(id: 'orphan', title: 'o', order: 0, parentId: 'gone').withAiAccess(AiAccess.guarded);
    expect(effectiveAiAccess([tight]).value, AiAccess.guarded);
    expect(inheritedAiAccess([orphan]), const EffectiveAiAccess(AiAccess.guarded, ConfigSource.appDefault));
    expect(allowedOwnAiAccess(inheritedAiAccess([orphan])?.value), [AiAccess.guarded]);
  });

  test('legacy values count through inheritance', () {
    expect(effectiveAiAccess([withRaw('"page"')]).value, AiAccess.open);
    expect(effectiveAiAccess([withRaw('"off"')]).value, AiAccess.guarded);
    expect(effectiveAiAccess([meta('sub'), withRaw('"page"')]).value, AiAccess.open);
  });

  test('what a page inherits, and which own values the UI offers', () {
    final open = binder(AiAccess.open);
    // Top-level standalone page: nothing limits it.
    expect(inheritedAiAccess([meta('top')]), isNull);
    expect(allowedOwnAiAccess(null), AiAccess.values);
    // A top-level page in a binder inherits the binder's value.
    expect(inheritedAiAccess([meta('top')], binder: open), const EffectiveAiAccess(AiAccess.open, ConfigSource.binder));
    expect(inheritedAiAccess([meta('top')], binder: binder()), const EffectiveAiAccess(AiAccess.guarded, ConfigSource.appDefault));
    // A subpage inherits from its parent, which is not "own".
    expect(
      inheritedAiAccess([meta('sub', AiAccess.open), meta('top', AiAccess.privileged)]),
      EffectiveAiAccess(AiAccess.privileged, const ConfigSource.page('top')),
    );
    expect(allowedOwnAiAccess(AiAccess.open), AiAccess.values);
    expect(allowedOwnAiAccess(AiAccess.privileged), [AiAccess.privileged, AiAccess.guarded]);
    expect(allowedOwnAiAccess(AiAccess.guarded), [AiAccess.guarded]);
  });
}
