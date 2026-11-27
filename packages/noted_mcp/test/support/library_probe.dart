// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Test helper, run as its own process from the package folder (the app's
// binder .zip tests start it, so the app doesn't depend on noted_mcp): loads
// the library of a data folder as the server does and prints one line,
//
//   library:JSON  {"pages": [{"id", "access", "locked", "folder", "binderAi"}]}
//
// where "access" is the AI access the server applies to the page and
// "binderAi" the binder's own `ai` value (null when it has none).
//
//   library_probe.dart <data dir>
import 'dart:convert';
import 'dart:io';

import 'package:noted_core/noted_core.dart';
import 'package:noted_mcp/noted_mcp.dart';

Future<void> main(List<String> args) async {
  final library = await NotedLibrary.load(Directory(args[0]));
  final pages = [
    for (final p in library.pages)
      {
        'id': p.id,
        'access': p.access.value,
        'locked': p.locked,
        'folder': p.location.path,
        'binderAi': p.location.binder?.aiAccess?.value,
      },
  ];
  stdout.writeln('library:${jsonEncode({'pages': pages})}');
  await stdout.flush();
  exit(0);
}
