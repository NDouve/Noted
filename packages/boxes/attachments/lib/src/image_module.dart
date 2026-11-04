// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'attachment_codecs.dart';
import 'attachment_io.dart';
import 'attachment_ref.dart';

/// Ids of the image module's commands.
abstract final class ImageCommands {
  static const String insert = 'noted.image.insert';
}

/// The image formats an image box takes (a GIF shows its first frame).
const Set<String> imageExtensions = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
};

/// The longest side, in pixels, of an image's display copy.
const int displayCopyMaxSide = 1600;

/// The longest side, in page units, of a new image box.
const double newImageMaxSide = 480;

/// The image box (`noted.image`): a picture kept as its original file, shown
/// from a downscaled display copy in the cache folder (never synced), with
/// alt text.
final class ImageModule extends BoxModule<ImageData?> {
  const ImageModule();

  @override
  BoxCodec<ImageData?> get codec => const ImageCodec();

  @override
  BoxFrameStyle get frameStyle => BoxFrameStyle.framelessUntilSelected;

  @override
  int fileAffinity(IncomingFile file) =>
      imageExtensions.contains(file.extension) ? 10 : 0;

  @override
  Future<(ImageData?, Size)?> createFromFile(
    IncomingFile file,
    AttachmentStore store,
  ) async {
    final size = await imageSize(file.bytes);
    if (size == null) return null;
    final ref = await storeIncoming(file, store);
    final (w, h) = size;
    final data = ImageData(ref: ref, width: w, height: h);
    return (data, newImageBoxSize(w, h));
  }

  @override
  double? aspectRatio(ImageData? data) =>
      data == null ? null : data.width / data.height;

  /// The alt-text strip under the picture keeps its height while resizing.
  @override
  double aspectRatioExtraHeight(ImageData? data) => imageCaptionHeight;

  @override
  Future<ImageData?> convertAttachments(
    ImageData? data,
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
      id: ImageCommands.insert,
      label: 'Insert image',
      icon: Icons.image_rounded,
      text: () => 'Image',
      enabled: () => host.attachments != null && !host.controller.readOnly,
      listenable: host.controller,
      invoke: () async {
        final store = host.attachments;
        if (store == null) return;
        final files = await store.pick(imagesOnly: true);
        await host.insertFiles(files);
      },
    ),
  ];

  @override
  Widget buildEditor(BuildContext context, BoxContext<ImageData?> box) =>
      _ImageBox(box: box, editable: true);

  @override
  Widget buildView(BuildContext context, BoxContext<ImageData?> box) =>
      _ImageBox(box: box, editable: false);
}

/// The size of a new image box for an image of [w] × [h] pixels: its pixel
/// size, scaled down so the longer side is at most [newImageMaxSide], plus
/// the alt-text strip below it ([imageCaptionHeight]).
Size newImageBoxSize(int w, int h) {
  final scale = math.min(1.0, newImageMaxSide / math.max(w, h));
  final width = math.max(24.0, w * scale);
  return Size(width, width * h / w + imageCaptionHeight);
}

/// The height of the alt-text strip under the picture, in page units.
const double imageCaptionHeight = 28;

/// The pixel size of the image in [bytes] (its first frame), or null if it
/// can't be decoded.
Future<(int, int)?> imageSize(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final size = (frame.image.width, frame.image.height);
    frame.image.dispose();
    codec.dispose();
    return size;
  } on Object {
    return null;
  }
}

/// The display copy of an image: [bytes]' first frame, scaled down so its
/// longer side is at most [displayCopyMaxSide], as PNG. Null if it can't be
/// decoded.
Future<Uint8List?> makeDisplayCopy(Uint8List bytes) async {
  try {
    final size = await imageSize(bytes);
    if (size == null) return null;
    final (w, h) = size;
    final scale = math.min(1.0, displayCopyMaxSide / math.max(w, h));
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: math.max(1, (w * scale).round()),
      targetHeight: math.max(1, (h * scale).round()),
    );
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    return png?.buffer.asUint8List();
  } on Object {
    return null;
  }
}

