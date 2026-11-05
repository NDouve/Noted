// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:noted_core/noted_core.dart';

import 'notebook.dart';

// Opening an existing page or binder from the file system (a double-click on
// a `.canvas` file or on `noted-binder.json`). The path comes from the
// command line of a first launch, or from the native runner when a second
// launch hands it to the running Noted. Paths are untrusted: see
// [resolveOpenPath].
//
// macOS (not wired up here): add a `CFBundleDocumentTypes` entry for the
// `.canvas` extension (and `noted-binder.json`) to `macos/Runner/Info.plist`,
// and in `AppDelegate.swift` override `application(_:openFiles:)` to send each
// path over the same channel as [OpenFileService.channel] (method `open`);
// the Dart side below needs no change.

/// The command-line arguments that name a file to open: everything that isn't
/// a flag (`--…`) or empty, in order.
List<String> openArgs(List<String> args) => [
  for (final a in args)
    if (a.isNotEmpty && !a.startsWith('--')) a,
];

/// [raw] as an absolute, normalized path if it is an existing file named
/// `*.canvas` or exactly `noted-binder.json`; otherwise throws a
/// [NotebookException] saying why. Nothing is created or changed.
String resolveOpenPath(String raw) {
  if (raw.isEmpty || raw.contains('\u0000')) {
    throw const NotebookException(
      "Noted can't open that: it isn't a file path.",
    );
  }
  final abs = File(raw).absolute.path;
  final String path;
  try {
    path = Uri.file(abs).normalizePath().toFilePath();
  } on Object {
    throw const NotebookException(
      "Noted can't open that: it isn't a file path.",
    );
  }
  final name = path.split(RegExp(r'[\\/]')).last;
  if (!name.endsWith(PageStore.extension) && name != binderFileName) {
    throw NotebookException(
      "Noted opens only page files ($name isn't one) and $binderFileName.",
    );
  }
  if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
    throw NotebookException("Noted can't find the file $name.");
  }
  return path;
}

/// Joins the folder or binder of the file at [raw] (as Open binder… does for
/// a binder, or as a standalone storage folder for a page outside binders),
/// then opens the page, or the binder's cover. Throws a [NotebookException]
/// for anything it can't do; nothing is written beyond what joining a folder
/// or binder writes (`binders.json`).
Future<void> openExistingFile(Notebook nb, String raw) async {
  final path = resolveOpenPath(raw);
  final dir = File(path).parent.path;
  final sep = Platform.pathSeparator;
  final isBinderFile = path.endsWith('$sep$binderFileName');
  final inBinder = isBinderFile || File('$dir$sep$binderFileName').existsSync();

  String? pageId;
  if (!isBinderFile) {
    try {
      pageId = readPage(await File(path).readAsString()).id;
    } on PageFormatException catch (e) {
      throw NotebookException("Noted can't read that page: ${e.message}");
    } on FileSystemException catch (e) {
      throw NotebookException("Noted can't read that page: ${e.message}");
    } on FormatException {
      throw const NotebookException("Noted can't read that page.");
    }
  }

  // Comparable form of a path, as the notebook compares them.
  String key(String p) {
    final k = File(p).absolute.path.replaceAll(r'\', '/');
    return Platform.isWindows ? k.toLowerCase() : k;
  }

  final dirKey = key(dir);
  // What this call adds (so a refusal can undo exactly that): judged from the
  // lists before and after the add.
  final bindersBefore = nb.binders.length;
  final foldersBefore = nb.standaloneFolders.length;
  String? added; // the path to remove again if the page is refused

  try {
    if (inBinder) {
      // A binder already listed is matched without regard to case (Windows).
      final listed = nb.binders
          .where((b) => key(b.path) == dirKey)
          .map((b) => b.path)
          .firstOrNull;
      final section = await nb.addBinder(listed ?? dir);
      if (nb.binders.length > bindersBefore) added = section.path;
      if (!section.available) {
        throw NotebookException(
          section.reason ?? "That binder can't be opened.",
        );
      }
      if (isBinderFile) {
        nb.showCover(section.path);
        return;
      }
    } else {
      final loc = await nb.addStandaloneFolder(dir);
      if (nb.standaloneFolders.length > foldersBefore && loc.isNotEmpty) {
        added = loc;
      }
    }
    final id = pageId!;
    // A file Noted hasn't listed yet (it arrived after its folder was joined)
    // is the one asked for: it becomes the page's file, and any other file
    // with that id is listed as a duplicate. Nothing is written.
    await nb.adoptUnlistedPageFile(path, id);
    // A file whose page id is already in Noted from elsewhere (a copy) is
    // listed as unreadable by the join; opening the id would open the other.
    final copy = [
      ...nb.unreadable,
      for (final b in nb.binders) ...b.unreadable,
    ].any((u) => key(u.path) == key(path));
    final section = inBinder
        ? nb.binders.where((b) => key(b.path) == dirKey).firstOrNull
        : null;
    final owner = nb.binderOfPage(id);
    final elsewhere = inBinder
        ? owner == null || section == null || key(owner) != key(section.path)
        : owner != null;
    if (copy || (nb.pageTitleOf(id) != null && elsewhere)) {
      throw const NotebookException(
        'A page with the same id is already in Noted, from another file.',
      );
    }
    if (nb.pageTitleOf(id) == null) {
      throw const NotebookException(
        "Noted can't add that page: it is a copy of another page or can't be read.",
      );
    }
    await nb.open(id);
  } on Object {
    final undo = added;
    if (undo != null) {
      try {
        if (inBinder) {
          await nb.removeBinder(undo);
        } else {
          await nb.removeStandaloneFolder(undo);
        }
      } on Object {
        // Left joined; the refusal below is what the user sees.
      }
    }
    rethrow;
  }
}

/// Receives files to open: from the command line at start, and over
/// [channel] from the native runner (a second launch handing its path to
/// this instance). Failures go to [notify] as one line.
class OpenFileService {
  OpenFileService(this.notebook);

  static const MethodChannel channel = MethodChannel('noted/open_files');

  final Notebook notebook;

  /// Shows a one-line notice (set by the app once it has a window).
  void Function(String message)? notify;

  Future<void> _chain = Future.value();

  /// Opens [path]; one file at a time, in the order given.
  Future<void> open(String path) => _chain = _chain.then((_) => _open(path));

  Future<void> _open(String path) async {
    try {
      await openExistingFile(notebook, path);
    } on NotebookException catch (e) {
      notify?.call(e.message);
    } on Object catch (e) {
      notify?.call("Noted can't open that file (${e.runtimeType}).");
    }
  }

  /// Opens the files named by the launch [args], then listens on [channel]
  /// (after asking the runner for the paths it held back while loading).
  /// Call once the notebook is loaded.
  Future<void> start(List<String> args, {bool listen = true}) async {
    for (final a in openArgs(args)) {
      await open(a);
    }
    if (!listen) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is String) {
        await open(call.arguments as String);
      }
    });
    try {
      final pending = await channel.invokeMethod<List<Object?>>('ready');
      for (final p in pending ?? const []) {
        if (p is String) await open(p);
      }
    } on MissingPluginException {
      // No native runner side (other platforms, tests).
    }
  }
}
