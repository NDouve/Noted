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
- Build tooling and run history live in a separate private repository.

## Writing

Docs, READMEs, UI text and reports: say it once, in the fewest words that stay exact. No marketing, no restating, no explaining what the reader already knows. Describe only what is built; planned features go in the roadmap, not the README.

## "Curate" means updating `docs/decisions.md`

When the maintainer says **curate**, update `docs/decisions.md` and nothing else.
- Keep it factual, neutral and app-focused, with no personal context, opinions or discussion history.
- Append new entries in chronological order using the next number, each with: date, status, decision, rationale, and alternatives considered.
- The status says who decided: the maintainer, or the build team (the PM or the maintainer's PM chat). The maintainer reviews build-team entries monthly and keeps or supersedes them.
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
4. **The MCP server is a separate executable with no key access and no decryption code.**
   - AI-facing output is built from saved data only, never the live screen. Encrypted content is never readable.
   - It may verify AI codes by hash (no keys, no decryption).
   - It writes only two things: (1) its own access log, append only; (2) an AI box's own data in a page file, and only when Noted isn't running and that box allows writes while Noted is closed, within the Writer permission the box grants. If another writer replaces that page file during the write, the page's previous bytes are kept as a conflict copy beside it; the server never deletes them. It never writes anything else.
   - While Noted is running, every write goes to the app over the local link, and the app decides and saves through its normal path.
5. **There is no developer-run backend.** All data stays on the user's devices and in their chosen storage.

## Current phase: Prototype 1, the AI phase

**In scope:**
- the canvas (zoom, bounded pan, Fit all, page backgrounds)
- the page tree (pages that become dividers once they have subpages)
- the Box API
- note boxes, using `appflowy_editor` (tables, formulas, equations), and drawing boxes
- image and file boxes, with their files in a folder beside the page or embedded in it
- links in notes (Ctrl+K)
- binders without passwords
- templates
- file-based sync with per-box conflicts (OneDrive conflict copies)
- the recovery store
- dark mode and the design system in `docs/design`
- the command registry and two built-in toolbar layouts (Tabs and Contextual), switchable in settings
- search (find on page and search all pages)
- the MCP server (`packages/noted_mcp`, a separate executable) and page and binder AI access (Open, Privileged, Guarded; Guarded by default; pages inherit and can only tighten)
- AI boxes, AI writing through the app, and per-box codes (Writer and Reader, with new-connection approval, ask before each write, an activity log and expiry); Privileged pages and binders use Reader codes
- the Page settings and Binder settings panel (background, images and files, AI access, box types allowed)
- module availability per page and binder (a disallowed box type behaves like a switched-off module)
- iPad and Android test builds (sideloaded, notes stored on the device)
- Microsoft sign-in and OneDrive sync for the iPad and Android builds, through Microsoft Graph (in progress; `runs/designs/2026-11-05-onedrive-sync.md` in the build repository)
- storage in iCloud Drive, Google Drive and WebDAV alongside OneDrive, for the iPad, Android and browser builds
- every in-scope cloud works fully, conflict copies included: iCloud Drive, Google Drive and WebDAV behave as OneDrive does, and a provider-specific gap is a bug (0163)
- Google sign-in, for Google Drive only
- import: text and markdown files, images, PDF pages as images, a spreadsheet as a table or as an image, a Word document as text or as an image, a slide as an image
- export: per box in the formats its module lists, and several boxes together through a print-preview layout
- sharing and opening a binder as a plain `.zip` of its folder
- the browser version (a static web build, no server)

**Out of scope until the maintainer starts the next phase:**
- binder passwords and encryption
- per-AI rules, tiers and lanes
- other integrations, Microsoft sign-in for anything beyond OneDrive sync, and Google sign-in for anything beyond Google Drive
- Dropbox and other storage providers
- full Word, PowerPoint and Excel boxes
- customizable toolbars (user-arranged or scripted)
- reMarkable

**Dev loop:** run the app on Windows with `flutter run -d windows`. Test interactively with a mouse and keyboard. Check typing on a page crowded with boxes, editing while zoomed, dragging and resizing boxes, drawing, and sync between two machines. These are the known risk areas.
