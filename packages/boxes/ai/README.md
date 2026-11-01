# noted_box_ai

The AI box: a note-like box that AI chats connect to with per-box codes.

- `lib/src/ai_codec.dart`: the data side. Stored shape is the note box's
  (`{"document": ...}`) plus an optional legacy `"owner"` (a connection id
  from before per-box codes; kept as written, nothing writes it any more).
  `aiWrite` turns markdown into note blocks and marks each with
  `markAiWritten`; the mark only counts while it matches the block's text.
- `lib/src/ai_box_access.dart`: `AiBoxAccess`, what the app implements over
  its local code store and activity log, and `NoAiBoxAccess` for hosts
  without one. It is not part of the Box API.
- `lib/src/ai_module.dart`: the widgets. The note module's editor and light
  view are reused (`NoteEditorView`), with a thin bar on AI-written blocks
  and a header: the "AI" label, a connections indicator and **Connect a
  chat**. The command `noted.ai.insert` replaces the toolbar placeholder
  once the module is registered.
- `lib/src/ai_connect_dialog.dart`: Connect a chat. Writer or Reader, a
  label and an optional expiry, then the code, shown once.
- `lib/src/ai_connections_dialog.dart`: the box's codes with their approved
  sessions (each revocable), Ask before each write, and the activity list.

`AiModule(access: ...)` takes the app's `AiBoxAccess`; without one the box
shows no connections and Connect is off. The look of the marker and the
header is in `docs/design/ai-box.md`.
