// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:noted_core/noted_core_read.dart';

/// Page ids of the fixture, by name.
abstract final class Ids {
  static const public = 'a000000000000001'; // Whole page (own)
  static const publicChild = 'a000000000000002'; // inherits Whole page
  static const hidden = 'a000000000000003'; // Off (own), under public
  static const hiddenChild = 'a000000000000004'; // inherits Off
  static const boxUnderHidden = 'a000000000000005'; // Box only (own), under hidden
  static const plain = 'b000000000000001'; // nothing set: Off (default)
  static const plainChild = 'b000000000000002'; // Whole page (own), under plain
  static const boxy = 'c000000000000001'; // Box only (own)
  static const unknown = 'c000000000000002'; // unknown value: follows parent (none): Off
  static const binderPage = 'd000000000000001'; // inherits the binder's Whole page
  static const binderOff = 'd000000000000002'; // Off (own) in the binder
  static const locked = 'e000000000000001'; // Whole page, but its binder is locked
}

/// Text that must never reach AI.
const String secret = 'SECRET-DATA-7731';

Map<String, Object?> _para(List<Map<String, Object?>> delta) => {
  'type': 'paragraph',
  'data': {'delta': delta},
};

Map<String, Object?> _t(String text, [Map<String, Object?>? attrs]) => {'insert': text, 'attributes': ?attrs};

Map<String, Object?> _cell(int row, int col, String text, {String? value}) => {
  'type': 'table/cell',
  'data': {'rowPosition': row, 'colPosition': col},
  'children': [
    {
      'type': 'paragraph',
      'data': {
        'delta': [_t(text)],
        'formulaValue': ?value,
      },
    },
  ],
};

/// A note document with a heading, styled text, lists, a link to [linkedOff]
/// (an Off page) and to [linkedOn], an equation and a table.
Map<String, Object?> richNote({required String linkedOff, required String linkedOn}) => {
  'document': {
    'type': 'page',
    'children': [
      {
        'type': 'heading',
        'data': {
          'level': 2,
          'delta': [_t('Trip plan')],
        },
      },
      _para([_t('Pack the '), _t('zebra', {'bold': true}), _t(' tent and '), _t('maps', {'italic': true}), _t('.')]),
      {
        'type': 'bulleted_list',
        'data': {
          'delta': [_t('Tickets')],
        },
        'children': [
          {
            'type': 'bulleted_list',
            'data': {
              'delta': [_t('Train')],
            },
          },
        ],
      },
      {
        'type': 'numbered_list',
        'data': {
          'delta': [_t('Book')],
        },
      },
      {
        'type': 'numbered_list',
        'data': {
          'delta': [_t('Pay')],
        },
      },
      {
        'type': 'todo_list',
        'data': {
          'checked': true,
          'delta': [_t('Passport')],
        },
      },
      _para([
        _t('See '),
        _t('hidden notes', {'href': 'noted:page/$linkedOff'}),
        _t(', '),
        _t('the child', {'href': 'noted:page/$linkedOn'}),
        _t(' and '),
        _t('the web', {'href': 'https://example.com'}),
        _t('.'),
      ]),
      {
        'type': 'math_equation',
        'data': {'formula': r'E = mc^2'},
      },
      {
        'type': 'table',
        'data': {'rowsLen': 3, 'colsLen': 2},
        'children': [
          _cell(0, 0, 'Item'),
          _cell(0, 1, 'Cost'),
          _cell(1, 0, 'Tent'),
          _cell(1, 1, '120'),
          _cell(2, 0, 'Total'),
          _cell(2, 1, '=SUM(B2:B2)', value: '120'),
        ],
      },
    ],
  },
};

Map<String, Object?> simpleNote(String text) => {
  'document': {
    'type': 'page',
    'children': [
      _para([_t(text)]),
    ],
  },
};

BoxRecord box(String id, String type, Object? data, Bounds at, {String snapshot = ''}) =>
    BoxRecord.create(
      id: id,
      typeId: type,
      dataVersion: 1,
      bounds: at,
      data: RawJson.encode(data),
      snapshotText: snapshot,
      rev: 'r',
    );

NotedPage page(String id, String title, {String? parent, String? ai, List<CanvasNode> nodes = const []}) {
  var meta = PageMeta.create(id: id, title: title, order: 0, parentId: parent);
  if (ai != null) meta = PageMeta.tryRead(meta.fields.set(aiSettingKey, RawJson.encode(ai)))!;
  var p = NotedPage.create(meta);
  for (final n in nodes) {
    p = p.insertNode(n);
  }
  return p;
}

