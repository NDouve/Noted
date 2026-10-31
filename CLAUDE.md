# Noted

Noted is an open-source, OneNote-style notebook built with Flutter (Dart) from one codebase for Windows, macOS, Linux, iOS/iPadOS and Android. Pages are freeform canvases, and everything on a page is a box.

## Source of truth

- **`docs/decisions.md` is the spec.** Read the entries relevant to a task before starting it.
- Active entries are binding. Superseded entries are history: don't reintroduce them.
- If a task conflicts with an active entry, stop and ask the maintainer. Don't work around the conflict.
- Items marked *unverified* must be checked against a primary source before you rely on them.

## Working rules

- **Don't change scope without the maintainer's sign-off.** Discuss first, then build what was agreed.
- Ask before:
  - adding a dependency (check its license against the rule below)
  - changing the page file format
  - changing the Box API
  - creating a new top-level directory or package
- Make small, focused commits with clear messages. Don't change the git author identity that's already configured.
- Before every commit, run `flutter analyze` and `flutter test` and fix what they report.
- Never commit personal information: no real names other than the maintainer's handle, no email addresses, device serials, employer details or account identifiers.

## "Curate" means updating `docs/decisions.md`

When the maintainer says **curate**, update `docs/decisions.md` and nothing else.
- Keep it factual, neutral and app-focused, with no personal context, opinions or discussion history.
- Append new entries in chronological order using the next number, each with: date, status, decision, rationale, and alternatives considered.
- Never delete an entry. Mark a replaced entry superseded and point it to the entry that replaces it.

## Licensing

- Noted is licensed under MPL-2.0. Put the MPL-2.0 header (Exhibit A) at the top of every new source file.
- Dependencies must be MIT, BSD, Apache-2.0 or MPL-2.0.
- Fonts may also be SIL OFL 1.1; ship the font's licence file with it.
- Never copy GPL or AGPL code, including code from the AppFlowy application. You may read it for reference only.

## Architecture invariants (never violate)

1. **Every box type goes through the Box API**, including the plain note box. Box types are modules that can be switched on or off, and the API is versioned.
2. **The core never parses, rewrites or drops data from box types it doesn't support.** That data passes through load, save, sync and encryption byte-for-byte. Unsupported boxes render from their saved read-only snapshot.
3. **Encrypted content exists as plaintext only in the on-screen editor state of an unlocked box.** Plaintext never reaches the page model, disk, autosave, undo history that persists past lock, search indexes, logs, crash reports, thumbnails or conflict copies.
4. **The MCP server is a separate executable with no key access and no decryption code.** It reads saved page data only. AI-facing output is never built from the live screen.
5. **There is no developer-run backend.** All data stays on the user's devices and in their chosen storage.

## Current phase: Prototype 1

**In scope:**
- the canvas (zoom, bounded pan, Fit all, page backgrounds)
- the page tree (pages that become dividers once they have subpages)
- the Box API
- note boxes, using `appflowy_editor` (tables, formulas, equations), and drawing boxes
- binders without passwords
- templates
- file-based sync with per-box conflicts (OneDrive conflict copies)
- the recovery store
- dark mode and the design system in `docs/design`
- the command registry and two built-in toolbar layouts (Tabs and Contextual), switchable in settings
- search (find on page and search all pages)

**Out of scope until the maintainer starts the next phase:**
- binder passwords and encryption
- AI and MCP
- integrations and Microsoft sign-in
- conflict copies from providers other than OneDrive
- customizable toolbars (user-arranged or scripted)
- reMarkable

**Dev loop:** run the app on Windows with `flutter run -d windows`. Test interactively with a mouse and keyboard. Check typing on a page crowded with boxes, editing while zoomed, dragging and resizing boxes, drawing, and sync between two machines. These are the known risk areas.
