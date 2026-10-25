// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

const String oddData = '{ "z":1.0,"a" :[1e2,  -0.0], "s":"\\u00e9" }';

String pageText(String id, {String? parent, int order = 0, String title = 'T'}) =>
    '{"edges":[{"id":"e1","fromNode":"b1","toNode":"f1"}],'
    '"nodes":[{"id":"b1","type":"text","x":10,"y":20,"width":300,"height":80,'
    '"text":"caf\\u00e9","futureField":[ 1 ],'
    '"noted":{"type":"vendor.future","v":7,"rev":"r1","baseRev":"r0",'
    '"data":$oddData,"conflicts":[{"deleted":true,"at":1}],"later":true}},'
    '{ "id":"f1","type":"file","file":"a.png","x":0,"y":0,"width":5,"height":5 }],'
    '"noted":{"format":1,"pageId":"$id","parentId":${parent == null ? 'null' : '"$parent"'},'
    '"title":"$title","order":$order,"extra":1.50}}';

void main() {
  test('a page template round-trips and keeps box content verbatim', () {
    final t = NotedTemplate.forPage(
      name: 'Notes',
      page: readPage(pageText('p1', parent: 'x', order: 4)),
      id: 'aaaaaaaaaaaaaaaa',
      created: DateTime.utc(2026, 1, 1),
    );
    expect(t.kind, TemplateKind.page);
    expect(t.page.meta.parentId, isNull);
    expect(t.page.meta.order, 0);
    final text = t.write();
    expect(text, contains('"data":$oddData'));
    final back = NotedTemplate.parse(text);
    expect(back.id, 'aaaaaaaaaaaaaaaa');
    expect(back.name, 'Notes');
    expect(back.created, DateTime.utc(2026, 1, 1).millisecondsSinceEpoch);
    expect(back.write(), text);
    expect(writePage(back.page), writePage(t.page));
  });

  test('unknown fields and extensions round-trip byte for byte', () {
    final src =
        '{"format":1,"templateId":"abc","kind":"page","name":"N","created":5,'
        '"extensions":{"rules":[ 1,  2 ],"s":"\\u00e9"},"x-future":{"a": 1.50},'
        '"page":${pageText('p1')}}\n';
    final t = NotedTemplate.parse(src);
    expect(t.write(), src);
    expect(t.extensions!.text, '{"rules":[ 1,  2 ],"s":"\\u00e9"}');
    expect(t.fields.toRaw().text, contains('"x-future":{"a": 1.50}'));
  });

  test('a newer format is refused', () {
    final src = '{"format":2,"templateId":"abc","kind":"page","name":"N","page":${pageText('p1')}}';
    expect(() => NotedTemplate.parse(src), throwsA(isA<UnsupportedTemplateFormatException>()));
    expect(() => NotedTemplate.parse('nope'), throwsA(isA<TemplateFormatException>()));
    expect(
      () => NotedTemplate.parse('{"format":1,"templateId":"a","kind":"zzz"}'),
      throwsA(isA<TemplateFormatException>()),
    );
    expect(
      () => NotedTemplate.parse('{"format":1,"templateId":"a","kind":"page","page":{"noted":{}}}'),
      throwsA(isA<TemplateFormatException>()),
    );
  });

  test('instantiating a page gives new ids and revs, and keeps contents', () {
    final t = NotedTemplate.forPage(name: 'N', page: readPage(pageText('p1', title: 'Title')));
    final a = t.instantiatePage(parentId: 'par', order: 3);
    final b = t.instantiatePage(order: 0, title: 'Other');
    expect(a.id, isNot('p1'));
    expect(a.id, isNot(b.id));
    expect(a.meta.parentId, 'par');
    expect(a.meta.order, 3);
    expect(a.meta.title, 'Title');
    expect(b.meta.title, 'Other');
    expect(a.meta.fields['extra']!.text, '1.50');
    final box = a.nodes[0] as BoxRecord;
    final src = t.page.nodes[0] as BoxRecord;
    expect(box.id, isNot('b1'));
    expect(box.id, isNot((b.nodes[0] as BoxRecord).id));
    expect(box.rev, isNot('r1'));
    expect(box.rev, hasLength(16));
    expect(box.baseRev, isNull);
    expect(box.isConflicted, isFalse);
    expect(box.data!.text, oddData);
    expect(box.noted['later']!.text, 'true');
    expect(box.snapshotText, src.snapshotText);
    expect(box.bounds, src.bounds);
    expect(box.fields['futureField']!.text, '[ 1 ]');
    final foreign = a.nodes[1] as ForeignNode;
    expect(foreign.id, isNot('f1'));
    expect(foreign.nodeType, 'file');
    // The edge follows the new ids.
    final edge = a.top['edges']!.text;
    expect(edge, contains('"fromNode":"${box.id}"'));
    expect(edge, contains('"toNode":"${foreign.id}"'));
    // The result is a valid page file.
    expect(readPage(writePage(a)).nodes, hasLength(2));
  });

  test('a binder template keeps settings and tree, with new ids', () {
    final binder = Binder.create(
      title: 'Work',
      description: 'd',
      owner: 'me',
      color: binderPalette[2],
    );
    final t = NotedTemplate.forBinder(
      name: 'Work',
      binder: binder,
      pages: [
        readPage(pageText('p1', title: 'Root')),
        readPage(pageText('p2', parent: 'p1', order: 1, title: 'Child')),
        readPage(pageText('p3', parent: 'gone', title: 'Orphan')),
      ],
    );
    final back = NotedTemplate.parse(t.write());
    expect(back.kind, TemplateKind.binder);
    expect(back.binderSettings.title, 'Work');
    expect(back.pages.map((p) => p.id), ['p1', 'p2', 'p3']);
    final made = back.instantiateBinder();
    expect(made.binder.id, isNot(binder.id));
    expect(
      [made.binder.title, made.binder.description, made.binder.owner, made.binder.color],
      ['Work', 'd', 'me', binderPalette[2]],
    );
    final ids = made.pages.map((p) => p.id).toSet();
    expect(ids, hasLength(3));
    expect(ids.intersection({'p1', 'p2', 'p3'}), isEmpty);
    expect(made.pages[0].meta.parentId, isNull);
    expect(made.pages[1].meta.parentId, made.pages[0].id);
    expect(made.pages[1].meta.order, 1);
    expect(made.pages[2].meta.parentId, isNull);
    expect(made.pages[1].meta.title, 'Child');
    expect((made.pages[1].nodes[0] as BoxRecord).data!.text, oddData);
  });

  test('the store lists, saves, never overwrites, and lists unreadable files', () async {
    final dir = await Directory.systemTemp.createTemp('noted_tpl');
    addTearDown(() => dir.delete(recursive: true));
    final store = TemplateStore(Directory('${dir.path}/templates'));
    expect(await store.scan(), isEmpty);
    expect(Directory('${dir.path}/templates').existsSync(), isFalse);

    final t = NotedTemplate.forPage(name: 'N', page: readPage(pageText('p1')));
    final file = await store.save(t);
    expect(file.path, endsWith('${t.id}$templateExtension'));
    await expectLater(store.save(t), throwsA(isA<FileSystemException>()));

    final newer = File('${dir.path}/templates/zzz$templateExtension')
      ..writeAsStringSync('{"format":9,"templateId":"zzz","kind":"page"}');
    final entries = await store.scan();
    expect(entries.whereType<ReadableTemplate>().single.template.id, t.id);
    String norm(String p) => p.replaceAll(r'\', '/');
    expect(norm(entries.whereType<UnreadableTemplate>().single.path), norm(newer.path));
    expect(newer.readAsStringSync(), '{"format":9,"templateId":"zzz","kind":"page"}');
    expect(
      Directory('${dir.path}/templates').listSync().where((f) => f.path.endsWith('.tmp')),
      isEmpty,
    );

    await store.delete(file.path);
    expect(file.existsSync(), isFalse);
  });
}
