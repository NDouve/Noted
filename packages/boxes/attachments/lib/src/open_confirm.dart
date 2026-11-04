// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';

/// The platform families that differ in which files they run.
enum RunnablePlatform {
  windows,
  macos,
  linux;

  /// This machine's family. Other systems (the phones) use the Linux list.
  static RunnablePlatform get current => Platform.isWindows
      ? windows
      : Platform.isMacOS || Platform.isIOS
      ? macos
      : linux;
}

const Set<String> _windowsRunnable = {
  'exe', 'bat', 'cmd', 'com', 'ps1', 'vbs', 'vbe', 'js', 'jse', 'wsf', 'wsh', //
  'msc', 'lnk', 'url', 'msi', 'msp', 'scr', 'cpl', 'hta', 'pif', 'reg', 'jar',
};

const Set<String> _macRunnable = {
  'app',
  'command',
  'tool',
  'sh',
  'pkg',
  'mpkg',
  'dmg',
  'terminal',
  'workflow', //
  'jar',
  'scpt',
  'applescript',
  'action',
  'osx',
  'run',
  'bin',
  'csh',
  'ksh',
  'zsh',
};

const Set<String> _linuxRunnable = {
  'sh', 'run', 'bin', 'appimage', 'desktop', 'jar', 'py', 'pl', //
};

/// The last extension of [name] (lowercase, no dot), after dropping the
/// trailing dots and spaces Windows strips; empty if it has none.
String lastExtension(String name) {
  final base = name
      .split(RegExp(r'[\/]'))
      .last
      .replaceAll(RegExp(r'[. ]+$'), '');
  final dot = base.lastIndexOf('.');
  return dot < 0 ? '' : base.substring(dot + 1).trim().toLowerCase();
}

/// The extensions in a `PATHEXT` value (`.COM;.EXE;...`), lowercase, no dot.
/// Anything odd is skipped.
Set<String> pathExtExtensions(String? pathExt) {
  final out = <String>{};
  for (final part in (pathExt ?? '').split(';')) {
    final e = part.trim().replaceFirst(RegExp(r'^\.+'), '').toLowerCase();
    if (e.isNotEmpty && !e.contains(RegExp(r'[\/.\s]'))) out.add(e);
  }
  return out;
}

/// Whether the system would run [name] rather than just show it: on Windows
/// the fixed list plus every `PATHEXT` extension ([pathExt], default the
/// environment's), on macOS and Linux their lists. [executableBit] is the
/// Linux/macOS permission bit of the file, when known.
bool isRunnableFileName(
  String name, {
  RunnablePlatform? platform,
  String? pathExt,
  bool executableBit = false,
}) {
  final p = platform ?? RunnablePlatform.current;
  if (p != RunnablePlatform.windows && executableBit) return true;
  final ext = lastExtension(name);
  if (ext.isEmpty) return false;
  return switch (p) {
    RunnablePlatform.windows =>
      _windowsRunnable.contains(ext) ||
          pathExtExtensions(pathExt ?? Platform.environment['PATHEXT'])
              .contains(ext),
    RunnablePlatform.macos => _macRunnable.contains(ext),
    RunnablePlatform.linux => _linuxRunnable.contains(ext),
  };
}

/// Whether opening needs a question first: the name the user sees or the name
/// the file is stored under is runnable.
bool needsOpenConfirmation({
  required String displayName,
  String? storedName,
  RunnablePlatform? platform,
  String? pathExt,
}) =>
    isRunnableFileName(displayName, platform: platform, pathExt: pathExt) ||
    (storedName != null &&
        isRunnableFileName(storedName, platform: platform, pathExt: pathExt));

/// Asks whether to open [displayName], a file the system may run. True only on
/// Open; Cancel (the default), Escape or a click outside answer false.
Future<bool> confirmOpenRunnable(
  BuildContext context,
  String displayName,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('open-confirm-dialog'),
      title: const Text('Open this file?'),
      content: Text(
        '"$displayName" is a kind of file your computer can run as a program. '
        'Only open it if you trust where it came from.',
        key: const ValueKey('open-confirm-text'),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('open-confirm-cancel'),
          autofocus: true,
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('open-confirm-open'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Open'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
