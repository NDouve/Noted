// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Box API 0.18: box export (formats, the module hooks, offscreen), the
// canvas.exportBox command and the capped raster helpers.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

class _Codec extends BoxCodec<String> {
  const _Codec();
  @override
  String get typeId => 'test.text';
  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.fixed;
  @override
  String create() => '';
  @override
  String decode(Object? json, int storedVersion) => json! as String;
  @override
  Object? encode(String data) => data;
  @override
  String snapshotText(String data) => data;
  @override
  AiExposure aiExposure(String data) => AiText(data);
}

/// Records what its views were built with.
class _Module extends BoxModule<String> {
  _Module({this.formats = const []});

  final List<ExportFormat> formats;
  final List<bool> offscreenSeen = [];

  @override
  BoxCodec<String> get codec => const _Codec();

  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) => buildView(context, box);

  @override
  Widget buildView(BuildContext context, BoxContext<String> box) {
    offscreenSeen.add(box.offscreen);
    return Text(box.data);
  }

  @override
  List<ExportFormat> exportFormats(String data) => formats;

  @override
  Future<ExportedFile?> export(String data, ExportFormat format, ExportContext context) async =>
      format.id == 'text' ? ExportedFile('', Uint8List.fromList(data.codeUnits)) : null;
}

BoxRecord _box(String id, String text) => BoxRecord.create(
  id: id,
  typeId: 'test.text',
  dataVersion: 1,
  bounds: const Bounds(100, 100, 200, 100),
  data: RawJson.encode(text),
  snapshotText: text,
  rev: 'r-$id',
);

NotedPage _page(List<CanvasNode> nodes) {
  var p = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
  for (final n in nodes) {
    p = p.insertNode(n);
  }
  return p;
}

class _FakeSource implements ExportImageSource {
  _FakeSource(this.width, this.height);

  @override
  final int width;
  @override
  final int height;
  final List<(int?, int?)> decoded = [];
  bool disposed = false;

  @override
  Future<ui.Codec> instantiateCodec({int? targetWidth, int? targetHeight}) async {
    decoded.add((targetWidth, targetHeight));
    throw StateError('stop here');
  }

  @override
  void dispose() => disposed = true;
}

// A GIF of two frames of one pixel: the first red, the second blue (each with
// its own local colour table).
final Uint8List _twoFrameGif = Uint8List.fromList([
  ...'GIF89a'.codeUnits, 1, 0, 1, 0, 0x80, 0, 0, 255, 255, 255, 0, 0, 0, //
  0x21, 0xF9, 4, 0, 10, 0, 0, 0, //
  0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0x80, 255, 0, 0, 0, 0, 0, 2, 2, 0x44, 1, 0,
  0x21, 0xF9, 4, 0, 10, 0, 0, 0, //
  0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0x80, 0, 0, 255, 0, 0, 0, 2, 2, 0x44, 1, 0,
  0x3B,
]);

