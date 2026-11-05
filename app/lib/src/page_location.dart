// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.


import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'notebook.dart';

/// The folder that holds page [id]'s file (shown in Page settings), or null
/// if it can't be told. A binder's page is in the binder's folder; a
/// standalone page is in the default folder or one of the extra folders.
String? pageFolderPath(Notebook nb, String id) => nb.folderOfPage(id);

/// What the "show the folder" button says on this platform.
String showFolderLabel() => defaultTargetPlatform == TargetPlatform.macOS
    ? 'Show in Finder'
    : defaultTargetPlatform == TargetPlatform.windows
    ? 'Show in File Explorer'
    : 'Show in file manager';

/// Opens [path] in the system's file manager. Tests replace it.
Future<void> Function(String path) showFolderInFileManager = (path) async {
  try {
    await launchUrl(Uri.directory(path));
  } on Object catch (e) {
    debugPrint('Showing $path failed: $e');
  }
};
