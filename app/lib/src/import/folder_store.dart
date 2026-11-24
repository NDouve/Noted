// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import '../page_attachments.dart' show overLimitNotice;

/// The store an import's images go through when the page embeds files but
/// the import's images together are over [embedLimitBytes]: its `storage` is
/// the folder, every [put] goes to the folder, and every other call (and the
/// [VerifyingAttachmentStore] and [PageFolderAttachmentStore] interfaces,
/// when [inner] has them) is forwarded to the page's own store. The user is
/// told once, with 0098's notice.
AttachmentStore forceFolderStorage(AttachmentStore inner) => switch (inner) {
  PageFolderAttachmentStore() => _PageFolderForward(inner),
  VerifyingAttachmentStore() => _VerifyingForward(inner),
  _ => _Forward(inner),
};

class _Forward implements AttachmentStore {
  _Forward(this.inner);

  final AttachmentStore inner;
  bool _told = false;

  @override
  AttachmentStorage get storage => AttachmentStorage.folder;

  @override
  Future<StoredAttachment> put(Uint8List bytes, {required String extension, AttachmentStorage? storage}) {
    if (!_told) {
      _told = true;
      inner.notify(overLimitNotice);
    }
    return inner.put(bytes, extension: extension, storage: AttachmentStorage.folder);
  }

  @override
  Future<Uint8List?> read(String fileName) => inner.read(fileName);

  @override
  bool exists(String fileName) => inner.exists(fileName);

  @override
  Listenable get changes => inner.changes;

  @override
  Directory get cacheDirectory => inner.cacheDirectory;

  @override
  void notify(String message) => inner.notify(message);

  @override
  Future<void> open(String name, {String? fileName, Uint8List? bytes}) => inner.open(name, fileName: fileName, bytes: bytes);

  @override
  Future<List<IncomingFile>> pick({required bool imagesOnly}) => inner.pick(imagesOnly: imagesOnly);
}

class _VerifyingForward extends _Forward implements VerifyingAttachmentStore {
  _VerifyingForward(VerifyingAttachmentStore super.inner);

  VerifyingAttachmentStore get _v => inner as VerifyingAttachmentStore;

  @override
  Future<VerifiedAttachment> readVerified(String fileName, {required int size}) => _v.readVerified(fileName, size: size);

  @override
  Future<VerifiedAttachment> verify(String fileName, {required int size}) => _v.verify(fileName, size: size);
}

class _PageFolderForward extends _VerifyingForward implements PageFolderAttachmentStore {
  _PageFolderForward(PageFolderAttachmentStore super.inner);

  PageFolderAttachmentStore get _p => inner as PageFolderAttachmentStore;

  @override
  Future<StoredAttachment> putInPageFolder(Uint8List bytes, {required String extension, AttachmentStorage? storage}) =>
      _p.putInPageFolder(bytes, extension: extension, storage: AttachmentStorage.folder);

  @override
  Future<VerifiedAttachment> verifyInPageFolder(String fileName, {required int size}) =>
      _p.verifyInPageFolder(fileName, size: size);
}
