// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// The part of Noted core a process needs to read saved pages, check an AI
/// code and write an AI box, and nothing more: the page model and file
/// format (including the splice that replaces one box's record in a page
/// file's text), binders, the page tree, search matching, the page AI access,
/// module availability, the code format and the local link, the AI write
/// (`applyAiWrite`) and note markdown (including the markdown importer), and,
/// read-only, the code store (`AiAccessView`, `AiCode`, `verifyAiCode`) and
/// the server's access log format (`AiMcpLogEntry`, `parseAiMcpLog`).
///
/// The MCP server (`packages/noted_mcp`, invariant 4) imports only this. Its
/// hashing is `package:crypto`'s SHA-256, used to check a code's key against
/// the stored hash; there is no code store writer, file lock, log writer,
/// attachment or storage-writing code and (later) no encryption code in its
/// import graph, and its tests check that. Everything here is pure Dart: no
/// file access at all.
library;

export 'src/ai/ai_access.dart';
export 'src/ai/ai_access_read.dart';
export 'src/ai/ai_box.dart';
export 'src/ai/ai_code.dart';
export 'src/ai/ai_code_format.dart';
export 'src/ai/ai_link.dart';
export 'src/ai/ai_mcp_log.dart';
export 'src/binder/binder.dart';
export 'src/format/note_markdown.dart';
export 'src/format/note_markdown_import.dart';
export 'src/format/page_format.dart';
export 'src/format/page_splice.dart';
export 'src/json/raw_json.dart';
export 'src/model/bounds.dart';
export 'src/model/box_types.dart';
export 'src/model/config_source.dart';
export 'src/model/page.dart';
export 'src/search/search_query.dart';
export 'src/search/text_folding.dart';
export 'src/tree/page_tree.dart';
