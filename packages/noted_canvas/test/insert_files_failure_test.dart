// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

class _Codec extends BoxCodec<String> {
  const _Codec();
  @override
  String get typeId => 'test.file';
  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.growsWithContent;
  @override
  String create() => '';
  @override
  String decode(Object? json, int storedVersion) => json! as String;
  @override
  Object? encode(String data) => data;
  @override
  String snapshotText(String data) => data;
  @override
  bool isEmpty(String data) => data.trim().isEmpty;
  @override
  AiExposure aiExposure(String data) => AiText(data);
}

/// A module that stores each file through the page's store, as the image and
/// file boxes do.
class _Module extends BoxModule<String> {
  const _Module();
  @override
  BoxCodec<String> get codec => const _Codec();
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) => Text(box.data);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) => Text(box.data);
  @override
  int fileAffinity(IncomingFile file) => 1;
  @override
  Future<(String, Size)?> createFromFile(IncomingFile file, AttachmentStore store) async {
    await store.put(file.bytes, extension: file.extension);
    return (file.name, const Size(100, 40));
  }
}

/// A store whose folder rejects files named in [reject].
class _Store implements AttachmentStore {
  _Store(this.reject);
  final Set<String> reject;
  final List<String> notices = [];

  @override
  Future<StoredAttachment> put(Uint8List bytes, {required String extension, AttachmentStorage? storage}) async {
    if (reject.contains(extension)) throw const FileSystemException('The folder rejects new files');
    return StoredAttachment(hash: contentHash(bytes), fileName: 'x.$extension');
  }

  @override
  void notify(String message) => notices.add(message);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  testWidgets('a file whose copy cannot be stored makes no box and is reported; the others still go in', (t) async {
    final store = _Store({'bad'});
    final c = CanvasController(
      NotedPage.create(PageMeta.create(id: 'p', title: 'T', order: 0)),
      ModuleRegistry()..register(const _Module(), alwaysOn: true, isDefault: true),
    );
    final key = GlobalKey<PageCanvasState>();
    t.view.physicalSize = const Size(1000, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageCanvas(key: key, controller: c, attachments: store),
        ),
      ),
    );
    await key.currentState!.insertFiles([
      IncomingFile('first.bad', Uint8List.fromList(const [1])),
      IncomingFile('second.txt', Uint8List.fromList(const [2])),
    ]);
    await t.pump();
    expect(c.page.nodes.whereType<BoxRecord>(), hasLength(1));
    expect(store.notices, ['"first.bad" could not be added: the page\'s folder could not be written.']);
    c.dispose();
  });
}
