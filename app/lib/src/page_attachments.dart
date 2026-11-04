// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'attachment_copy.dart';

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
class PageAttachments extends ChangeNotifier implements VerifyingAttachmentStore {
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
    await _write(name, hash, bytes);
    return StoredAttachment(hash: hash, fileName: name, overLimit: want == AttachmentStorage.embedded);
  }

  // Writes [name] (the file for [bytes], whose hash is [hash]) into the assets
  // folder, atomically, or into the recovery folder if the page's folder can't
  // be written. A file already under that name is trusted only if it holds
  // [hash]: a damaged one is kept aside (see [setAsideDamaged]) and the good
  // bytes are written under the name, so both copies stay. When the existing
  // file can't be replaced (it is shorter than [bytes], still changing, a
  // link, or could not be set aside), the good bytes are kept beside it under
  // `<name>.kept-<n>` and the user is told; nothing is ever overwritten.
  static int _tmpCounter = 0;

  Future<void> _write(String name, String hash, Uint8List bytes) async {
    Future<void> keepBeside(Directory d, String why) async {
      final kept = await keepGoodCopy(d, name, bytes);
      notify(
        kept == null
            ? 'A file in this page\'s folder $why, and a good copy could not be saved.'
            : 'A file in this page\'s folder $why. A good copy was kept as "$kept" beside it.',
      );
    }

    Future<void> into(Directory d) async {
      final target = _in(d, name);
      await d.create(recursive: true);
      final type = FileSystemEntity.typeSync(target.path, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        if (type != FileSystemEntityType.file) {
          await keepBeside(d, 'is not a plain file');
          return;
        }
        final c = await checkAttachmentFile(target, hash, bytes.length);
        if (c.state == AttachmentState.ok) return;
        if (c.state == AttachmentState.syncing) {
          await keepBeside(d, 'is incomplete or still changing');
          return;
        }
        final r = await setAsideDamaged(target, c.found!);
        if (r.name == null) {
          await keepBeside(d, 'is damaged and could not be set aside (it is at "${r.leftAt}")');
          return;
        }
        notify(
          'A damaged copy of a file was found in this page\'s folder. It was kept as "${r.name}" and the good copy was saved.',
        );
      }
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

  /// Checks the folder file [fileName] against the hash in its name, in the
  /// page's folder and then the recovery folder. A damaged file is kept aside
  /// beside it (see [setAsideDamaged]); the caller tells the user, who knows
  /// the file by its own name. A missing file is looked for among the kept
  /// copies first (see [restoreKeptCopy]).
  Future<VerifiedAttachment> _check(String fileName, int size, {required bool keepBytes}) async {
    final hash = attachmentNameHash(fileName);
    for (final d in [folder, ?recoveryFolder]) {
      final f = _in(d, fileName);
      var type = FileSystemEntity.typeSync(f.path, followLinks: false);
      if (type == FileSystemEntityType.notFound && hash != null && await restoreKeptCopy(d, fileName, hash, size)) {
        type = FileSystemEntity.typeSync(f.path, followLinks: false);
        filesChanged();
      }
      if (type == FileSystemEntityType.notFound) continue;
      // A link or a folder is never trusted (the same rule as in the writer).
      if (type != FileSystemEntityType.file) return const VerifiedAttachment(AttachmentState.syncing);
      if (hash == null) {
        // Not named by a hash: nothing to check it against.
        try {
          return VerifiedAttachment(AttachmentState.ok, bytes: keepBytes ? await f.readAsBytes() : null);
        } on FileSystemException {
          return const VerifiedAttachment(AttachmentState.syncing);
        }
      }
      final c = await checkAttachmentFile(f, hash, size, keepBytes: keepBytes);
      switch (c.state) {
        case AttachmentState.ok:
          return VerifiedAttachment(AttachmentState.ok, bytes: c.bytes);
        case AttachmentState.syncing:
          return const VerifiedAttachment(AttachmentState.syncing);
        case AttachmentState.damaged:
          final r = await setAsideDamaged(f, c.found!);
          if (r.leftAt != fileName) filesChanged();
          return VerifiedAttachment(AttachmentState.damaged, keptAs: r.name, leftAt: r.leftAt);
      }
    }
    return const VerifiedAttachment(AttachmentState.syncing);
  }

  @override
  Future<VerifiedAttachment> readVerified(String fileName, {required int size}) =>
      _check(fileName, size, keepBytes: true);

  @override
  Future<VerifiedAttachment> verify(String fileName, {required int size}) =>
      _check(fileName, size, keepBytes: false);

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
      // A copy left by an earlier open is reused only if it still holds these
      // bytes (a damaged or half-written one is rewritten: it is only a copy).
      final want = contentHash(bytes);
      if (!await file.exists() || await contentHashOfStream(file.openRead()) != want) {
        await file.writeAsBytes(bytes, flush: true);
      }
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
