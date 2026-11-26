// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// What Export checks about a box before anything is asked or made: it exists,
// isn't encrypted, its type is allowed, its module is on and lists a format,
// and a file is ready. Boxes that fail are never decoded.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/export/export_flow.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

/// Counts decodes; a box of this type must never be decoded when it can't be
/// exported.
int decodes = 0;

class _Codec extends BoxCodec<String> {
  const _Codec(this.typeId);
  @override
  final String typeId;
  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.fixed;
  @override
  String create() => '';
  @override
  String decode(Object? json, int storedVersion) {
    decodes++;
    return json! as String;
  }

  @override
  Object? encode(String data) => data;
  @override
  String snapshotText(String data) => data;
  @override
  AiExposure aiExposure(String data) => AiText(data);
}

class _Module extends BoxModule<String> {
  _Module(this.id, this.formats);
  final String id;
  final List<ExportFormat> formats;

  @override
  BoxCodec<String> get codec => _Codec(id);
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) => const SizedBox();
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) => const SizedBox();
  @override
  List<ExportFormat> exportFormats(String data) => formats;
}

BoxRecord _record(String id, String type, {int version = 1, String data = 'x'}) => BoxRecord.create(
  id: id,
  typeId: type,
  dataVersion: version,
  bounds: const Bounds(0, 0, 100, 50),
  data: RawJson.encode(data),
  snapshotText: 'saved',
  rev: 'r',
);

class _Store extends ChangeNotifier implements AttachmentStore {
  final Map<String, Uint8List> folder = {};
  @override
  AttachmentStorage get storage => AttachmentStorage.folder;
  @override
  Future<StoredAttachment> put(Uint8List bytes, {required String extension, AttachmentStorage? storage}) =>
      throw UnimplementedError();
  @override
  Future<Uint8List?> read(String fileName) async => folder[fileName];
  @override
  bool exists(String fileName) => folder.containsKey(fileName);
  @override
  Listenable get changes => this;
  @override
  Directory get cacheDirectory => Directory.systemTemp;
  @override
  void notify(String message) {}
  @override
  Future<void> open(String name, {String? fileName, Uint8List? bytes}) async {}
  @override
  Future<List<IncomingFile>> pick({required bool imagesOnly}) async => const [];
}

class _DownloadStore extends _Store implements DownloadingAttachmentStore {
  final Map<String, AttachmentDownload> state = {};
  @override
  AttachmentDownload download(String fileName) => state[fileName] ?? AttachmentDownload.onDevice;
  @override
  String? downloadError(String fileName) => null;
  @override
  void retryDownload(String fileName) {}
}