/// Writes the fixture's data folder: `settings.json`, `binders.json`, the
/// default `pages` folder, a binder whose AI setting is Whole page, and a
/// locked binder. Returns the data folder.
Directory writeFixture(Directory root) {
  final data = Directory('${root.path}/data')..createSync(recursive: true);
  final pages = Directory('${data.path}/pages')..createSync();
  final binder = Directory('${root.path}/Trips')..createSync();
  final locked = Directory('${root.path}/Vault')..createSync();
  void save(Directory d, NotedPage p) => File('${d.path}/${p.id}.canvas').writeAsStringSync(writePage(p));

  save(
    pages,
    page(
      Ids.public,
      'Public plans',
      ai: 'page',
      nodes: [
        // Out of file order on purpose: reading order is by position.
        box('img', 'noted.image', {
          'image': {'name': 'cat.png', 'size': 3, 'hash': 'h', 'file': 'h.png'},
          'width': 1,
          'height': 1,
          'alt': 'A cat on a map',
        }, const Bounds(500, 40, 100, 100)),
        box('note', 'noted.note', richNote(linkedOff: Ids.hidden, linkedOn: Ids.publicChild), const Bounds(40, 40, 400, 300)),
        box('drw', 'noted.drawing', {'strokes': secret}, const Bounds(40, 400, 200, 100)),
        box('file', 'noted.file', {
          'file': {'name': 'Itinerary.pdf', 'size': 9, 'hash': 'f', 'data': base64Encode(utf8.encode(secret))},
        }, const Bounds(300, 400, 280, 64)),
        box('enc', 'noted.encrypted', {'ciphertext': secret}, const Bounds(40, 600, 200, 60), snapshot: secret),
        box('odd', 'acme.chart', {'series': secret}, const Bounds(300, 600, 200, 60), snapshot: secret),
      ],
    ),
  );
  save(pages, page(Ids.publicChild, 'Packing list', parent: Ids.public, nodes: [box('n2', 'noted.note', simpleNote('zebra socks'), const Bounds(0, 0, 100, 40))]));
  save(pages, page(Ids.hidden, 'Hidden diary', parent: Ids.public, ai: 'off', nodes: [box('n3', 'noted.note', simpleNote('zebra $secret'), const Bounds(0, 0, 100, 40))]));
  save(pages, page(Ids.hiddenChild, 'Hidden child', parent: Ids.hidden, nodes: [box('n4', 'noted.note', simpleNote('zebra hidden child'), const Bounds(0, 0, 100, 40))]));
  save(pages, page(Ids.boxUnderHidden, 'Shared outline', parent: Ids.hidden, ai: 'box', nodes: [box('n5', 'noted.note', simpleNote('zebra kestrel $secret'), const Bounds(0, 0, 100, 40))]));
  save(pages, page(Ids.plain, 'Plain page', nodes: [box('n6', 'noted.note', simpleNote('zebra plain'), const Bounds(0, 0, 100, 40))]));
  save(pages, page(Ids.plainChild, 'Opened up', parent: Ids.plain, ai: 'page', nodes: [box('n7', 'noted.note', simpleNote('zebra opened'), const Bounds(0, 0, 100, 40))]));
  save(pages, page(Ids.boxy, 'Zebra boxes', ai: 'box', nodes: [box('n8', 'noted.note', simpleNote('giraffe $secret'), const Bounds(0, 0, 100, 40))]));
  save(pages, page(Ids.unknown, 'Future setting', ai: 'cloud', nodes: [box('n9', 'noted.note', simpleNote('zebra future'), const Bounds(0, 0, 100, 40))]));

  File('${binder.path}/$binderFileName').writeAsStringSync(
    Binder.create(title: 'Trips', color: binderPalette.first).withAiSetting(AiSetting.wholePage).write(),
  );
  save(binder, page(Ids.binderPage, 'Binder page', nodes: [box('n10', 'noted.note', simpleNote('zebra binder'), const Bounds(0, 0, 100, 40))]));
  save(binder, page(Ids.binderOff, 'Binder secret', ai: 'off', nodes: [box('n11', 'noted.note', simpleNote('zebra binder off'), const Bounds(0, 0, 100, 40))]));

  final vault = jsonDecode(Binder.create(title: 'Vault', color: binderPalette.first).write()) as Map<String, Object?>;
  vault['encryption'] = {'scheme': 'later'};
  File('${locked.path}/$binderFileName').writeAsStringSync(jsonEncode(vault));
  save(locked, page(Ids.locked, 'Vault page', ai: 'page', nodes: [box('n12', 'noted.note', simpleNote('zebra vault'), const Bounds(0, 0, 100, 40))]));

  File('${data.path}/settings.json').writeAsStringSync(jsonEncode({'format': 1, 'theme': 'system'}));
  File('${data.path}/binders.json').writeAsStringSync(
    jsonEncode({
      'format': 1,
      'binders': [binder.path, locked.path],
    }),
  );
  return data;
}

/// Ids of the pages AI must never see.
const Set<String> offIds = {Ids.hidden, Ids.hiddenChild, Ids.plain, Ids.unknown, Ids.binderOff, Ids.locked};

/// Titles of those pages.
const Set<String> offTitles = {'Hidden diary', 'Hidden child', 'Plain page', 'Future setting', 'Binder secret', 'Vault page'};
