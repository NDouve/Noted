// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'fake_store.dart';

BoxRecord _box(BoxCodec<Object?> codec, String id, Object? data, Bounds at) =>
    BoxRecord.create(
      id: id,
      typeId: codec.typeId,
      dataVersion: codec.dataVersion,
      bounds: at,
      data: RawJson.encode(codec.encode(data)),
      snapshotText: codec.snapshotText(data),
      rev: 'r',
    ).withFixedHeight(true);

/// A store whose folder reads run [onRead] first (to edit the page while a
/// conversion is waiting on a file).
class _HookStore extends FakeStore {
  void Function()? onRead;

  @override
  Future<Uint8List?> read(String fileName) async {
    await Future<void>.value();
    onRead?.call();
    return super.read(fileName);
  }
}

void main() {
  late CanvasController c;
  late FakeStore store;
  final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7 fake'));

  Future<void> pump(WidgetTester t, {List<CanvasNode> nodes = const []}) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final modules = ModuleRegistry()
      ..register(const ImageModule())
      ..register(const FileModule(), isDefault: true);
    var page = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
    for (final n in nodes) {
      page = page.insertNode(n);
    }
    c = CanvasController(page, modules);
    await t.pumpWidget(
      MaterialApp(
        theme: notedThemeData(Brightness.light),
        home: Scaffold(
          body: PageCanvas(controller: c, attachments: store),
        ),
      ),
    );
    await t.pump();
  }

  setUp(() => store = FakeStore());
  tearDown(() => FileClipboard.read = () async => const []);

  PageCanvasState canvas(WidgetTester t) =>
      t.state<PageCanvasState>(find.byType(PageCanvas));

  List<BoxRecord> boxes() => c.page.nodes.whereType<BoxRecord>().toList();

  Object? data(BoxRecord b) => (c.modules.codecs.resolve(b) as LiveBox).data;

  // Lets real image decoding finish, then rebuilds.
  Future<void> settleReal(WidgetTester t) async {
    for (var i = 0; i < 5; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump();
    }
  }

  testWidgets(
    'an image file becomes an image box at the point, kept in the folder',
    (t) async {
      await pump(t);
      await t.runAsync(
        () => canvas(t).insertFiles([
          IncomingFile('red.png', redPng),
        ], at: const Offset(100, 80)),
      );
      await t.pump();
      final b = boxes().single;
      expect(b.typeId, ImageCodec.id);
      expect(b.bounds.x, 100);
      expect(b.bounds.y, 80);
      final d = data(b)! as ImageData;
      expect((d.width, d.height), (4, 4));
      expect(d.ref.file, '${contentHash(redPng)}.png');
      expect(store.folder.keys, [d.ref.file]);
      expect(b.snapshotText, '[image: ]');
      expect(c.selectedId, b.id);
      // One undo removes it.
      c.undo();
      expect(boxes(), isEmpty);
    },
  );

  testWidgets('embedded mode keeps the bytes in the box', (t) async {
    store.storage = AttachmentStorage.embedded;
    await pump(t);
    await t.runAsync(
      () => canvas(t).insertFiles([IncomingFile('red.png', redPng)]),
    );
    await t.pump();
    final d = data(boxes().single)! as ImageData;
    expect(d.ref.isEmbedded, isTrue);
    expect(store.folder, isEmpty);
  });

  testWidgets(
    'any other file becomes a file box with its name and size; double-click opens it',
    (t) async {
      await pump(t);
      await t.runAsync(
        () => canvas(t).insertFiles([
          IncomingFile('Plan.pdf', pdf),
        ], at: const Offset(40, 40)),
      );
      await t.pump();
      final b = boxes().single;
      expect(b.typeId, FileCodec.id);
      expect(b.snapshotText, '[file: Plan.pdf]');
      expect(find.text('Plan.pdf'), findsOneWidget);
      expect(find.text(formatByteSize(pdf.length)), findsOneWidget);
      final box = find.byKey(const ValueKey('file-box'));
      await t.tap(box);
      await t.pump(const Duration(milliseconds: 50));
      await t.tap(box);
      await t.pump(const Duration(milliseconds: 400));
      expect(store.opened.single.$1, 'Plan.pdf');
      expect(store.opened.single.$2, '${contentHash(pdf)}.pdf');
    },
  );

  testWidgets(
    'several files are stacked; an image that doesn\'t decode is skipped',
    (t) async {
      await pump(t);
      await t.runAsync(
        () => canvas(t).insertFiles([
          IncomingFile('a.pdf', pdf),
          IncomingFile('broken.png', Uint8List.fromList([1, 2, 3])),
          IncomingFile('b.txt', pdf),
        ], at: Offset.zero),
      );
      await t.pump();
      final ys = boxes().map((b) => b.bounds.y).toList();
      expect(ys, hasLength(2));
      expect(ys[1], greaterThan(ys[0]));
    },
  );

  testWidgets('dropping files creates boxes where they were dropped', (
    t,
  ) async {
    await pump(t);
    final global = t.getCenter(find.byType(PageCanvas)) + const Offset(100, 50);
    final expected = canvas(t).pageAtGlobal(global)!;
    await t.runAsync(
      () => canvas(t).dropFiles([IncomingFile('drop.pdf', pdf)], global),
    );
    await t.pump();
    final b = boxes().single;
    expect(b.bounds.x, closeTo(expected.dx, 0.01));
    expect(b.bounds.y, closeTo(expected.dy, 0.01));
  });

  testWidgets('Ctrl+V on the canvas pastes the clipboard\'s image as a box', (
    t,
  ) async {
    FileClipboard.read = () async => [IncomingFile('Pasted image.png', redPng)];
    await pump(t);
    await t.runAsync(() async {
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyV);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await t.pump();
    expect(boxes().single.typeId, ImageCodec.id);
  });

  testWidgets('Insert → Image and Insert → File pick files', (t) async {
    await pump(t);
    store.toPick = [IncomingFile('red.png', redPng)];
    await t.runAsync(() => canvas(t).commands.invoke(ImageCommands.insert));
    await t.pump();
    store.toPick = [IncomingFile('x.pdf', pdf)];
    await t.runAsync(() => canvas(t).commands.invoke(FileCommands.insert));
    await t.pump();
    expect(boxes().map((b) => b.typeId), [ImageCodec.id, FileCodec.id]);
  });

  testWidgets(
    'a missing file shows "Still syncing" and fills in when it arrives',
    (t) async {
      final hash = contentHash(redPng);
      final image = _box(
        const ImageCodec(),
        'img',
        ImageData(
          ref: AttachmentRef(
            name: 'red.png',
            size: redPng.length,
            hash: hash,
            file: '$hash.png',
          ),
          width: 4,
          height: 4,
        ),
        const Bounds(40, 40, 120, 120),
      );
      final file = _box(
        const FileCodec(),
        'file',
        FileData(
          ref: AttachmentRef(
            name: 'Plan.pdf',
            size: pdf.length,
            hash: contentHash(pdf),
            file: '${contentHash(pdf)}.pdf',
          ),
        ),
        const Bounds(300, 40, 280, 64),
      );
      await pump(t, nodes: [image, file]);
      await settleReal(t);
      expect(find.byKey(const ValueKey('still-syncing')), findsNWidgets(2));
      expect(find.byKey(const ValueKey('image-box-picture')), findsNothing);

      // Real time: the box reads the file and decodes it.
      await t.runAsync(() async {
        store.arrive('$hash.png', redPng);
        store.arrive('${contentHash(pdf)}.pdf', pdf);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await settleReal(t);
      expect(find.byKey(const ValueKey('still-syncing')), findsNothing);
      expect(find.byKey(const ValueKey('image-box-picture')), findsOneWidget);
      expect(find.text(formatByteSize(pdf.length)), findsOneWidget);
      // The display copy was cached outside the page folder.
      expect(displayCopyFile(store.cacheDirectory, hash).existsSync(), isTrue);
    },
  );

  testWidgets('resizing an image keeps its aspect ratio; Shift frees it', (
    t,
  ) async {
    final hash = contentHash(redPng);
    final image = _box(
      const ImageCodec(),
      'img',
      ImageData(
        ref: AttachmentRef(name: 'red.png', size: 1, hash: hash, bytes: redPng),
        width: 8,
        height: 4,
      ),
      const Bounds(100, 100, 200, 100 + imageCaptionHeight),
    );
    await pump(t, nodes: [image]);
    Future<void> dragRight(double dx) async {
      final b = c.page.node('img')!.bounds!;
      final start =
          canvas(t).view!.toScreen(Offset(b.x + b.width, b.y + b.height / 2)) +
          t.getTopLeft(find.byType(PageCanvas)) +
          const Offset(0, CommandToolbar.height);
      final g = await t.startGesture(start);
      await g.moveBy(Offset(dx / 2, 0));
      await g.moveBy(Offset(dx / 2, 0));
      await g.up();
      await t.pump();
    }

    final scale = canvas(t).view!.scale;
    await dragRight(100 * scale);
    var b = c.page.node('img')!.bounds!;
    expect(b.width, closeTo(300, 1));
    // The picture keeps 2:1; the caption strip below keeps its height.
    expect(b.height, closeTo(150 + imageCaptionHeight, 1));

    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await dragRight(100 * scale);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    b = c.page.node('img')!.bounds!;
    expect(b.width, closeTo(400, 1));
    expect(b.height, closeTo(150 + imageCaptionHeight, 1));
  });

  testWidgets('a click on an image or a file box selects it', (t) async {
    final hash = contentHash(redPng);
    await pump(
      t,
      nodes: [
        _box(
          const ImageCodec(),
          'img',
          ImageData(
            ref: AttachmentRef(
              name: 'red.png',
              size: 1,
              hash: hash,
              bytes: redPng,
            ),
            width: 4,
            height: 4,
          ),
          const Bounds(40, 40, 120, 120),
        ),
        _box(
          const FileCodec(),
          'file',
          FileData(
            ref: AttachmentRef(name: 'a.pdf', size: 1, hash: 'h', bytes: pdf),
          ),
          const Bounds(300, 40, 280, 64),
        ),
      ],
    );
    Future<void> frames() async {
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    expect(c.selectedId, isNull);
    await t.tap(find.byKey(const ValueKey('image-box')));
    await frames();
    expect(c.selectedId, 'img');
    expect(c.editingId, isNull, reason: 'selected, not edited');
    await t.tap(find.byKey(const ValueKey('file-box')));
    await frames();
    expect(c.selectedId, 'file');
    expect(store.opened, isEmpty, reason: 'one click selects; two open');

    // Backspace removes the selected file box; Delete the image; undo
    // brings each back.
    await t.sendKeyEvent(LogicalKeyboardKey.backspace);
    await t.pump();
    expect(c.page.node('file'), isNull);
    await t.tap(find.byKey(const ValueKey('image-box')));
    await frames();
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await t.pump();
    expect(boxes(), isEmpty);
    c.undo();
    c.undo();
    await t.pump();
    expect(boxes().map((b) => b.id).toSet(), {'img', 'file'});
  });

  testWidgets('typing in the alt text doesn\'t delete the box', (t) async {
    final hash = contentHash(redPng);
    await pump(
      t,
      nodes: [
        _box(
          const ImageCodec(),
          'img',
          ImageData(
            ref: AttachmentRef(name: 'red.png', size: 1, hash: hash, bytes: redPng),
            width: 4,
            height: 4,
            alt: 'Red',
          ),
          const Bounds(40, 40, 120, 148),
        ),
      ],
    );
    await t.tap(find.byKey(const ValueKey('image-alt-text')));
    await t.pump();
    expect(c.editingId, 'img');
    await t.sendKeyEvent(LogicalKeyboardKey.backspace);
    await t.pump();
    expect(c.page.node('img'), isNotNull);
  });

  testWidgets('the alt text sits below the picture, never over it', (t) async {
    final hash = contentHash(redPng);
    await pump(
      t,
      nodes: [
        _box(
          const ImageCodec(),
          'img',
          ImageData(
            ref: AttachmentRef(name: 'red.png', size: 1, hash: hash, bytes: redPng),
            width: 4,
            height: 4,
            alt: 'A red square',
          ),
          const Bounds(40, 40, 120, 148),
        ),
      ],
    );
    final picture = t.getRect(find.byKey(const ValueKey('image-box')));
    final caption = t.getRect(find.byKey(const ValueKey('image-caption')));
    expect(caption.top, closeTo(picture.bottom, 0.01));
    expect(picture.overlaps(caption), isFalse);
    final scale = canvas(t).view!.scale;
    expect(caption.height, closeTo(imageCaptionHeight * scale, 0.01));
    expect(find.text('A red square'), findsOneWidget);
    // A new box makes room for it.
    expect(newImageBoxSize(400, 200), const Size(400, 200 + imageCaptionHeight));
    expect(newImageBoxSize(1000, 500).width, newImageMaxSide);
  });

  testWidgets('converting a page\'s attachments is one undo step, both ways', (
    t,
  ) async {
    await pump(t);
    await t.runAsync(() async {
      await canvas(t).insertFiles([
        IncomingFile('red.png', redPng),
        IncomingFile('Plan.pdf', pdf),
      ], at: Offset.zero);
    });
    await t.pump();
    final before = c.page;
    final r = await t.runAsync(
      () => convertPageAttachments(c, store, AttachmentStorage.embedded),
    );
    await t.pump();
    expect(r!.changed, 2);
    expect(r.overLimit, isEmpty);
    for (final b in boxes()) {
      final ref = switch (data(b)) {
        final ImageData d => d.ref,
        final FileData d => d.ref,
        _ => null,
      };
      expect(ref!.isEmbedded, isTrue, reason: b.typeId);
    }
    c.undo();
    expect(
      writePage(c.page),
      writePage(before),
      reason: 'one undo restores both',
    );

    c.redo();
    store.folder.clear();
    final back = await t.runAsync(
      () => convertPageAttachments(c, store, AttachmentStorage.folder),
    );
    expect(back!.changed, 2);
    expect(store.folder, hasLength(2));
  });

  testWidgets('a box edited during conversion is converted again, not '
      'overwritten with the old capture', (t) async {
    final gated = _HookStore();
    store = gated;
    await pump(t);
    await t.runAsync(() async {
      await canvas(t).insertFiles([IncomingFile('red.png', redPng)], at: Offset.zero);
    });
    await t.pump();
    final id = boxes().single.id;
    var reads = 0;
    gated.onRead = () {
      // A sync update lands while the first read is outstanding.
      if (reads++ != 0) return;
      final d = data(boxes().single) as ImageData;
      c.editBox(id, d.copyWith(alt: 'newer caption'));
    };
    final r = await t.runAsync(
      () => convertPageAttachments(c, store, AttachmentStorage.embedded),
    );
    await t.pump();
    expect(r!.changed, 1);
    expect(r.skipped, isEmpty);
    final d = data(boxes().single) as ImageData;
    expect(d.alt, 'newer caption');
    expect(d.ref.isEmbedded, isTrue);
    c.undo();
    final back = data(boxes().single) as ImageData;
    expect(back.alt, 'newer caption', reason: 'undo keeps the newer edit');
    expect(back.ref.isEmbedded, isFalse, reason: 'one undo reverts the conversion');
  });

  // A box with no revision, as a hand-edited page can have.
  BoxRecord noRev(BoxRecord b) {
    final p = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
    final text = writePage(p.insertNode(b)).replaceAll(RegExp(r'"rev":\s*"r",?'), '');
    return readPage(text).nodes.whereType<BoxRecord>().single;
  }

  BoxRecord folderImage(String id, {String alt = ''}) {
    final hash = contentHash(redPng);
    final file = attachmentFileName(hash, 'png');
    store.folder[file] = redPng;
    return noRev(
      _box(
        const ImageCodec(),
        id,
        ImageData(
          ref: AttachmentRef(name: 'red.png', size: redPng.length, hash: hash, file: file),
          width: 4,
          height: 4,
          alt: alt,
        ),
        const Bounds(40, 40, 120, 148),
      ),
    );
  }

  testWidgets('a box without a revision converts', (t) async {
    await pump(t, nodes: [folderImage('img')]);
    expect(boxes().single.rev, isNull);
    final r = await t.runAsync(
      () => convertPageAttachments(c, store, AttachmentStorage.embedded),
    );
    expect(r!.changed, 1);
    expect(r.skipped, isEmpty);
    expect((data(boxes().single) as ImageData).ref.isEmbedded, isTrue);
  });

  testWidgets('a box without a revision, edited during the read, is converted '
      'again', (t) async {
    final gated = _HookStore();
    store = gated;
    await pump(t, nodes: [folderImage('img')]);
    var reads = 0;
    gated.onRead = () {
      if (reads++ != 0) return;
      // A sync update: the same box, still without a revision.
      c.applyExternal(c.page.replaceNode(folderImage('img', alt: 'newer caption')));
    };
    final r = await t.runAsync(
      () => convertPageAttachments(c, store, AttachmentStorage.embedded),
    );
    expect(r!.skipped, isEmpty);
    final d = data(boxes().single) as ImageData;
    expect(d.alt, 'newer caption');
    expect(d.ref.isEmbedded, isTrue);
  });

  testWidgets('a box deleted during the read is dropped, not reported', (t) async {
    final gated = _HookStore();
    store = gated;
    await pump(t);
    await t.runAsync(() async {
      await canvas(t).insertFiles([
        IncomingFile('red.png', redPng),
        IncomingFile('Plan.pdf', pdf),
      ], at: Offset.zero);
    });
    await t.pump();
    final img = boxes().firstWhere((b) => b.typeId == const ImageCodec().typeId);
    gated.onRead = () => c.delete(img.id);
    final r = await t.runAsync(
      () => convertPageAttachments(c, store, AttachmentStorage.embedded),
    );
    expect(r!.skipped, isEmpty);
    expect(r.changed, 1);
    expect(boxes(), hasLength(1));
  });

  testWidgets('over-limit files of a deleted box are not reported', (t) async {
    final gated = _HookStore();
    store = gated;
    await pump(t);
    await t.runAsync(
      () => canvas(t).insertFiles([
        IncomingFile('huge.zip', Uint8List(embedLimitBytes + 1)),
        IncomingFile('small.pdf', pdf),
      ], at: Offset.zero),
    );
    await t.pump();
    final huge = boxes().firstWhere((b) => (data(b) as FileData).ref.name == 'huge.zip');
    gated.onRead = () {
      if (c.page.node(huge.id) != null) c.delete(huge.id);
    };
    final r = await t.runAsync(
      () => convertPageAttachments(c, store, AttachmentStorage.embedded),
    );
    expect(r!.overLimit, isEmpty);
    expect(r.changed, 1);
  });

  testWidgets('a box whose conversion returned nothing, replaced during the '
      'read, is converted again and the notice skips the old file', (t) async {
    final gated = _HookStore();
    store = gated;
    await pump(t);
    await t.runAsync(
      () => canvas(t).insertFiles([
        IncomingFile('huge.zip', Uint8List(embedLimitBytes + 1)),
        IncomingFile('small.pdf', pdf),
      ], at: Offset.zero),
    );
    await t.pump();
    final huge = boxes().firstWhere((b) => (data(b) as FileData).ref.name == 'huge.zip');
    final small = boxes().firstWhere((b) => (data(b) as FileData).ref.name == 'small.pdf');
    final smallRef = (data(small) as FileData).ref;
    gated.onRead = () {
      final d = data(c.page.node(huge.id)! as BoxRecord) as FileData;
      if (d.ref.name == 'huge.zip') c.editBox(huge.id, d.copyWith(ref: smallRef));
    };
    final r = await t.runAsync(
      () => convertPageAttachments(c, store, AttachmentStorage.embedded),
    );
    await t.pump();
    expect(r!.skipped, isEmpty);
    expect(r.overLimit, isEmpty, reason: 'the box no longer has the huge file');
    expect(r.changed, 2);
    for (final b in boxes()) {
      expect((data(b) as FileData).ref.isEmbedded, isTrue);
    }
  });

  testWidgets('a box whose conversion returned nothing and keeps changing is '
      'skipped, and the notice does not name its file', (t) async {
    final gated = _HookStore();
    store = gated;
    await pump(t);
    await t.runAsync(
      () => canvas(t).insertFiles([
        IncomingFile('huge.zip', Uint8List(embedLimitBytes + 1)),
        IncomingFile('small.pdf', pdf),
      ], at: Offset.zero),
    );
    await t.pump();
    final huge = boxes().firstWhere((b) => (data(b) as FileData).ref.name == 'huge.zip');
    // The box records a size under the limit (a hand-edited page), so the
    // file is read and found too big; a recorded size over the limit is
    // skipped without reading it.
    final hd = data(c.page.node(huge.id)! as BoxRecord) as FileData;
    c.editBox(huge.id, hd.copyWith(ref: AttachmentRef(name: hd.ref.name, size: 10, hash: hd.ref.hash, file: hd.ref.file)));
    var n = 0;
    gated.onRead = () {
      // Still over the limit, but a different edit every time.
      final d = data(c.page.node(huge.id)! as BoxRecord) as FileData;
      c.editBox(
        huge.id,
        d.copyWith(ref: AttachmentRef(
          name: 'huge-${n++}.zip',
          size: d.ref.size,
          hash: d.ref.hash,
          file: d.ref.file,
        )),
      );
    };
    final r = await t.runAsync(
      () => convertPageAttachments(c, store, AttachmentStorage.embedded),
    );
    await t.pump();
    expect(r!.skipped, [huge.id]);
    expect(r.overLimit, isEmpty);
    expect(r.changed, 1, reason: 'the small file still converts');
  });

  testWidgets('a box converted once whose retry returns nothing is not '
      'committed with the old data', (t) async {
    final gated = _HookStore();
    store = gated;
    await pump(t);
    await t.runAsync(
      () => canvas(t).insertFiles([
        IncomingFile('small.pdf', pdf),
        IncomingFile('huge.zip', Uint8List(embedLimitBytes + 1)),
      ], at: Offset.zero),
    );
    await t.pump();
    final small = boxes().firstWhere((b) => (data(b) as FileData).ref.name == 'small.pdf');
    final huge = boxes().firstWhere((b) => (data(b) as FileData).ref.name == 'huge.zip');
    final hugeRef = (data(huge) as FileData).ref;
    var reads = 0;
    gated.onRead = () {
      // While the small file is read, its box is pointed at an oversized one.
      if (reads++ != 0) return;
      c.editBox(
        small.id,
        FileData(
          ref: AttachmentRef(
            name: 'other.zip',
            size: hugeRef.size,
            hash: hugeRef.hash,
            file: hugeRef.file,
          ),
        ),
      );
    };
    final r = await t.runAsync(
      () => convertPageAttachments(c, store, AttachmentStorage.embedded),
    );
    await t.pump();
    expect(r!.skipped, isEmpty);
    expect(r.changed, 0, reason: 'the old capture is not committed');
    expect(r.overLimit, containsAll(['other.zip', 'huge.zip']));
    final d = data(c.page.node(small.id)! as BoxRecord) as FileData;
    expect(d.ref.name, 'other.zip');
    expect(d.ref.isEmbedded, isFalse);
  });

  testWidgets('a box that keeps changing is skipped and reported', (t) async {
    final gated = _HookStore();
    store = gated;
    await pump(t);
    await t.runAsync(() async {
      await canvas(t).insertFiles([
        IncomingFile('red.png', redPng),
        IncomingFile('Plan.pdf', pdf),
      ], at: Offset.zero);
    });
    await t.pump();
    final img = boxes().firstWhere((b) => b.typeId == const ImageCodec().typeId);
    var n = 0;
    gated.onRead = () {
      final d = data(c.page.node(img.id)! as BoxRecord) as ImageData;
      c.editBox(img.id, d.copyWith(alt: 'edit ${n++}'));
    };
    final r = await t.runAsync(
      () => convertPageAttachments(c, store, AttachmentStorage.embedded),
    );
    await t.pump();
    expect(r!.skipped, [img.id]);
    expect(r.changed, 1, reason: 'the file box still converts');
    final d = data(c.page.node(img.id)! as BoxRecord) as ImageData;
    expect(d.alt, startsWith('edit '));
    expect(d.ref.isEmbedded, isFalse);
  });

  testWidgets(
    'embedding reports files over the limit and leaves them in the folder',
    (t) async {
      await pump(t);
      final big = Uint8List(embedLimitBytes + 1);
      await t.runAsync(
        () => canvas(t).insertFiles([
          IncomingFile('huge.zip', big),
          IncomingFile('small.pdf', pdf),
        ], at: Offset.zero),
      );
      await t.pump();
      final r = await t.runAsync(
        () => convertPageAttachments(c, store, AttachmentStorage.embedded),
      );
      expect(r!.changed, 1);
      expect(r.overLimit, ['huge.zip']);
    },
  );
}
