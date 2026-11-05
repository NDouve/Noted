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

  if (inBinder) {
    final section = await nb.addBinder(dir);
    if (!section.available) {
      throw NotebookException(section.reason ?? "That binder can't be opened.");
    }
    if (isBinderFile) {
      nb.showCover(section.path);
      return;
    }
  } else {
    await nb.addStandaloneFolder(dir);
  }
  if (nb.pageTitleOf(pageId!) == null) {
    throw const NotebookException(
      "Noted can't add that page: it is a copy of another page or can't be read.",
    );
  }
  await nb.open(pageId);
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
