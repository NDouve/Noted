# Next run: AI phase 2 — the AI box and writing

All items below are approved by the maintainer.

## 1. Answers to the last report

- Commit the reusable `app/scripts/screenshot-window.ps1` for reviewer-ui: yes.
- Commit the drop and clipboard plugin registrations in `GeneratedPluginRegistrant.swift`: yes.
- Use the maintainer's local date (America/New_York) for decision and changelog dates.

## 2. Invariant 4: new wording (maintainer-approved)

Replace invariant 4 in CLAUDE.md with:

> **4. The MCP server is a separate executable with no key access and no decryption code.**
> - It reads saved page files only. AI-facing output is never built from the live screen.
> - It never writes any file.
> - Its only way to change content is to send a write request to the running Noted app over a local connection.
> - The app decides: it accepts a request only for a box owned by the requesting AI's token, on a page whose AI setting allows writing, and saves it through its normal path. It rejects everything else.
> - If the app isn't running, every write fails.

Move "AI boxes, writing and tokens" into scope in Current phase. Per-AI rules, tiers and lanes stay out.

## 3. AI box module (`packages/boxes/ai`, allowed under delegated authority)

- A box type through the Box API. Insert → AI box (replaces the placeholder in both toolbars).
- Shows the box's content as a note-like document. Text the AI wrote is tagged as AI-written (a small "AI" label on the box and a subtle marker on AI-written blocks); text the user types stays untagged. The tag is stored in the box data, so another AI reading the page sees which text came from an AI (D-054).
- Each AI box records which connection owns it (the token's id, never the secret).
- Text snapshot for search and MCP: the content as markdown, with AI-written blocks marked.

## 4. Connections and tokens

- Gear menu → "AI connections": list, add, rename, revoke.
- Adding one creates a random token. Show the secret once, with a copy button. Store only a hash of it, in local app settings, never in page files.
- On an AI box: "Connected AI" picks which connection owns it.
- Revoking a connection rejects its requests immediately; its boxes keep their content and become user-owned text.

## 5. Write path

- The app listens on a local-only connection (named pipe on Windows; keep it platform-neutral for later). Requests carry the token.
- `noted_mcp` gains `write_box(box_id, content, mode: replace | append)` and `list_my_boxes`. It forwards writes to the app and returns the app's answer. It still never writes a file; keep the test that enforces this and extend it.
- The app accepts a write only if all of these hold: the token is valid and not revoked; the box exists and is owned by that token; the page's AI setting is Box only or Whole page; the box isn't in a conflict (D-031); the page isn't locked. Otherwise it returns a clear error.
- An accepted write goes through the normal save path, is one undo step, and shows in the open page right away.
- Box only pages: `read_page` now returns that AI's own boxes (and only those).
- `noted_mcp` reads the token from an environment variable (`NOTED_TOKEN`). Update `register-mcp.ps1` and docs/mcp.md so registration includes it.

## 6. Tests

- Every acceptance rule above, each with a request that should be rejected.
- Revocation takes effect immediately.
- Writes are undoable and survive a restart.
- App not running: writes fail cleanly; reads still work.
- Box only returns only the AI's own boxes; Off stays invisible.
- `noted_mcp` still never opens a file for writing.
- An end-to-end test: the real app (or a test harness of it) plus the real `noted_mcp` over stdio, writing into an AI box.

## 7. Finish

Analyze, all tests, the integration suite, push, confirm CI, rebuild the release exe and zip, register the new build with Claude Code (with a token for a "Claude Code" connection on this machine). Curate: the new invariant 4 wording (superseding the old), the AI box, connections and tokens, and the write path. Report in the standard format, including a sample `write_box` round trip.
