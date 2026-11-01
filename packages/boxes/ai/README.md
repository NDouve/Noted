# noted_box_ai

The AI box: a note-like box that one AI connection owns and writes to.

- `lib/src/ai_codec.dart`: the data side. Stored shape is the note box's
  (`{"document": ...}`) plus an optional `"owner"` (a connection id, never a
  secret). `aiWrite` turns markdown into note blocks and marks each with
  `markAiWritten`; the mark only counts while it matches the block's text.
- `lib/src/ai_module.dart`: the widgets. The note module's editor and light
  view are reused (`NoteEditorView`), with a thin bar on AI-written blocks, an
  "AI" label and a "Connected AI" menu. The command `noted.ai.insert`
  replaces the toolbar placeholder once the module is registered.

`AiModule(connections: ...)` takes the app's list of connections; the module
only reads their ids and names.
