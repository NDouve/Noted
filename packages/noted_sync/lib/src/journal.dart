// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:noted_core/noted_core.dart';

import 'remote_tree.dart' show isSafeName;

/// The journal exists but can't be read. It is never overwritten or treated as
/// empty.
class JournalUnreadable implements Exception {
  JournalUnreadable(this.message);
  final String message;
  @override
  String toString() => 'JournalUnreadable: $message';
}

/// One item of the last complete remote map.
class RemoteEntry {
  const RemoteEntry({
    required this.id,
    required this.parent,
    required this.name,
    required this.folder,
    this.cTag,
    this.hash,
    this.size = 0,
    this.seq = 0,
    this.special = false,
  });

  factory RemoteEntry.fromJson(String id, Map<String, dynamic> j) =>
      RemoteEntry(
        id: id,
        parent: j['p'] as String?,
        name: j['n'] as String,
        folder: j['k'] == 'd',
        cTag: j['c'] as String?,
        hash: j['h'] as String?,
        size: j['s'] as int,
        seq: j['q'] as int,
        special: j['x'] == true,
      );

  final String id;
  final String? parent;
  final String name;
  final bool folder;
  final String? cTag;

  /// quickXorHash, base64.
  final String? hash;
  final int size;

  /// Arrival sequence: the higher one wins when two live ids share a path.
  final int seq;

  /// Not mirrored: a shortcut, a package or another item that isn't a plain
  /// file or folder.
  final bool special;

  Map<String, dynamic> toJson() => {
    'x': special,
    'p': parent,
    'n': name,
    'k': folder ? 'd' : 'f',
    'c': cTag,
    'h': hash,
    's': size,
    'q': seq,
  };
}

/// What the engine knows about one mirrored file, keyed by case-folded
/// remote path.
class FileRecord {
  FileRecord({
    required this.path,
    this.itemId,
    this.cTag,
    this.hash,
    this.size = 0,
    this.base,
    this.blob = false,
    this.retained = false,
    this.mtime,
  });

  factory FileRecord.fromJson(Map<String, dynamic> j) => FileRecord(
    path: j['path'] as String,
    itemId: j['id'] as String?,
    cTag: j['c'] as String?,
    hash: j['h'] as String?,
    size: j['s'] as int,
    base: j['bl'] == null
        ? null
        : ContentIdentity(j['bl'] as int, j['bs'] as String),
    blob: j['blob'] as bool,
    retained: j['ret'] as bool,
    mtime: j['mt'] as int?,
  );

  /// Where the file is on disk, relative to the working copy, with `/`, in the
  /// spelling the disk has.
  String path;
  String? itemId;
  String? cTag;

  /// The remote quickXorHash and size this record's base corresponds to.
  String? hash;
  int size;

  /// What the engine last published or adopted here (a copy of what OneDrive
  /// had). Null when there is none.
  ContentIdentity? base;

  /// Whether the base bytes are kept in the blob store.
  bool blob;

  /// A remote delete of an attachment was not applied: the file stays.
  bool retained;

  /// The local file's modified time (ms) when it was last checked equal to
  /// [base]; lets a poll skip hashing.
  int? mtime;

  FileRecord copy() => FileRecord(
    path: path,
    itemId: itemId,
    cTag: cTag,
    hash: hash,
    size: size,
    base: base,
    blob: blob,
    retained: retained,
    mtime: mtime,
  );

  Map<String, dynamic> toJson() => {
    'path': path,
    'id': itemId,
    'c': cTag,
    'h': hash,
    's': size,
    'bl': base?.length,
    'bs': base?.sha256,
    'blob': blob,
    'ret': retained,
    'mt': mtime,
  };
}

/// A re-path step that deleted (or is about to delete) the old file.
class Moving {
  const Moving({
    required this.oldKey,
    required this.oldPath,
    required this.newKey,
    required this.newPath,
    required this.identity,
    required this.keep,
  });

  factory Moving.fromJson(Map<String, dynamic> j) => Moving(
    oldKey: j['ok'] as String,
    oldPath: j['op'] as String,
    newKey: j['nk'] as String,
    newPath: j['np'] as String,
    identity: ContentIdentity(j['len'] as int, j['sha'] as String),
    keep: j['kp'] as String,
  );

  final String oldKey;
  final String oldPath;
  final String newKey;
  final String newPath;
  final ContentIdentity identity;

  /// The name (SHA-256, lowercase hex) of the durable copy of the snapshot in
  /// the state folder's `keep/`, written before this entry.
  final String keep;

  Map<String, dynamic> toJson() => {
    'kp': keep,
    'ok': oldKey,
    'op': oldPath,
    'nk': newKey,
    'np': newPath,
    'len': identity.length,
    'sha': identity.sha256,
  };
}

/// Everything the pull remembers between rounds.
class Journal {
  /// Which delta the token belongs to: `folder` or `drive`.
  String? endpoint;

  /// The delta link of the last complete round; null before the first.
  String? deltaLink;
  int seq = 0;
  Map<String, RemoteEntry> map = {};

  /// Files by case-folded remote path.
  Map<String, FileRecord> files = {};

  /// Folders the engine created or adopted: case-folded path to the path on
  /// disk (relative, `/`, the disk's spelling).
  Map<String, String> folders = {};

  /// Paths the user chose to keep here, and paths a resync left in place.
  Set<String> kept = {};

  /// When a path was first planned for deletion (ms since the epoch).
  Map<String, int> firstSeen = {};

  /// Paths the user agreed to remove.
  Set<String> approved = {};
  Moving? moving;

  /// Hash mismatches per path, since the last good download.
  Map<String, int> mismatches = {};

