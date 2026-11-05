// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'notebook.dart';

/// The folder that holds page [id]'s file (shown in Page settings), or null
/// if the page is unknown.
String? pageFolderPath(Notebook nb, String id) => nb.folderOfPage(id);

/// What the "show the folder" button says on this platform.
String showFolderLabel() => defaultTargetPlatform == TargetPlatform.macOS
    ? 'Show in Finder'
    : defaultTargetPlatform == TargetPlatform.windows
    ? 'Show in File Explorer'
    : 'Show in file manager';

/// The URI that opens folder [path] in the file manager. A Windows network
/// path (UNC, two leading backslashes) becomes `file://server/share/folder/`.
Uri folderUri(String path, {bool? windows}) => Uri.directory(path, windows: windows);

/// Opens [path] in the system's file manager. Returns false if the folder is
/// not there or the system could not open it. Tests replace it.
Future<bool> Function(String path) showFolderInFileManager = (path) async {
  try {
    if (!await Directory(path).exists()) return false;
    return await launchUrl(folderUri(path));
  } on Object catch (e) {
    debugPrint('Showing $path failed: $e');
    return false;
  }
};
