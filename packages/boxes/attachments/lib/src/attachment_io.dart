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
Future<AttachmentRef> storeIncoming(IncomingFile file, AttachmentStore store) async {
  final s = await store.put(file.bytes, extension: file.extension);
  final ref = AttachmentRef(name: file.name, size: file.bytes.length, hash: s.hash);
  final embedded = s.embedded;
  return embedded != null ? ref.embedded(embedded) : ref.inFolder(s.fileName);
}

/// The bytes of [ref], or null if its folder file isn't there (yet).
Future<Uint8List?> loadAttachment(AttachmentRef ref, AttachmentStore? store) async {
  final bytes = ref.bytes;
  if (bytes != null) return bytes;
  final file = ref.file;
  if (file == null || store == null) return null;
  return store.read(file);
}

/// Whether [ref]'s file is in the folder but not there yet, for example
/// still syncing from another device.
bool attachmentMissing(AttachmentRef ref, AttachmentStore? store) {
  if (ref.isEmbedded) return false;
  final file = ref.file;
  return file == null || store == null || !store.exists(file);
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
      if (ref.isEmbedded || file == null) return null;
      final bytes = await store.read(file);
      if (bytes == null) return null;
      if (!canEmbed(bytes)) {
        overLimit.add(ref.name);
        return null;
      }
      return ref.embedded(bytes);
    case AttachmentStorage.folder:
      final bytes = ref.bytes;
      if (bytes == null) return null;
      final s = await store.put(bytes, extension: ref.extension, storage: AttachmentStorage.folder);
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
              Icon(Icons.cloud_sync_rounded, size: m.icon, color: scheme.onSurfaceVariant),
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
