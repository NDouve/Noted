// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:noted_canvas/noted_canvas.dart';

import '../app_theme.dart';

/// The host's PNG of a box's read-only view (design: rendering): [module]'s
/// `hostBuild` with a read-only [BoxBinding] (commit and requestBounds do
/// nothing, no find, no insertFilesBeside; the files come from [attachments]),
/// `offscreen` set so a module keeps it out of its live-editor registry, in
/// the light theme on white paper. The view is built from [data], the record
/// the page's controller holds, never from the live screen.
///
/// It is drawn in an overlay entry placed out of view (not `Offstage`, which
/// paints nothing), left for a frame or two and some time for fonts and
/// images, then rasterised at [pixelRatio], scaled down to the export caps.
/// The entry is removed afterwards. Null if the overlay is not there or the
/// view could not be rasterised.
Future<Uint8List?> renderBoxPng({
  required BuildContext context,
  required BoxModule<Object?> module,
  required Object? data,
  required String boxId,
  required Size size,
  required AttachmentStore? attachments,
  double pixelRatio = 2,
  Duration settle = const Duration(milliseconds: 120),
}) async {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null || size.width <= 0 || size.height <= 0) return null;
  final key = GlobalKey();
  final raster = exportRasterSize(size, pixelRatio);
  final entry = OverlayEntry(
    maintainState: true,
    builder: (context) => Positioned(
      // Out of view, to the left of the window; it is still laid out and painted.
      left: -size.width - 200,
      top: 0,
      width: size.width,
      height: size.height,
      child: ExcludeSemantics(
        child: IgnorePointer(
          child: ExcludeFocus(
            child: Theme(
              data: buildNotedTheme(Brightness.light),
              child: RepaintBoundary(
                key: key,
                // White paper inside the boundary, so it is in the picture.
                child: ColoredBox(
                  color: Colors.white,
                  child: Material(
                    type: MaterialType.transparency,
                    child: Builder(
                      builder: (context) => module.hostBuild(
                        context,
                        BoxBinding(
                          boxId: boxId,
                          data: data,
                          bounds: Offset.zero & size,
                          readOnly: true,
                          autoHeight: false,
                          autofocus: false,
                          commit: (_) {},
                          requestBounds: (_) {},
                          attachments: attachments,
                          offscreen: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  try {
    await _frames(2);
    await Future<void>.delayed(settle);
    await _frames(1);
    final boundary = key.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return null;
    final image = await boundary.toImage(pixelRatio: raster.scale);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      return bytes?.buffer.asUint8List(
        bytes.offsetInBytes,
        bytes.lengthInBytes,
      );
    } finally {
      image.dispose();
    }
  } finally {
    entry.remove();
    entry.dispose();
  }
}

/// Waits for [n] frames to have been drawn.
Future<void> _frames(int n) async {
  for (var i = 0; i < n; i++) {
    final done = Completer<void>();
    SchedulerBinding.instance.addPostFrameCallback((_) => done.complete());
    SchedulerBinding.instance.scheduleFrame();
    await done.future;
  }
}
