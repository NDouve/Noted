// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// A drive item as Graph describes it, only the parts the pull uses.
class RemoteItem {
  const RemoteItem({
    required this.id,
    this.name,
    this.parentId,
    this.driveId,
    this.isFolder = false,
    this.deleted = false,
    this.cTag,
    this.eTag,
    this.size = 0,
    this.quickXorHash,
    this.isRoot = false,
    this.isSpecial = false,
  });

  factory RemoteItem.fromJson(Map<String, dynamic> json) {
    final parent = json['parentReference'];
    final file = json['file'];
    final hashes = file is Map ? file['hashes'] : null;
    final size = json['size'];
    return RemoteItem(
      id: json['id'] as String,
      name: json['name'] is String ? json['name'] as String : null,
      parentId: parent is Map && parent['id'] is String
          ? parent['id'] as String
          : null,
      driveId: parent is Map && parent['driveId'] is String
          ? parent['driveId'] as String
          : null,
      isFolder: json['folder'] is Map,
      isRoot: json['root'] is Map,
      // A shortcut (`remoteItem`), a OneNote notebook (`package`) or anything
      // that is neither a folder nor a file: never fetched.
      isSpecial:
          json['remoteItem'] is Map ||
          json['package'] is Map ||
          (json['folder'] is! Map && json['file'] is! Map),
      deleted: json['deleted'] is Map,
      cTag: json['cTag'] is String ? json['cTag'] as String : null,
      eTag: json['eTag'] is String ? json['eTag'] as String : null,
      size: size is int ? size : 0,
      quickXorHash: hashes is Map && hashes['quickXorHash'] is String
          ? hashes['quickXorHash'] as String
          : null,
    );
  }

  final String id;

  /// Absent on some `deleted` items.
  final String? name;
  final String? parentId;
  final String? driveId;
  final bool isFolder;
  final bool deleted;
  final String? cTag;
  final String? eTag;
  final int size;

  /// Base64, as Graph gives it.
  final String? quickXorHash;

  /// The drive's root item (the `root` facet).
  final bool isRoot;

  /// Not a folder or a file the pull can fetch.
  final bool isSpecial;
}

/// One page of a delta enumeration: [nextLink] while there are more, then
/// [deltaLink] on the last page.
class DeltaPage {
  const DeltaPage(this.items, {this.nextLink, this.deltaLink});

  final List<RemoteItem> items;
  final Uri? nextLink;
  final Uri? deltaLink;
}