  Map<String, dynamic> toJson() => {
    'v': 1,
    'endpoint': endpoint,
    'deltaLink': deltaLink,
    'seq': seq,
    'map': {for (final e in map.entries) e.key: e.value.toJson()},
    'files': {for (final e in files.entries) e.key: e.value.toJson()},
    'folders': folders,
    'kept': kept.toList()..sort(),
    'firstSeen': firstSeen,
    'approved': approved.toList()..sort(),
    'moving': moving?.toJson(),
    'mismatches': mismatches,
  };

  /// A path read from the journal is used for writes and deletes, so it must
  /// be relative and made of usable names only.
  static void _checkRelative(String path, String what) {
    if (path.isEmpty || path.startsWith('/')) {
      throw JournalUnreadable('$what is not a relative path');
    }
    for (final seg in path.split('/')) {
      if (!isSafeName(seg)) {
        throw JournalUnreadable('$what has an unusable name');
      }
    }
  }

  static Journal fromJson(Map<String, dynamic> j) {
    if (j['v'] != 1) throw JournalUnreadable('unknown version ${j['v']}');
    final out = Journal()
      ..endpoint = j['endpoint'] as String?
      ..deltaLink = j['deltaLink'] as String?
      ..seq = j['seq'] as int;
    for (final e in (j['map'] as Map).entries) {
      out.map[e.key as String] = RemoteEntry.fromJson(
        e.key as String,
        (e.value as Map).cast<String, dynamic>(),
      );
    }
    for (final e in (j['files'] as Map).entries) {
      final rec = FileRecord.fromJson((e.value as Map).cast<String, dynamic>());
      _checkRelative(rec.path, 'a file path');
      out.files[e.key as String] = rec;
    }
    for (final e in (j['folders'] as Map).entries) {
      final v = e.value as String;
      _checkRelative(v, 'a folder path');
      out.folders[e.key as String] = v;
    }
    for (final v in j['kept'] as List) {
      out.kept.add(v as String);
    }
    for (final e in (j['firstSeen'] as Map).entries) {
      out.firstSeen[e.key as String] = e.value as int;
    }
    for (final v in j['approved'] as List) {
      out.approved.add(v as String);
    }
    if (j['moving'] != null) {
      final m = Moving.fromJson((j['moving'] as Map).cast<String, dynamic>());
      _checkRelative(m.oldPath, 'a moving path');
      _checkRelative(m.newPath, 'a moving path');
      final hex = RegExp(r'^[0-9a-f]{64}$');
      if (!hex.hasMatch(m.keep) || !hex.hasMatch(m.identity.sha256)) {
        throw JournalUnreadable('a moving entry has a bad copy name');
      }
      out.moving = m;
    }
    for (final e in (j['mismatches'] as Map).entries) {
      out.mismatches[e.key as String] = e.value as int;
    }
    final link = out.deltaLink;
    if (link != null) {
      final u = Uri.tryParse(link);
      if (u == null || !u.hasScheme) {
        throw JournalUnreadable('the delta link is not a link');
      }
    }
    return out;
  }
}

/// Reads and writes `journal.json` in the state folder. Writes go to a temp
/// name and are renamed over the journal, so a kill leaves the old or the new
/// one.
class JournalStore {
  JournalStore(this.dir);

  final Directory dir;

  File get file => File('${dir.path}${Platform.pathSeparator}journal.json');

  /// The saved journal, or null when there is none. Throws
  /// [JournalUnreadable] when a file is there that can't be read.
  Future<Journal?> load() async {
    final f = file;
    final String text;
    try {
      if (!await f.exists()) return null;
      text = await f.readAsString();
    } on FileSystemException catch (e) {
      throw JournalUnreadable('${e.message} (${e.path})');
    } on FormatException {
      throw JournalUnreadable('not text');
    }
    try {
      final j = jsonDecode(text);
      if (j is! Map<String, dynamic>) throw JournalUnreadable('not an object');
      return Journal.fromJson(j);
    } on JournalUnreadable {
      rethrow;
    } catch (e) {
      // Not echoed: a bad value could be a link with a token in it.
      throw JournalUnreadable('a value has the wrong shape (${e.runtimeType})');
    }
  }

  Future<void> save(Journal journal) async {
    await dir.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(journal.toJson()), flush: true);
    await tmp.rename(file.path);
  }
}

/// Base bytes of mirrored pages and binder files, named by their SHA-256.
class BlobStore {
  BlobStore(this.dir);

  final Directory dir;
  static final Random _random = Random.secure();

  File fileFor(String sha) => File('${dir.path}${Platform.pathSeparator}$sha');

  Future<bool> has(String sha) => fileFor(sha).exists();

  /// Keeps a copy of [src] under [sha] (the SHA-256 of its bytes).
  Future<void> put(File src, String sha) async {
    if (await has(sha)) return;
    await dir.create(recursive: true);
    final part = File(
      '${dir.path}${Platform.pathSeparator}$sha.part-${_random.nextInt(1 << 32)}',
    );
    await src.copy(part.path);
    try {
      await part.rename(fileFor(sha).path);
    } on FileSystemException {
      if (!await has(sha)) rethrow;
      await part.delete();
    }
  }

  /// Deletes the blob named [sha], if it is there.
  Future<void> remove(String sha) async {
    try {
      await fileFor(sha).delete();
    } on FileSystemException {
      // Already gone, or swept later.
    }
  }

  /// Deletes every blob whose name is not in [keep], and stray partial copies.
  Future<void> sweep(Set<String> keep) async {
    if (!await dir.exists()) return;
    await for (final f in dir.list(followLinks: false)) {
      if (f is! File) continue;
      final name = f.path.split(RegExp(r'[\\/]')).last;
      if (keep.contains(name)) continue;
      try {
        await f.delete();
      } on FileSystemException {
        // Next round.
      }
    }
  }
}
