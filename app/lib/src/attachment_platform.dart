// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:url_launcher/url_launcher.dart';

import 'notebook.dart' show defaultPagesDirectory;

/// The image formats offered by Insert → Image.
const List<String> pickableImageExtensions = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];

/// Asks for files with the system's file dialog (only images when
/// [imagesOnly]).
Future<List<IncomingFile>> pickAttachments({required bool imagesOnly}) async {
  final files = await openFiles(
    acceptedTypeGroups: [
      if (imagesOnly) const XTypeGroup(label: 'Images', extensions: pickableImageExtensions),
    ],
  );
  return [for (final f in files) IncomingFile(f.name, await f.readAsBytes())];
}

/// Opens [file] with the system's default app.
Future<void> openWithDefaultApp(File file) async {
  try {
    await launchUrl(Uri.file(file.path));
  } on Object catch (e) {
    debugPrint('Opening ${file.path} failed: $e');
  }
}

/// The folder for derived files such as image display copies: in the local
/// (not roaming) app data on Windows, never in a page folder, so never
/// synced.
Directory defaultCacheDirectory() {
  final sep = Platform.pathSeparator;
  final local = Platform.environment['LOCALAPPDATA'];
  if (Platform.isWindows && local != null) return Directory('$local${sep}Noted${sep}cache');
  return Directory('${defaultPagesDirectory().absolute.parent.path}${sep}cache');
}

/// The extension an image's bytes say it has (PNG, JPEG, GIF, WebP, BMP), or
/// png.
String sniffImageExtension(Uint8List b) {
  bool at(int i, List<int> sig) {
    if (b.length < i + sig.length) return false;
    for (var k = 0; k < sig.length; k++) {
      if (b[i + k] != sig[k]) return false;
    }
    return true;
  }

  if (at(0, const [0xFF, 0xD8, 0xFF])) return 'jpg';
  if (at(0, 'GIF8'.codeUnits)) return 'gif';
  if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) return 'webp';
  if (at(0, 'BM'.codeUnits)) return 'bmp';
  return 'png';
}

/// The files on the clipboard: an image (copied from a browser or an image
/// app), or files copied in the file manager.
Future<List<IncomingFile>> readClipboardFiles() async {
  try {
    final image = await Pasteboard.image;
    if (image != null && image.isNotEmpty) {
      return [IncomingFile('Pasted image.${sniffImageExtension(image)}', image)];
    }
    final paths = await Pasteboard.files();
    final out = <IncomingFile>[];
    for (final p in paths) {
      final f = File(p);
      if (!await f.exists()) continue;
      out.add(IncomingFile(p.split(RegExp(r'[\\/]')).last, await f.readAsBytes()));
    }
    return out;
  } on Object catch (e) {
    debugPrint('Reading the clipboard failed: $e');
    return const [];
  }
}
