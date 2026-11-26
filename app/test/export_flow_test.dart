// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Export… (design: box export, build steps 1 and 2): one box from the File
// menu, in the formats its module lists, through the checked write.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/export/export_flow.dart';
import 'package:noted/src/import/convert.dart' show runInIsolate;
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/settle_saves.dart';
import 'support/shell_world.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

// A GIF of two frames of one pixel: the first red, the second blue.
final Uint8List _gif = Uint8List.fromList([
  ...'GIF89a'.codeUnits, 1, 0, 1, 0, 0x80, 0, 0, 255, 255, 255, 0, 0, 0, //
  0x21, 0xF9, 4, 0, 10, 0, 0, 0, //
  0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0x80, 255, 0, 0, 0, 0, 0, 2, 2, 0x44, 1, 0,
  0x21, 0xF9, 4, 0, 10, 0, 0, 0, //
  0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0x80, 0, 0, 255, 0, 0, 0, 2, 2, 0x44, 1, 0,
  0x3B,
]);

BoxRecord _box(BoxCodec<Object?> codec, String id, Object? data, Bounds at) => commitBox(
  createBox(codec, at).withId(id),
  codec,
  data,
);

NoteData _noteData(String text, [Map<String, Object?>? attrs]) => NoteData({
  'document': {
    'type': 'page',
    'children': [
      {
        'type': 'paragraph',
        'data': {
          'delta': [
            {'insert': text, 'attributes': ?attrs},
          ],
        },
      },
    ],
  },
});

BoxRecord _note(String id, String text, [Map<String, Object?>? attrs]) =>
    _box(const NoteCodec(), id, _noteData(text, attrs), const Bounds(100, 100, 300, 60));

Stroke _stroke(String id) => Stroke(
  id: id,
  size: 12,
  points: Float64List.fromList([10, 20, 0.5, 0, 150, 20, 0.5, 10, 150, 80, 0.5, 20]),
);

