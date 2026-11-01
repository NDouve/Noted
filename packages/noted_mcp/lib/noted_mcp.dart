// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Noted's read-only MCP server (invariant 4): reads saved page files only,
/// with no key access and no decryption code.
library;

export 'src/library.dart';
export 'src/server.dart';
export 'src/tools.dart';
