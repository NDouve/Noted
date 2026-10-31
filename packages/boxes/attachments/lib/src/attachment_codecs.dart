// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pure Dart: no Flutter imports (0034).

import 'dart:convert';

import 'package:noted_core/noted_core.dart';

import 'attachment_ref.dart';

/// An image box's content: the image file, its size in pixels and its alt
/// text.
final class ImageData {
  const ImageData({
    required this.ref,
    required this.width,
    required this.height,
    this.alt = '',
    this.extra = const {},
  });

  final AttachmentRef ref;

  /// The image's size in pixels (of the first frame for an animated GIF).
  final int width;
  final int height;

  /// Describes the image for screen readers, search and the AI.
  final String alt;

  /// Keys this version doesn't know, written back unchanged.
  final Map<String, Object?> extra;

  ImageData copyWith({AttachmentRef? ref, String? alt}) => ImageData(
    ref: ref ?? this.ref,
    width: width,
    height: height,
    alt: alt ?? this.alt,
    extra: extra,
  );
}

/// The data side of the image box (`noted.image`).
final class ImageCodec extends BoxCodec<ImageData?> {
  const ImageCodec();

  static const String id = 'noted.image';

  @override
  String get typeId => id;

  @override
  int get dataVersion => 1;

  @override
  BoxApiVersion get apiVersion => boxApiVersion;

  @override
  BoxSizing get sizing => BoxSizing.fixed;

  /// An image box is only ever made from a file; a box without one is
  /// empty.
  @override
  ImageData? create() => null;

  @override
  ImageData? decode(Object? json, int storedVersion) {
    if (json is! Map) return null;
    final ref = AttachmentRef.fromJson(json['image']);
    if (ref == null) return null;
    final w = json['width'];
    final h = json['height'];
    final alt = json['alt'];
    return ImageData(
      ref: ref,
      width: w is int && w > 0 ? w : 1,
      height: h is int && h > 0 ? h : 1,
      alt: alt is String ? alt : '',
      extra: extraKeys(json, const {'image', 'width', 'height', 'alt'}),
    );
  }

  @override
  Object? encode(ImageData? data) => data == null
      ? null
      : {
          'image': data.ref.toJson(),
          'width': data.width,
          'height': data.height,
          'alt': data.alt,
          ...data.extra,
        };

  /// `[image: <alt text>]`.
  @override
  String snapshotText(ImageData? data) => '[image: ${data?.alt.trim() ?? ''}]';

  /// Never: a box whose data can't be read is kept, not discarded.
  @override
  bool isEmpty(ImageData? data) => false;

  /// The AI sees the alt text, never the pixels.
  @override
  AiExposure aiExposure(ImageData? data) => AiText(snapshotText(data));

  @override
  MergeResult<ImageData?> merge(
    ImageData? base,
    ImageData? mine,
    ImageData? theirs,
  ) {
    if (mine == null || theirs == null) {
      return mine == null && theirs == null
          ? const Merged(null)
          : const Conflicted();
    }
    final ref = pickMerged(base?.ref, mine.ref, theirs.ref);
    final alt = pickMerged(base?.alt, mine.alt, theirs.alt);
    final extra = pickMerged(
      jsonEncode(base?.extra ?? const {}),
      jsonEncode(mine.extra),
      jsonEncode(theirs.extra),
    );
    if (ref == null || alt == null || extra == null) return const Conflicted();
    final from = ref == mine.ref ? mine : theirs;
    return Merged(
      ImageData(
        ref: ref,
        width: from.width,
        height: from.height,
        alt: alt,
        extra: extra == jsonEncode(mine.extra) ? mine.extra : theirs.extra,
      ),
    );
  }

  /// Reads and writes the page's assets folder.
  @override
  Set<BoxPermission> get permissions => {attachmentsPermission};
}

/// A file box's content: the file.
final class FileData {
  const FileData({required this.ref, this.extra = const {}});

  final AttachmentRef ref;
  final Map<String, Object?> extra;

  FileData copyWith({AttachmentRef? ref}) =>
      FileData(ref: ref ?? this.ref, extra: extra);
}

/// The data side of the file box (`noted.file`).
final class FileCodec extends BoxCodec<FileData?> {
  const FileCodec();

  static const String id = 'noted.file';

  @override
  String get typeId => id;

  @override
  int get dataVersion => 1;

  @override
  BoxApiVersion get apiVersion => boxApiVersion;

  @override
  BoxSizing get sizing => BoxSizing.fixed;

  @override
  FileData? create() => null;

  @override
  FileData? decode(Object? json, int storedVersion) {
    if (json is! Map) return null;
    final ref = AttachmentRef.fromJson(json['file']);
    if (ref == null) return null;
    return FileData(ref: ref, extra: extraKeys(json, const {'file'}));
  }

  @override
  Object? encode(FileData? data) =>
      data == null ? null : {'file': data.ref.toJson(), ...data.extra};

  /// `[file: <name>]`.
  @override
  String snapshotText(FileData? data) => '[file: ${data?.ref.name ?? ''}]';

  @override
  bool isEmpty(FileData? data) => false;

  /// The AI sees the file's name, never its content.
  @override
  AiExposure aiExposure(FileData? data) => AiText(snapshotText(data));

  @override
  MergeResult<FileData?> merge(
    FileData? base,
    FileData? mine,
    FileData? theirs,
  ) {
    if (mine == null || theirs == null) {
      return mine == null && theirs == null
          ? const Merged(null)
          : const Conflicted();
    }
    final ref = pickMerged(base?.ref, mine.ref, theirs.ref);
    if (ref == null) return const Conflicted();
    return Merged(ref == mine.ref ? mine : theirs);
  }

  @override
  Set<BoxPermission> get permissions => {attachmentsPermission};
}

/// The permission to read and write the page's assets folder (0034).
const BoxPermission attachmentsPermission = BoxPermission('attachments');
