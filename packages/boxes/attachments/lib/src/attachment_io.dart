// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'attachment_ref.dart';

/// Stores [file] through [store] the way the page's setting says and
/// returns the ref to keep in the box.
Future<AttachmentRef> storeIncoming(
  IncomingFile file,
  AttachmentStore store,
) async {
  final s = await store.put(file.bytes, extension: file.extension);
  final ref = AttachmentRef(
    name: file.name,
    size: file.bytes.length,
    hash: s.hash,
  );
  final embedded = s.embedded;
  return embedded != null ? ref.embedded(embedded) : ref.inFolder(s.fileName);
}

/// What reading an attachment found: its [bytes] when [state] is
/// [AttachmentState.ok].
typedef AttachmentRead = ({AttachmentState state, Uint8List? bytes});

final RegExp _hashFileName = RegExp(r'^([0-9a-f]{64})(\.[a-z0-9]+)?$');

/// Whether [hash] is a SHA-256 in lowercase hex: the only form that may be
/// used in a file name or cache path.
bool isContentHash(String hash) => RegExp(r'^[0-9a-f]{64}$').hasMatch(hash);

/// Whether [ref]'s folder file is named by another hash than the box
/// records: the file is then not the one the box means, whatever it holds.
bool _namedByOtherHash(AttachmentRef ref) {
  final m = _hashFileName.firstMatch(ref.file ?? '');
  return m != null && m.group(1) != ref.hash;
}

/// Reads [ref]'s bytes and checks them against the hash stored in the box
/// (once; callers load a file, never per frame). Embedded bytes were checked
/// when the ref was read. A folder file shorter than the box's recorded size,
/// or one still changing, is [AttachmentState.syncing]; one at its full size
/// with another hash is [AttachmentState.damaged] and the user is told, with
/// the file's name from the box. A [VerifyingAttachmentStore] does the check
/// and keeps the damaged file aside; for any other store it is done here and
/// the file stays where it is. A file whose name carries another hash than
/// the box's is never read as this attachment.
Future<AttachmentRead> readAttachment(AttachmentRef ref, AttachmentStore? store) async {
  const syncing = (state: AttachmentState.syncing, bytes: null);
  const damaged = (state: AttachmentState.damaged, bytes: null);
  final embedded = ref.bytes;
  if (embedded != null) return (state: AttachmentState.ok, bytes: embedded);
  if (ref.isDamaged) {
    store?.notify(_embeddedDamagedNotice(ref));
    return damaged;
  }
  final file = ref.file;
  if (file == null || store == null) return syncing;
  // Not a name this app writes: a missing file, never looked for.
  if (!isAttachmentFileName(file)) return syncing;
  if (_namedByOtherHash(ref)) {
    store.notify(_otherFileNotice(ref));
    return damaged;
  }
  if (store is VerifyingAttachmentStore) {
    final v = await store.readVerified(file, size: ref.size);
    if (v.state == AttachmentState.damaged) store.notify(_folderDamagedNotice(ref, v));
    return (state: v.state, bytes: v.bytes);
  }
  final bytes = await store.read(file);
  if (bytes == null || bytes.length < ref.size) return syncing;
  if (contentHash(bytes) != ref.hash) {
    store.notify(_folderDamagedNotice(ref, null));
    return damaged;
  }
  return (state: AttachmentState.ok, bytes: bytes);
}

/// The same check as [readAttachment] without keeping the bytes, before a
/// file is handed to another program.
Future<AttachmentState> verifyAttachment(AttachmentRef ref, AttachmentStore? store) async {
  final file = ref.file;
  if (ref.isEmbedded ||
      file == null ||
      store is! VerifyingAttachmentStore ||
      !isAttachmentFileName(file) ||
      _namedByOtherHash(ref)) {
    return (await readAttachment(ref, store)).state;
  }
  final v = await store.verify(file, size: ref.size);
  if (v.state == AttachmentState.damaged) store.notify(_folderDamagedNotice(ref, v));
  return v.state;
}

String _embeddedDamagedNotice(AttachmentRef ref) =>
    '"${ref.name}" is damaged: the data stored in the page does not match its hash, so it was not used. The page still holds it unchanged.';

String _otherFileNotice(AttachmentRef ref) =>
    '"${ref.name}" was not shown: the file it points to belongs to different content, so it was not used.';

String _folderDamagedNotice(AttachmentRef ref, VerifiedAttachment? v) {
  final head = '"${ref.name}" is damaged: the file in the page\'s folder does not match its hash, so it was not used.';
  if (v == null) return '$head It was left where it is.';
  final kept = v.keptAs;
  if (kept != null) return '$head The damaged copy was kept as "$kept" beside it.';
  return '$head It could not be moved aside; it is at "${v.leftAt}".';
}

/// The bytes of [ref], or null if its folder file isn't there (yet), is
/// still arriving or is damaged (see [readAttachment]).
Future<Uint8List?> loadAttachment(AttachmentRef ref, AttachmentStore? store) async =>
    (await readAttachment(ref, store)).bytes;

/// Whether [ref]'s file is in the folder but not there yet, for example
/// still syncing from another device.
bool attachmentMissing(AttachmentRef ref, AttachmentStore? store) {
  if (ref.isEmbedded || ref.isDamaged) return false;
  final file = ref.file;
  return file == null || store == null || !isAttachmentFileName(file) || !store.exists(file);
}

/// [ref] kept the [to] way, or null if it stays as it is: already that way,
/// still syncing, or (embedding) over [embedLimitBytes], in which case its
/// name is added to [overLimit].
Future<AttachmentRef?> convertAttachment(
  AttachmentRef ref,
  AttachmentStorage to,
  AttachmentStore store,
  List<String> overLimit,
) async {
  switch (to) {
    case AttachmentStorage.embedded:
      final file = ref.file;
      if (ref.isEmbedded || file == null || !isAttachmentFileName(file)) return null;
      // Too large to embed: not read at all.
      if (ref.size > embedLimitBytes) {
        overLimit.add(ref.name);
        return null;
      }
      // Embedding would replace the ref and drop the damaged data the page
      // still holds, so that box is left as it is and the user is told.
      if (ref.damagedData != null) {
        store.notify(
          '"${ref.name}" was not embedded: the data stored in the page is damaged, and is kept as it is.',
        );
        return null;
      }
      // Verified first: a damaged or still arriving file is never embedded.
      final read = await readAttachment(ref, store);
      final bytes = read.bytes;
      if (bytes == null) return null;
      if (!canEmbed(bytes)) {
        overLimit.add(ref.name);
        return null;
      }
      return ref.embedded(bytes);
    case AttachmentStorage.folder:
      final bytes = ref.bytes;
      if (bytes == null) return null;
      final s = await store.put(
        bytes,
        extension: ref.extension,
        storage: AttachmentStorage.folder,
      );
      return ref.inFolder(s.fileName);
  }
}

/// Shown in place of a file that hasn't arrived: "Still syncing". It fills
/// in by itself once the file is there (the box listens to
/// [AttachmentStore.changes]).
class StillSyncing extends StatelessWidget {
  const StillSyncing({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = NotedMetrics.of(context);
    final type = NotedTypography.of(context);
    return Semantics(
      label: 'Still syncing: $name',
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(m.space2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_sync_rounded,
                size: m.icon,
                color: scheme.onSurfaceVariant,
              ),
              SizedBox(width: m.space2),
              Flexible(
                child: Text(
                  'Still syncing',
                  key: const ValueKey('still-syncing'),
                  overflow: TextOverflow.ellipsis,
                  style: type.small.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
