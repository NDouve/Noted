// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// First launch and a save on an Android device (run 2026-11-25-01, task 1),
// run by the `android-emulator` job of ci.yml and by nothing else. The real
// app (`main()`) runs on the device's own, fresh storage.
//
// The job installs the apks once and runs one phase per `am instrument`, with
// `am force-stop` between them (a `flutter test -d` run would uninstall the app
// and wipe the saved page). `MainActivityTest` writes the phase, and the run
// id, to `<cache>/noted-test-phase` before the activity starts: two lines. This
// test reads and deletes that file, then runs the phase.
//
//  - probe: what the device does with `link` and `renameat2`, and whether
//    `publishExclusive` works through the registered publisher. It never fails.
//  - write: the app starts on fresh storage and shows its first page; a note
//    with a text is added and the page file on disk gets it (autosave, no
//    flush); a marker file is written outside `Noted/`.
//  - engine: no phase file (started by `am start`): starts the app and keeps it
//    running for 2 minutes; each engine that runs main() prints NOTED_MAIN_START.
//  - check: after a force-stop, the app starts again; the marker proves the
//    data was not wiped; the page holds the text, the file holds it, and no
//    temporary or set-aside file is left in the pages folder.
//
// Every line the job greps starts with `NOTED_`.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:noted/main.dart' as app;
import 'package:noted/src/notebook.dart' show Notebook, defaultPagesDirectory;
import 'package:noted/src/load_error_view.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/src/storage/file_stamp.dart' show allocCString, freeNative;
import 'package:path_provider/path_provider.dart';

typedef _LinkC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _LinkD = int Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _Rename2C = Int32 Function(Int32, Pointer<Uint8>, Int32, Pointer<Uint8>, Uint32);
typedef _Rename2D = int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef _ErrnoC = Pointer<Int32> Function();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'first launch and a save (the phase comes from the instrumentation)',
    (t) async {
      final (phase, runId) = await _readPhase();
      print('NOTED_PHASE $phase run=$runId');
      switch (phase) {
        case 'probe':
          await _probe();
        case 'write':
          await _write(t, runId);
        case 'check':
          await _check(t, runId);
        case 'engine':
          await _engine(t);
        default:
          fail('unknown phase "$phase"');
      }
      print('NOTED_PHASE_OK $phase');
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

String _textFor(String runId) => 'android save $runId';

Future<(String, String)> _readPhase() async {
  final f = File('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}noted-test-phase');
  // No phase file: the app was started by `am start` (the one-engine step), not
  // by the instrumentation. The `engine` phase only starts it.
  if (!f.existsSync()) return ('engine', 'local');
  final lines = f.readAsLinesSync();
  f.deleteSync();
  return (lines.first.trim(), lines.length > 1 ? lines[1].trim() : 'local');
}

// --- probe --------------------------------------------------------------------

Future<void> _probe() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}${Platform.pathSeparator}noted-probe')..createSync(recursive: true);
  String p(String n) => '${dir.path}${Platform.pathSeparator}$n';
  try {
    final libc = DynamicLibrary.process();
    final link = libc.lookupFunction<_LinkC, _LinkD>('link');
    final errno = libc.lookupFunction<_ErrnoC, _ErrnoC>('__errno', isLeaf: true);
    final hasRenameat2 = libc.providesSymbol('renameat2');
    print('NOTED_PROBE_OS ${Platform.operatingSystemVersion}');
    File(p('a')).writeAsStringSync('a');
    final a = allocCString(p('a'));
    final b = allocCString(p('b'));
    try {
      final rc = link(a, b);
      final e = rc == 0 ? 0 : errno().value;
      print('NOTED_LINK_PROBE link=$rc errno=$e renameat2=$hasRenameat2');
      if (rc == 0) print('NOTED_LINK_PROBE link works here: this level publishes by link; the rename path is a guard');
    } finally {
      freeNative(a);
      freeNative(b);
    }
    if (hasRenameat2) {
      final rename2 = libc.lookupFunction<_Rename2C, _Rename2D>('renameat2');
      File(p('c')).writeAsStringSync('c');
      File(p('d')).writeAsStringSync('d');
      final c = allocCString(p('c'));
      final d = allocCString(p('d'));
      final f = allocCString(p('free'));
      try {
        // RENAME_NOREPLACE = 1, AT_FDCWD = -100.
        var rc = rename2(-100, c, -100, d, 1);
        var e = rc == 0 ? 0 : errno().value;
        print('NOTED_LINK_PROBE renameat2 over an existing name: rc=$rc errno=$e (expect -1 and 17)');
        rc = rename2(-100, c, -100, f, 1);
        e = rc == 0 ? 0 : errno().value;
        print('NOTED_LINK_PROBE renameat2 to a free name: rc=$rc errno=$e (expect 0)');
      } finally {
        freeNative(c);
        freeNative(d);
        freeNative(f);
      }
    }
    // The real thing: publishExclusive through the registered publisher.
    useRenamePublishOnAndroid();
    final tmp = File(p('tmp'))..writeAsStringSync('published');
    final done = await publishExclusive(tmp, p('target'));
    final again = File(p('tmp2'))..writeAsStringSync('second');
    final taken = await publishExclusive(again, p('target'));
    print(
      'NOTED_PUBLISH_PROBE free=$done taken=$taken '
      'content=${File(p('target')).readAsStringSync()} tmpGone=${!tmp.existsSync()}',
    );
  } catch (e, st) {
    print('NOTED_PROBE_ERROR $e\n$st');
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // Only the probe's own files.
    }
  }
}

