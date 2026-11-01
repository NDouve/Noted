// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// The part of Noted core a process needs to read saved pages, and nothing
/// more: the page model and file format, binders, the page tree, search
/// matching, the page AI access, module availability, the code format and the
/// local link, and note markdown.
///
/// The MCP server (`packages/noted_mcp`, invariant 4) imports only this, so
/// no hashing, code store, attachment, storage-writing or (later) encryption
/// code is in its import graph; its tests check that.
library;

export 'src/ai/ai_access.dart';
export 'src/ai/ai_box.dart';
export 'src/ai/ai_code_format.dart';
export 'src/ai/ai_link.dart';
export 'src/binder/binder.dart';
export 'src/format/note_markdown.dart';
export 'src/format/page_format.dart';
export 'src/json/raw_json.dart';
export 'src/model/bounds.dart';
export 'src/model/box_types.dart';
export 'src/model/config_source.dart';
export 'src/model/page.dart';
export 'src/search/search_query.dart';
export 'src/search/text_folding.dart';
export 'src/tree/page_tree.dart';
