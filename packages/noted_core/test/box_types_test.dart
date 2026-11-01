// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  PageMeta meta(String id) => PageMeta.create(id: id, title: id, order: 0);
  Binder binder() => Binder.create(title: 'B', color: binderPalette.first);

  PageMeta withRaw(String raw) {
    final text = writePage(NotedPage.create(meta('x')));
    return readPage(text.replaceFirst('"pageId"', '"boxTypes":$raw,"pageId"')).meta;
  }

  test('choices are stored in the page header and the binder file', () {
    final m = meta('p').withBoxType('noted.draw', false).withBoxType('noted.ai', true);
    expect(m.boxTypeChoices, {'noted.draw': false, 'noted.ai': true});
    expect(m.boxTypeChoice('noted.draw'), isFalse);
    expect(m.boxTypeChoice('noted.note'), isNull);
    final back = readPage(writePage(NotedPage.create(m))).meta;
    expect(back.boxTypeChoices, {'noted.draw': false, 'noted.ai': true});
    expect(writePage(NotedPage.create(m)), contains('"boxTypes":{"noted.draw":false,"noted.ai":true}'));

    final b = binder().withBoxType('noted.draw', false);
    expect(Binder.parse(b.write()).boxTypeChoices, {'noted.draw': false});
    expect(b.write(), contains('"boxTypes":{"noted.draw":false}'));
  });

  test('removing the last choice removes the key; no change returns the same object', () {
    final m = meta('p').withBoxType('a', false);
    expect(identical(m.withBoxType('a', false), m), isTrue);
    expect(m.withBoxType('a', null).rawBoxTypes, isNull);
    expect(m.withBoxType('a', true).boxTypeChoice('a'), isTrue);
    final none = meta('q');
    expect(identical(none.withBoxType('a', null), none), isTrue);
    final b = binder().withBoxType('a', true);
    expect(b.withBoxType('a', null).rawBoxTypes, isNull);
    expect(identical(b.withBoxType('a', true), b), isTrue);
  });

  test('unknown keys and values are kept as written; a non-boolean value inherits', () {
    final m = withRaw('{"future.box":{"x":1.50},"noted.draw":"no","noted.ai":false}');
    expect(m.boxTypeChoices, {'noted.ai': false});
    expect(m.boxTypeChoice('noted.draw'), isNull);
    final changed = m.withBoxType('noted.note', false);
    expect(
      changed.rawBoxTypes!.text,
      '{"future.box":{"x":1.50},"noted.draw":"no","noted.ai":false,"noted.note":false}',
    );
    final cleared = changed.withBoxType('noted.ai', null);
    expect(cleared.rawBoxTypes!.text, '{"future.box":{"x":1.50},"noted.draw":"no","noted.note":false}');
    expect(writePage(NotedPage.create(m)), contains('"future.box":{"x":1.50}'));
    // A non-boolean choice is not "not allowed".
    expect(effectiveBoxTypeAllowed('noted.draw', [m]).allowed, isTrue);
  });

  test('allowed unless any level disallows it, and the source is the highest one that does', () {
    final off = meta('top').withBoxType('t', false);
    final leaf = meta('leaf');
    expect(effectiveBoxTypeAllowed('t', [leaf]).allowed, isTrue);
    expect(effectiveBoxTypeAllowed('t', [leaf]).source, isNull);
    expect(effectiveBoxTypeAllowed('t', [leaf, off]), BoxTypeAvailability.disallowed(const ConfigSource.page('top')));
    expect(effectiveBoxTypeAllowed('t', [meta('leaf').withBoxType('t', false)]), const BoxTypeAvailability.disallowed(ConfigSource.own));
    expect(effectiveBoxTypeAllowed('other', [leaf, off]).allowed, isTrue);
    final b = binder().withBoxType('t', false);
    expect(effectiveBoxTypeAllowed('t', [leaf, off], binder: b), const BoxTypeAvailability.disallowed(ConfigSource.binder));
  });

  test('a lower level cannot allow what a higher one disallows', () {
    final b = binder().withBoxType('t', false);
    final leaf = meta('leaf').withBoxType('t', true);
    expect(effectiveBoxTypeAllowed('t', [leaf], binder: b).allowed, isFalse);
    final top = meta('top').withBoxType('t', false);
    expect(effectiveBoxTypeAllowed('t', [leaf, top]).allowed, isFalse);
    // Allowing at the binder (or the top) is harmless: nothing is disallowed.
    expect(effectiveBoxTypeAllowed('t', [leaf], binder: binder().withBoxType('t', true)).allowed, isTrue);
  });

  test('what a page inherits tells the UI whether it may allow the type', () {
    final top = meta('top').withBoxType('t', false);
    final leaf = meta('leaf').withBoxType('t', false);
    expect(inheritedBoxTypeAllowed('t', [leaf, top]), BoxTypeAvailability.disallowed(const ConfigSource.page('top')));
    expect(inheritedBoxTypeAllowed('t', [leaf]).allowed, isTrue);
    expect(inheritedBoxTypeAllowed('t', [leaf], binder: binder().withBoxType('t', false)).source, ConfigSource.binder);
  });
}
