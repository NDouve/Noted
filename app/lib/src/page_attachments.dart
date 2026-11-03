// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

/// Asks the user for files (only images when [imagesOnly]).
typedef FilePicker = Future<List<IncomingFile>> Function({required bool imagesOnly});

/// Opens a file with the system's default app.
typedef FileOpener = Future<void> Function(File file);

/// The notice shown when a file too large to embed goes to the folder.
const String overLimitNotice =
    'Files over 5 MB are kept in the folder beside the page, not in the page file.';

/// The open page's images and files: its assets folder,
/// `<page id>.assets/` beside the page file, as an [AttachmentStore].
///
/// A file that can't be written there because the folder is away (0064) is
/// kept in [recoveryDirectory] instead, under `<page id>.assets/`, and read
/// from there until the notebook moves it into place with the recovered
/// page.
class PageAttachments extends ChangeNotifier implements AttachmentStore {
  PageAttachments({
    required this.pageFolder,
    required this.pageId,
    required AttachmentStorage Function() storage,
    required this.cacheDirectory,
    this.recoveryDirectory,
    this.onNotice,
    this.picker,
    this.opener,
    bool watch = true,
  }) : _storage = storage,
       _watch = watch {
    _startWatching();
  }

  /// The folder that holds the page file.
  final Directory pageFolder;
  final String pageId;
  final AttachmentStorage Function() _storage;
  final bool _watch;

  @override
  final Directory cacheDirectory;

  /// The recovery store's folder (0070), or null for none.
  final Directory? recoveryDirectory;

  final void Function(String message)? onNotice;
  final FilePicker? picker;
  final FileOpener? opener;

  StreamSubscription<FileSystemEvent>? _watcher;
  bool _disposed = false;

  /// The assets folder.
  Directory get folder => Directory('${pageFolder.path}${Platform.pathSeparator}${assetsFolderName(pageId)}');

  /// Where files are kept while the folder can't be written.
  Directory? get recoveryFolder {
    final r = recoveryDirectory;
    return r == null ? null : Directory('${r.path}${Platform.pathSeparator}${assetsFolderName(pageId)}');
  }

  File _in(Directory d, String fileName) => File('${d.path}${Platform.pathSeparator}$fileName');

  @override
  AttachmentStorage get storage => _storage();

  @override
  Listenable get changes => this;

  /// Something changed in or around the assets folder (the notebook's
  /// folder watcher saw it): tell the boxes, and watch the folder if it has
  /// just appeared.
  void filesChanged() {
    if (_disposed) return;
    _startWatching();
    notifyListeners();
  }

  void _startWatching() {
    if (!_watch || _watcher != null || _disposed) return;
    final f = folder;
    if (!f.existsSync()) return;
    try {
      _watcher = f.watch().listen(
        (_) => filesChanged(),
        onError: (Object e) => _stopWatching(),
        onDone: _stopWatching,
      );
    } on FileSystemException catch (e) {
      debugPrint('Watching ${f.path} failed: $e');
    }
  }

  void _stopWatching() {
    unawaited(_watcher?.cancel());
    _watcher = null;
  }

  @override
  Future<StoredAttachment> put(
    Uint8List bytes, {
    required String extension,
    AttachmentStorage? storage,
  }) async {
    final hash = contentHash(bytes);
    final name = attachmentFileName(hash, extension);
    final want = storage ?? this.storage;
    if (want == AttachmentStorage.embedded) {
      if (canEmbed(bytes)) {
        return StoredAttachment(hash: hash, fileName: name, embedded: bytes);
      }
      onNotice?.call(overLimitNotice);
    }
    await _write(name, bytes);
    return StoredAttachment(hash: hash, fileName: name, overLimit: want == AttachmentStorage.embedded);
  }

  // Writes [name] into the assets folder (atomically; an existing file has
  // the same content, so it is left alone), or into the recovery folder if
  // the page's folder can't be written.
  static int _tmpCounter = 0;

  Future<void> _write(String name, Uint8List bytes) async {
    Future<void> into(Directory d) async {
      final target = _in(d, name);
      if (await target.exists()) return;
      await d.create(recursive: true);
      // A unique name, so an extensionless write (`<hash>.tmp`) can never
      // clobber a real attachment called `<hash>.tmp`.
      final tmp = File('${target.path}.${DateTime.now().microsecondsSinceEpoch}-${_tmpCounter++}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(target.path);
    }

    try {
      if (!await pageFolder.exists()) {
        throw FileSystemException('The page folder is not available', pageFolder.path);
      }
      await into(folder);
      _startWatching();
    } on FileSystemException catch (e) {
      final r = recoveryFolder;
      if (r == null) rethrow;
      debugPrint('Keeping $name for recovery: $e');
      await into(r);
    }
    filesChanged();
  }

  @override
  Future<Uint8List?> read(String fileName) async {
    for (final d in [folder, ?recoveryFolder]) {
      final f = _in(d, fileName);
      try {
        if (await f.exists()) return await f.readAsBytes();
      } on FileSystemException {
        // Being written or locked: try the next place.
      }
    }
    return null;
  }

  @override
  bool exists(String fileName) =>
      _in(folder, fileName).existsSync() || (recoveryFolder != null && _in(recoveryFolder!, fileName).existsSync());

  @override
  void notify(String message) => onNotice?.call(message);

  @override
  Future<void> open(String name, {String? fileName, Uint8List? bytes}) async {
    File? file;
    if (bytes != null) {
      // An embedded file: open a temporary copy with its own name.
      final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}noted-open${Platform.pathSeparator}${contentHash(bytes).substring(0, 16)}');
      await dir.create(recursive: true);
      final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      file = _in(dir, safe.isEmpty ? 'file' : safe);
      if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
    } else if (fileName != null) {
      for (final d in [folder, ?recoveryFolder]) {
        final f = _in(d, fileName);
        if (await f.exists()) {
          file = f;
          break;
        }
      }
    }
    if (file == null) return;
    await opener?.call(file);
  }

  @override
  Future<List<IncomingFile>> pick({required bool imagesOnly}) async =>
      await picker?.call(imagesOnly: imagesOnly) ?? const [];

  @override
  void dispose() {
    _disposed = true;
    _stopWatching();
    super.dispose();
  }
}
