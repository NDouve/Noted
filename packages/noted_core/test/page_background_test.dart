// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

String pageText({String? background, String title = 'T'}) =>
    '{"nodes":[],"edges":[],'
    '"noted":{"format":1,"pageId":"p1","parentId":null,"title":"$title",'
    '"order":0,"extra":1.50${background == null ? '' : ',"background":$background'}}}';

void main() {
  test('each background round-trips', () {
    for (final b in PageBackground.values) {
      final src = readPage(pageText(background: '"${b.name}"'));
      expect(src.meta.background, b);
      expect(readPage(writePage(src)).meta.background, b);
      expect(writePage(readPage(writePage(src))), writePage(src));
    }
  });

  test('a missing value reads as plain and writes nothing', () {
    final page = readPage(pageText());
    expect(page.meta.background, PageBackground.plain);
    expect(writePage(page), isNot(contains('background')));
  });

  test('choosing a background writes it; plain removes the key', () {
    var page = readPage(pageText());
    page = page.withMeta(page.meta.withBackground(PageBackground.ruled));
    expect(writePage(page), contains('"background":"ruled"'));
    expect(readPage(writePage(page)).meta.background, PageBackground.ruled);
    page = page.withMeta(page.meta.withBackground(PageBackground.plain));
    expect(writePage(page), isNot(contains('background')));
    expect(page.meta.background, PageBackground.plain);
  });

  test('other header fields stay byte-identical when the background changes', () {
    final page = readPage(pageText(title: 'T'));
    final before = writePage(page);
    final dots = writePage(page.withMeta(page.meta.withBackground(PageBackground.dots)));
    expect(dots.replaceAll(',"background":"dots"', ''), before);
    final back = readPage(dots);
    expect(writePage(back.withMeta(back.meta.withBackground(PageBackground.plain))), before);
  });

  test('an unknown value reads as plain and is preserved byte-for-byte', () {
    for (final raw in ['"hexagons"', '3', '{ "a" : [ 1 ] }']) {
      final src = pageText(background: raw);
      final page = readPage(src);
      expect(page.meta.background, PageBackground.plain);
      final out = writePage(page);
      expect(out, contains('"background":$raw'));
      expect(writePage(readPage(out)), out);

      // Renaming and moving the page leave the unknown value alone.
      final renamed = page.withMeta(page.meta.withTitle('New'));
      expect(writePage(renamed), contains('"background":$raw'));
      final moved = page.withMeta(page.meta.withPlacement(parentId: 'q', order: 3));
      expect(writePage(moved), contains('"background":$raw'));
      // Choosing what it already reads as (plain) is the user's choice: it goes.
      final plain = page.meta.withBackground(PageBackground.plain);
      expect(plain.rawBackground, isNull);
    }
  });

  test('an explicit "plain" is kept when plain is chosen again', () {
    final page = readPage(pageText(background: '"plain"'));
    expect(identical(page.meta.withBackground(PageBackground.plain), page.meta), isTrue);
    expect(writePage(page), contains('"background":"plain"'));
  });

  test('undo restores the previous stored value, unknown ones included', () {
    final codecs = CodecRegistry();
    final h = PageHistory();
    var page = readPage(pageText(background: '"hexagons"'));
    h.record(PageChange.background(page.meta.rawBackground));
    page = page.withMeta(page.meta.withBackground(PageBackground.graph));
    page = page.withMeta(page.meta.withTitle('Renamed'));
    page = h.undo(page, codecs)!;
    expect(page.meta.rawBackground!.text, '"hexagons"');
    expect(page.meta.title, 'Renamed');
    page = h.redo(page, codecs)!;
    expect(page.meta.background, PageBackground.graph);
  });

  test('a page template carries the background, also into a new page', () {
    final page = readPage(pageText(background: '"graph"'));
    final t = NotedTemplate.forPage(
      name: 'Grid',
      page: page,
      id: 'aaaaaaaaaaaaaaaa',
      created: DateTime.utc(2026, 1, 1),
    );
    expect(t.page.meta.background, PageBackground.graph);
    final back = NotedTemplate.parse(t.write());
    expect(back.page.meta.background, PageBackground.graph);
    final fresh = back.instantiatePage(order: 0);
    expect(fresh.meta.background, PageBackground.graph);
    expect(writePage(fresh), contains('"background":"graph"'));
  });
}
