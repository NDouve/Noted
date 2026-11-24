// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// PDF pages and sheets as images: the renderer's channel is faked, the pixel
// cap, a failed page, a password-protected file, the page range, the document
// closed whatever happens, embedded mode over the limit, and a reload.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/import/convert.dart';
import 'package:noted/src/import/document_render.dart';
import 'package:noted/src/import/folder_store.dart';
import 'package:noted/src/import/import_dialog.dart';
import 'package:noted/src/import/import_flow.dart';
import 'package:noted/src/import/import_format.dart';
import 'package:noted/src/import/import_limits.dart';
import 'package:noted/src/import/sheet_blocks.dart';
import 'package:noted/src/import/sheet_image.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_attachments.dart' show overLimitNotice;
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/png_builder.dart';
import 'support/settle_saves.dart';
import 'support/shell_world.dart';
import 'support/zip_builder.dart';

Future<R> _inline<R>(R Function() work) async => work();

/// The platform renderer, as a fake: pages are sized and cut the way the
/// native side does ([fitPixels]), and every call is recorded.
class FakeRenderer {
  FakeRenderer({List<(double, double)>? pages, this.pageCount}) : pages = pages ?? [(200.0, 300.0)];

  final List<(double, double)> pages;
  int? pageCount;
  bool password = false, invalid = false;
  final Set<int> failing = {}, oversize = {};
  int padding = 0;
  Future<void>? gate;
  int opened = 0, closed = 0;
  final rendered = <int>[];
  final args = <List<int>>[];
  final sizes = <({int width, int height})>[];

  void install() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('noted/document_render');
    messenger.setMockMethodCallHandler(channel, _handle);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  Future<Object?> _handle(MethodCall c) async {
    final a = c.arguments as Map<Object?, Object?>;
    switch (c.method) {
      case 'open':
        opened++;
        if (password) throw PlatformException(code: 'password');
        if (invalid) throw PlatformException(code: 'invalid');
        return {'handle': 7, 'pageCount': pageCount ?? pages.length};
      case 'render':
        final i = a['index']! as int;
        args.add([a['handle']! as int, i, a['maxW']! as int, a['maxH']! as int]);
        rendered.add(i);
        if (gate != null && rendered.length > 1) await gate;
        if (failing.contains(i)) throw PlatformException(code: 'render');
        if (oversize.contains(i)) return claimPng(5000, 5000);
        final p = pages[i % pages.length];
        final size = fitPixels(p.$1, p.$2, maxW: a['maxW']! as int, maxH: a['maxH']! as int);
        if (size == null) return null;
        sizes.add(size);
        return buildPng(size.width, size.height, padding: padding);
      case 'close':
        closed++;
        return null;
    }
    return null;
  }
}