void main() {
  late Directory out;
  late List<String> notices;
  late List<String> picked; // the names the save dialog was offered
  late StreamSubscription<String> sub;
  Future<String?> Function(String name, ExportFormat f)? pickOverride;
  var runs = 0;

  setUp(() {
    out = Directory.systemTemp.createTempSync('noted_export_flow');
    notices = [];
    picked = [];
    pickOverride = null;
    runs = 0;
    exportSavePicker = (name, format) async {
      picked.add(name);
      final over = pickOverride;
      if (over != null) return over(name, format);
      return '${out.path}${Platform.pathSeparator}$name';
    };
    exportRunner = <R>(work) async {
      runs++;
      return runInIsolate(work);
    };
  });

  tearDown(() {
    exportSavePicker = (name, format) async => null;
    exportRunner = runInIsolate;
    debugDefaultTargetPlatformOverride = null;
    out.deleteSync(recursive: true);
  });

  Future<ShellWorld> open(WidgetTester t, {Size size = const Size(1440, 900)}) async {
    final w = await ShellWorld.open(t, size: size);
    sub = w.nb.attachmentNotices.listen(notices.add);
    addTearDown(sub.cancel);
    return w;
  }

  Future<void> until(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(done(), isTrue, reason: 'waited too long');
  }

  Future<void> insert(WidgetTester t, ShellWorld w, BoxRecord box) async {
    w.nb.current!.insertBox(box);
    await t.pump();
  }

  /// Selects [id] and chooses File > Export….
  Future<void> startExport(WidgetTester t, ShellWorld w, String id) async {
    w.nb.current!.select(id);
    await t.pump();
    await t.tap(find.byKey(const ValueKey('menu-top-File')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('menu-canvas.exportBox')));
    await t.pump();
  }

  /// Chooses [id] in the format dialog and confirms.
  Future<void> chooseFormat(WidgetTester t, String id) async {
    await until(t, () => find.byKey(const ValueKey('export-dialog')).evaluate().isNotEmpty);
    await t.tap(find.byKey(ValueKey('export-format-$id')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('export-ok')));
    await t.pump();
  }

  /// Runs an export of [id] in [format] (null: the box has one format and no
  /// dialog) and waits for its notice.
  Future<String> export(WidgetTester t, ShellWorld w, String id, String? format) async {
    notices.clear();
    await startExport(t, w, id);
    if (format != null) await chooseFormat(t, format);
    await until(t, () => notices.isNotEmpty);
    return notices.single;
  }

  File exported(String name) => File('${out.path}${Platform.pathSeparator}$name');

  group('the File menu', () {
    testWidgets('has Export…, on only with exactly one box selected', (t) async {
      final w = await open(t);
      await insert(t, w, _note('a', 'one'));
      await insert(t, w, _note('b', 'two'));
      await t.tap(find.byKey(const ValueKey('menu-top-File')));
      await t.pumpAndSettle();
      MenuItemButton item() => t.widget<MenuItemButton>(find.byKey(const ValueKey('menu-canvas.exportBox')));
      expect(find.text('Export…'), findsOneWidget);
      expect(item().onPressed, isNull, reason: 'nothing is selected');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();

      w.nb.current!.select('a');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('menu-top-File')));
      await t.pumpAndSettle();
      expect(item().onPressed, isNotNull, reason: 'one box');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();

      w.nb.current!.toggleMulti('b');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('menu-top-File')));
      await t.pumpAndSettle();
      expect(item().onPressed, isNull, reason: 'two boxes');
      await w.close(t);
    });

    testWidgets('is there in a narrow window too', (t) async {
      final w = await open(t, size: const Size(600, 800));
      await insert(t, w, _note('a', 'one'));
      w.nb.current!.select('a');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('menu-top-File')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('menu-canvas.exportBox')), findsOneWidget);
      expect(
        t.widget<MenuItemButton>(find.byKey(const ValueKey('menu-canvas.exportBox'))).onPressed,
        isNotNull,
      );
      await w.close(t);
    });

    testWidgets('is not in the toolbar layouts, the box context menu or Details', (t) async {
      for (final style in ToolbarStyle.values) {
        expect(jsonEncode(style.layout.toJson()), isNot(contains(CanvasCommands.exportBox)), reason: style.name);
      }
      final w = await open(t);
      await insert(t, w, _note('a', 'one'));
      w.nb.current!.select('a');
      await t.pump();
      expect(find.text('Export…'), findsNothing, reason: 'not on the toolbar');
      // The box's context menu.
      final b = w.nb.current!.page.node('a')!.bounds!;
      final at = w.canvasOrigin(t) + w.canvas(t).view!.toScreen(Offset(b.x + 40, b.y + 30));
      final g = await t.startGesture(at, kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await g.up();
      await g.removePointer();
      await t.pumpAndSettle();
      expect(find.text('Export…'), findsNothing, reason: 'not in the box menu');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      // The Details panel.
      await t.tap(find.byKey(const ValueKey('menu-top-View')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('menu-app.view.panel')));
      await t.pumpAndSettle();
      expect(find.text('Export…'), findsNothing, reason: 'not in Details');
      await w.close(t);
    });

    testWidgets('is absent on devices', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final w = await open(t);
      expect(t.widget<PageCanvas>(find.byType(PageCanvas)).onExportBox, isNull);
      expect(w.canvas(t).commands[CanvasCommands.exportBox], isNull);
      expect(find.byKey(const ValueKey('menu-top-File')), findsNothing, reason: 'no menu bar on a device');
      await w.close(t);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('notes', () {
    testWidgets('plain text, from the note\'s own snapshot', (t) async {
      final w = await open(t);
      await insert(t, w, _note('a', 'Hello world'));
      final notice = await export(t, w, 'a', 'text');
      expect(notice, 'Exported Alpha - Note.txt.');
      expect(picked, ['Alpha - Note.txt']);
      expect(exported('Alpha - Note.txt').readAsStringSync(), 'Hello world');
      await w.close(t);
    });

    testWidgets('markdown is the escaped export form', (t) async {
      final w = await open(t);
      await insert(t, w, _note('a', 'see [x](javascript:alert(1)) <b>'));
      await export(t, w, 'a', 'markdown');
      expect(exported('Alpha - Note.md').readAsStringSync(), r'see \[x\]\(javascript:alert\(1\)\) &lt;b>');
      await w.close(t);
    });

    testWidgets('html is a standalone page with nothing external', (t) async {
      final w = await open(t);
      await insert(t, w, _note('a', '<script>x</script>'));
      await export(t, w, 'a', 'html');
      final text = exported('Alpha - Note.html').readAsStringSync();
      expect(text, contains('<p>&lt;script&gt;x&lt;/script&gt;</p>'));
      expect(text, isNot(contains('<script>')));
      await w.close(t);
    });

    testWidgets('png is the host\'s picture of the read-only view, drawn offscreen', (t) async {
      final w = await open(t);
      await insert(t, w, _note('a', 'Picture me'));
      final live = noteLiveCount('a');
      final notice = await export(t, w, 'a', 'png');
      expect(notice, 'Exported Alpha - Note.png.');
      final bytes = exported('Alpha - Note.png').readAsBytesSync();
      expect(isPngBytes(Uint8List.fromList(bytes)), isTrue);
      final px = (await t.runAsync(() => decodeToRgba(Uint8List.fromList(bytes), 'x')))!;
      expect(px.width, 600, reason: '300 wide at 2x');
      // A note grows with its text: the record's own height, at 2x.
      expect(px.height, (w.nb.current!.page.node('a')!.bounds!.height * 2).round());
      // The paper is white, not the page background, whatever the theme.
      expect(px.rgba.sublist(0, 4), [255, 255, 255, 255]);
      expect(noteLiveCount('a'), live, reason: 'the offscreen view was never one of the live notes');
      await w.close(t);
    });

    testWidgets('jpeg and pdf come from that picture, converted in one isolate each', (t) async {
      final w = await open(t);
      await insert(t, w, _note('a', 'Picture me'));
      await export(t, w, 'a', 'jpeg');
      expect(runs, 1);
      final jpeg = exported('Alpha - Note.jpg').readAsBytesSync();
      expect(jpeg.sublist(0, 2), [0xFF, 0xD8]);
      await export(t, w, 'a', 'pdf');
      expect(runs, 2);
      final pdf = exported('Alpha - Note.pdf').readAsBytesSync();
      expect(String.fromCharCodes(pdf.sublist(0, 8)), '%PDF-1.4');
      // 300 logical px wide is 225 pt; the height is the note's own times 0.75.
      final h = (w.nb.current!.page.node('a')!.bounds!.height * 0.75).toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
      expect(String.fromCharCodes(pdf), contains('/MediaBox [0 0 225 $h]'));
      await w.close(t);
    });
  });

  group('drawings', () {
    BoxRecord drawing() => _box(
      const DrawingCodec(),
      'd',
      DrawingData(strokes: [_stroke('s1')]),
      const Bounds(100, 100, 200, 100),
    );

    testWidgets('png and svg', (t) async {
      final w = await open(t);
      await insert(t, w, drawing());
      await export(t, w, 'd', 'png');
      final png = exported('Alpha - Drawing.png').readAsBytesSync();
      final px = (await t.runAsync(() => decodeToRgba(Uint8List.fromList(png), 'x')))!;
      expect((px.width, px.height), (400, 200));
      await export(t, w, 'd', 'svg');
      expect(exported('Alpha - Drawing.svg').readAsStringSync(), contains('<path d="M'));
      await w.close(t);
    });
  });

  group('images and files', () {
    Future<BoxRecord> imageIn(WidgetTester t, ShellWorld w, String id, Uint8List bytes, String name, {bool embed = false}) async {
      final ref = await t.runAsync(() async {
        final s = await w.nb.attachments!.put(
          bytes,
          extension: normalizedExtension(name),
          storage: embed ? AttachmentStorage.embedded : AttachmentStorage.folder,
        );
        final r = AttachmentRef(name: name, size: bytes.length, hash: s.hash);
        return s.embedded != null ? r.embedded(s.embedded!) : r.inFolder(s.fileName);
      });
      return _box(const ImageCodec(), id, ImageData(ref: ref!, width: 1, height: 1), const Bounds(100, 100, 120, 100));
    }

    testWidgets('an image\'s original is the stored file under its own name', (t) async {
      final w = await open(t);
      await insert(t, w, await imageIn(t, w, 'i', _png, 'Red dot.png'));
      final notice = await export(t, w, 'i', 'original');
      expect(notice, 'Exported Red dot.png.');
      expect(picked, ['Red dot.png']);
      expect(exported('Red dot.png').readAsBytesSync(), _png);
      await w.close(t);
    });

    testWidgets('a PNG original as PNG is the same bytes, never re-encoded', (t) async {
      final w = await open(t);
      await insert(t, w, await imageIn(t, w, 'i', _png, 'dot.png', embed: true));
      await export(t, w, 'i', 'png');
      expect(exported('Alpha - Image.png').readAsBytesSync(), _png);
      await w.close(t);
    });

    testWidgets('a GIF as PNG gives its first frame; as JPEG it is converted from that PNG', (t) async {
      final w = await open(t);
      await insert(t, w, await imageIn(t, w, 'i', _gif, 'anim.gif'));
      await export(t, w, 'i', 'png');
      final png = exported('Alpha - Image.png').readAsBytesSync();
      final px = (await t.runAsync(() => decodeToRgba(Uint8List.fromList(png), 'x')))!;
      expect(px.rgba.sublist(0, 4), [255, 0, 0, 255]);
      await export(t, w, 'i', 'jpeg');
      expect(exported('Alpha - Image.jpg').readAsBytesSync().sublist(0, 2), [0xFF, 0xD8]);
      await w.close(t);
    });

    testWidgets('a file box has one format: no dialog, its own name', (t) async {
      final w = await open(t);
      final bytes = Uint8List.fromList(utf8.encode('hello file'));
      final ref = (await t.runAsync(() async {
        final s = await w.nb.attachments!.put(bytes, extension: 'txt', storage: AttachmentStorage.folder);
        return AttachmentRef(name: 'Notes.txt', size: bytes.length, hash: s.hash).inFolder(s.fileName);
      }))!;
      await insert(t, w, _box(const FileCodec(), 'f', FileData(ref: ref), const Bounds(100, 100, 280, 64)));
      final notice = await export(t, w, 'f', null);
      expect(notice, 'Exported Notes.txt.');
      expect(find.byKey(const ValueKey('export-dialog')), findsNothing);
      expect(exported('Notes.txt').readAsBytesSync(), bytes);
      await w.close(t);
    });

    testWidgets('a file that is not there yet says it is still syncing, and opens nothing', (t) async {
      final w = await open(t);
      final bytes = Uint8List.fromList([1, 2, 3]);
      final ref = AttachmentRef(name: 'Later.pdf', size: 3, hash: contentHash(bytes), file: '${contentHash(bytes)}.pdf');
      await insert(t, w, _box(const FileCodec(), 'f', FileData(ref: ref), const Bounds(100, 100, 280, 64)));
      expect(await export(t, w, 'f', null), 'Later.pdf is still syncing.');
      expect(picked, isEmpty);
      await w.close(t);
    });

    testWidgets('a file with a name that is not an attachment name is not found, and never read', (t) async {
      final w = await open(t);
      final ref = AttachmentRef(name: 'Odd.txt', size: 1, hash: 'a' * 64, file: '../../secret.txt');
      await insert(t, w, _box(const FileCodec(), 'f', FileData(ref: ref), const Bounds(100, 100, 280, 64)));
      expect(await export(t, w, 'f', null), 'File not found: Odd.txt');
      await w.close(t);
    });

    testWidgets('a damaged file says so and exports nothing', (t) async {
      final w = await open(t);
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final hash = contentHash(bytes);
      final folder = Directory('${w.dir.path}/pages/${w.first}.assets')..createSync(recursive: true);
      File('${folder.path}/$hash.bin').writeAsBytesSync([9, 9, 9, 9]);
      final ref = AttachmentRef(name: 'Bad.bin', size: 4, hash: hash, file: '$hash.bin');
      await insert(t, w, _box(const FileCodec(), 'f', FileData(ref: ref), const Bounds(100, 100, 280, 64)));
      notices.clear();
      await startExport(t, w, 'f');
      const message = 'Bad.bin is damaged on this device. Nothing was exported.';
      await until(t, () => notices.contains(message));
      // The store also tells the user about the copy it set aside (0132).
      expect(notices, hasLength(2));
      expect(out.listSync(), isEmpty);
      await w.close(t);
    });
  });

  group('the write', () {
    testWidgets('a taken name asks "Replace <name>?" and replaces on Replace', (t) async {
      final w = await open(t);
      await insert(t, w, _note('a', 'new text'));
      exported('Alpha - Note.txt').writeAsStringSync('old text');
      notices.clear();
      await startExport(t, w, 'a');
      await chooseFormat(t, 'text');
      await until(t, () => find.byKey(const ValueKey('export-replace-dialog')).evaluate().isNotEmpty);
      expect(find.text('Replace Alpha - Note.txt?'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('export-replace-ok')));
      await t.pump();
      await until(t, () => notices.isNotEmpty);
      expect(notices.single, 'Exported Alpha - Note.txt.');
      expect(exported('Alpha - Note.txt').readAsStringSync(), 'new text');
      await w.close(t);
    });

    testWidgets('Cancel at the replace prompt writes nothing', (t) async {
      final w = await open(t);
      await insert(t, w, _note('a', 'new text'));
      exported('Alpha - Note.txt').writeAsStringSync('old text');
      await startExport(t, w, 'a');
      await chooseFormat(t, 'text');
      await until(t, () => find.byKey(const ValueKey('export-replace-dialog')).evaluate().isNotEmpty);
      await t.tap(find.byKey(const ValueKey('export-replace-cancel')));
      await t.pump();
      await until(t, () => find.byKey(const ValueKey('export-replace-dialog')).evaluate().isEmpty);
      // The temp is removed once the declined write unwinds.
      await until(t, () => out.listSync().length == 1);
      expect(exported('Alpha - Note.txt').readAsStringSync(), 'old text');
      expect(notices, isEmpty);
      await w.close(t);
    });

    testWidgets('a file that changed while the prompt was open is not replaced', (t) async {
      final w = await open(t);
      await insert(t, w, _note('a', 'new text'));
      exported('Alpha - Note.txt').writeAsStringSync('old text');
      notices.clear();
      await startExport(t, w, 'a');
      await chooseFormat(t, 'text');
      await until(t, () => find.byKey(const ValueKey('export-replace-dialog')).evaluate().isNotEmpty);
      exported('Alpha - Note.txt').writeAsStringSync('somebody else wrote this');
      await t.tap(find.byKey(const ValueKey('export-replace-ok')));
      await t.pump();
      await until(t, () => notices.isNotEmpty);
      expect(notices.single, 'Alpha - Note.txt changed since you chose it. Nothing was written.');
      expect(exported('Alpha - Note.txt').readAsStringSync(), 'somebody else wrote this');
      expect(out.listSync(), hasLength(1));
      await w.close(t);
    });

    testWidgets('Noted\'s own folders are refused', (t) async {
      final w = await open(t);
      await insert(t, w, _note('a', 'text'));
      pickOverride = (name, f) async => '${w.dir.path}${Platform.pathSeparator}pages${Platform.pathSeparator}$name';
      final before = _snapshot(w.dir);
      expect(await export(t, w, 'a', 'text'), "Choose a place outside Noted's folders.");
      expect(_snapshot(w.dir), before);
      pickOverride = (name, f) async => '${w.dir.path}${Platform.pathSeparator}binders.json';
      notices.clear();
      await startExport(t, w, 'a');
      await chooseFormat(t, 'text');
      await until(t, () => notices.isNotEmpty);
      expect(notices.single, "Choose a place outside Noted's folders.");
      await w.close(t);
    });

    testWidgets('the notebook\'s files are byte-identical after an export', (t) async {
      final w = await open(t);
      await insert(t, w, _note('a', 'text'));
      await settleSaves(t, w.nb);
      final before = _snapshot(w.dir);
      await export(t, w, 'a', 'markdown');
      expect(_snapshot(w.dir), before);
      await w.close(t);
    });
  });

  group('the box is checked again after the save dialog', () {
    testWidgets('a box deleted while the dialog is open: nothing is made or written', (t) async {
      final w = await open(t);
      await insert(t, w, _note('a', 'text'));
      pickOverride = (name, f) async {
        w.nb.current!.delete('a');
        return '${out.path}${Platform.pathSeparator}$name';
      };
      expect(await export(t, w, 'a', 'text'), 'Box removed. Nothing was exported.');
      expect(out.listSync(), isEmpty);
      await w.close(t);
    });

    testWidgets('a box type disallowed while the dialog is open', (t) async {
      final w = await open(t);
      await insert(
        t,
        w,
        _box(const DrawingCodec(), 'd', DrawingData(strokes: [_stroke('s')]), const Bounds(100, 100, 200, 100)),
      );
      final gate = Completer<void>();
      var asking = false;
      pickOverride = (name, f) async {
        asking = true;
        await gate.future;
        return '${out.path}${Platform.pathSeparator}$name';
      };
      notices.clear();
      await startExport(t, w, 'd');
      await chooseFormat(t, 'svg');
      await until(t, () => asking);
      // The user (or a sync) disallows the type while the save dialog is open.
      await w.run(t, () => w.nb.setBoxType(w.first, 'noted.drawing', false));
      gate.complete();
      await until(t, () => notices.isNotEmpty);
      expect(notices.single, 'Not allowed on this page');
      expect(out.listSync(), isEmpty);
      await w.close(t);
    });

    testWidgets('the page changing while the dialog is open stops the export', (t) async {
      final w = await open(t);
      await insert(t, w, _note('a', 'text'));
      final gate = Completer<void>();
      var asking = false;
      pickOverride = (name, f) async {
        asking = true;
        await gate.future;
        return '${out.path}${Platform.pathSeparator}$name';
      };
      notices.clear();
      await startExport(t, w, 'a');
      await chooseFormat(t, 'text');
      await until(t, () => asking);
      await w.openPage(t, w.second);
      gate.complete();
      await until(t, () => notices.isNotEmpty);
      expect(notices.single, 'Export stopped: the page changed.');
      expect(out.listSync(), isEmpty);
      await w.close(t);
    });

    testWidgets('a cancelled save dialog writes nothing and says nothing', (t) async {
      final w = await open(t);
      await insert(t, w, _note('a', 'text'));
      pickOverride = (name, f) async => null;
      await startExport(t, w, 'a');
      await chooseFormat(t, 'text');
      await t.pump(const Duration(milliseconds: 300));
      expect(out.listSync(), isEmpty);
      expect(notices, isEmpty);
      await w.close(t);
    });
  });

  group('boxes that can\'t be exported say why', () {
    testWidgets('an unknown box type: this device can\'t run it', (t) async {
      final w = await open(t);
      final unknown = BoxRecord.create(
        id: 'u',
        typeId: 'other.thing',
        dataVersion: 1,
        bounds: const Bounds(100, 100, 100, 100),
        data: RawJson.encode({'x': 1}),
        snapshotText: 'saved text',
        rev: 'r',
      );
      await insert(t, w, unknown);
      expect(await export(t, w, 'u', null), 'This box type is off on this device.');
      expect(picked, isEmpty);
      await w.close(t);
    });

    testWidgets('a disallowed type shows "Not allowed on this page"', (t) async {
      final w = await open(t);
      await insert(
        t,
        w,
        _box(const DrawingCodec(), 'd', DrawingData(strokes: [_stroke('s')]), const Bounds(100, 100, 200, 100)),
      );
      await w.nb.setBoxType(w.first, 'noted.drawing', false);
      await t.pump();
      expect(await export(t, w, 'd', null), 'Not allowed on this page');
      await w.close(t);
    });

    testWidgets('an encrypted box shows "Encrypted box"', (t) async {
      final w = await open(t);
      final enc = BoxRecord.create(
        id: 'e',
        typeId: 'noted.encrypted-note',
        dataVersion: 1,
        bounds: const Bounds(100, 100, 100, 100),
        data: RawJson.encode('cipher'),
        snapshotText: '',
        rev: 'r',
      );
      await insert(t, w, enc);
      expect(await export(t, w, 'e', null), 'Encrypted box');
      await w.close(t);
    });
  });
}

/// Every file under [dir] with its bytes, by relative path.
Map<String, List<int>> _snapshot(Directory dir) => {
  for (final e in dir.listSync(recursive: true).whereType<File>())
    e.path.substring(dir.path.length): e.readAsBytesSync(),
};
