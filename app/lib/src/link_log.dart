// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:noted_box_note/noted_box_note.dart';

import 'device_storage.dart';

/// The most the link log grows to before it starts over.
const int linkLogLimit = 256 * 1024;

/// The link log: `%LOCALAPPDATA%\Noted\logs\link.log` on Windows (local, not
/// roaming app data), `~/.noted/logs/link.log` on other desktops, and the
/// app's private folder on a device. Never derived from the pages folder, so
/// `NOTED_PAGES_DIR` or a synced pages folder does not move it there. Null
/// where no such folder is known (then the log goes to the console only).
File? defaultLinkLogFile() {
  final sep = Platform.pathSeparator;
  final env = Platform.environment;
  final Directory? base;
  if (isMobilePlatform) {
    base = deviceSupportDirectory() ?? deviceCacheDirectory();
  } else if (Platform.isWindows && env['LOCALAPPDATA'] != null) {
    base = Directory('${env['LOCALAPPDATA']}${sep}Noted');
  } else if (env['HOME'] != null) {
    base = Directory('${env['HOME']}$sep.noted');
  } else {
    base = null;
  }
  return base == null ? null : File('${base.path}${sep}logs${sep}link.log');
}

/// Sends the link path's diagnostics to the debug console and to [file],
/// which a release build has when it prints nowhere. Lines are fixed text
/// (never a link or note content); the file is append-only and starts over
/// past [linkLogLimit]. A failure to write is ignored.
void installLinkLog([File? file]) {
  final target = file ?? defaultLinkLogFile();
  linkLog = (line) {
    debugPrint('Noted: $line');
    if (target == null) return;
    try {
      target.parent.createSync(recursive: true);
      if (target.existsSync() && target.lengthSync() > linkLogLimit) target.writeAsStringSync('');
      target.writeAsStringSync('${DateTime.now().toIso8601String()} $line\n', mode: FileMode.append, flush: true);
    } on Object {
      // Logging must never break the app.
    }
  };
}