void main() {
  late List<String> notices;
  late StreamSubscription<String> sub;

  setUp(() {
    notices = [];
    importRunner = _inline;
    importCapabilities = const ImportCapabilities(pdfPages: true, sheetImages: true);
  });

  tearDown(() {
    importRunner = runInIsolate;
    importCapabilities = const ImportCapabilities();
    importLimits = () => ImportLimits.desktop;
    importPicker = pickImportSources;
  });

  Future<ShellWorld> open(WidgetTester t) async {
    final w = await ShellWorld.open(t, size: const Size(1440, 900));
    sub = w.nb.attachmentNotices.listen(notices.add);
    addTearDown(sub.cancel);
    return w;
  }

  Future<void> until(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 400 && !done(); i++) {
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(done(), isTrue, reason: 'waited too long');
  }

  bool shown(String key) => find.byKey(ValueKey(key)).evaluate().isNotEmpty;

  Future<void> choose(WidgetTester t, String choice) async {
    await until(t, () => shown('import-dialog'));
    await t.tap(find.byKey(ValueKey('import-choice-$choice')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('import-ok')));
    await t.pump();
  }

  /// Runs the Import command on [name] with [bytes] and the choice [choice].
  Future<void> importFile(WidgetTester t, ShellWorld w, String name, Uint8List bytes, String choice) async {
    importPicker = () async => [ImportSource(name, length: () async => bytes.length, read: () async => bytes)];
    final run = w.canvas(t).commands.invoke('app.import');
    await choose(t, choice);
    await until(t, () => importsRunning.value == 0);
    await t.runAsync(() => run);
    await w.settle(t);
  }

  List<BoxRecord> boxes(ShellWorld w) => w.nb.current!.page.nodes.whereType<BoxRecord>().toList();
  final pdf = Uint8List.fromList('%PDF-1.4 fake'.codeUnits);

  /// Waits for the save, loads the folder in a new notebook and checks that
  /// the page has the same boxes with the same data, and that every folder
  /// file they point at is there and holds the bytes its name says.
  Future<void> expectReloads(WidgetTester t, ShellWorld w) async {
    final a = w.nb.current!;
    await settleSaves(t, w.nb);
    await t.runAsync(() => w.nb.flush());
    late Notebook again;
    await t.runAsync(() async {
      again = Notebook(PageStore(Directory('${w.dir.path}/pages')), buildModules(), saveDelay: Duration.zero);
      await again.load();
      await again.open(w.first);
    });
    final reloaded = again.current!;
    expect([for (final n in reloaded.page.nodes) n.id], [for (final n in a.page.nodes) n.id]);
    final names = RegExp(r'[0-9a-f]{64}\.png');
    for (final n in a.page.nodes.whereType<BoxRecord>()) {
      final r = reloaded.page.node(n.id)! as BoxRecord;
      expect(r.bounds, n.bounds);
      expect(r.data.toString(), n.data.toString());
      for (final m in names.allMatches(n.data.toString())) {
        final file = m.group(0)!;
        expect(again.attachments!.exists(file), isTrue, reason: '$file is in the folder');
        final v = await t.runAsync(() => again.attachments!.verify(file, size: 0));
        expect(v!.state, AttachmentState.ok, reason: '$file holds the bytes its name says');
      }
    }
    await t.runAsync(() async {
      again.dispose();
      // The reloaded page may still be checking its attachment files (a slow
      // disk): let it finish, or the folder can't be deleted on Windows.
      await Future<void>.delayed(const Duration(seconds: 1));
    });
  }

  testWidgets('a two-page PDF makes two image boxes, in order, stacked down; the document is closed; it loads again (folder)', (t) async {
    final r = FakeRenderer(pages: [(200, 300), (300, 200)])..install();
    final w = await open(t);
    await importFile(t, w, 'doc.pdf', pdf, 'pagesAsImages');
    final b = boxes(w);
    expect(b.map((x) => x.typeId), ['noted.image', 'noted.image']);
    expect(b[0].data.toString(), contains('doc-1.png'));
    expect(b[1].data.toString(), contains('doc-2.png'));
    expect(b[1].bounds.x, b[0].bounds.x);
    expect(b[1].bounds.y, greaterThan(b[0].bounds.y + b[0].bounds.height - 1));
    expect(r.opened, 1);
    expect(r.closed, 1);
    expect(r.rendered, [0, 1]);
    expect(r.args.every((x) => x[2] == 4096 && x[3] == 4096), isTrue);
    expect(w.nb.attachments!.folder.listSync().whereType<File>(), hasLength(2));
    await expectReloads(t, w);
    await w.close(t);
  });

  testWidgets('embedded mode: a small import stays embedded, and loads again', (t) async {
    FakeRenderer(pages: [(200, 300), (300, 200)]).install();
    final w = await open(t);
    await t.runAsync(() => w.nb.setAttachmentStorage(w.first, AttachmentStorage.embedded));
    await importFile(t, w, 'doc.pdf', pdf, 'pagesAsImages');
    expect(boxes(w), hasLength(2));
    expect(w.nb.attachments!.folder.existsSync() ? w.nb.attachments!.folder.listSync() : [], isEmpty);
    expect(notices, isEmpty);
    await expectReloads(t, w);
    await w.close(t);
  });

  testWidgets('embedded mode: images over 5 MB together go to the folder, with the notice once, and load again', (t) async {
    // Two pages of 3 MB: each fits, together they don't.
    FakeRenderer(pages: [(200, 300), (300, 200)])
      ..padding = 3 * 1024 * 1024
      ..install();
    final w = await open(t);
    await t.runAsync(() => w.nb.setAttachmentStorage(w.first, AttachmentStorage.embedded));
    await importFile(t, w, 'doc.pdf', pdf, 'pagesAsImages');
    expect(boxes(w), hasLength(2));
    expect(w.nb.attachments!.folder.listSync().whereType<File>(), hasLength(2));
    expect(boxes(w).every((b) => RegExp(r'[0-9a-f]{64}\.png').hasMatch(b.data.toString())), isTrue);
    expect(notices, [overLimitNotice]);
    await expectReloads(t, w);
    await w.close(t);
  });

  testWidgets('a tall page is rendered within 4,096 px and 16 MP', (t) async {
    final r = FakeRenderer(pages: [(612, 20000)])..install();
    final w = await open(t);
    await importFile(t, w, 'tall.pdf', pdf, 'pagesAsImages');
    expect(boxes(w), hasLength(1));
    expect(r.args.single.sublist(2), [4096, 4096]);
    final s = r.sizes.single;
    expect(s.height, 4096);
    expect(s.width, lessThan(200));
    await w.close(t);
  });

  test('the pixel cap: 4,096 a side, 16 megapixels, under 1 px skipped', () {
    expect(fitPixels(612, 792), (width: 1275, height: 1650));
    final big = fitPixels(3000, 3000)!;
    expect(big.width, lessThanOrEqualTo(4000));
    expect(big.width * big.height, lessThanOrEqualTo(maxImagePixels));
    expect(big.width, big.height);
    final wide = fitPixels(100000, 100)!;
    expect(wide.width, 4096);
    expect(wide.height, greaterThanOrEqualTo(1));
    expect(fitPixels(1000000, 1), isNull);
    expect(fitPixels(0, 100), isNull);
  });

  testWidgets('a page the renderer returns over the cap is left out and named; the others go in', (t) async {
    final r = FakeRenderer(pages: [(200, 300)])
      ..oversize.add(1)
      ..install();
    r.pageCount = 3;
    final w = await open(t);
    await importFile(t, w, 'doc.pdf', pdf, 'pagesAsImages');
    expect(boxes(w), hasLength(2));
    expect(notices, ['"doc.pdf": page 2 could not be shown, so left out.']);
    expect(r.closed, 1);
    await w.close(t);
  });

  testWidgets('a page that fails to render is skipped and named', (t) async {
    final r = FakeRenderer(pages: [(200, 300)])
      ..failing.addAll([0, 2])
      ..install();
    r.pageCount = 4;
    final w = await open(t);
    await importFile(t, w, 'doc.pdf', pdf, 'pagesAsImages');
    expect(boxes(w), hasLength(2));
    expect(boxes(w)[0].data.toString(), contains('doc-2.png'));
    expect(boxes(w)[1].data.toString(), contains('doc-4.png'));
    expect(notices, ['"doc.pdf": pages 1, 3 could not be shown, so left out.']);
    expect(r.closed, 1);
    await w.close(t);
  });

  testWidgets('a password-protected PDF is refused by name', (t) async {
    final r = FakeRenderer()
      ..password = true
      ..install();
    final w = await open(t);
    await importFile(t, w, 'secret.pdf', pdf, 'pagesAsImages');
    expect(boxes(w), isEmpty);
    expect(notices, ['"secret.pdf" is password-protected.']);
    expect(r.opened, 1);
    expect(r.closed, 0);
    await w.close(t);
  });

  testWidgets('a PDF that cannot be read is refused', (t) async {
    FakeRenderer()
      ..invalid = true
      ..install();
    final w = await open(t);
    await importFile(t, w, 'bad.pdf', pdf, 'pagesAsImages');
    expect(boxes(w), isEmpty);
    expect(notices, ['"bad.pdf" can’t be read.']);
    await w.close(t);
  });

  testWidgets('a PDF over the source size is refused before it is read', (t) async {
    final r = FakeRenderer()..install();
    final w = await open(t);
    importLimits = () => const ImportLimits(sourceBytes: 10, entryBytes: 10, archiveBytes: 10);
    var read = false;
    importPicker = () async => [
      ImportSource('huge.pdf', length: () async => 1000, read: () async {
        read = true;
        return Uint8List(1000);
      }),
    ];
    final run = w.canvas(t).commands.invoke('app.import');
    await choose(t, 'pagesAsImages');
    await until(t, () => importsRunning.value == 0);
    await t.runAsync(() => run);
    expect(read, isFalse);
    expect(r.opened, 0);
    expect(notices, ['"huge.pdf" is too large to import.']);
    await w.close(t);
  });

  testWidgets('over 50 pages asks for a range (1 to 50 by default, at most 50), and renders only that', (t) async {
    final r = FakeRenderer(pages: [(100, 100)], pageCount: 120)..install();
    final w = await open(t);
    importPicker = () async => [ImportSource('long.pdf', length: () async => 10, read: () async => pdf)];
    final run = w.canvas(t).commands.invoke('app.import');
    await choose(t, 'pagesAsImages');
    await until(t, () => shown('import-range-dialog'));
    String text(String k) => t.widget<TextField>(find.byKey(ValueKey(k))).controller!.text;
    expect([text('import-range-from'), text('import-range-to')], ['1', '50']);
    await t.enterText(find.byKey(const ValueKey('import-range-to')), '51');
    await t.pump();
    expect(shown('import-range-problem'), isTrue);
    expect(t.widget<FilledButton>(find.byKey(const ValueKey('import-range-ok'))).onPressed, isNull);
    await t.enterText(find.byKey(const ValueKey('import-range-from')), '61');
    await t.enterText(find.byKey(const ValueKey('import-range-to')), '65');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('import-range-ok')));
    await until(t, () => importsRunning.value == 0);
    await t.runAsync(() => run);
    await w.settle(t);
    expect(r.rendered, [60, 61, 62, 63, 64]);
    expect(boxes(w), hasLength(5));
    expect(boxes(w).first.data.toString(), contains('long-61.png'));
    expect(r.closed, 1);
    await w.close(t);
  });

  testWidgets('cancelling the range closes the document and adds nothing', (t) async {
    final r = FakeRenderer(pages: [(100, 100)], pageCount: 51)..install();
    final w = await open(t);
    importPicker = () async => [ImportSource('long.pdf', length: () async => 10, read: () async => pdf)];
    final run = w.canvas(t).commands.invoke('app.import');
    await choose(t, 'pagesAsImages');
    await until(t, () => shown('import-range-dialog'));
    await t.tap(find.byKey(const ValueKey('import-range-cancel')));
    await until(t, () => importsRunning.value == 0);
    await t.runAsync(() => run);
    expect(boxes(w), isEmpty);
    expect(r.rendered, isEmpty);
    expect(r.closed, 1);
    await w.close(t);
  });

  testWidgets('a page change in the middle of the rendering stops the import, and the document is still closed', (t) async {
    final gate = Completer<void>();
    final r = FakeRenderer(pages: [(100, 100)], pageCount: 3)
      ..gate = gate.future
      ..install();
    final w = await open(t);
    final a = w.nb.current!;
    importPicker = () async => [ImportSource('doc.pdf', length: () async => 10, read: () async => pdf)];
    final run = w.canvas(t).commands.invoke('app.import');
    await choose(t, 'pagesAsImages');
    await until(t, () => r.rendered.length >= 2);
    await w.openPage(t, w.second);
    gate.complete();
    await until(t, () => importsRunning.value == 0);
    await t.runAsync(() => run);
    expect(a.page.nodes.whereType<BoxRecord>(), isEmpty);
    expect(boxes(w), isEmpty);
    expect(notices, ['Import stopped: the page changed.']);
    expect(r.closed, 1);
    await w.close(t);
  });

  test('the range check', () {
    expect(pageRangeProblem(1, 50, 120), isNull);
    expect(pageRangeProblem(61, 65, 120), isNull);
    expect(pageRangeProblem(1, 51, 120), isNotNull);
    expect(pageRangeProblem(0, 5, 120), isNotNull);
    expect(pageRangeProblem(5, 4, 120), isNotNull);
    expect(pageRangeProblem(100, 121, 120), isNotNull);
    expect(pageRangeProblem(null, 4, 120), isNotNull);
  });

  test('sheet chunks: at most 100 rows and 2,000 cells', () {
    expect(sheetChunks(250, 10), [(0, 100), (100, 200), (200, 250)]);
    // 50 columns: 40 rows hold 2,000 cells.
    expect(sheetChunks(100, 50), [(0, 40), (40, 80), (80, 100)]);
    expect(sheetChunks(1, 3), [(0, 1)]);
  });

  testWidgets('a big sheet chunk is drawn within the pixel cap', (t) async {
    final long = 'x' * 150;
    final sheet = SheetData('Wide', [
      for (var r = 0; r < 40; r++) [for (var c = 0; c < 50; c++) '$long $r $c'],
    ]);
    final plan = (await planSheet(sheet))!;
    expect(plan.cut, isFalse);
    final png = await t.runAsync(() => drawSheetChunk(sheet, plan, 0, 40));
    final s = pngSize(png!)!;
    expect(s.width, lessThanOrEqualTo(maxImageSide));
    expect(s.height, lessThanOrEqualTo(maxImageSide));
    expect(s.width * s.height, lessThanOrEqualTo(maxImagePixels));
    expect(s.width, maxImageSide, reason: 'it was wider than the cap and was scaled down');
  });

  testWidgets('a cell shows all its lines: the row grows to fit', (t) async {
    final one = (await planSheet(SheetData(null, [['a', 'b']])))!;
    final five = (await planSheet(SheetData(null, [['a\nb\nc\nd\ne', 'b']])))!;
    expect(five.cut, isFalse);
    final line = one.rowHeights.single - 2 * sheetPadY;
    expect(five.rowHeights.single, closeTo(5 * line + 2 * sheetPadY, 0.01));
  });

  testWidgets('a row taller than an image is cut and named; the sheet name widens the image', (t) async {
    final tall = SheetData(null, [[List.filled(400, 'x').join('\n')]]);
    final plan = (await planSheet(tall))!;
    expect(plan.cut, isTrue);
    expect(plan.rowHeights.single, lessThanOrEqualTo(maxImageSide));
    final png = await t.runAsync(() => drawSheetChunk(tall, plan, 0, 1));
    expect(pngSize(png!)!.height, lessThanOrEqualTo(maxImageSide));
    // The title is wider than the table.
    final named = SheetData('Quarterly Revenue Report for the whole year', [['1']]);
    final p = (await planSheet(named))!;
    expect(p.titleWidth, greaterThan(p.widths.single + 16));
    final img = await t.runAsync(() => drawSheetChunk(named, p, 0, 1));
    expect(pngSize(img!)!.width, greaterThanOrEqualTo((p.titleWidth + 24).floor()));
  });

  testWidgets('a 1 MB cell is cut before it is laid out', (t) async {
    final huge = SheetData(null, [['x' * (1 << 20)]]);
    final plan = (await planSheet(huge))!;
    expect(plan.cut, isTrue);
    expect(plan.rowHeights.single, lessThan(maxImageSide));
    final w = await open(t);
    await importFile(t, w, 'big.csv', Uint8List.fromList(utf8.encode('"${"y" * (1 << 20)}",b\n')), 'asImage');
    expect(boxes(w), hasLength(1));
    expect(notices, ['"big.csv": long cells were shortened.']);
    await w.close(t);
  });

  testWidgets('a cell the reader kept whole is drawn without the shortened notice; one it cut is noticed', (t) async {
    final w = await open(t);
    await importFile(t, w, 'mid.csv', Uint8List.fromList(utf8.encode('"${"m" * 3000}",b\n')), 'asImage');
    expect(boxes(w), hasLength(1));
    expect(notices, isEmpty);
    await w.close(t);
  });

  testWidgets('the layout of a big sheet stops at its first yield when the page changed', (t) async {
    final w = await open(t);
    final first = w.nb.current!;
    var converted = false;
    importRunner = <R>(R Function() work) async {
      final r = work();
      converted = true;
      return r;
    };
    // 60 rows of 50 cells: the layout yields after 2,000 cells.
    final rows = [for (var r = 0; r < 60; r++) [for (var c = 0; c < 50; c++) 'r$r c$c'].join(',')].join('\n');
    importPicker = () async => [ImportSource('big.csv', length: () async => 10, read: () async => Uint8List.fromList(utf8.encode(rows)))];
    final run = w.canvas(t).commands.invoke('app.import');
    await choose(t, 'asImage');
    for (var i = 0; i < 100 && !converted; i++) {
      await t.pump(Duration.zero);
    }
    expect(converted, isTrue);
    await w.openPage(t, w.second);
    await until(t, () => importsRunning.value == 0);
    unawaited(run);
    expect(boxes(w), isEmpty);
    expect(notices, ['Import stopped: the page changed.']);
    expect(first.page.nodes.whereType<BoxRecord>(), isEmpty);
    await w.close(t);
  });

  testWidgets('a cell too long to show in full gives the notice', (t) async {
    final w = await open(t);
    final cell = List.filled(400, 'x').join('\n');
    await importFile(t, w, 'x.csv', Uint8List.fromList(utf8.encode('"$cell",b\n')), 'asImage');
    expect(boxes(w), hasLength(1));
    expect(notices, ['"x.csv": some cells were too long to show in full.']);
    await w.close(t);
  });

  testWidgets('a sheet as an image: a chunk per 100 rows, stacked down; it loads again', (t) async {
    final w = await open(t);
    final rows = StringBuffer();
    for (var r = 1; r <= 250; r++) {
      rows.write('<row r="$r">${[for (var k = 0; k < 3; k++) '<c r="${String.fromCharCode(0x41 + k)}$r"><v>${r * 10 + k}</v></c>'].join()}</row>');
    }
    await importFile(t, w, 'book.xlsx', buildXlsx({'Data': rows.toString()}), 'asImage');
    final b = boxes(w);
    expect(b.map((x) => x.typeId), ['noted.image', 'noted.image', 'noted.image']);
    expect(b[0].data.toString(), contains('book-1.png'));
    expect(b[2].data.toString(), contains('book-3.png'));
    expect(b[1].bounds.y, greaterThan(b[0].bounds.y));
    expect(notices, isEmpty);
    await expectReloads(t, w);
    await w.close(t);
  });

  testWidgets('a csv as an image', (t) async {
    final w = await open(t);
    await importFile(t, w, 'a.csv', Uint8List.fromList('a,b\n1,2\n3,4\n'.codeUnits), 'asImage');
    expect(boxes(w).map((x) => x.typeId), ['noted.image']);
    await w.close(t);
  });

  test('the folder store forces the folder, forwards the rest and keeps the interfaces', () async {
    final inner = _Inner();
    final s = forceFolderStorage(inner);
    expect(s, isA<PageFolderAttachmentStore>());
    expect(s.storage, AttachmentStorage.folder);
    expect(inner.storage, AttachmentStorage.embedded);
    await s.put(Uint8List(1), extension: 'png');
    await s.put(Uint8List(2), extension: 'png', storage: AttachmentStorage.embedded);
    expect(inner.puts, [AttachmentStorage.folder, AttachmentStorage.folder]);
    expect(inner.notices, [overLimitNotice]);
    expect(s.exists('x'), isTrue);
    await (s as PageFolderAttachmentStore).verifyInPageFolder('x', size: 3);
    await s.putInPageFolder(Uint8List(1), extension: 'png');
    await s.readVerified('x', size: 1);
    expect(inner.calls, ['verifyInPageFolder', 'putInPageFolder', 'readVerified']);
    expect(forceFolderStorage(_Plain()), isNot(isA<VerifyingAttachmentStore>()));
  });
}

