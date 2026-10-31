// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'attachment_codecs.dart';
import 'attachment_io.dart';

/// Ids of the file module's commands.
abstract final class FileCommands {
  static const String insert = 'noted.file.insert';
}

/// The size of a new file box, in page units.
const Size newFileBoxSize = Size(280, 64);

/// The file box (`noted.file`): any file, shown as an icon with its name and
/// size; a double-click opens it with the system's default app.
final class FileModule extends BoxModule<FileData?> {
  const FileModule();

  @override
  BoxCodec<FileData?> get codec => const FileCodec();

  /// Takes any file, below every module made for a kind of file.
  @override
  int fileAffinity(IncomingFile file) => 1;

  @override
  Future<(FileData?, Size)?> createFromFile(IncomingFile file, AttachmentStore store) async {
    final ref = await storeIncoming(file, store);
    return (FileData(ref: ref), newFileBoxSize);
  }

  @override
  Future<FileData?> convertAttachments(
    FileData? data,
    AttachmentStorage to,
    AttachmentStore store,
    List<String> overLimit,
  ) async {
    if (data == null) return null;
    final ref = await convertAttachment(data.ref, to, store, overLimit);
    return ref == null ? null : data.copyWith(ref: ref);
  }

  @override
  List<Command> commands(CommandHost host) => [
    Command(
      id: FileCommands.insert,
      label: 'Insert file',
      icon: Icons.attach_file_rounded,
      text: () => 'File',
      enabled: () => host.attachments != null && !host.controller.readOnly,
      listenable: host.controller,
      invoke: () async {
        final store = host.attachments;
        if (store == null) return;
        final files = await store.pick(imagesOnly: false);
        await host.insertFiles(files);
      },
    ),
  ];

  @override
  Widget buildEditor(BuildContext context, BoxContext<FileData?> box) => _FileBox(box: box);

  @override
  Widget buildView(BuildContext context, BoxContext<FileData?> box) => _FileBox(box: box);
}

/// The icon for a file with [extension].
IconData fileIcon(String extension) => switch (extension) {
  'pdf' => Icons.picture_as_pdf_rounded,
  'doc' || 'docx' || 'odt' || 'rtf' || 'txt' || 'md' => Icons.description_rounded,
  'xls' || 'xlsx' || 'ods' || 'csv' => Icons.table_chart_rounded,
  'ppt' || 'pptx' || 'odp' => Icons.slideshow_rounded,
  'zip' || '7z' || 'rar' || 'gz' || 'tar' => Icons.folder_zip_rounded,
  'mp3' || 'wav' || 'flac' || 'm4a' || 'ogg' => Icons.audio_file_rounded,
  'mp4' || 'mov' || 'mkv' || 'avi' || 'webm' => Icons.video_file_rounded,
  'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' || 'svg' => Icons.image_rounded,
  _ => Icons.insert_drive_file_rounded,
};

class _FileBox extends StatelessWidget {
  const _FileBox({required this.box});

  final BoxContext<FileData?> box;

  @override
  Widget build(BuildContext context) {
    final store = box.attachments;
    final changes = store?.changes;
    return changes == null ? _content(context) : ListenableBuilder(listenable: changes, builder: (c, _) => _content(c));
  }

  Widget _content(BuildContext context) {
    final data = box.data;
    final store = box.attachments;
    final scheme = Theme.of(context).colorScheme;
    final m = NotedMetrics.of(context);
    final type = NotedTypography.of(context);
    if (data == null) {
      return Center(child: Text('This file can\'t be shown', style: type.small));
    }
    final ref = data.ref;
    final missing = attachmentMissing(ref, store);
    Future<void> open() async {
      if (store == null || missing) return;
      await store.open(ref.name, fileName: ref.isEmbedded ? null : ref.file, bytes: ref.bytes);
    }

    return Tooltip(
      message: missing ? '${ref.name}: still syncing' : 'Double-click to open ${ref.name}',
      child: GestureDetector(
        key: const ValueKey('file-box'),
        behavior: HitTestBehavior.opaque,
        onDoubleTap: open,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: m.space3, vertical: m.space2),
          child: Row(
            children: [
              Icon(fileIcon(ref.extension), size: m.icon * 1.6, color: scheme.primary),
              SizedBox(width: m.space3),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ref.name,
                      key: const ValueKey('file-box-name'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.bodyStrong,
                    ),
                    Text(
                      missing ? 'Still syncing' : formatByteSize(ref.size),
                      key: ValueKey(missing ? 'still-syncing' : 'file-box-size'),
                      style: type.small.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
