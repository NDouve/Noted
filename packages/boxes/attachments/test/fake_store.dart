// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

/// A 4 × 4 red PNG.
final Uint8List redPng = Uint8List.fromList(const [
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  4,
  0,
  0,
  0,
  4,
  8,
  6,
  0,
  0,
  0,
  169,
  241,
  158,
  126,
  0, //
  0,
  0,
  18,
  73,
  68,
  65,
  84,
  120,
  218,
  99,
  56,
  161,
  161,
  241,
  31,
  25,
  51,
  144,
  46,
  0,
  0,
  108,
  56,
  33,
  113,
  177,
  44,
  5,
  224,
  0, //
  0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
]);

/// An [AttachmentStore] that keeps the "folder" in memory.
class FakeStore extends ChangeNotifier implements AttachmentStore {
  FakeStore({this.storage = AttachmentStorage.folder, Directory? cache})
    : cacheDirectory =
          cache ?? Directory.systemTemp.createTempSync('noted_fake_cache');

  @override
  AttachmentStorage storage;

  final Map<String, Uint8List> folder = {};
  final List<String> notices = [];
  final List<(String, String?, Uint8List?)> opened = [];
  List<IncomingFile> toPick = const [];

  @override
  final Directory cacheDirectory;

  @override
  Listenable get changes => this;

  /// A file arrives in the folder (synced from another device).
  void arrive(String fileName, Uint8List bytes) {
    folder[fileName] = bytes;
    notifyListeners();
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
      notices.add('over limit');
    }
    folder.putIfAbsent(name, () => bytes);
    notifyListeners();
    return StoredAttachment(
      hash: hash,
      fileName: name,
      overLimit: want == AttachmentStorage.embedded,
    );
  }

  @override
  Future<Uint8List?> read(String fileName) async => folder[fileName];

  @override
  bool exists(String fileName) => folder.containsKey(fileName);

  @override
  void notify(String message) => notices.add(message);

  @override
  Future<void> open(String name, {String? fileName, Uint8List? bytes}) async =>
      opened.add((name, fileName, bytes));

  @override
  Future<List<IncomingFile>> pick({required bool imagesOnly}) async => toPick;
}