/// Where the display copy of the image with [hash] is cached.
File displayCopyFile(Directory cache, String hash) => File(
  '${cache.path}${Platform.pathSeparator}images${Platform.pathSeparator}$hash-$displayCopyMaxSide.png',
);

/// The display copy of [ref]: from the cache, or made from the original and
/// cached. Null while the original isn't there, isn't verified or doesn't
/// decode. The cache is keyed by the hash, so the original is checked against
/// that hash before anything is cached (see [readAttachment]).
Future<Uint8List?> loadDisplayCopy(
  AttachmentRef ref,
  AttachmentStore? store,
) async => (await loadDisplayCopyChecked(ref, store)).bytes;

/// [loadDisplayCopy] with what the check of the original found.
Future<AttachmentRead> loadDisplayCopyChecked(
  AttachmentRef ref,
  AttachmentStore? store,
) async {
  // The hash becomes part of a cache path: only a real SHA-256 may.
  if (!isContentHash(ref.hash)) {
    store?.notify(
      "\"${ref.name}\" can't be shown: its hash is not valid."
    );
    return (state: AttachmentState.damaged, bytes: null);
  }
  final cache = store == null
      ? null
      : displayCopyFile(store.cacheDirectory, ref.hash);
  if (cache != null) {
    try {
      if (await cache.exists()) {
        return (state: AttachmentState.ok, bytes: await cache.readAsBytes());
      }
    } on FileSystemException {
      // Fall through and make it again.
    }
  }
  final read = await readAttachment(ref, store);
  final original = read.bytes;
  if (original == null) return read;
  final copy = await makeDisplayCopy(original);
  if (copy == null || cache == null) return (state: read.state, bytes: copy);
  try {
    await cache.parent.create(recursive: true);
    final tmp = File('${cache.path}.tmp');
    await tmp.writeAsBytes(copy, flush: true);
    await tmp.rename(cache.path);
  } on FileSystemException catch (e) {
    debugPrint('Caching the display copy of ${ref.name} failed: $e');
  }
  return (state: read.state, bytes: copy);
}

class _ImageBox extends StatefulWidget {
  const _ImageBox({required this.box, required this.editable});

  final BoxContext<ImageData?> box;
  final bool editable;

  @override
  State<_ImageBox> createState() => _ImageBoxState();
}

class _ImageBoxState extends State<_ImageBox> {
  Uint8List? _pixels;
  String? _loadedHash;
  bool _loading = false;
  bool _retry = false;
  AttachmentState? _state;
  String? _stateHash;
  final FocusNode _altFocus = FocusNode();
  late final TextEditingController _alt = TextEditingController(
    text: widget.box.data?.alt ?? '',
  );
  Listenable? _changes;

  @override
  void initState() {
    super.initState();
    _listen();
    _altFocus.addListener(() => setState(() {}));
    _load();
  }

  @override
  void didUpdateWidget(_ImageBox old) {
    super.didUpdateWidget(old);
    _listen();
    final alt = widget.box.data?.alt ?? '';
    if (!_altFocus.hasFocus && _alt.text != alt) _alt.text = alt;
    _load();
  }

  void _listen() {
    final next = widget.box.attachments?.changes;
    if (identical(next, _changes)) return;
    _changes?.removeListener(_filesChanged);
    _changes = next;
    next?.addListener(_filesChanged);
  }

