// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:noted_core/noted_core_read.dart';

/// Page ids of the fixture, by name.
abstract final class Ids {
  static const public = 'a000000000000001'; // Open (own), top-level
  static const publicChild = 'a000000000000002'; // inherits Open
  static const hidden = 'a000000000000003'; // Guarded (own), tightens public
  static const hiddenChild = 'a000000000000004'; // inherits Guarded
  static const looser = 'a000000000000005'; // Open (own) under hidden: ignored, stays Guarded
  static const plain = 'b000000000000001'; // nothing set: Guarded (default)
  static const plainChild = 'b000000000000002'; // Open (own) under plain: ignored, stays Guarded
  static const priv = 'c000000000000001'; // Privileged (own), top-level
  static const privChild = 'c000000000000002'; // inherits Privileged
  static const privLoose = 'c000000000000003'; // Open (own) under priv: ignored, stays Privileged
  static const privTight = 'c000000000000004'; // Guarded (own) under priv
  static const unknown = 'c000000000000005'; // unknown value: Guarded
  static const legacyPage = 'c000000000000006'; // legacy "page": Open
  static const legacyBox = 'c000000000000007'; // legacy "box": Guarded
  static const legacyOff = 'c000000000000008'; // legacy "off": Guarded
  static const binderPage = 'd000000000000001'; // inherits the binder's Open
  static const binderPriv = 'd000000000000002'; // Privileged (own) in the Open binder: tightens
  static const binderGuarded = 'd000000000000003'; // Guarded (own) in the binder
  static const privBinderPage = 'd100000000000001'; // inherits a Privileged binder
  static const guardedBinderPage = 'd200000000000001'; // binder with nothing set: Guarded
  static const locked = 'e000000000000001'; // Open, but its binder is locked
  static const aiOpen = 'f000000000000001'; // Open: a note, two AI boxes
  static const aiGuarded = 'f000000000000002'; // Guarded: an AI box
  static const aiLocked = 'f000000000000003'; // in the locked binder: an AI box
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
/// (a page AI can't see) and to [linkedOn], an equation and a table.
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

/// The data of an AI box whose text is [text], marked as written by an AI.
Map<String, Object?> aiBoxData(String text, {String? owner}) {
  final para = markAiWritten({
    'type': 'paragraph',
    'data': {
      'delta': [
        {'insert': text},
      ],
    },
  });
  return {
    'owner': ?owner,
    'document': {
      'type': 'page',
      'children': [para],
    },
  };
}

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

/// A page; [ai] is the stored `ai` value exactly as written (legacy and
/// unknown values included).
NotedPage page(String id, String title, {String? parent, String? ai, List<CanvasNode> nodes = const []}) {
  var meta = PageMeta.create(id: id, title: title, order: 0, parentId: parent);
  if (ai != null) meta = PageMeta.tryRead(meta.fields.set(aiAccessKey, RawJson.encode(ai)))!;
  var p = NotedPage.create(meta);
  for (final n in nodes) {
    p = p.insertNode(n);
  }
  return p;
}

/// Writes the fixture's data folder: `settings.json`, `binders.json`, the
/// default `pages` folder, a binder that is Open, one that is Privileged, one
/// with nothing set, and a locked binder. Returns the data folder.
Directory writeFixture(Directory root) {
  final data = Directory('${root.path}/data')..createSync(recursive: true);
  final pages = Directory('${data.path}/pages')..createSync();
  final binder = Directory('${root.path}/Trips')..createSync();
  final privBinder = Directory('${root.path}/Taxes')..createSync();
  final bareBinder = Directory('${root.path}/Bare')..createSync();
  final locked = Directory('${root.path}/Vault')..createSync();
  void save(Directory d, NotedPage p) => File('${d.path}/${p.id}.canvas').writeAsStringSync(writePage(p));
  const small = Bounds(0, 0, 100, 40);

  save(
    pages,
    page(
      Ids.public,
      'Public plans',
      ai: 'open',
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
  save(pages, page(Ids.publicChild, 'Packing list', parent: Ids.public, nodes: [box('n2', 'noted.note', simpleNote('zebra socks'), small)]));
  save(pages, page(Ids.hidden, 'Hidden diary', parent: Ids.public, ai: 'guarded', nodes: [box('n3', 'noted.note', simpleNote('zebra $secret'), small)]));
  save(pages, page(Ids.hiddenChild, 'Hidden child', parent: Ids.hidden, nodes: [box('n4', 'noted.note', simpleNote('zebra hidden child'), small)]));
  save(pages, page(Ids.looser, 'Looser outline', parent: Ids.hidden, ai: 'open', nodes: [box('n5', 'noted.note', simpleNote('zebra kestrel $secret'), small)]));
  save(pages, page(Ids.plain, 'Plain page', nodes: [box('n6', 'noted.note', simpleNote('zebra plain'), small)]));
  save(pages, page(Ids.plainChild, 'Opened up', parent: Ids.plain, ai: 'open', nodes: [box('n7', 'noted.note', simpleNote('zebra opened'), small)]));
  save(pages, page(Ids.priv, 'Zebra privileged', ai: 'privileged', nodes: [box('n8', 'noted.note', simpleNote('giraffe privileged text'), small)]));
  save(pages, page(Ids.privChild, 'Privileged child', parent: Ids.priv, nodes: [box('n13', 'noted.note', simpleNote('zebra privileged child'), small)]));
  save(pages, page(Ids.privLoose, 'Loosened child', parent: Ids.priv, ai: 'open', nodes: [box('n14', 'noted.note', simpleNote('zebra loosened child'), small)]));
  save(pages, page(Ids.privTight, 'Tightened child', parent: Ids.priv, ai: 'guarded', nodes: [box('n15', 'noted.note', simpleNote('zebra tightened child'), small)]));
  save(pages, page(Ids.unknown, 'Future setting', ai: 'cloud', nodes: [box('n9', 'noted.note', simpleNote('zebra future'), small)]));
  save(pages, page(Ids.legacyPage, 'Legacy page', ai: 'page', nodes: [box('n16', 'noted.note', simpleNote('zebra legacy page'), small)]));
  save(pages, page(Ids.legacyBox, 'Legacy box', ai: 'box', nodes: [box('n17', 'noted.note', simpleNote('zebra legacy box'), small)]));
  save(pages, page(Ids.legacyOff, 'Legacy off', ai: 'off', nodes: [box('n18', 'noted.note', simpleNote('zebra legacy off'), small)]));
  save(
    pages,
    page(
      Ids.aiOpen,
      'Open AI',
      ai: 'open',
      nodes: [
        box('note1', 'noted.note', simpleNote('okapi note'), small),
        box('aiA', aiBoxTypeId, aiBoxData('okapi from A'), const Bounds(0, 100, 100, 40)),
        box('aiB', aiBoxTypeId, aiBoxData('okapi from B', owner: '9999999999999999'), const Bounds(0, 200, 100, 40)),
      ],
    ),
  );
  save(
    pages,
    page(
      Ids.aiGuarded,
      'Guarded AI',
      ai: 'guarded',
      nodes: [
        box('note2', 'noted.note', simpleNote('okapi private $secret'), small),
        box(
          'aiG',
          aiBoxTypeId,
          aiBoxData('okapi guarded box see the other page'),
          const Bounds(0, 100, 100, 40),
        ),
      ],
    ),
  );

  File('${binder.path}/$binderFileName').writeAsStringSync(
    Binder.create(title: 'Trips', color: binderPalette.first).withAiAccess(AiAccess.open).write(),
  );
  save(binder, page(Ids.binderPage, 'Binder page', nodes: [box('n10', 'noted.note', simpleNote('zebra binder'), small)]));
  save(binder, page(Ids.binderPriv, 'Binder looser', ai: 'privileged', nodes: [box('n11', 'noted.note', simpleNote('zebra binder privileged'), small)]));
  save(binder, page(Ids.binderGuarded, 'Binder secret', ai: 'guarded', nodes: [box('n19', 'noted.note', simpleNote('zebra binder guarded'), small)]));

  File('${privBinder.path}/$binderFileName').writeAsStringSync(
    Binder.create(title: 'Taxes', color: binderPalette.first).withAiAccess(AiAccess.privileged).write(),
  );
  save(privBinder, page(Ids.privBinderPage, 'Tax page', nodes: [box('n20', 'noted.note', simpleNote('zebra taxes'), small)]));

  File('${bareBinder.path}/$binderFileName').writeAsStringSync(
    Binder.create(title: 'Bare', color: binderPalette.first).write(),
  );
  save(bareBinder, page(Ids.guardedBinderPage, 'Bare page', nodes: [box('n21', 'noted.note', simpleNote('zebra bare'), small)]));

  final vault = jsonDecode(Binder.create(title: 'Vault', color: binderPalette.first).write()) as Map<String, Object?>;
  vault['encryption'] = {'scheme': 'later'};
  vault['ai'] = 'open';
  File('${locked.path}/$binderFileName').writeAsStringSync(jsonEncode(vault));
  save(locked, page(Ids.locked, 'Vault page', ai: 'open', nodes: [box('n12', 'noted.note', simpleNote('zebra vault'), small)]));
  save(
    locked,
    page(Ids.aiLocked, 'Vault AI', ai: 'open', nodes: [box('aiV', aiBoxTypeId, aiBoxData('okapi vault box'), small)]),
  );

  File('${data.path}/settings.json').writeAsStringSync(jsonEncode({'format': 1, 'theme': 'system'}));
  File('${data.path}/binders.json').writeAsStringSync(
    jsonEncode({
      'format': 1,
      'binders': [binder.path, privBinder.path, bareBinder.path, locked.path],
    }),
  );
  return data;
}

/// The pages any AI reads without a code.
const Set<String> openIds = {
  Ids.public,
  Ids.publicChild,
  Ids.legacyPage,
  Ids.binderPage,
  Ids.aiOpen,
};

/// Ids of the pages AI must never see, whatever it holds (a code can't open
/// them): Guarded ones (own, inherited, legacy, unknown or default), pages
/// in a locked binder.
const Set<String> guardedIds = {
  Ids.hidden,
  Ids.hiddenChild,
  Ids.looser,
  Ids.plain,
  Ids.plainChild,
  Ids.privTight,
  Ids.unknown,
  Ids.legacyBox,
  Ids.legacyOff,
  Ids.binderGuarded,
  Ids.guardedBinderPage,
  Ids.aiGuarded,
  Ids.locked,
  Ids.aiLocked,
};

/// The Privileged pages: visible only with a grant.
const Set<String> privilegedIds = {Ids.priv, Ids.privChild, Ids.privLoose, Ids.binderPriv, Ids.privBinderPage};

/// Titles of the Guarded pages.
const Set<String> guardedTitles = {
  'Hidden diary',
  'Hidden child',
  'Looser outline',
  'Plain page',
  'Opened up',
  'Tightened child',
  'Future setting',
  'Legacy box',
  'Legacy off',
  'Binder secret',
  'Bare page',
  'Guarded AI',
  'Vault page',
  'Vault AI',
};
