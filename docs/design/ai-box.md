# AI box

The AI box is a note box plus a header strip and a mark on text an AI wrote. Chrome stays neutral: `accent` means selection, so none of this uses it.

## The AI marker

- A **2 px** vertical bar, colour `text-muted` at 60% opacity (`onSurfaceVariant`), square ends, no shadow. It reads in light and dark.
- It sits in the margin left of the text column: its right edge is 4 px (`space-1`) left of the block's text start, inside the box's own side padding. It never reaches into the text and never crosses the box frame. On a bullet or numbered item it is beside the whole item, left of the bullet glyph, not beside the text.
- It spans the block's own row, from its top to where its nested children (indented items the user wrote under it) begin, so it never runs down beside text the AI didn't write. Where the children can't be measured (the read-only view) it spans the whole block. Consecutive top-level blocks touch, so **consecutive AI-written blocks draw one unbroken bar**. A block the user wrote (or edited: typing ends the mark) has no bar, which ends the run.
- It takes no room and ignores the pointer; adding it never changes a box's height.
- It marks only blocks whose text still matches what the AI wrote. It is a visual cue, not a proof (the snapshot for other AIs carries `<ai-written>` tags).

## Header strip

28 px tall, `space-2` side padding, above the note. Left to right:

1. The **AI** badge: `label` type in `text-muted` on `surface-hover`, `radius-sm`.
2. The **connections indicator** (right side): a link icon and "No chats", "1 chat", "N chats" (expired codes are not counted), in `small` `text-muted`. It opens the connections panel. When the store can't be read it shows an alert icon and "Connections unavailable". Below 260 px it keeps only the icon.
3. **Connect a chat**: a compact text button (24 px high) with an add-link icon. It is absent in a view that can't edit (a read-only page) and off when AI connections aren't available (a tooltip says why). Revoking, the Writer permission and the two switches stay usable on a read-only page: they change the local code store, not the page.

All icons are `text-muted`, not `text`.

## Connect a chat

A dialog in three steps; every step has the standard dialog actions.

1. **Role**: two rows, **Writer** (reads and writes this box; one per box) and **Reader** (reads only; any number).
2. **Details**: a **Label** field (hint "Feedback – work chat"; Enter submits), **Expires** as chips (None, 1 day, 7 days, 30 days), and for a Writer on a box that has one, an info line that the old Writer stops working. An error from the app shows under the form in `error`.
3. **Code**: titled "Code for <label>", the code in a monospace well (`bg-app`, hairline, `radius-md`), Copy (becomes Copied) and Done. The note says the code is shown only once and works only on this computer. Escape and a click outside don't close this step; only Done does.

## Connections panel

Opened from the indicator. Rows: each code with a key icon, its label, then "Writer or Reader · Created date · Last used time (or Never used) · Expires date"; "Expired" in `text-muted` for an expired code. A Revoke icon button per code (confirms: "Revoke <label>?"), and under its facts one line in `text-muted`, "Approved <date>" or "Not approved yet" (none for an expired code; approval is per code; there are no session rows). Below the list: the **Writer permission** (three rows, each a muted radio icon, a name and a one-line explanation in `text-muted`: **Append only** (default), **Edit** (append, and change text the AI wrote itself), **Full** (also replace the whole box and delete its text); under Edit a note says text the AI wrote stays the AI's even if the user bolds or ticks it, so the AI may replace it, and that once the user changes a block's words or type it is theirs), the **Ask before each write** switch, the **Allow writes while Noted is closed (no approval)** switch (off by default; a line in `error` warns that while Noted is closed the AI writes without asking, within the Writer permission; turning Ask on also turns this off; disabled, with "Not available while Ask before each write is on", while Ask is on), then the **Activity** list (time, what and by whom, result; an entry made while Noted was closed adds "while Noted was closed"), newest first, the last 100. A problem from the store shows at the top in `error` with a muted icon.