  // A file arrived (or left) in the assets folder: try again if waiting.
  void _filesChanged() {
    if (_pixels != null || !mounted) return;
    _loadedHash = null;
    if (_loading) {
      _retry = true;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    final data = widget.box.data;
    if (data == null || _loading || _loadedHash == data.ref.hash) return;
    _loading = true;
    final hash = data.ref.hash;
    final read = await loadDisplayCopyChecked(data.ref, widget.box.attachments);
    final pixels = read.bytes;
    _loading = false;
    if (!mounted) return;
    // A damaged file stays "damaged" while it is missing (it was set aside):
    // "Still syncing" would suggest it will mend itself. A good file
    // arriving replaces it.
    var state = read.state;
    if (state == AttachmentState.syncing &&
        _state == AttachmentState.damaged &&
        _stateHash == hash) {
      state = AttachmentState.damaged;
    }
    setState(() {
      _pixels = pixels;
      _state = state;
      _stateHash = hash;
      // A damaged file is not looked at again until the folder changes, so a
      // rebuild (hover, drag) does not hash and report it again.
      _loadedHash = pixels == null && state != AttachmentState.damaged ? null : hash;
    });
    // The change that a set-aside caused is not a reason to look again.
    if (_retry && pixels == null) {
      _retry = false;
      if (state != AttachmentState.damaged) unawaited(_load());
    }
  }

  void _commitAlt(String value) {
    final data = widget.box.data;
    if (data == null || data.alt == value) return;
    widget.box.commit(data.copyWith(alt: value));
  }

  @override
  void dispose() {
    _changes?.removeListener(_filesChanged);
    _altFocus.dispose();
    _alt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.box.data;
    final scheme = Theme.of(context).colorScheme;
    final m = NotedMetrics.of(context);
    final type = NotedTypography.of(context);
    final pixels = _pixels;
    final Widget picture;
    if (data == null) {
      picture = _note(
        context,
        Icons.broken_image_rounded,
        'This image can\'t be shown',
      );
    } else if (pixels != null) {
      picture = Image.memory(
        pixels,
        key: const ValueKey('image-box-picture'),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        semanticLabel: data.alt.isEmpty ? null : data.alt,
      );
    } else if (_state == AttachmentState.damaged) {
      picture = _note(
        context,
        Icons.broken_image_rounded,
        'This image is damaged',
      );
    } else if (_state == AttachmentState.ok) {
      // Read fine but does not decode.
      picture = _note(
        context,
        Icons.broken_image_rounded,
        "This image can't be shown",
      );
    } else if (_state == AttachmentState.syncing ||
        attachmentMissing(data.ref, widget.box.attachments)) {
      picture = ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: StillSyncing(name: data.ref.name),
      );
    } else {
      picture = ColoredBox(color: scheme.surfaceContainerHighest);
    }
    // The picture above, the alt text below it in its own strip
    // ([imageCaptionHeight]), so the caption never covers the picture. A
    // click on the picture selects the box (the canvas does that for content
    // that doesn't take the focus).
    final Widget caption;
    if (data == null) {
      caption = const SizedBox.shrink();
    } else if (widget.editable) {
      caption = TextField(
        key: const ValueKey('image-alt-text'),
        controller: _alt,
        focusNode: _altFocus,
        style: type.small,
        maxLines: 1,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Alt text',
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(
            horizontal: m.space2,
            vertical: m.space1,
          ),
        ),
        onChanged: _commitAlt,
        onSubmitted: _commitAlt,
      );
    } else {
      caption = Padding(
        padding: EdgeInsets.symmetric(horizontal: m.space2),
        child: Text(
          data.alt,
          key: const ValueKey('image-alt-caption'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: type.small.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: KeyedSubtree(key: const ValueKey('image-box'), child: picture),
        ),
        SizedBox(
          key: const ValueKey('image-caption'),
          height: imageCaptionHeight,
          child: Align(alignment: Alignment.centerLeft, child: caption),
        ),
      ],
    );
  }

  Widget _note(BuildContext context, IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    final m = NotedMetrics.of(context);
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: m.icon, color: scheme.onSurfaceVariant),
            SizedBox(width: m.space2),
            Flexible(
              child: Text(
                text,
                overflow: TextOverflow.ellipsis,
                style: NotedTypography.of(context).small
                    .copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
