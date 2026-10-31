// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pure Dart: no Flutter imports, so the codecs can be loaded by a process
// that has no UI (such as a future MCP server, 0034).

import 'dart:convert';
import 'dart:typed_data';

import 'package:noted_core/noted_core.dart';

/// The file an image or file box holds, as stored in its data:
///
/// ```json
/// {"name": "Plan.pdf", "size": 48213, "hash": "9f86d0…",
///  "file": "9f86d0….pdf"}                // in the page's assets folder
/// {"name": "Plan.pdf", "size": 48213, "hash": "9f86d0…",
///  "data": "JVBERi0xLjcK…"}              // embedded, base64
/// ```
///
/// `file` is relative to the page's assets folder (`<page id>.assets/`), so
/// a page that gets a new id (made from a template) keeps its boxes as they
/// are. A ref may hold both; the embedded bytes win.
final class AttachmentRef {
  const AttachmentRef({
    required this.name,
    required this.size,
    required this.hash,
    this.file,
    this.bytes,
  });

  /// The name the user sees, with its extension.
  final String name;

  /// The size in bytes.
  final int size;

  /// The [contentHash] of the bytes.
  final String hash;

  /// The file name in the page's assets folder, or null if embedded.
  final String? file;

  /// The embedded bytes, or null if in the folder.
  final Uint8List? bytes;

  bool get isEmbedded => bytes != null;

  /// The extension of [name], lowercase.
  String get extension => normalizedExtension(name);

  /// Reads a ref written by [toJson]; null if [json] isn't one.
  static AttachmentRef? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final size = json['size'];
    final hash = json['hash'];
    final file = json['file'];
    final data = json['data'];
    Uint8List? bytes;
    if (data is String) {
      try {
        bytes = base64Decode(data);
      } on FormatException {
        bytes = null;
      }
    }
    if (hash is! String || (file is! String && bytes == null)) return null;
    return AttachmentRef(
      name: name is String ? name : (file is String ? file : 'file'),
      size: size is int ? size : (bytes?.length ?? 0),
      hash: hash,
      file: file is String ? file : null,
      bytes: bytes,
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'size': size,
    'hash': hash,
    'file': ?file,
    if (bytes != null) 'data': base64Encode(bytes!),
  };

  /// The same file kept in the assets folder as [fileName].
  AttachmentRef inFolder(String fileName) =>
      AttachmentRef(name: name, size: size, hash: hash, file: fileName);

  /// The same file embedded as [data].
  AttachmentRef embedded(Uint8List data) =>
      AttachmentRef(name: name, size: size, hash: hash, bytes: data);

  @override
  bool operator ==(Object other) =>
      other is AttachmentRef &&
      other.name == name &&
      other.size == size &&
      other.hash == hash &&
      other.file == file &&
      other.isEmbedded == isEmbedded;

  @override
  int get hashCode => Object.hash(name, size, hash, file, isEmbedded);
}

/// The merged value of one field, or null if both sides changed it
/// differently.
T? pickMerged<T>(T base, T mine, T theirs) {
  if (mine == theirs || theirs == base) return mine;
  if (mine == base) return theirs;
  return null;
}

/// Keys of [json] other than [known], kept so a newer version's fields
/// survive.
Map<String, Object?> extraKeys(Map<Object?, Object?> json, Set<String> known) =>
    {
      for (final e in json.entries)
        if (e.key is String && !known.contains(e.key)) e.key as String: e.value,
    };
