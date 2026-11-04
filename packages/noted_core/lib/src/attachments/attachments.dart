// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../binder/binder.dart';
import '../json/raw_json.dart';
import '../model/page.dart';

/// Where the images and files a page holds are kept: the page and binder
/// setting "Store images and files".
///
/// - [folder]: in `<page id>.assets/` beside the page file, named by their
///   content hash ([attachmentFileName]); the box stores the name and hash.
/// - [embedded]: inside the page file, as base64 in the box, with the hash.
///
/// Every box reads both kinds whatever the current setting is.
enum AttachmentStorage {
  folder('folder', 'In a folder beside the page'),
  embedded('embedded', 'In the page file');

  const AttachmentStorage(this.value, this.label);

  /// How the setting is written in a page header or binder file
  /// (`"attachments"`).
  final String value;
  final String label;

  /// The setting named [value], or null for a missing or unknown value (the
  /// page then follows its parent).
  static AttachmentStorage? parse(Object? value) {
    for (final s in values) {
      if (s.value == value) return s;
    }
    return null;
  }
}

/// The key of the setting in a page header's `noted` object and in a
/// binder file.
const String attachmentStorageKey = 'attachments';

/// Files larger than this always go to the folder, even when the setting is
/// [AttachmentStorage.embedded]: base64 makes them a third larger, and the
/// whole page file is rewritten on every save.
const int embedLimitBytes = 5 * 1024 * 1024;

/// The folder beside a page file that holds its attachments.
String assetsFolderName(String pageId) => '$pageId.assets';

/// The lowercase hex SHA-256 of [bytes]: an attachment's identity. Two
/// devices that add the same file make the same name, so they can't
/// conflict.
String contentHash(List<int> bytes) => sha256.convert(bytes).toString();

/// The same hash of a stream of chunks, without holding the whole file.
Future<String> contentHashOfStream(Stream<List<int>> chunks) async =>
    (await sha256.bind(chunks).first).toString();

/// The name an attachment is stored under in the assets folder:
/// `<hash>.<ext>` (just `<hash>` without an extension). The extension is
/// lowercased and limited to letters and digits.
String attachmentFileName(String hash, String extension) {
  final ext = _cleanExtension(extension);
  return ext.isEmpty ? hash : '$hash.$ext';
}

final RegExp _attachmentFileName = RegExp(r'^[0-9a-f]{64}(\.[a-z0-9]{1,10})?$');

/// Whether [fileName] (a box's `file` value) is a name this app writes:
/// `<64 lowercase hex>` or `<64 lowercase hex>.<1-10 lowercase letters or
/// digits>`. It is the only form that may be joined onto the assets folder;
/// anything else (a path, `..`, a drive letter, a UNC path) is treated as a
/// missing file and never read, opened, copied or deleted.
bool isAttachmentFileName(String fileName) => _attachmentFileName.hasMatch(fileName);

/// [name]'s extension without the dot, lowercase, letters and digits only
/// (at most 10); empty if it has none.
String normalizedExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : _cleanExtension(name.substring(dot + 1));
}

String _cleanExtension(String raw) {
  final ext = raw.toLowerCase();
  if (ext.isEmpty || ext.length > 10 || !RegExp(r'^[a-z0-9]+$').hasMatch(ext)) {
    return '';
  }
  return ext;
}

/// Whether [bytes] may be embedded in the page file ([embedLimitBytes]).
bool canEmbed(Uint8List bytes) => bytes.length <= embedLimitBytes;

/// A size as shown to the user: `512 B`, `14 KB`, `3.2 MB`.
String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  final mb = bytes / (1024 * 1024);
  return mb < 10 ? '${mb.toStringAsFixed(1)} MB' : '${mb.round()} MB';
}

/// The setting on a page header.
extension PageAttachmentSetting on PageMeta {
  /// The page's own choice, or null if it has none (or an unknown value,
  /// which is kept as written) and follows its parent.
  AttachmentStorage? get attachmentStorage =>
      AttachmentStorage.parse(fields.string(attachmentStorageKey));

  /// The stored value exactly as written, or null if absent.
  RawJson? get rawAttachmentStorage => fields[attachmentStorageKey];

  /// Returns a copy with its own choice [value]; null removes it, so the
  /// page follows its parent again. Returns this page unchanged if it
  /// already stores that value.
  PageMeta withAttachmentStorage(AttachmentStorage? value) {
    if (value == null) {
      if (rawAttachmentStorage == null) return this;
      return PageMeta.tryRead(fields.remove(attachmentStorageKey))!;
    }
    if (rawAttachmentStorage?.text == RawJson.encode(value.value).text) return this;
    return PageMeta.tryRead(fields.set(attachmentStorageKey, RawJson.encode(value.value)))!;
  }
}

/// The setting on a binder.
extension BinderAttachmentSetting on Binder {
  /// The binder's choice, or null if it has none (or an unknown value, kept
  /// as written).
  AttachmentStorage? get attachmentStorage =>
      AttachmentStorage.parse(fields.string(attachmentStorageKey));

  /// Returns a copy with [value]; null removes the field.
  Binder withAttachmentStorage(AttachmentStorage? value) {
    final next = value == null
        ? fields.remove(attachmentStorageKey)
        : fields.set(attachmentStorageKey, RawJson.encode(value.value));
    return Binder.tryRead(next)!;
  }
}

/// The setting that applies to a page (configuration inheritance, 0027):
/// the first own choice among [chain] (the page, then its parent pages,
/// nearest first), then [binder]'s, then [AttachmentStorage.folder].
AttachmentStorage effectiveAttachmentStorage(
  Iterable<PageMeta> chain, {
  Binder? binder,
}) {
  for (final p in chain) {
    final s = p.attachmentStorage;
    if (s != null) return s;
  }
  return binder?.attachmentStorage ?? AttachmentStorage.folder;
}
