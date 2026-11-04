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
  /// folder under its content hash. Throws a `FileSystemException` when no
  /// copy could be stored. A folder file that exists already is
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

/// What checking a folder file against its content hash found.
enum AttachmentState {
  /// The file is there and holds the bytes its hash names.
  ok,

  /// The file isn't there yet, is shorter than the size the box recorded, or
  /// was still changing while it was checked ("Still syncing").
  syncing,

  /// The file is at its full size but does not hold the bytes its hash names.
  damaged,
}

/// The result of [VerifyingAttachmentStore.readVerified] and [VerifyingAttachmentStore.verify].
@immutable
final class VerifiedAttachment {
  const VerifiedAttachment(this.state, {this.bytes, this.keptAs, this.leftAt});

  final AttachmentState state;

  /// The bytes, when [state] is [AttachmentState.ok].
  final Uint8List? bytes;

  /// When [state] is [AttachmentState.damaged]: the name the damaged copy was
  /// kept under beside the file, or null if it could not be set aside.
  final String? keptAs;

  /// When [state] is [AttachmentState.damaged] and [keptAs] is null: the name
  /// of the file it was left under (it may have moved part-way).
  final String? leftAt;
}

/// An [AttachmentStore] that can check a folder file against the hash in its
/// name (the notebook side names every attachment by its hash) before anyone
/// trusts it, and that keeps a damaged file aside instead of using or
/// deleting it. Optional: modules use it when the store has it, and check the
/// bytes against the hash stored in the box themselves when it doesn't.
abstract interface class VerifyingAttachmentStore implements AttachmentStore {
  /// Reads the folder file [fileName] (the page's folder, then the recovery
  /// folder) and checks it. [size] is the size the box recorded: a shorter
  /// file is [AttachmentState.syncing], never damaged. Streams the file once;
  /// call it when a file is loaded, never per frame.
  Future<VerifiedAttachment> readVerified(String fileName, {required int size});

  /// The same check without keeping the bytes (for a large file that is only
  /// handed to another program).
  Future<VerifiedAttachment> verify(String fileName, {required int size});
}

/// A [VerifyingAttachmentStore] that can also store and check a file in the
/// page's own assets folder only, never in a recovery folder. Optional: a
/// conversion to the folder ("Move attachments to folder") drops a box's
/// embedded copy only after the file is stored and verified there, so it
/// refuses to convert for a store that does not implement this.
abstract interface class PageFolderAttachmentStore implements VerifyingAttachmentStore {
  /// [AttachmentStore.put] without the recovery fallback: stores [bytes] in the
  /// page's own assets folder, or throws a `FileSystemException`.
  Future<StoredAttachment> putInPageFolder(
    Uint8List bytes, {
    required String extension,
    AttachmentStorage? storage,
  });

  /// [VerifyingAttachmentStore.verify] on the page's own assets folder only:
  /// a copy in a recovery folder is never looked at.
  Future<VerifiedAttachment> verifyInPageFolder(String fileName, {required int size});
}