Future<Uint8List> _png(int w, int h, ui.Color color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = color);
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  group('exportRasterSize', () {
    test('2x of a small box', () {
      final r = exportRasterSize(const Size(300, 200), 2);
      expect((r.width, r.height, r.scale), (600, 400, 2.0));
    });

    test('no side is over 4,096 px', () {
      final r = exportRasterSize(const Size(3000, 100), 2);
      expect(r.width, 4096);
      expect(r.height, lessThanOrEqualTo(137));
      expect(r.scale, closeTo(4096 / 3000, 1e-9));
    });

    test('no raster holds more than 16 MP', () {
      final r = exportRasterSize(const Size(4000, 4000), 2);
      expect(r.width * r.height, lessThanOrEqualTo(exportMaxPixels));
      expect(r.width, lessThanOrEqualTo(exportMaxSide));
      // The aspect ratio is kept.
      expect(r.width / r.height, closeTo(1, 0.01));
    });

    test('an empty size is one pixel', () {
      final r = exportRasterSize(Size.zero, 2);
      expect(r.width, greaterThanOrEqualTo(1));
      expect(r.height, greaterThanOrEqualTo(1));
    });
  });

  test('jpeg and pdf are host ids; a module lists neither', () {
    expect(ExportFormat.hostIds, {'jpeg', 'pdf'});
    expect(ExportFormat.png.extension, 'png');
    expect(ExportFormat.original.extension, '');
  });

  group('the module hooks', () {
    test('a module lists no format by default, which turns Export off', () {
      final m = _Module();
      expect(m.hostExportFormats('x'), isEmpty);
    });

    test('the untyped hooks check the data type', () async {
      final m = _Module(formats: const [ExportFormat.text]);
      expect(m.hostExportFormats('x'), [ExportFormat.text]);
      expect(m.hostExportFormats(42), isEmpty);
      const context = ExportContext(size: Size(10, 10));
      expect((await m.hostExport('abc', ExportFormat.text, context))!.bytes, 'abc'.codeUnits);
      expect(await m.hostExport(42, ExportFormat.text, context), isNull);
      expect(await m.hostExport('abc', ExportFormat.markdown, context), isNull);
    });

    test('renderView is null without a host', () async {
      expect(await const ExportContext(size: Size(1, 1)).renderView(), isNull);
      final c = ExportContext(size: const Size(1, 1), viewRenderer: () async => Uint8List.fromList([1]));
      expect(await c.renderView(), [1]);
    });

    testWidgets('offscreen is false on the canvas and true when the binding says so', (t) async {
      final m = _Module();
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Column(
              children: [
                m.hostBuild(
                  context,
                  BoxBinding(
                    boxId: 'a',
                    data: 'one',
                    bounds: Rect.zero,
                    readOnly: true,
                    autoHeight: false,
                    autofocus: false,
                    commit: (_) {},
                    requestBounds: (_) {},
                  ),
                ),
                m.hostBuild(
                  context,
                  BoxBinding(
                    boxId: 'a',
                    data: 'two',
                    bounds: Rect.zero,
                    readOnly: true,
                    autoHeight: false,
                    autofocus: false,
                    commit: (_) {},
                    requestBounds: (_) {},
                    offscreen: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(m.offscreenSeen, [false, true]);
    });
  });

  group('canvas.exportBox', () {
    late CanvasController c;
    late CommandRegistry registry;

    Future<PageCanvasState> pump(
      WidgetTester t, {
      Future<void> Function(PageCanvasState canvas)? onExportBox,
      bool readOnly = false,
    }) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final modules = ModuleRegistry()..register(_Module(formats: const [ExportFormat.text]), isDefault: true);
      c = CanvasController(_page([_box('a', 'alpha'), _box('b', 'beta')]), modules, onChanged: (_) {});
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageCanvas(
              controller: c,
              readOnly: readOnly,
              onExportBox: onExportBox,
              onCommandsChanged: (r) {
                if (r != null) registry = r;
              },
            ),
          ),
        ),
      );
      await t.pump();
      return t.state<PageCanvasState>(find.byType(PageCanvas));
    }

    testWidgets('is not registered without a handler', (t) async {
      await pump(t);
      expect(registry[CanvasCommands.exportBox], isNull);
    });

    testWidgets('is enabled for exactly one selected box, and runs the handler', (t) async {
      PageCanvasState? ran;
      final canvas = await pump(t, onExportBox: (s) async => ran = s);
      final command = registry[CanvasCommands.exportBox]!;
      expect(command.label, 'Export…');
      expect(command.enabled, isFalse, reason: 'nothing is selected');
      c.select('a');
      await t.pump();
      expect(registry[CanvasCommands.exportBox]!.enabled, isTrue);
      await registry[CanvasCommands.exportBox]!.run();
      expect(ran, same(canvas));
      c.toggleMulti('b');
      await t.pump();
      expect(c.multiSelection.length, 2);
      expect(registry[CanvasCommands.exportBox]!.enabled, isFalse, reason: 'two boxes are selected');
    });

    testWidgets('works on a read-only page', (t) async {
      await pump(t, onExportBox: (s) async {}, readOnly: true);
      c.select('a');
      await t.pump();
      expect(registry[CanvasCommands.exportBox]!.enabled, isTrue);
    });

    testWidgets('captureExportTarget holds until the controller or the page changes', (t) async {
      final canvas = await pump(t, onExportBox: (s) async {});
      final target = canvas.captureExportTarget();
      expect(target.holds, isTrue);
      expect(target.pageId, 'p');
      expect(target.controller, same(c));
      await t.pumpWidget(const SizedBox());
      expect(target.holds, isFalse);
    });
  });

  group('decodeWithinCap', () {
    tearDown(() => exportImageOpener = null);

    test('decodes straight to a size within the cap, never at full size', () async {
      final source = _FakeSource(8000, 6000);
      exportImageOpener = (_) async => source;
      await expectLater(decodeWithinCap(Uint8List(0), 'big.png'), throwsStateError);
      expect(source.decoded, [(4096, 3072)]);
      expect(source.disposed, isTrue);
    });

    test('an image at the cap decodes at its own size', () async {
      final source = _FakeSource(100, 50);
      exportImageOpener = (_) async => source;
      await expectLater(decodeWithinCap(Uint8List(0), 'a.png'), throwsStateError);
      expect(source.decoded, [(100, 50)]);
    });

    test('an image over 100 MP is refused before any decode', () async {
      final source = _FakeSource(12000, 10000);
      exportImageOpener = (_) async => source;
      await expectLater(
        decodeWithinCap(Uint8List(0), 'huge.png'),
        throwsA(
          isA<ExportRefused>().having(
            (e) => e.message,
            'message',
            'huge.png is too large to convert. Export the original instead.',
          ),
        ),
      );
      expect(source.decoded, isEmpty);
      expect(source.disposed, isTrue);
    });

    testWidgets('a PNG decodes to RGBA at its size', (t) async {
      await t.runAsync(() async {
        final png = await _png(5, 3, const Color(0xFF00FF00));
        expect(isPngBytes(png), isTrue);
        final px = await decodeToRgba(png, 'g.png');
        expect((px.width, px.height), (5, 3));
        expect(px.rgba.sublist(0, 4), [0, 255, 0, 255]);
        expect(isPngBytes(Uint8List(3)), isFalse);
      });
    });

    testWidgets('a GIF gives its first frame', (t) async {
      await t.runAsync(() async {
        final image = await decodeWithinCap(_twoFrameGif, 'a.gif');
        final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        expect((image.width, image.height), (1, 1));
        expect(data!.buffer.asUint8List().sublist(0, 4), [255, 0, 0, 255]);
        final png = await imageToPng(image);
        expect(isPngBytes(png), isTrue);
        image.dispose();
      });
    });
  });
}
