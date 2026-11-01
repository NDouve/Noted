// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Noted's MCP server (invariant 4): reads saved page files, with no key access
/// and no decryption code. While Noted runs the app checks codes and decides
/// every write; while it is closed the server checks codes by hash against the
/// saved code store, logs each request, and may write one AI box that allows it
/// (through the narrow writer, `closed_writer.dart`).
library;

export 'src/closed_access.dart';
export 'src/closed_writer.dart';
export 'src/library.dart';
export 'src/link_client.dart';
export 'src/running_probe.dart';
export 'src/server.dart';
export 'src/toolbox.dart';
export 'src/tools.dart';