// --- the real app ---------------------------------------------------------------

String _visibleText(WidgetTester t) {
  final out = <String>[];
  for (final w in t.widgetList<Text>(find.byType(Text))) {
    final s = w.data ?? w.textSpan?.toPlainText();
    if (s != null && s.trim().isNotEmpty) out.add(s.trim());
  }
  return out.join(' | ');
}

/// Starts the real app and waits for its first page; prints the first-launch
/// lines the job greps. Fails on the error screen and after 60 s.
Future<Notebook> _launch(WidgetTester t) async {
  unawaited(
    app.main(const <String>[]).catchError((Object e, StackTrace st) {
      print('NOTED_FIRST_LAUNCH main() threw: $e\n$st');
    }),
  );
  final end = DateTime.now().add(const Duration(seconds: 60));
  while (true) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 50));
    if (find.byType(LoadErrorView).evaluate().isNotEmpty || find.byType(app.StorageErrorApp).evaluate().isNotEmpty) {
      final text = _visibleText(t);
      print('NOTED_FIRST_LAUNCH error: $text');
      fail('the first launch shows the error screen: $text');
    }
    if (find.byType(app.NotedApp).evaluate().isNotEmpty) {
      final nb = t.widget<app.NotedApp>(find.byType(app.NotedApp)).notebook;
      if (nb.current != null && nb.currentId != null && find.byType(PageCanvas).evaluate().isNotEmpty) {
        print('NOTED_FIRST_LAUNCH ok page=${nb.currentId}');
        return nb;
      }
    }
    if (DateTime.now().isAfter(end)) {
      final text = _visibleText(t);
      print('NOTED_FIRST_LAUNCH timeout: $text');
      fail('no first page after 60 s: $text');
    }
  }
}

Directory _pages() => defaultPagesDirectory();

List<File> _pageFiles() => [
  for (final e in _pages().listSync())
    if (e is File && e.path.endsWith('.canvas')) e,
];

Future<File> _marker() async =>
    File('${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}noted-test-phase.marker');

Future<void> _write(WidgetTester t, String runId) async {
  final nb = await _launch(t);
  final text = _textFor(runId);
  // A note on the open page, as typing in a new note box leaves it.
  final c = nb.current!;
  final box = c.createBoxAt(const Bounds(100, 100, 0, 0));
  final codec = c.modules.codecs.codecFor(box.typeId)!;
  c.commit(
    box.id,
    codec.decode({
      'document': {
        'type': 'page',
        'children': [
          {
            'type': 'paragraph',
            'data': {
              'delta': [
                {'insert': text},
              ],
            },
          },
        ],
      },
    }, 1),
  );
  // The autosave, not a flush: the page file gets the text within 20 s.
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!_pageFiles().any((f) => f.readAsStringSync().contains(text))) {
    if (DateTime.now().isAfter(end)) {
      print('NOTED_WRITE timeout: files=${_pageFiles().map((f) => f.path).toList()} left=${_pages().listSync().map((e) => e.path).toList()}');
      fail('the page file never got "$text" (autosave)');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await t.pump(const Duration(milliseconds: 50));
  }
  print('NOTED_WRITE ok: the page file holds "$text"');
  (await _marker()).writeAsStringSync('written $runId');
  print('NOTED_WRITE marker written');
}

Future<void> _check(WidgetTester t, String runId) async {
  final marker = await _marker();
  if (!marker.existsSync()) {
    print('NOTED_CHECK data was wiped: no marker');
    fail('data was wiped: the marker of the write phase is gone');
  }
  final nb = await _launch(t);
  final text = _textFor(runId);
  final shown = [
    for (final n in nb.current!.page.nodes)
      if (n is BoxRecord) n.data?.decode().toString() ?? '',
  ];
  print('NOTED_CHECK boxes=${shown.length} onScreen=${find.textContaining(text, findRichText: true).evaluate().length}');
  expect(shown.any((s) => s.contains(text)), isTrue, reason: 'the page shows "$text"');
  expect(find.textContaining(text, findRichText: true), findsWidgets, reason: 'the text is on the screen');
  expect(_pageFiles().any((f) => f.readAsStringSync().contains(text)), isTrue, reason: 'the page file holds "$text"');
  final stray = [
    for (final e in _pages().listSync())
      if (e.path.endsWith('.tmp') || e.path.contains('.cas-')) e.path,
  ];
  expect(stray, isEmpty, reason: 'no temporary or set-aside file is left');
  print('NOTED_CHECK ok');
}
Future<void> _engine(WidgetTester t) async {
  await _launch(t);
  final end = DateTime.now().add(const Duration(minutes: 2));
  while (DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await t.pump(const Duration(milliseconds: 50));
  }
}
