// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;

import 'package:flutter/widgets.dart';
import 'package:noted_core/noted_core.dart';

import 'attachment_store.dart';
import 'canvas_tool.dart';
import 'command_host.dart';
import 'commands.dart';

/// What a box module sees of its box while it is on screen.
///
/// The module keeps its live editing state (cursor, selection, the editor's
/// own undo) in its widgets. Content reaches the page only through [commit],
/// which runs the data through the codec's `encode`.
abstract interface class BoxContext<D> {
  String get boxId;

  /// The box's current data. The object a module passed to [commit] comes
  /// back here unchanged, so a module can tell its own edits from changes
  /// made elsewhere (undo, reload) by identity.
  D get data;

  /// The box's rectangle in page coordinates.
  Rect get bounds;

  /// The box is shown but can't be edited.
  bool get readOnly;

  /// The box sizes itself to its content: its type grows with content and
  /// the user hasn't set its height. When false the box keeps its height
  /// and the module scrolls content that overflows (see [BoxScrollScope]).
  bool get autoHeight;

  /// The box was just created by the user and should take keyboard focus.
  bool get autofocus;

  /// Saves new content: encoded by the codec, with a fresh snapshot and a
  /// new revision. Doesn't rebuild the canvas.
  void commit(D data);

  /// Find on page (Box API 0.6): what is being looked for while the find bar
  /// is open, or null. A module may mark the matches in its own content;
  /// the canvas frames the matching boxes either way.
  ValueListenable<BoxFind?> get find;

  /// Asks the host to move or resize the box, for example to grow it with
  /// its content. The host applies the request after the current frame and
  /// ignores it while the user is dragging or resizing that box.
  void requestBounds(Rect bounds);

  /// The page's images and files (Box API 0.7), or null where there are
  /// none (a page that isn't stored in a folder, a conflict preview).
  AttachmentStore? get attachments;

  /// Creates boxes for [files] beside this box (Box API 0.7), for example an
  /// image pasted while the caret is in a note.
  void insertFilesBeside(List<IncomingFile> files);
}

/// The Flutter side of a box type (0034). Each box type is one module.
///
/// The data side is [codec], which has no Flutter dependency.
abstract class BoxModule<D> {
  const BoxModule();

  BoxCodec<D> get codec;

  /// The live box on the canvas.
  Widget buildEditor(BuildContext context, BoxContext<D> box);

  /// The box shown read-only.
  Widget buildView(BuildContext context, BoxContext<D> box);

  /// The box's settings panel, if it has settings.
  Widget? buildSettings(BuildContext context, BoxContext<D> box) => null;

  /// Canvas tools this module adds, for example a pen (Box API 0.2).
  List<CanvasTool> get tools => const [];

  /// Commands this module adds, for example "insert table" (Box API 0.4).
  /// Called once for each open page canvas; the canvas owns the commands and
  /// disposes them. Each tool in [tools] is already a command (same id), so
  /// list only the others. Ids are namespaced by module and must be unique.
  List<Command> commands(CommandHost host) => const [];

  /// How the canvas frames this module's boxes (Box API 0.5).
  BoxFrameStyle get frameStyle => BoxFrameStyle.framed;

  /// Renders an image snapshot (0035) as PNG bytes, or returns null for a
  /// text-only snapshot. Not stored yet: Prototype 1 boxes are text only.
  Future<Uint8List?> snapshotImage(D data, Size size) async => null;

  /// How well this module can hold [file] (Box API 0.7): 0 for not at all;
  /// a pasted, dropped or picked file goes to the module with the highest
  /// value (an image module above a module that takes any file).
  int fileAffinity(IncomingFile file) => 0;

  /// Makes the data and size of a new box holding [file], storing the file
  /// through [store] (Box API 0.7). Null if the file can't be used (an
  /// image that doesn't decode).
  Future<(D, Size)?> createFromFile(IncomingFile file, AttachmentStore store) async => null;

  /// The width / height the box keeps while the user resizes it (Box API
  /// 0.7), or null for none. Holding Shift resizes freely.
  double? aspectRatio(D data) => null;

  /// The same content with its files kept the [to] way (Box API 0.7: "Embed
  /// attachments", "Move attachments to folder"), or null if nothing
  /// changes. Names of files that stay in the folder because they are over
  /// [embedLimitBytes] are added to [overLimit].
  Future<D?> convertAttachments(
    D data,
    AttachmentStorage to,
    AttachmentStore store,
    List<String> overLimit,
  ) async => null;

  /// Untyped [createFromFile], for the canvas.
  Future<(Object?, Size)?> hostCreateFromFile(IncomingFile file, AttachmentStore store) async =>
      await createFromFile(file, store);

  /// Untyped [aspectRatio], for the canvas.
  double? hostAspectRatio(Object? data) => data is D ? aspectRatio(data) : null;

  /// Untyped [convertAttachments], for the canvas.
  Future<Object?> hostConvertAttachments(
    Object? data,
    AttachmentStorage to,
    AttachmentStore store,
    List<String> overLimit,
  ) async => data is D ? await convertAttachments(data, to, store, overLimit) : null;

  /// Called by the box host. Keeps [D] typed across the untyped host.
  Widget hostBuild(BuildContext context, BoxBinding binding) {
    final box = _TypedBoxContext<D>(binding);
    return binding.readOnly
        ? buildView(context, box)
        : buildEditor(context, box);
  }
}

/// The host's untyped side of a [BoxContext].
final class BoxBinding {
  const BoxBinding({
    required this.boxId,
    required this.data,
    required this.bounds,
    required this.readOnly,
    required this.autoHeight,
    required this.autofocus,
    required this.commit,
    required this.requestBounds,
    this.find,
    this.attachments,
    this.insertFilesBeside,
  });

  final String boxId;
  final Object? data;
  final Rect bounds;
  final bool readOnly;
  final bool autoHeight;
  final bool autofocus;
  final void Function(Object? data) commit;
  final void Function(Rect bounds) requestBounds;

  /// Find on page, or null where there is none (a conflict dialog preview).
  final ValueListenable<BoxFind?>? find;

  /// The page's images and files, or null.
  final AttachmentStore? attachments;

  /// Creates boxes beside this one, or null where boxes can't be added.
  final void Function(List<IncomingFile> files)? insertFilesBeside;
}

final class _TypedBoxContext<D> implements BoxContext<D> {
  _TypedBoxContext(this._b);

  final BoxBinding _b;

  @override
  String get boxId => _b.boxId;
  @override
  D get data => _b.data as D;
  @override
  Rect get bounds => _b.bounds;
  @override
  bool get readOnly => _b.readOnly;
  @override
  bool get autoHeight => _b.autoHeight;
  @override
  bool get autofocus => _b.autofocus;
  @override
  void commit(D data) => _b.commit(data);
  @override
  void requestBounds(Rect bounds) => _b.requestBounds(bounds);
  @override
  ValueListenable<BoxFind?> get find => _b.find ?? _noFind;
  @override
  AttachmentStore? get attachments => _b.attachments;
  @override
  void insertFilesBeside(List<IncomingFile> files) => _b.insertFilesBeside?.call(files);

  static final ValueNotifier<BoxFind?> _noFind = ValueNotifier<BoxFind?>(null);
}

/// How the canvas frames a module's boxes (Box API 0.5, BoxFrame
/// guidelines).
enum BoxFrameStyle {
  /// A surface fill and a hairline frame while idle; an accent border when
  /// selected.
  framed,

  /// No fill and no frame until selected (the drawing box: ink straight on
  /// the page); a dashed accent outline when selected.
  framelessUntilSelected,
}
