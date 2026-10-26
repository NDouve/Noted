// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Test harness for the hands-on checklist automation.
///
/// Every test runs the real [NotedApp] on a real Windows window, but with a
/// [Notebook] whose every data location (pages, `binders.json`,
/// `settings.json`, the recovery folder, app-wide templates, binder and
/// standalone folders) is inside one per-test temp directory ([Env]). The
/// maintainer's real data (`%APPDATA%\Noted`) is never opened:
/// [Env.assertIsolated] checks that at the start of every test.
library;

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

final String _sep = Platform.pathSeparator;

/// The per-test sandbox: a temp directory and the paths inside it.
class Env {
  Env._(this.root)
    : pages = Directory('${root.path}${_sep}pages'),
      appDir = Directory('${root.path}${_sep}app'),
      binders = File('${root.path}${_sep}app${_sep}binders.json'),
      settingsFile = File('${root.path}${_sep}app${_sep}settings.json'),
      recovery = Directory('${root.path}${_sep}app${_sep}recovery'),
      templates = Directory('${root.path}${_sep}app${_sep}templates');

  final Directory root;
  final Directory pages;
  final Directory appDir;
  final File binders;
  final File settingsFile;
  final Directory recovery;
  final Directory templates;

  static Future<Env> create(String name) async {
    final tmp = await Directory.systemTemp.createTemp('noted_it_${name}_');
    final env = Env._(Directory(await tmp.resolveSymbolicLinks()));
    await env.pages.create(recursive: true);
    await env.appDir.create(recursive: true);
    return env;
  }

  /// A folder inside the sandbox (created).
  Directory folder(String name) {
    final d = Directory('${root.path}$_sep$name');
    d.createSync(recursive: true);
    return d;
  }

