// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';

/// The platform families that differ in which files they run.
enum RunnablePlatform {
  windows,
  macos,
  linux,
  android;

  /// This machine's family.
  static RunnablePlatform get current => Platform.isWindows
      ? windows
      : Platform.isMacOS || Platform.isIOS
      ? macos
      : Platform.isAndroid
      ? android
      : linux;
}

const Set<String> _windowsRunnable = {
  'exe', 'bat', 'cmd', 'com', 'ps1', 'vbs', 'vbe', 'js', 'jse', 'wsf', 'wsh', //
  'msc', 'lnk', 'url', 'msi', 'msp', 'scr', 'cpl', 'hta', 'pif', 'reg', 'jar',
  'appref-ms',
  'application',
  'xbap',
  'settingcontent-ms',
  'scf',
  'chm',
  'inf', //
  'ws', 'wsc', 'sct', 'shb', 'shs', 'psm1', 'psd1', 'ps1xml', 'psc1', 'msix',
  'msixbundle', 'appx', 'appxbundle', 'diagcab', 'library-ms', 'search-ms',
  'website', 'xll', 'iso', 'img', 'vhd', 'vhdx',
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
  'fileloc', 'inetloc', 'webloc', 'jnlp', 'scptd',
};

const Set<String> _linuxRunnable = {
  'sh', 'run', 'bin', 'appimage', 'desktop', 'jar', 'py', 'pl', //
};

/// The last extension of [name] (lowercase, no dot), after dropping the
/// trailing dots and spaces Windows strips; empty if it has none.
String lastExtension(String name) {
  final base = name
      .split(RegExp(r'[\\/]'))
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
    if (e.isNotEmpty && !e.contains(RegExp(r'[\\/.\s]'))) out.add(e);
  }
  return out;
}

/// Whether the system would run [name] rather than just show it: on Windows
/// the fixed list plus every `PATHEXT` extension ([pathExt], default the
/// environment's), on the other systems their lists. Only the name is
/// looked at.
bool isRunnableFileName(
  String name, {
  RunnablePlatform? platform,
  String? pathExt,
}) {
  final p = platform ?? RunnablePlatform.current;
  final ext = lastExtension(name);
  if (ext.isEmpty) return false;
  return switch (p) {
    RunnablePlatform.windows =>
      _windowsRunnable.contains(ext) ||
          pathExtExtensions(pathExt ?? Platform.environment['PATHEXT'])
              .contains(ext),
    RunnablePlatform.macos => _macRunnable.contains(ext),
    RunnablePlatform.linux => _linuxRunnable.contains(ext),
    RunnablePlatform.android => _linuxRunnable.contains(ext) || ext == 'apk',
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

/// [name] made safe to show: control characters and the bidirectional
/// controls that can reorder text are replaced, and a name longer than
/// [maxLength] is shortened in the middle so its end (the extension) stays.
String cleanNameForDisplay(String name, {int maxLength = 80}) {
  final s = name.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f\u061c\u200b-\u200f\u202a-\u202e\u2060-\u2069\ufeff]'), '\u00b7');
  final runes = s.runes.toList();
  if (runes.length <= maxLength) return s;
  // Keep the extension (when it is short) and as much of the start as fits.
  final dot = s.lastIndexOf('.');
  final tail = dot > 0 && s.length - dot <= 20 ? s.substring(dot) : '';
  final tailLength = tail.runes.length;
  final keep = maxLength - tailLength - 1;
  final head = String.fromCharCodes(runes.take(keep));
  return '$head…$tail';
}

/// Asks whether to open [displayName], a file the system may run. True only on
/// Open; Cancel (the default), Escape or a click outside answer false.
Future<bool> confirmOpenRunnable(
  BuildContext context,
  String displayName,
) async {
  final shown = cleanNameForDisplay(displayName);
  final ext = lastExtension(displayName);
  final ok = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (context) => AlertDialog(
      key: const ValueKey('open-confirm-dialog'),
      title: const Text('Open this file?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              shown,
              key: const ValueKey('open-confirm-name'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (ext.isNotEmpty)
              Text(
                'Type: .$ext',
                key: const ValueKey('open-confirm-type'),
                textDirection: TextDirection.ltr,
              ),
            const SizedBox(height: 12),
            const Text(
              'This kind of file can run as a program on your computer. Only open it if you trust where it came from.',
              key: ValueKey('open-confirm-text'),
            ),
          ],
        ),
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
