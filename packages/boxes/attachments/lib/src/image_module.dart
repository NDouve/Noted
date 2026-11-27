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
    final ref = await storeIncomingOrNotify(file, store);
    if (ref == null) return null;
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
        // Read before the first await; the picker may outlive the page.
        final inv = host.invocation;
        final files = await store.pick(imagesOnly: true);
        if (inv != null && !inv.isCurrent) {
          store.notify(insertStoppedNotice);
          return;
        }
        await host.insertFiles(files, at: inv?.anchor);
      },
    ),
  ];

  @override
  List<ExportFormat> exportFormats(ImageData? data) =>
      data == null ? const [] : const [ExportFormat.original, ExportFormat.png];

  /// The original file (read and checked by [readAttachment]), or a PNG: a PNG
  /// original within the export caps unchanged, any other image (or a PNG over
  /// the caps) decoded within them (a GIF's first frame); one over 100 MP is
  /// refused with a [ExportRefused] whose message the host shows.
  @override
  Future<ExportedFile?> export(ImageData? data, ExportFormat format, ExportContext context) async {
    if (data == null) return null;
    final read = await readAttachment(data.ref, context.attachments);
    final bytes = read.bytes;
    if (bytes == null) return null;
    switch (format.id) {
      case 'original':
        return ExportedFile(data.ref.name, bytes);
      case 'png':
        // A PNG within the raster caps passes through; one over them (or with
        // a header that can't be read) goes through the capped decode.
        final dims = pngDimensions(bytes);
        if (dims != null &&
            dims.$1 > 0 &&
            dims.$2 > 0 &&
            dims.$1 <= exportMaxSide &&
            dims.$2 <= exportMaxSide &&
            dims.$1 * dims.$2 <= exportMaxPixels) {
          return ExportedFile('', bytes);
        }
        try {
          final image = await decodeWithinCap(bytes, data.ref.name);
          try {
            return ExportedFile('', await imageToPng(image));
          } finally {
            image.dispose();
          }
        } on ExportRefused {
          rethrow;
        } on Object {
          return null;
        }
    }
    return null;
  }

  @override
  Widget buildEditor(BuildContext context, BoxContext<ImageData?> box) =>
      _ImageBox(box: box, editable: true);

  @override
  Widget buildView(BuildContext context, BoxContext<ImageData?> box) =>
      _ImageBox(box: box, editable: false);
}

/// The width and height in the IHDR chunk of a PNG in [bytes], read from the
/// header without decoding; null if [bytes] isn't a PNG or its first chunk
/// isn't a well-formed IHDR: 13 bytes of data, a matching CRC-32 and a valid
/// bit depth and colour type pair.
(int, int)? pngDimensions(Uint8List bytes) {
  if (bytes.length < 33 || !isPngBytes(bytes)) return null;
  final d = ByteData.sublistView(bytes);
  if (d.getUint32(8) != 13 || d.getUint32(12) != 0x49484452) return null;
  if (_crc32(bytes, 12, 29) != d.getUint32(29)) return null;
  final depth = bytes[24], color = bytes[25];
  final depths = switch (color) {
    0 => const [1, 2, 4, 8, 16],
    2 || 4 || 6 => const [8, 16],
    3 => const [1, 2, 4, 8],
    _ => const <int>[],
  };
  if (!depths.contains(depth)) return null;
  return (d.getUint32(16), d.getUint32(20));
}

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

/// The CRC-32 of `bytes[start, end)`, as PNG chunks use.
int _crc32(Uint8List bytes, int start, int end) {
  var c = 0xFFFFFFFF;
  for (var i = start; i < end; i++) {
    c = _crcTable[(c ^ bytes[i]) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
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
  // A file that can't be found is not shown from the cache either.
  if (attachmentNameInvalid(ref)) return (state: AttachmentState.syncing, bytes: null);
  // The hash becomes part of a cache path: only a real SHA-256 may.
  if (!isContentHash(ref.hash)) {
    store?.notify("\"${ref.name}\" can't be shown: its hash is not valid.");
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

  // What a load is for: the hash and the folder file the box names, so a
  // corrected file name with the same hash is loaded again.
  String _loadKey(AttachmentRef ref) => '${ref.hash}|${ref.file}';

  Future<void> _load() async {
    final data = widget.box.data;
    if (data == null || _loading || _loadedHash == _loadKey(data.ref)) return;
    _loading = true;
    final hash = _loadKey(data.ref);
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
      // A file is not looked at again until the folder changes, so a rebuild
      // (hover, drag) does not hash and report it again. Only a store that
      // doesn't report changes is asked again on a rebuild while waiting.
      _loadedHash =
          pixels == null && state != AttachmentState.damaged && _changes == null
          ? null
          : hash;
    });
    // The change that a set-aside caused is not a reason to look again.
    if (_retry && pixels == null) {
      _retry = false;
      if (state != AttachmentState.damaged) {
        _loadedHash = null;
        unawaited(_load());
      }
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
    } else if (attachmentNameInvalid(data.ref)) {
      picture = _note(
        context,
        Icons.broken_image_rounded,
        'File not found: ${data.ref.name}',
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
        child: StillSyncing(
          name: data.ref.name,
          store: widget.box.attachments,
          fileName: data.ref.file,
        ),
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
                maxLines: 2,
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
