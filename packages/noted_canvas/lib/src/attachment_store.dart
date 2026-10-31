// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:noted_core/noted_core.dart';

/// A file pasted, dropped or picked onto a page (Box API 0.7).
@immutable
final class IncomingFile {
  const IncomingFile(this.name, this.bytes);

  /// The file name the user sees, with its extension.
  final String name;
  final Uint8List bytes;

  /// The extension, lowercase and without the dot ([normalizedExtension]).
  String get extension => normalizedExtension(name);
}

/// What [AttachmentStore.put] did with a file.
@immutable
final class StoredAttachment {
  const StoredAttachment({
    required this.hash,
    required this.fileName,
    this.embedded,
    this.overLimit = false,
  });

  /// The file's [contentHash].
  final String hash;

  /// Its name in the page's assets folder ([attachmentFileName]), whether or
  /// not it was written there.
  final String fileName;

  /// The bytes to keep in the box when the file is embedded; null when it
  /// went to the folder.
  final Uint8List? embedded;

  /// Embedding was asked for but the file is larger than [embedLimitBytes],
  /// so it went to the folder.
  final bool overLimit;
}

/// The images and files of the open page (Box API 0.7): its assets folder,
/// `<page id>.assets/` beside the page file, and the "Store images and
/// files" setting that applies to it.
///
/// A module keeps what [put] returns in its box data: the folder file name
/// and hash, or the embedded bytes and hash. The core never reads box data;
/// it only moves, copies and removes the folder with its page.
abstract interface class AttachmentStore {
  /// The setting that applies to the page (its own, a parent's, its
  /// binder's, or the folder default).
  AttachmentStorage get storage;

  /// Stores [bytes]: embedded if [storage] (default: this page's setting)
  /// says so and the file is at most [embedLimitBytes], otherwise in the
  /// folder under its content hash. A folder file that exists already is
  /// left alone (same name, same content). Over the limit, the user is told
  /// once in a one-line notice.
  Future<StoredAttachment> put(
    Uint8List bytes, {
    required String extension,
    AttachmentStorage? storage,
  });

  /// The bytes of the folder file [fileName], or null if it isn't there yet
  /// (for example still syncing from another device).
  Future<Uint8List?> read(String fileName);

  /// Whether the folder file [fileName] is there.
  bool exists(String fileName);

  /// Notifies when files arrive in or leave the assets folder, so a box
  /// waiting for one can fill in.
  Listenable get changes;

  /// A folder outside the page folders (never synced) for derived files,
  /// such as downscaled display copies of images.
  Directory get cacheDirectory;

  /// Shows a one-line notice.
  void notify(String message);

  /// Opens a file with the system's default app: the folder file
  /// [fileName], or [bytes] (an embedded file) written to a temporary copy
  /// named [name].
  Future<void> open(String name, {String? fileName, Uint8List? bytes});

  /// Asks the user for files (only images when [imagesOnly]); empty if they
  /// cancel.
  Future<List<IncomingFile>> pick({required bool imagesOnly});
}

/// Reads files (an image) from the system clipboard, for pasting onto a
/// page. The app sets [read]; without it, nothing is pasted.
abstract final class FileClipboard {
  static Future<List<IncomingFile>> Function() read = () async => const [];
}