  static String _n(String p) => p.replaceAll('/', r'\').toLowerCase();

  bool contains(String path) {
    final r = _n(root.absolute.path);
    final p = _n(File(path).absolute.path);
    return p == r || p.startsWith('$r\\');
  }

  /// Fails unless every data location of [nb] and [settings] is inside the
  /// sandbox and none is under the real `%APPDATA%\Noted`.
  void assertIsolated(Notebook nb, AppSettings settings) {
    final paths = <String, String?>{
      'pages': nb.store.directory.path,
      'binders.json': nb.bindersFile?.path,
      'settings.json': settings.file?.path,
      'recovery': nb.recoveryDirectory?.path,
      'templates': nb.appTemplatesDirectory?.path,
      'default binder folder': nb.builtinBinderFolderPath,
      'new page folder': nb.newPageFolderPath,
    };
    final appData = Platform.environment['APPDATA'];
    for (final e in paths.entries) {
      expect(e.value, isNotNull, reason: '${e.key} must be set');
      expect(
        contains(e.value!),
        isTrue,
        reason: '${e.key} (${e.value}) must be under the temp dir ${root.path}',
      );
      if (appData != null) {
        expect(
          _n(File(e.value!).absolute.path).startsWith(_n('$appData${_sep}Noted')),
          isFalse,
          reason: '${e.key} must not be in the real app data',
        );
      }
    }
  }

  Future<void> dispose() async {
    for (var i = 0; i < 5; i++) {
      try {
        if (root.existsSync()) await root.delete(recursive: true);
        return;
      } on FileSystemException {
        // A watcher may still hold a handle for a moment.
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
  }
}

/// One run of the app against an [Env].
class Session {
  Session(this.tester, this.env);

  final WidgetTester tester;
  final Env env;
  late Notebook nb;
  late AppSettings settings;

  /// What the folder picker answers (null: cancelled), and how often it was asked.
  String? pickAnswer;
  int picks = 0;

  /// Starts the app: builds a [Notebook] the way `main()` does, but in the
  /// sandbox, loads it and shows [NotedApp].
  Future<void> launch({
    Size size = const Size(1400, 900),
    bool watchFiles = false,
    Duration folderCheckInterval = Duration.zero,
    Duration saveDelay = const Duration(milliseconds: 200),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    settings = AppSettings(env.settingsFile);
    nb = Notebook(
      PageStore(env.pages),
      buildModules(),
      saveDelay: saveDelay,
      bindersFile: env.binders,
      recoveryDirectory: env.recovery,
      pickFolder: () async {
        picks++;
        return pickAnswer;
      },
      watchFiles: watchFiles,
      watchDebounce: const Duration(milliseconds: 150),
      folderCheckInterval: folderCheckInterval,
      deviceName: 'TESTPC',
      settings: settings,
    );
    env.assertIsolated(nb, settings);
    await nb.load();
    await tester.pumpWidget(NotedApp(notebook: nb, settings: settings));
    await pump(300);
  }

  /// Closes the app cleanly (flushes), as quitting does.
  Future<void> close() async {
    await nb.flush();
    await tester.pumpWidget(const SizedBox());
    await pump(100);
    nb.dispose();
    settings.dispose();
  }

  /// Quit and start again on the same data: a restart.
  Future<void> restart({bool watchFiles = false, Duration folderCheckInterval = Duration.zero}) async {
    await close();
    await launch(watchFiles: watchFiles, folderCheckInterval: folderCheckInterval);
  }

  /// Pumps fixed frames for [ms] (never pumpAndSettle: a focused editor
  /// blinks its caret forever).
  Future<void> pump([int ms = 200]) async {
    for (var t = 0; t < ms; t += 50) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Pumps until [done] (up to [timeout]), then a little more.
  Future<void> until(
    bool Function() done, {
    Duration timeout = const Duration(seconds: 15),
    String? what,
  }) async {
    final end = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(end)) {
        fail('timed out waiting for ${what ?? 'condition'}');
      }
      await tester.pump(const Duration(milliseconds: 50));
    }
    await pump(100);
  }

  /// Waits for saves to reach the disk.
  Future<void> flush() async {
    await nb.flush();
    await pump(100);
  }

  // Finders and state ------------------------------------------------------

  Finder row(String id) => find.byKey(ValueKey('page-row-$id'));

  List<String> get rootIds => nb.tree.roots.map((p) => p.id).toList();

  List<String> kids(String id) => nb.tree.childrenOf(id).map((p) => p.id).toList();

  List<String> canvasFiles(Directory d) => [
    for (final f in d.listSync())
      if (f is File && f.path.endsWith('.canvas')) f.path.split(RegExp(r'[\\/]')).last,
  ];

  bool hasPageFile(Directory d, String id) => File('${d.path}$_sep$id.canvas').existsSync();

  // Gestures ---------------------------------------------------------------

  Future<void> rightClick(String id) async {
    final at = tester.getCenter(row(id)) + const Offset(-40, 0);
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    await g.down(at);
    await g.up();
    await g.removePointer();
    await pump(300);
  }

  /// Right-clicks a page row and picks the menu item with [label].
  Future<void> pageMenu(String id, String label) async {
    await rightClick(id);
    if (find.text(label).evaluate().isEmpty) {
      fail('menu item $label not found');
    }
    await tester.tap(find.text(label).last);
    await pump(400);
  }

  Future<void> tapText(String text, {int settle = 400}) async {
    await tester.tap(find.text(text).last);
    await pump(settle);
  }

  Future<void> tapKey(String key, {int settle = 400}) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await pump(settle);
  }

  Future<void> ctrl(LogicalKeyboardKey key, {bool shift = false}) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pump(150);
  }

  Future<void> key(LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await pump(150);
  }

  /// Creates a page through the model (setup) and names it.
  Future<String> newPage(String title, {String? parentId, String? binderPath}) async {
    final id = await nb.createPage(parentId: parentId, binderPath: binderPath);
    await nb.rename(id, title);
    await pump(100);
    return id;
  }
}

/// Runs [body] in a fresh sandbox and cleans it up afterwards.
Future<void> withSession(
  WidgetTester tester,
  String name,
  Future<void> Function(Session s) body, {
  Future<void> Function(Env env)? prepare,
  bool watchFiles = false,
  Duration folderCheckInterval = Duration.zero,
}) async {
  final env = await Env.create(name);
  final s = Session(tester, env);
  var started = false;
  try {
    if (prepare != null) await prepare(env);
    await s.launch(watchFiles: watchFiles, folderCheckInterval: folderCheckInterval);
    started = true;
    await body(s);
  } finally {
    try {
      if (started) await s.close();
    } catch (_) {}
    tester.view.reset();
    await env.dispose();
  }
}
