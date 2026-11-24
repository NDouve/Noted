// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/menu_bar.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_attachments.dart';
import 'package:noted/src/window_channel.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_core/noted_core.dart';

import 'real_io.dart';
import 'settle_saves.dart';

/// The app window over a real notebook in a temp folder, for the menu bar,
/// panel and theme tests. Pages are "Alpha" (open) and "Beta".
class ShellWorld {
  ShellWorld._(this.dir, this.nb, this.settings, this.first, this.second);

  final Directory dir;
  final Notebook nb;
  final AppSettings settings;
  final String first;
  final String second;

  /// Opens the window at [size]. With [checked] the notebook is loaded through
  /// `loadChecked`, which sets `firstLoadSucceeded` (File items need it).
  static Future<ShellWorld> open(
    WidgetTester t, {
    Size size = const Size(1280, 800),
    double dpr = 1,
    bool checked = true,
    ToolbarStyle toolbar = ToolbarStyle.tabs,
    WindowChannel? window,
  }) async {
    t.view.physicalSize = size * dpr;
    t.view.devicePixelRatio = dpr;
    addTearDown(t.view.reset);
    late Directory dir;
    late Notebook nb;
    late String first;
    late String second;
    await t.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('noted_shell');
      nb = Notebook(
        PageStore(Directory('${dir.path}/pages')..createSync()),
        buildModules(),
        saveDelay: Duration.zero,
      );
      if (checked) {
        await nb.loadChecked();
      } else {
        await nb.load();
      }
      first = nb.currentId!;
      second = await nb.createPage();
      await nb.rename(first, 'Alpha');
      await nb.rename(second, 'Beta');
      await nb.open(first);
    });
    final settings = AppSettings(
      File('${dir.path}/settings.json'),
      profileMarker: File('${dir.path}/binders.json'),
    )..toolbar = toolbar;
    final world = ShellWorld._(dir, nb, settings, first, second);
    await t.pumpWidget(NotedApp(notebook: nb, settings: settings, window: window));
    await world.settle(t);
    return world;
  }

  /// Pumps frames (and real IO time) until the window is quiet.
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    await t.pump(const Duration(milliseconds: 100));
  }

  /// The open page's canvas.
  PageCanvasState canvas(WidgetTester t) => t.state<PageCanvasState>(find.byType(PageCanvas));

  /// The menu bar's state.
  AppMenuBarState bar(WidgetTester t) => t.state<AppMenuBarState>(find.byType(AppMenuBar));

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await settleSaves(t, nb);
    await settleAttachmentChecks(t, nb.attachments);
    await t.runAsync(() async {
      nb.dispose();
      // A file check still reading an attachment holds the folder on Windows
      // for a moment: try again, for up to 10 s.
      for (var i = 0;; i++) {
        try {
          await dir.delete(recursive: true);
          return;
        } on FileSystemException {
          if (i >= 50) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    });
  }
}

/// A note box whose first paragraph is [text].
BoxRecord shellNote(String id, String text, {Bounds at = const Bounds(100, 100, 300, 40)}) {
  const codec = NoteCodec();
  final data = NoteData({
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
  });
  return BoxRecord.create(
    id: id,
    typeId: NoteCodec.id,
    dataVersion: 1,
    bounds: at,
    data: RawJson.encode(codec.encode(data)),
    snapshotText: codec.snapshotText(data),
    rev: 'r-$id',
  );
}

extension ShellWorldActions on ShellWorld {
  /// The top-left corner of the canvas area (under the menu bar, the title
  /// row and the toolbar).
  Offset canvasOrigin(WidgetTester t) => t.getTopLeft(find.byKey(PageCanvas.overlayKey));

  /// Puts a note box with [text] on the open page.
  Future<void> addNote(
    WidgetTester t,
    String id,
    String text, {
    Bounds at = const Bounds(100, 100, 300, 40),
  }) async {
    nb.current!.insertBox(shellNote(id, text, at: at));
    await t.pump();
  }

  /// Clicks into the note [id] so its editor takes the focus.
  Future<void> editNote(WidgetTester t, String id) async {
    final b = nb.current!.page.node(id)!.bounds!;
    final c = canvas(t);
    await t.tapAt(canvasOrigin(t) + c.view!.toScreen(Offset(b.x + 20, b.y + 14)));
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  /// A binder in a new folder with one page; returns its section.
  Future<BinderSection> addBinderWithPage(WidgetTester t, String name, {bool open = false}) async {
    late BinderSection binder;
    await t.runAsync(() async {
      final folder = await Directory('${dir.path}/$name').create();
      binder = await nb.addBinder(folder.path);
      final page = await nb.createPage(binderPath: binder.path);
      if (open) await nb.open(page);
    });

    await t.pump();
    return binder;
  }
}

extension ShellWorldOpen on ShellWorld {
  /// Runs [action] (a notebook change that saves or waits for a frame), pumping
  /// the window with real IO time until it is done.
  Future<void> run(WidgetTester t, Future<Object?> Function() action) async {
    var done = false;
    Object? error;
    unawaited(
      action().then<void>(
        (_) => done = true,
        onError: (Object e) {
          error = e;
          done = true;
        },
      ),
    );
    for (var i = 0; i < 100 && !done; i++) {
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    if (error != null) throw error!;
    expect(done, isTrue, reason: 'the notebook change finished');
    await t.pump(const Duration(milliseconds: 100));
  }

  /// Opens page [id] like a click in the tree.
  Future<void> openPage(WidgetTester t, String id) => run(t, () => nb.open(id));
}

/// The note editor (appflowy's `AppFlowyEditor`), found by its name: the app
/// does not depend on appflowy_editor.
final Finder noteEditorFinder = find.byWidgetPredicate(
  (w) => w.runtimeType.toString() == 'AppFlowyEditor',
);

/// The editor's selection as text (null: none), to compare before and after.
String? noteSelection(WidgetTester t) {
  final editor = t.widget(noteEditorFinder) as dynamic;
  return editor.editorState.selection?.toString();
}

/// Waits until [attachments] has no file check running (a check reads an
/// asset file; deleting the folder meanwhile fails on Windows).
Future<void> settleAttachmentChecks(
  WidgetTester t,
  PageAttachments? attachments, {
  Duration limit = const Duration(seconds: 20),
}) async {
  final clock = Stopwatch()..start();
  final scaled = limit * realIoScale;
  while (attachments != null && attachments.pendingChecks > 0) {
    if (clock.elapsed > scaled) fail('${attachments.pendingChecks} attachment checks did not finish within $scaled.');
    // A check started in the test's fake-time zone needs that zone pumped.
    await t.pump();
    await t.runAsync(() => realIoPause(20));
  }
}
