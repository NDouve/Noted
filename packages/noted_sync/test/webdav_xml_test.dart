// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_sync/src/webdav/webdav_xml.dart';

List<int> b(String s) => utf8.encode(s);

const String _sample =
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">'
    '<d:response><d:href>/dav/Noted/</d:href><d:propstat><d:prop>'
    '<d:resourcetype><d:collection/></d:resourcetype>'
    '<oc:fileid>12</oc:fileid></d:prop>'
    '<d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
    '<d:propstat><d:prop><d:getetag/><d:getcontentlength/></d:prop>'
    '<d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>'
    '<d:response><d:href>/dav/Noted/a%20b.canvas</d:href><d:propstat><d:prop>'
    '<d:resourcetype/><d:getetag>&quot;e1&quot;</d:getetag>'
    '<d:getcontentlength>3</d:getcontentlength></d:prop>'
    '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
    '</d:multistatus>';

void main() {
  group('parseXml', () {
    test('elements, text, attributes and namespaces under any prefix', () {
      for (final doc in [
        '<a:r xmlns:a="urn:x"><a:c k="v">t</a:c></a:r>',
        '<z:r xmlns:z="urn:x"><z:c k="v">t</z:c></z:r>',
        '<r xmlns="urn:x"><c k="v">t</c></r>',
        '<r xmlns="urn:x"><q:c xmlns:q="urn:x" k="v">t</q:c></r>',
      ]) {
        final r = parseXml(b(doc));
        expect(r.named('urn:x', 'r'), isTrue, reason: doc);
        final c = r.child('urn:x', 'c')!;
        expect(c.text, 't');
        expect(c.attributes['k'], 'v');
      }
    });

    test('a prefix that is not bound, or bound twice, is handled by scope', () {
      expect(() => parseXml(b('<a:r/>')), throwsA(isA<XmlParseException>()));
      final r = parseXml(
        b('<r xmlns:p="urn:1"><p:a xmlns:p="urn:2"><p:b/></p:a><p:c/></r>'),
      );
      expect(r.children[0].ns, 'urn:2');
      expect(r.children[0].children[0].ns, 'urn:2');
      expect(r.children[1].ns, 'urn:1');
    });

    test('the five entities, numeric references, CDATA, comments, a BOM', () {
      final r = parseXml([
        0xef, 0xbb, 0xbf, //
        ...b(
          '<?xml version="1.0"?><!-- c --><r a="&lt;&amp;&#65;">'
          '&lt;&gt;&amp;&quot;&apos;&#x42;&#67;<![CDATA[<raw>&amp;]]>'
          '<!-- inner --></r><!-- after -->',
        ),
      ]);
      expect(r.attributes['a'], '<&A');
      expect(r.text, '<>&"\'BC<raw>&amp;');
    });

    test('a DOCTYPE or an entity declaration is refused', () {
      for (final doc in [
        '<!DOCTYPE r><r/>',
        '<!DOCTYPE r [<!ENTITY x "y">]><r>&x;</r>',
        '<?xml version="1.0"?><!DOCTYPE r SYSTEM "http://example.org/x.dtd"><r/>',
        '<r><!ENTITY x "y"></r>',
      ]) {
        expect(
          () => parseXml(b(doc)),
          throwsA(isA<XmlParseException>()),
          reason: doc,
        );
      }
    });

    test(
      'an entity that is not predefined is refused, even with no DOCTYPE',
      () {
        for (final doc in [
          '<r>&x;</r>',
          '<r>&nbsp;</r>',
          '<r>&amp</r>',
          '<r>&#;</r>',
          '<r>&#x;</r>',
          '<r>&#xZZ;</r>',
          '<r>&#0;</r>',
          '<r>&#1;</r>',
          '<r>&#xD800;</r>',
          '<r>&#1114112;</r>',
          '<r>&#+65;</r>',
          '<r a="&x;"/>',
        ]) {
          expect(
            () => parseXml(b(doc)),
            throwsA(isA<XmlParseException>()),
            reason: doc,
          );
        }
      },
    );

    test('malformed documents are refused', () {
      for (final doc in [
        '',
        '   ',
        'text',
        '<r>',
        '<r></s>',
        '<r><a></r></a>',
        '<r a=1/>',
        '<r a="1" a="2"/>',
        '<r a="<"/>',
        '<r/><s/>',
        '</r>',
        '<r><![CDATA[x</r>',
        '<r><!-- x</r>',
        '<r><? x</r>',
        '<1r/>',
        '<r xmlns:="x"/>',
        '<?xml version="1.0" encoding="utf-16"?><r/>',
      ]) {
        expect(
          () => parseXml(b(doc)),
          throwsA(isA<XmlParseException>()),
          reason: doc,
        );
      }
      expect(
        () => parseXml([0xff, 0xfe, 0x3c]),
        throwsA(isA<XmlParseException>()),
      );
    });

    test('nesting beyond the depth cap is refused, at any size', () {
      String nested(int n) => '${'<a>' * n}${'</a>' * n}';
      expect(parseXml(b(nested(64)), maxDepth: 64).name, 'a');
      expect(
        () => parseXml(b(nested(65)), maxDepth: 64),
        throwsA(isA<XmlParseException>()),
      );
      // Far deeper than the stack could take, with no end tags at all.
      expect(
        () => parseXml(b('<a>' * 200000)),
        throwsA(isA<XmlParseException>()),
      );
    });

    test('a billion-laughs shape expands to nothing', () {
      final doc =
          '<!DOCTYPE l [<!ENTITY a "aaaa"><!ENTITY b "&a;&a;&a;&a;">]>'
          '<l>&b;&b;&b;&b;</l>';
      expect(() => parseXml(b(doc)), throwsA(isA<XmlParseException>()));
    });
  });

  group('parseMultistatus', () {
    test(
      'responses, hrefs, propstats and a 404 propstat for a missing property',
      () {
        final rs = parseMultistatus(b(_sample));
        expect(rs, hasLength(2));
        expect(rs[0].hrefs, ['/dav/Noted/']);
        expect(rs[0].ok, isTrue);
        expect(
          rs[0].prop(davNs, 'resourcetype')!.childNames,
          contains('{DAV:}collection'),
        );
        expect(rs[0].prop(ownCloudNs, 'fileid')!.text, '12');
        // Missing from the 200 propstat, listed in the 404 one: just absent.
        expect(rs[0].prop(davNs, 'getetag'), isNull);
        expect(rs[0].propstats.map((p) => p.status), [200, 404]);
        // An empty resourcetype is present: a file.
        final file = rs[1].prop(davNs, 'resourcetype')!;
        expect(file.childNames, isEmpty);
        expect(rs[1].prop(davNs, 'getetag')!.text, '"e1"');
        expect(rs[1].prop(davNs, 'getcontentlength')!.text, '3');
      },
    );

    test('a property is read from a 2xx propstat only', () {
      final rs = parseMultistatus(
        b(
          '<d:multistatus xmlns:d="DAV:"><d:response><d:href>/x</d:href>'
          '<d:propstat><d:prop><d:getetag>"a"</d:getetag></d:prop>'
          '<d:status>HTTP/1.1 403 Forbidden</d:status></d:propstat>'
          '</d:response></d:multistatus>',
        ),
      );
      expect(rs.single.prop(davNs, 'getetag'), isNull);
    });

    test('a response status of its own, and an unreadable one', () {
      final rs = parseMultistatus(
        b(
          '<d:multistatus xmlns:d="DAV:">'
          '<d:response><d:href>/a</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>'
          '<d:response><d:href>/b</d:href><d:status>nonsense</d:status></d:response>'
          '<d:response><d:href>/c</d:href><d:status>HTTP/1.1 200 OK</d:status></d:response>'
          '<d:response><d:href>/d</d:href></d:response>'
          '</d:multistatus>',
        ),
      );
      expect(rs.map((r) => r.ok), [false, false, true, true]);
      expect(rs[0].status, 404);
      expect(rs[1].status, 0);
      expect(rs[3].status, isNull);
    });

    test('a resource-id is the text inside its href', () {
      final rs = parseMultistatus(
        b(
          '<D:multistatus xmlns:D="DAV:"><D:response><D:href>/x</D:href>'
          '<D:propstat><D:prop><D:resource-id><D:href>urn:uuid:1</D:href>'
          '</D:resource-id></D:prop><D:status>HTTP/1.1 200 OK</D:status>'
          '</D:propstat></D:response></D:multistatus>',
        ),
      );
      expect(rs.single.prop(davNs, 'resource-id')!.text, 'urn:uuid:1');
    });

    test('anything that is not a multistatus, or a response with no href, is refused', () {
      for (final doc in [
        '<d:other xmlns:d="DAV:"/>',
        '<multistatus/>',
        '<d:multistatus xmlns:d="DAV:"><d:response/></d:multistatus>',
        '<d:multistatus xmlns:d="DAV:"><d:response><d:href> </d:href></d:response></d:multistatus>',
      ]) {
        expect(
          () => parseMultistatus(b(doc)),
          throwsA(isA<XmlParseException>()),
          reason: doc,
        );
      }
    });
  });

  group('fuzz', () {
    // Whatever the input, the parser ends and throws only XmlParseException.
    void check(List<int> bytes) {
      try {
        parseMultistatus(bytes);
      } on XmlParseException {
        // Refused: fine.
      }
    }

    test('random bytes', () {
      final rnd = Random(11);
      for (var i = 0; i < 3000; i++) {
        check([for (var k = rnd.nextInt(200); k > 0; k--) rnd.nextInt(256)]);
      }
    });

    test('random strings made of markup pieces', () {
      final rnd = Random(12);
      const pieces = [
        '<',
        '>',
        '/',
        '</',
        '/>',
        '<?',
        '?>',
        '<!--',
        '-->',
        '<![CDATA[',
        ']]>',
        '<!',
        '&',
        ';',
        '&#',
        '&#x',
        'amp',
        'lt',
        'xmlns',
        'xmlns:d',
        '="',
        '"',
        "'",
        '=',
        ' ',
        ':',
        'd:',
        'a',
        'DAV:',
        'multistatus',
        'response',
        'href',
        'd:response',
        'd:href',
        'propstat',
        'status',
        'é',
        '\u{1F600}',
        '\u0000',
        '\n',
      ];
      for (var i = 0; i < 5000; i++) {
        final s = StringBuffer();
        for (var k = rnd.nextInt(40); k > 0; k--) {
          s.write(pieces[rnd.nextInt(pieces.length)]);
        }
        check(b(s.toString()));
      }
    });

    test('a valid reply with bytes changed, cut or inserted', () {
      final rnd = Random(13);
      final base = b(_sample);
      for (var i = 0; i < 4000; i++) {
        final bytes = List<int>.of(base);
        for (var k = 1 + rnd.nextInt(4); k > 0; k--) {
          switch (rnd.nextInt(3)) {
            case 0:
              bytes[rnd.nextInt(bytes.length)] = rnd.nextInt(256);
            case 1:
              final from = rnd.nextInt(bytes.length);
              bytes.removeRange(
                from,
                min(bytes.length, from + 1 + rnd.nextInt(30)),
              );
              if (bytes.isEmpty) bytes.add(0x3c);
            default:
              bytes.insert(rnd.nextInt(bytes.length), rnd.nextInt(256));
          }
        }
        if (rnd.nextBool()) bytes.length = rnd.nextInt(bytes.length) + 1;
        check(bytes);
      }
    });
  });
}