void main() {
  late ModuleRegistry modules;
  late CanvasController c;

  ExportTarget target({Set<String> disallowed = const {}, AttachmentStore? store}) => ExportTarget.internal(
    controller: c,
    pageId: 'p',
    store: store,
    disallowed: disallowed,
    check: () => true,
  );

  void setUpPage(List<BoxRecord> boxes) {
    var page = NotedPage.create(PageMeta.create(id: 'p', title: 'T', order: 0));
    for (final b in boxes) {
      page = page.insertNode(b);
    }
    c = CanvasController(page, modules, onChanged: (_) {});
  }

  setUp(() {
    decodes = 0;
    modules = ModuleRegistry()
      ..register(_Module('test.ok', const [ExportFormat.text, ExportFormat.png]))
      ..register(_Module('test.none', const []))
      ..register(_Module('test.encrypted', const [ExportFormat.text]))
      ..register(_Module('test.off', const [ExportFormat.text]), enabled: false)
      ..register(_Module('test.old', const [ExportFormat.text]))
      ..register(const ImageModule())
      ..register(const FileModule(), isDefault: true);
  });

  Future<ExportCheck> check(String id, {Set<String> disallowed = const {}, AttachmentStore? store}) =>
      checkBoxForExport(target(disallowed: disallowed, store: store), id);

  String? reason(ExportCheck c) => c is ExportBlocked ? c.reason : null;

  test('a box that can be exported is ready with the module\'s formats and its label', () async {
    setUpPage([_record('a', 'test.ok')]);
    final r = await check('a') as ExportReady;
    expect([for (final f in r.formats) f.id], ['text', 'png', 'jpeg', 'pdf']);
    expect(r.data, 'x');
    expect(decodes, 1);
  });

  test('jpeg and pdf follow a listed png; one a module lists itself is dropped', () {
    expect(
      [for (final f in exportFormatsFor(const [ExportFormat.text, ExportFormat.png, ExportFormat.html]))  f.id],
      ['text', 'png', 'jpeg', 'pdf', 'html'],
    );
    expect(
      [for (final f in exportFormatsFor(const [ExportFormat.jpeg, ExportFormat.pdf, ExportFormat.text]))  f.id],
      ['text'],
      reason: 'no png: the host adds nothing, and drops the module\'s jpeg and pdf',
    );
    expect(
      [for (final f in exportFormatsFor(const [ExportFormat.pdf, ExportFormat.png, ExportFormat.jpeg]))  f.id],
      ['png', 'jpeg', 'pdf'],
    );
  });

  test('a module that lists nothing turns Export off', () async {
    setUpPage([_record('a', 'test.none')]);
    expect(reason(await check('a')), "This box can't be exported.");
  });

  test('a box that is gone says so', () async {
    setUpPage([]);
    expect(reason(await check('nope')), 'Box removed. Nothing was exported.');
  });

  test('an encrypted box is never decoded', () async {
    setUpPage([_record('a', 'test.encrypted')]);
    expect(reason(await check('a')), 'Encrypted box');
    expect(decodes, 0);
  });

  test('a disallowed type is never decoded', () async {
    setUpPage([_record('a', 'test.ok')]);
    expect(reason(await check('a', disallowed: {'test.ok'})), 'Not allowed on this page');
    expect(decodes, 0);
  });

  test('a module that is off, not installed, or older than the data is never decoded', () async {
    setUpPage([_record('off', 'test.off'), _record('gone', 'test.missing'), _record('new', 'test.old', version: 2)]);
    for (final id in ['off', 'gone', 'new']) {
      expect(reason(await check(id)), 'This box type is off on this device.', reason: id);
    }
    expect(decodes, 0);
  });

  test('a box whose data can\'t be read says so', () async {
    setUpPage([_record('a', 'test.ok', data: 'x')]);
    // A module whose decode throws.
    modules = ModuleRegistry()..register(_ThrowingModule(), isDefault: true);
    setUpPage([_record('a', 'test.throws')]);
    expect(reason(await check('a')), "This box can't be read. Nothing was exported.");
  });

  group('a file', () {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    AttachmentRef ref({String? file, String name = 'Plan.pdf'}) =>
        AttachmentRef(name: name, size: 4, hash: contentHash(bytes), file: file ?? '${contentHash(bytes)}.pdf');

    BoxRecord fileBox(AttachmentRef r) =>
        commitBox(createBox(const FileCodec(), const Bounds(0, 0, 100, 50)).withId('f'), const FileCodec(), FileData(ref: r));

    Future<String?> run(AttachmentRef r, AttachmentStore? store) async {
      setUpPage([fileBox(r)]);
      return reason(await check('f', store: store));
    }

    test('a name that is not an attachment name is not found, and the store is never asked', () async {
      final store = _Store();
      expect(await run(ref(file: '../x.pdf'), store), 'File not found: Plan.pdf');
    });

    test('downloading and failed downloads say downloading', () async {
      final store = _DownloadStore();
      final r = ref();
      store.folder[r.file!] = bytes;
      store.state[r.file!] = AttachmentDownload.downloading;
      expect(await run(r, store), 'Plan.pdf is downloading. Try again in a moment.');
      store.state[r.file!] = AttachmentDownload.failed;
      expect(await run(r, store), 'Plan.pdf is downloading. Try again in a moment.');
    });

    test('absent or short is still syncing, with or without a downloading store', () async {
      expect(await run(ref(), _Store()), 'Plan.pdf is still syncing.');
      expect(await run(ref(), _DownloadStore()), 'Plan.pdf is still syncing.');
      final short = _Store()..folder[ref().file!] = Uint8List.fromList([1]);
      expect(await run(ref(), short), 'Plan.pdf is still syncing.');
      expect(await run(ref(), null), 'Plan.pdf is still syncing.');
    });

    test('a damaged file says so', () async {
      final store = _Store()..folder[ref().file!] = Uint8List.fromList([9, 9, 9, 9]);
      expect(await run(ref(), store), 'Plan.pdf is damaged on this device. Nothing was exported.');
    });

    test('a good file is ready', () async {
      final store = _Store()..folder[ref().file!] = bytes;
      expect(await run(ref(), store), isNull);
    });

    test('an embedded file is ready without a store', () async {
      final embedded = AttachmentRef(name: 'e.txt', size: 4, hash: contentHash(bytes), bytes: bytes);
      expect(await run(embedded, null), isNull);
    });
  });
}

class _ThrowingModule extends BoxModule<String> {
  @override
  BoxCodec<String> get codec => const _ThrowingCodec();
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) => const SizedBox();
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) => const SizedBox();
  @override
  List<ExportFormat> exportFormats(String data) => const [ExportFormat.text];
}

class _ThrowingCodec extends _Codec {
  const _ThrowingCodec() : super('test.throws');
  @override
  String decode(Object? json, int storedVersion) => throw const FormatException('bad');
}
