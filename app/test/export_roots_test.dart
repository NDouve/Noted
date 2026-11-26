// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The folders an export never writes into: every storage location and binder
// folder, the recovery folder, the cache, the app data folder and the rest.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/export/export_roots.dart';
import 'package:noted/src/export/export_targets.dart';
import 'package:noted/src/notebook.dart';
import 'support/notebook_folder.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  test('every storage folder, binder folder and Noted-owned folder is refused, and what is below it', () async {
    final dir = Directory.systemTemp.createTempSync('noted_export_roots');
    final sep = Platform.pathSeparator;
    String at(String name) => '${dir.path}$sep$name';
    final outside = Directory(at('Documents'))..createSync();
    final nb = Notebook(
      PageStore(Directory(at('pages'))..createSync()),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File(at('app${sep}binders.json')),
      recoveryDirectory: Directory(at('app${sep}recovery')),
      cacheDirectory: Directory(at('app${sep}cache')),
      templatesDirectory: Directory(at('app${sep}templates')),
    );
    addTearDown(() => deleteTestFolder(dir, notebooks: [nb]));
    await nb.loadChecked();
    final binder = await nb.addBinder((Directory(at('Work'))..createSync()).path);
    final settings = AppSettings(File(at('app${sep}settings.json')));

    final roots = exportRefusedRoots(nb, settings: settings);
    final check = ExportTargetCheck(roots: () => roots);

    // Each storage location and each folder Noted keeps data in.
    for (final folder in [
      at('pages'), // the storage location
      binder.path, // a binder folder
      '${binder.path}${sep}templates', // its templates
      at('pages${sep}abc.assets'), // a page's attachments
      at('app'), // app data: binders.json, settings.json, ai-access.json, folder-access.json, the MCP log
      at('app${sep}recovery'),
      at('app${sep}cache'),
      at('app${sep}templates'),
      at('app${sep}deleted-attachments'),
    ]) {
      expect(check.refuses('$folder${sep}export.txt'), isTrue, reason: folder);
    }
    expect(check.refuses(at('app${sep}settings.json')), isTrue);
    expect(check.refuses(at('app${sep}binders.json')), isTrue);
    expect(check.refuses(at('app${sep}ai-access.json')), isTrue);
    // A folder of the user's own.
    expect(check.refuses('${outside.path}${sep}export.txt'), isFalse);

    // Noted's folder in the user's local app data, with `mcp` inside it.
    final local = Platform.isWindows ? Platform.environment['LOCALAPPDATA'] : null;
    if (local != null) {
      expect(check.refuses('$local${sep}Noted${sep}mcp${sep}x.txt'), isTrue);
      expect(check.refuses('$local${sep}Noted${sep}x.txt'), isTrue);
    }
  });

  test('the .noted folder in the home folder is refused on Linux and macOS', () async {
    final dir = Directory.systemTemp.createTempSync('noted_export_roots2');
    final nb = Notebook(PageStore(Directory('${dir.path}/pages')..createSync()), buildModules());
    addTearDown(() => deleteTestFolder(dir, notebooks: [nb]));
    for (final os in ['linux', 'macos']) {
      final roots = exportRefusedRoots(nb, environment: {'HOME': '${dir.path}/home'}, platform: os);
      expect(roots, contains('${dir.path}/home${Platform.pathSeparator}.noted'), reason: os);
    }
    final windows = exportRefusedRoots(nb, environment: {'HOME': '${dir.path}/home'}, platform: 'windows');
    expect(windows, isNot(contains('${dir.path}/home${Platform.pathSeparator}.noted')));
  });
}