class _Plain implements AttachmentStore {
  final List<AttachmentStorage?> puts = [];
  final List<String> notices = [];

  @override
  AttachmentStorage get storage => AttachmentStorage.embedded;

  @override
  Future<StoredAttachment> put(Uint8List bytes, {required String extension, AttachmentStorage? storage}) async {
    puts.add(storage);
    return StoredAttachment(hash: 'h', fileName: 'h.$extension');
  }

  @override
  Future<Uint8List?> read(String fileName) async => null;

  @override
  bool exists(String fileName) => true;

  @override
  Listenable get changes => ChangeNotifier();

  @override
  Directory get cacheDirectory => Directory.systemTemp;

  @override
  void notify(String message) => notices.add(message);

  @override
  Future<void> open(String name, {String? fileName, Uint8List? bytes}) async {}

  @override
  Future<List<IncomingFile>> pick({required bool imagesOnly}) async => const [];
}

class _Inner extends _Plain implements PageFolderAttachmentStore {
  final List<String> calls = [];

  @override
  Future<StoredAttachment> putInPageFolder(Uint8List bytes, {required String extension, AttachmentStorage? storage}) async {
    calls.add('putInPageFolder');
    return StoredAttachment(hash: 'h', fileName: 'h.$extension');
  }

  @override
  Future<VerifiedAttachment> verifyInPageFolder(String fileName, {required int size}) async {
    calls.add('verifyInPageFolder');
    return const VerifiedAttachment(AttachmentState.ok);
  }

  @override
  Future<VerifiedAttachment> readVerified(String fileName, {required int size}) async {
    calls.add('readVerified');
    return const VerifiedAttachment(AttachmentState.ok);
  }

  @override
  Future<VerifiedAttachment> verify(String fileName, {required int size}) async {
    calls.add('verify');
    return const VerifiedAttachment(AttachmentState.ok);
  }
}
