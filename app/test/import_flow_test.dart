// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Dropping and picking documents: the target is taken first, the dialog asks,
// the converted note boxes go in, and what is saved loads again the same.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/import/convert.dart';
import 'package:noted/src/import/import_flow.dart';
import 'package:noted/src/import/import_format.dart';
import 'package:noted/src/import/import_limits.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/settle_saves.dart';
import 'support/shell_world.dart';
import 'support/zip_builder.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Future<R> _inline<R>(R Function() work) async => work();

void main() {
  late List<String> notices;
  late StreamSubscription<String> sub;

  setUp(() {
    notices = [];
    importRunner = _inline;
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

  /// Pumps frames and real time until [done].
  Future<void> until(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(done(), isTrue, reason: 'waited too long');
  }

  /// Drops [files] on the middle of the canvas; the returned flag is true
  /// once the whole import is done.
  ({bool Function() done}) drop(WidgetTester t, ShellWorld w, List<File> files) {
    final target = t.widget<DropTarget>(find.byType(DropTarget));
    final at = t.getCenter(find.byKey(PageCanvas.overlayKey));
    target.onDragDone!(
      DropDoneDetails(files: [for (final f in files) DropItemFile(f.path)], localPosition: at, globalPosition: at),
    );
    return (done: () => importsRunning.value == 0);
  }

  Future<File> write(ShellWorld w, String name, List<int> bytes) async {
    final f = File('${w.dir.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  Future<void> choose(WidgetTester t, String choice) async {
    await until(t, () => find.byKey(const ValueKey('import-dialog')).evaluate().isNotEmpty);
    await t.tap(find.byKey(ValueKey('import-choice-$choice')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('import-ok')));
    await t.pump();
  }

  List<BoxRecord> boxes(ShellWorld w) => w.nb.current!.page.nodes.whereType<BoxRecord>().toList();

  List<Map<String, Object?>> blocksIn(BoxRecord b) {
    final json = jsonDecode(b.data.toString()) as Map<String, Object?>;
    return [for (final x in ((json['document']! as Map)['children']! as List)) x as Map<String, Object?>];
  }

  testWidgets('a dropped .md asks, and Import makes one note box that keeps its height free', (t) async {
    final w = await open(t);
    const md = '# Title\n\nSome *text*\n';
    final f = await t.runAsync(() => write(w, 'doc.md', utf8.encode(md)));
    final d = drop(t, w, [f!]);
    await choose(t, 'asText');
    await until(t, d.done);
    final b = boxes(w);
    expect(b, hasLength(1));
    expect(b.single.typeId, 'noted.note');
    expect(b.single.fixedHeight, isFalse);
    expect(blocksIn(b.single), markdownToNoteBlocks(md));
    await w.close(t);
  });

  testWidgets('As a file makes a file box', (t) async {
    final w = await open(t);
    final f = await t.runAsync(() => write(w, 'doc.md', utf8.encode('# x')));
    final d = drop(t, w, [f!]);
    await choose(t, 'asFile');
    await until(t, d.done);
    expect(boxes(w).map((b) => b.typeId), ['noted.file']);
    await w.close(t);
  });

  testWidgets('Cancel adds nothing', (t) async {
    final w = await open(t);
    final f = await t.runAsync(() => write(w, 'doc.md', utf8.encode('# x')));
    final d = drop(t, w, [f!]);
    await until(t, () => find.byKey(const ValueKey('import-dialog')).evaluate().isNotEmpty);
    await t.tap(find.byKey(const ValueKey('import-cancel')));
    await until(t, d.done);
    expect(boxes(w), isEmpty);
    await w.close(t);
  });

  testWidgets('an image skips the dialog; a PDF, with no renderer, is a file box as before', (t) async {
    final w = await open(t);
    final png = await t.runAsync(() => write(w, 'p.png', _png));
    final pdf = await t.runAsync(() => write(w, 'p.pdf', [1, 2, 3]));
    final d = drop(t, w, [png!, pdf!]);
    await until(t, d.done);
    expect(find.byKey(const ValueKey('import-dialog')), findsNothing);
    expect(boxes(w).map((b) => b.typeId), ['noted.image', 'noted.file']);
    await w.close(t);
  });

  testWidgets('a read-only page takes nothing and asks nothing', (t) async {
    final w = await open(t);
    w.nb.current!.readOnly = true;
    await t.pump();
    final f = await t.runAsync(() => write(w, 'doc.md', utf8.encode('# x')));
    final d = drop(t, w, [f!]);
    await until(t, d.done);
    expect(find.byKey(const ValueKey('import-dialog')), findsNothing);
    expect(boxes(w), isEmpty);
    w.nb.current!.readOnly = false;
    await w.close(t);
  });

  testWidgets('two files of one type: Use for all asks once, and the notes go side by side', (t) async {
    final w = await open(t);
    final a = await t.runAsync(() => write(w, 'a.txt', utf8.encode('first')));
    final b = await t.runAsync(() => write(w, 'b.txt', utf8.encode('second')));
    final d = drop(t, w, [a!, b!]);
    await until(t, () => find.byKey(const ValueKey('import-dialog')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('import-use-all')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('import-use-all')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('import-ok')));
    await until(t, d.done);
    final made = boxes(w);
    expect(made, hasLength(2));
    expect(made[1].bounds.x, made[0].bounds.x + made[0].bounds.width + 24);
    expect(made[1].bounds.y, made[0].bounds.y);
    await w.close(t);
  });

  testWidgets('a source over the size cap is refused before it is read', (t) async {
    final w = await open(t);
    importLimits = () => const ImportLimits(sourceBytes: 10, entryBytes: 10, archiveBytes: 10);
    var read = false;
    final c = w.canvas(t);
    final target = c.captureImportTarget(null)!;
    final run = runImport(
      t.element(find.byType(PageCanvas)),
      c,
      target,
      [
        ImportSource(
          'huge.txt',
          length: () async => 1000,
          read: () async {
            read = true;
            return Uint8List(1000);
          },
        ),
      ],
    );
    await until(t, () => find.byKey(const ValueKey('import-dialog')).evaluate().isNotEmpty);
    await t.tap(find.byKey(const ValueKey('import-ok')));
    await t.runAsync(() => run);
    await t.pump();
    expect(read, isFalse);
    expect(boxes(w), isEmpty);
    expect(notices, ['"huge.txt" is too large to import.']);
    await w.close(t);
  });

  testWidgets('a page that changes during the conversion gets nothing, and the other page neither', (t) async {
    final w = await open(t);
    final a = w.nb.current!;
    final gate = Completer<void>();
    importRunner = <R>(R Function() work) async {
      await gate.future;
      return work();
    };
    final f = await t.runAsync(() => write(w, 'doc.txt', utf8.encode('hello')));
    final d = drop(t, w, [f!]);
    await choose(t, 'asText');
    await t.pump();
    await w.openPage(t, w.second);
    final b = w.nb.current!;
    expect(identical(a, b), isFalse);
    gate.complete();
    await until(t, d.done);
    expect(a.page.nodes.whereType<BoxRecord>(), isEmpty);
    expect(b.page.nodes.whereType<BoxRecord>(), isEmpty);
    expect(notices, ['Import stopped: the page changed.']);
    await settleSaves(t, w.nb);
    await t.runAsync(() => w.nb.flush());
    late Notebook again;
    await t.runAsync(() async {
      again = Notebook(PageStore(Directory('${w.dir.path}/pages')), buildModules(), saveDelay: Duration.zero);
      await again.load();
      await again.open(w.first);
      expect(again.current!.page.nodes.whereType<BoxRecord>(), isEmpty);
      await again.open(w.second);
      expect(again.current!.page.nodes.whereType<BoxRecord>(), isEmpty);
      again.dispose();
    });
    await w.close(t);
  });

  testWidgets('the Import command picks, asks and adds; a read-only page has it off', (t) async {
    final w = await open(t);
    importPicker = () async => [
      ImportSource('t.txt', length: () async => 4, read: () async => Uint8List.fromList(utf8.encode('text'))),
    ];
    final run = w.canvas(t).commands.invoke('app.import');
    await choose(t, 'asText');
    await t.runAsync(() => run);
    await w.settle(t);
    expect(boxes(w).map((b) => b.typeId), ['noted.note']);
    w.nb.current!.readOnly = true;
    await t.pump();
    expect(w.canvas(t).commands['app.import']!.enabled, isFalse);
    w.nb.current!.readOnly = false;
    await w.close(t);
  });

  testWidgets('a docx as text, and an xlsx as tables with a split sheet, load again the same', (t) async {
    final w = await open(t);
    final docx = await t.runAsync(
      () => write(
        w,
        'letter.docx',
        buildDocx(wp('Dear *reader*', style: 'Heading1') + wp('Body \$1 & [x]', bold: true) + wp('item', numId: '1')),
      ),
    );
    importLimits = () => const ImportLimits(sourceBytes: 1 << 24, entryBytes: 1 << 24, archiveBytes: 1 << 24, noteCells: 60);
    final cells = StringBuffer();
    for (var r = 1; r <= 30; r++) {
      cells.write('<row r="$r">${[for (var k = 0; k < 10; k++) '<c r="${String.fromCharCode(0x41 + k)}$r"><v>${r * 100 + k}</v></c>'].join()}</row>');
    }
    final xlsx = await t.runAsync(() => write(w, 'book.xlsx', buildXlsx({'Data': cells.toString()})));
    final d = drop(t, w, [docx!, xlsx!]);
    await until(t, () => find.byKey(const ValueKey('import-dialog')).evaluate().isNotEmpty);
    expect(find.text('letter.docx'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('import-ok')));
    await until(t, () => find.text('book.xlsx').evaluate().isNotEmpty);
    await t.tap(find.byKey(const ValueKey('import-ok')));
    await until(t, d.done);
    final a = w.nb.current!;
    final made = boxes(w);
    expect(made.length, greaterThan(2), reason: 'the 300-cell sheet is split over boxes of 60 cells');
    expect(made.map((b) => b.typeId).toSet(), {'noted.note'});
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
    for (final n in a.page.nodes.whereType<BoxRecord>()) {
      final r = reloaded.page.node(n.id)! as BoxRecord;
      expect(r.bounds, n.bounds);
      expect(r.fixedHeight, n.fixedHeight);
      expect(r.data.toString(), n.data.toString());
      expect(r.snapshotText, n.snapshotText);
    }
    // The text box holds the literal characters.
    expect(made.first.snapshotText, contains(r'Body $1 & [x]'));
    await t.runAsync(() async => again.dispose());
    await w.close(t);
  });
}
