# Noted — Decision Log

A dated record of Noted's product and technical decisions. Each entry gives the decision, the reasoning, and the alternatives considered. Entries are listed in the order they were decided. A superseded entry stays in the log with a pointer to the entry that replaced it.

**Status values:** Active · Superseded · Deferred
**Unverified:** marks a claim that hasn't been confirmed against a primary source yet.

---

## 0001 — Framework: Flutter (Dart)
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:** Build with Flutter, using one codebase for Windows, macOS, Linux, iOS/iPadOS and Android.
- **Rationale:** It was the only evaluated option that covers all five platforms from a single codebase, runs without a WebView/Chromium runtime, and has a usable free rich-text editor.
- **Alternatives considered:**

| Option | Reason not chosen |
|---|---|
| WPF | Windows only. |
| Avalonia + Pro Rich Text Editor | The rich-text component is a paid commercial license. |
| Avalonia + community rich-text editors | Pre-1.0 maturity. |
| Tauri / WebView2 stacks, Electron | Requirement: no browser-engine runtime. Measured WebView2 memory use is comparable to Electron's, and WebView2 processes aren't shared across apps. |
| .NET MAUI | No official Linux support; no built-in rich text. |
| Uno Platform | Its Skia rich-edit control is experimental. |
| Flutter + flutter_quill | Frequent breaking changes; AppFlowy moved away from it. |
| Separate native app per platform | Five codebases to maintain. |
| Obsidian with plugins | No public plugin API for live canvas manipulation, JSON Canvas offers only four node types, any plugin can read every file (so per-box isolation can't be enforced), and it runs on Electron. |

## 0002 — Pages are freeform canvases
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:** Every page is a freeform canvas, not a linear or block document. Everything on a page is a box.
- **Rationale:** OneNote-style freedom to place content anywhere, with a single model for every type of content.

## 0003 — Canvas implementation
- **Date:** 2026-10-24
- **Status:** Active; extended by 0083 (zoom anchoring)
- **Decision:** A custom canvas built on Flutter's `InteractiveViewer`:
  - Zoom and pan, with panning bounded to the content plus padding.
  - A "Fit all" control.
  - Bounds use `boundaryMargin`, zoom limits use `minScale`/`maxScale`, and the view is controlled programmatically through `TransformationController`.
- **Rationale:** Bounded panning prevents getting lost on an empty canvas. Existing canvas packages (infinite_canvas, infinite_canvas_viewer, canvas_kit) are early-stage and are used for reference only.

## 0004 — One text editor component: appflowy_editor
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:** `appflowy_editor` is the editor inside every box that holds text.
- **Rationale:**
  - Supports multiple independent instances, focus switching, auto-expanding and fixed-height modes, and tables.
  - Dual-licensed AGPL-3.0 / MPL-2.0, and the MPL option fits 0021.
  - One canvas plus one editor component is simpler than maintaining two editor systems.
- **Notes:** Native format is its own JSON. It imports Markdown and Quill Delta. Markdown round-trip fidelity is unverified.

## 0005 — Special boxes
- **Date:** 2026-10-24
- **Status:** Active; sizing rule superseded by 0039
- **Decision:**
  - Special boxes have a fixed size and scroll internally; resizing a box reveals more of its content.
  - A box's type is permanent once it's created.
  - Types: AI, encrypted, link, meeting (0023), drawing (0016). reMarkable is deferred (0030).
- **Rationale:** Predictable layout, and simple security boundaries: an encrypted box can never become a plain box.

## 0006 — Page file format
- **Date:** 2026-10-24
- **Status:** Active (candidate)
- **Decision:** Use JSON Canvas 1.0. Custom box types are stored as extra fields on standard node types.
- **Rationale:** An open, documented format that stays readable outside the app.
- **Open:** whether the extra-field approach covers every box type.

## 0007 — Local-first storage, no developer backend
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:**
  - Notes are plain files.
  - Each device keeps a full local copy of everything it can reach.
  - Storage locations: SharePoint/OneDrive, Google Drive, a local always-on computer, a folder or network share, or WebDAV.
  - Sync drivers are swappable, and integrations are separate from storage.
- **Rationale:** Works offline, with no hosting cost or liability for user data. Users keep their data where they already store it.
- **Alternatives considered:** a hosted cloud service (cost, liability, platform security assessments); peer-to-peer-only sync (devices would have to be online at the same time).

## 0008 — AI connects through MCP
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:**
  - Any AI connects through a local MCP server; there is no vendor-specific integration.
  - An AI writes only into its own AI box(es), and conversation with it happens there.
  - Each AI box can be set to AI-write, AI-read, or both, and a page can hold several AI boxes.
- **Rationale:** Not tied to one vendor, with a single defined surface for AI interaction.

## 0009 — Encrypted boxes
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:** An encrypted box always appears encrypted to any AI, even while it's unlocked on screen. The protection comes from encryption, not from filtering.
  - In memory and on disk, the page model holds encrypted content only as ciphertext. Plaintext exists only in the box's on-screen editor state.
  - The MCP server is a separate executable with no key access and no decryption code. AI sees a placeholder, never ciphertext.
  - Keys are unlocked by passphrase (Argon2id), and per device through OS secure storage plus biometrics/PIN where available. Linux requires the passphrase every time.
  - Boxes relock automatically on timeout and when the app goes to the background. A lost passphrase can't be recovered.
  - AI-facing output is never built from the live screen.
  - Plaintext never reaches autosave, conflict copies, persisted undo, the search index, logs, crash reports, or thumbnails.
  - Screen capture is mitigated only partially: Windows display affinity and Android secure flags.
- **Rationale:** A filter can be bypassed; encryption can't. A passphrase is used because notes sync across devices, and keys tied to one device couldn't decrypt boxes created on another.
- **Alternatives considered:** a "skip encrypted boxes" filter; reusing the Microsoft/Google password (impossible under OAuth); click-to-unlock; a short PIN as the only key.

## 0010 — Copying from encrypted boxes
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:**
  - Every copy from an encrypted box is a secure copy with a visible countdown and a configurable timed clear.
  - The copy is excluded from clipboard history and cloud clipboard sync, using platform-specific mechanisms on Windows, macOS, KDE, Android and iOS.
  - The clipboard is cleared only if it still holds the app's item, and also on lock and on quit.
- **Rationale:** Limits how long copied secrets remain exposed.

## 0011 — AI content is untrusted
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:**
  - AI output is rendered as text; links and commands are never executed automatically.
  - Page content is treated as a possible prompt-injection path into a connected AI.
- **Rationale:** Prompt injection risk.

## 0012 — Integration security
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:**
  - Microsoft 365: delegated permissions only, least privilege.
  - Google: the `drive.file` scope; no Gmail integration.
  - OAuth tokens are stored in the OS keychain.
- **Rationale:** Least exposure. Restricted Google scopes trigger a recurring third-party security assessment.

## 0013 — Link boxes are generic
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:** A link box connects to any SharePoint list, Google Sheet, or URL, and the user chooses which field is the unique ID.
- **Rationale:** Works with any list, without hard-coding a particular organization's structure.

## 0014 — Notebook → section → page hierarchy
- **Date:** 2026-10-24
- **Status:** Superseded by 0025

## 0015 — Plain note boxes grow with content
- **Date:** 2026-10-24
- **Status:** Active; sizing superseded by 0039
- **Decision:** Clicking anywhere on a page creates a plain note box, which grows as content is added.

## 0016 — Ink anywhere on the page
- **Date:** 2026-10-24
- **Status:** Active; input rules superseded by 0033; drawing is delivered as a box module (0034)
- **Decision:** Drawing is possible anywhere on a page. A stroke creates a drawing box, or extends an existing one, and the box grows with the stroke. Drawing boxes can overlap other boxes.
- **Requirement:** no skipped or broken strokes, including fast, long strokes and strokes that cause a box to grow.
- **Implementation rules:**
  - The stroke in progress is drawn on a top overlay.
  - The canvas holds the pointer for the whole stroke.
  - Box and page bounds are updated when the stroke is committed, never by a rebuild under the pointer mid-stroke.
- **Input rules:**
  - A stylus inks, a finger pans, and a mouse or trackpad selects.
  - Devices without an active stylus get a draw-mode toggle.
- **Libraries:** perfect_freehand (MIT).

## 0017 — Tables and equations
- **Date:** 2026-10-24
- **Status:** Active; implemented by 0047, 0048 and 0055
- **Decision:** Text boxes support tables, plus inline and block LaTeX equations.
- **Notes:** Tables come from appflowy_editor's table block. Where the equation block's code will come from is open; see 0022.

## 0018 — Platforms and reference test devices
- **Date:** 2026-10-24
- **Status:** Active, extended by 0032
- **Decision:**
  - Targets: Windows, macOS, Linux, iOS/iPadOS and Android.
  - Freeform drawing must be validated on a Windows pen tablet, an iPad with stylus, and an Android phone without an active stylus.
  - The macOS build must run on Intel Macs on macOS 12, the current Flutter minimum.
- **Notes:** Windows pen pressure, iPad stylus input rate and prediction, and Android drawing latency in Flutter are unverified.

## 0019 — Encryption scope
- **Date:** 2026-10-24
- **Status:** Active, extended by 0026
- **Decision:** Encrypted boxes are the main way to encrypt content. There is no app-wide encryption.
- **Rationale:** Content inherits the protections of wherever it's stored. Encrypted boxes cover what storage protections don't: AI, and anyone with access to the storage location.

## 0020 — Sync conflict handling, per box
- **Date:** 2026-10-24
- **Status:** Active; implemented by 0051–0053
- **Decision:**
  - Each box records its revision and the revision it was edited from. When two devices edit the same box from the same revision, the box is marked conflicted.
  - A conflicted box is highlighted, and so is its page tab. Opening it shows both versions side by side, labeled with device and time.
  - Resolution options: keep mine, keep theirs, keep both (the second version is placed as a new, movable box), or edit manually in a merge view.
  - Automatic rules:
    - Moves and resizes: last write wins.
    - Delete on one device versus edit on another: the edit is kept and flagged.
    - Drawing strokes: merged as a union.
    - Encrypted boxes: resolved only after unlocking.
    - AI can't write to a conflicted box.
  - Conflict copies created by cloud providers are detected and merged per box.
- **Rationale:** No silent data loss, and no whole-page conflict copies.

## 0021 — Open source under MPL-2.0
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:**
  - Noted is licensed under the Mozilla Public License 2.0.
  - Dependencies must use MPL-compatible licenses (MIT, BSD, Apache-2.0, MPL-2.0). GPL/AGPL code is used as reference only and is never copied.
  - Dependency licenses are audited before each release.
- **Rationale:**
  - Compatible with the editor dependency's license.
  - Keeps changes to Noted's own files open while allowing broader reuse.
  - Includes a patent grant and a warranty disclaimer.
  - Avoids GPL's whole-application copyleft and its friction with app-store distribution.
- **Alternatives considered:** Apache-2.0; GPL-3.0/AGPL-3.0.

## 0022 — Equation block sourcing
- **Date:** 2026-10-24
- **Status:** Superseded by 0048 (verified: the pinned `appflowy_editor` ships no math block; the block is built in-house on `flutter_math_fork`, Apache-2.0)
- **Note:** The AppFlowy application has a math block, but whether it ships in the `appflowy_editor` package is unverified. If it isn't in the package, the block will be built in-house on a permissively licensed renderer, following 0021.

## 0023 — Meeting box
- **Date:** 2026-10-24
- **Status:** Active (supersedes the earlier "pages per recurring meeting" concept)
- **Decision:**
  - A meeting box can be added to any page and links to a single meeting or to a series.
  - Pages are never created automatically for meetings.
  - A page's tab is highlighted while a meeting linked on that page is in progress.
- **Implementation (Microsoft Graph):**
  - The box stores the event ID, or `seriesMasterId` for a series.
  - Highlighting uses `calendarView`, matching occurrences and exceptions by `seriesMasterId`.
  - Permission: `Calendars.ReadBasic` (delegated).
- **Notes:** The Google Calendar equivalent (`recurringEventId`) is unverified.

## 0024 — Overlapping boxes; ink over encrypted boxes
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:**
  - Boxes may overlap.
  - Ink drawn across an encrypted box is ordinary, unencrypted drawing-box ink that overlaps it.
  - To draw inside an encrypted box, the user clicks into the unlocked box first; those strokes are encrypted with the box.
- **Rationale:** Encrypted content is only ever created by an explicit action.

## 0025 — Page tree with elevation
- **Date:** 2026-10-24
- **Status:** Active (supersedes 0014)
- **Decision:**
  - The page is the default unit.
  - Any page can be elevated to a divider: a full page with its own canvas, plus subpages beneath it.
  - "Divider" is only the label for a page that has subpages, not a separate type.
  - Nesting depth is unlimited.
- **Rationale:** Structure is added only when content grows into it. A divider can hold its own content, for example shared reference material above its subpages.

## 0026 — Optional binders
- **Date:** 2026-10-24
- **Status:** Active (supersedes an earlier same-day version that required a binder at the top level); implemented without passwords, locking or encryption by 0049
- **Decision:** Binders are optional. Standalone pages use app-wide defaults and are stored locally unless configured otherwise. A binder is an environment that holds a page tree:
  - New pages inside a binder take the binder's defaults.
  - A cover page, visible while locked, shows title, description and owner (all editable) and the last-edited date (automatic).
  - Settings, available after unlocking: storage location, defaults, color, templates and password.
  - Each binder has a color applied to its navigation, and its own page templates.
  - Optional password, chosen per binder:
    - **Lock** (default): an in-app lock. The files stay readable at the storage location.
    - **Encrypt:** the files are encrypted at rest, with a warning when the storage is SharePoint or another organizational tenant.
  - A locked binder is invisible to AI. Once it's unlocked, page AI settings apply, and asking an AI to review a page inside a locked binder prompts an unlock.
  - For an encrypted binder, the app passes decrypted page content to the MCP server only while the binder is unlocked, filtered by page AI settings. The MCP server never holds the binder key.
  - Encrypted boxes keep their own keys and stay placeholders to AI even when the binder is unlocked.
- **Rationale:** Single-device local use doesn't need binders. Binders add value in multi-device setups and for projects that need their own environment. Encrypting files on organizational storage stops content inspection: eDiscovery and legal hold, DLP and retention labels, search, and assistant features. Lock mode provides protection without that conflict.

## 0027 — Configuration inheritance and exemptions
- **Date:** 2026-10-24
- **Status:** Active; storage prompt implemented by 0056
- **Decision:**
  - Every page has a configuration: storage location, AI setting, and other settings.
  - A page inherits its parent's configuration (a page, a binder, or the app defaults). An exemption overrides it for that page and everything below, until a lower page has its own exemption.
  - Creating a top-level standalone page prompts for a storage location.
  - Moving a page applies the new parent's configuration. When the storage location changes, the files move (copy, verify, delete). Moves made offline are queued. Exemptions travel with the page.
  - Each page file records its own parent, and each device rebuilds the tree from the pages it can reach.
  - A page stored somewhere a device can't reach is shown greyed out as "on another device".

## 0028 — AI read scope per page
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:**
  - Each page's AI setting is one of:
    - **Off:** no AI boxes, and the page is invisible to MCP.
    - **Box only:** an AI reads and writes only its own boxes.
    - **Whole page:** an AI reads every box and writes only to its own boxes.
  - The setting follows configuration inheritance (0027).
  - AI tokens carry identity only and are revocable. The MCP server checks the page setting on every request.
  - Link and meeting boxes are exposed to AI only as cached values, never fetched live; the MCP server holds no OAuth tokens.
  - Other AI boxes on the page are tagged as AI-authored.
- **Rationale:** Per-page control over what an AI can see, without letting AI access reach into connected services.

## 0029 — Envelope encryption and passphrase scope
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:**
  - Each encrypted box has its own random data key, which is wrapped with a passphrase-derived key (Argon2id). Content is encrypted with AES-256-GCM or XChaCha20-Poly1305.
  - Moving a box between passphrase scopes re-wraps only its data key.
  - There is one passphrase per binder, plus an app-wide passphrase for standalone pages. An exemption can carry its own passphrase, which applies to that page and everything below it.
- **Rationale:** Moves are instant and never re-encrypt content.
- **Alternative considered:** re-encrypting content on every move.

## 0030 — reMarkable integration
- **Date:** 2026-10-24
- **Status:** Deferred
- **Note:** Planned as a later phase:
  - Push a blank page to the tablet.
  - Return its handwriting into a reMarkable box.
  - Push typed text back to the tablet.

  reMarkable strokes will use the same stroke model as drawing boxes. The tablet's file format is proprietary, and no Dart parser is known.

## 0031 — Name and description
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:**
  - The application and repository are named **Noted**. The Apple App Store listing will use a variant of the name, because "Noted" is already in use there.
  - Description: "Noted is an open-source, OneNote-style notebook for Windows, macOS, Linux, iOS and Android. Pages are freeform canvases: type or draw anywhere, nest subpages under any page, and add special boxes for meetings, linked tasks, any AI, or encrypted text AI can't read. Notes stay as plain files wherever you store them."

## 0032 — macOS reference device
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:** The macOS reference test device is a Mac Pro (Late 2013): Intel Xeon, AMD FirePro graphics, running macOS 12 Monterey, the last officially supported release for that model. macOS testing on this device takes place after the initial prototypes, which run on Windows, iPadOS and Android.
- **Rationale:** It confirms the app installs and runs on older Intel hardware at Flutter's current minimum macOS version (12.0).

## 0033 — Tool-based input rules
- **Date:** 2026-10-24
- **Status:** Active (supersedes the input rules in 0016)
- **Decision:** The action an input performs depends on the selected tool, not on the device, following OneNote's Draw model.
  - **Draw tool:** mouse, trackpad, finger and stylus all draw.
  - **Select or type tool:** mouse, trackpad and finger select or type.
  - A stylus may default to ink in any mode.
- **Rationale:** Drawing with a mouse is a standard workflow. A rule based on device type would block it.

## 0034 — Boxes as modules (two stages)
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:** Base Noted consists of the canvas, the page tree, binders, plain note boxes, storage and sync. Every other box type is a module that can be switched on or off, and all of them implement a single versioned Box API. The API defines:
  - type ID and data fields
  - rendering and editing
  - conflict merge
  - AI exposure
  - required permissions
  - settings
  - snapshot (0035)

  Delivery is in two stages:
  - **Stage 1, compiled modules:** first-party boxes (AI, encrypted, link, meeting, drawing, reMarkable) are compiled modules. New box types are added in source, by contribution or fork, using a published template and guide. Box contributions require security review, because compiled modules run with full app privileges.
  - **Stage 2, downloadable boxes:** a sandboxed plugin host, itself delivered as one more box type, loads box modules at runtime. The planned sandbox is WebAssembly. Each downloadable box declares the permissions it needs, and the user approves them at install. A downloadable box can access only its own data, never encryption keys, encrypted boxes or other boxes, and is subject to the same AI exposure rules as any other box. Installation is from a file or URL initially.
- **Rationale:** Supports both contribution in source and runtime extension. The plain note box is the first module built on the Box API, so the API is proven before external authors rely on it.
- **Constraints:** App Store guideline 2.5.2 restricts downloading code that adds features, so iOS builds may ship without the stage-2 host or with a restricted one. Google Play policy on downloaded executable code may also apply. Whether either covers sandboxed WebAssembly is unverified. Desktop platforms have no store restriction.

## 0035 — Box snapshots and untouched pass-through
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:**
  - Each box stores a read-only snapshot (text, an image, or both) alongside its data. The snapshot is updated whenever the box is edited on a device that supports it.
  - A device that cannot run a box type shows the snapshot read-only, marked as editable on other devices. This applies to a module that is switched off, a platform without the plugin host, or a box type that isn't installed or comes from a newer app version.
  - The core never parses, rewrites or removes data from box types it doesn't support. That data passes through sync, decryption and re-encryption byte-for-byte.
  - Snapshots follow the encryption of their box and binder, and are never stored in plaintext.
  - A conflict on a box the device can't run keeps both versions until a supporting device resolves it.
- **Rationale:** Content stays visible and is never lost on devices that can't run a given box type.

## 0036 — Prototype sequence and development setup
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:**
  - The primary development and test machine is a Windows laptop without pen input. Development uses Claude Code with the local Flutter toolchain.
  - Prototype 1 covers the canvas, the page tree, the Box API, plain note boxes and editor boxes, validated on that machine.
  - Drawing is then added as a box module. Pen and touch validation on a Windows pen tablet, an iPad and an Android phone comes after that.
  - Prototype 1 is built by a single agent. Later phases, whose modules can be built in parallel, use a coordinating agent with separate writer and reviewer agents. Security-critical modules (encryption, the MCP boundary, clipboard handling) are written and reviewed by the most capable model.
- **Rationale:** The core canvas is tightly coupled and most of it can be evaluated without pen hardware. Parallel agents pay off once modules have clear boundaries.

## 0037 — appflowy_editor pinned to an upstream commit
- **Date:** 2026-10-24
- **Status:** Active
- **Decision:**
  - `appflowy_editor` comes from the upstream Git repository (AppFlowy-IO/appflowy-editor) at commit `01eccc6ee36bd07698bd80915289fe7070478cd2`, not from pub.dev.
  - Only the plain note box module depends on it directly; the app gets the editor's localization delegates through that module.
  - Noted returns to a pub.dev release once one includes the fix, and the dependency license audit is re-run then.
- **Rationale:**
  - The latest pub.dev release, 6.2.0, doesn't compile with Flutter 3.47. Flutter added `TextInputClient.onFocusReceived`, and the editor's `DeltaTextInputClient` mixin implements that interface without the new method.
  - The upstream main branch includes the fix. It is versioned 6.1.0 and has diverged from the 6.2.0 release.
  - The license is unchanged: the MPL-2.0 option of the dual license (0004, 0021).
- **Alternatives considered:**

| Option | Reason not chosen |
|---|---|
| Vendor 6.2.0 with a one-line patch | Carries a vendored copy in a new top-level directory until upstream releases. |
| Pin an older Flutter SDK | Changes the development setup and holds Flutter back. |

## 0038 — Page storage location for Prototype 1
- **Date:** 2026-10-24
- **Status:** Active; the default page folder became a setting in 0084
- **Decision:**
  - Prototype 1 stores pages as `<pageId>.canvas` files in one local folder: `%APPDATA%\Noted\pages` on Windows, `~/.noted/pages` on other platforms.
  - `--dart-define=NOTED_PAGES_DIR=<path>` overrides the folder.
  - The storage locations of 0007 and the storage prompt of 0027 come in later phases.
- **Rationale:** The Documents folder is often redirected into a cloud-synced folder, and sync is out of scope for Prototype 1.
- **Alternatives considered:** the Documents folder.

## 0039 — Box resizing and auto height
- **Date:** 2026-10-24
- **Status:** Active (supersedes the sizing rules in 0005 and 0015)
- **Decision:**
  - Every box, including the plain note box, resizes horizontally and vertically with the same handles: left, right and bottom edges, and bottom corners.
  - A box whose type grows with its content (the plain note box) grows until the user resizes its height. From then on it keeps the set height and scrolls internally when its content overflows.
  - Double-clicking the bottom edge returns the box to growing with its content.
  - Changing only the width keeps a growing box growing.
  - The setting is stored per box as `"fixedHeight": true` in the box's `noted` header; absent means false. Page-level undo restores it together with the box's bounds.
  - Ctrl+wheel over a box that scrolls internally zooms the canvas; the wheel alone scrolls the box.
- **Rationale:** One resize behavior for every box, while a new note still sizes itself to what is typed.
- **Alternatives considered:** plain note boxes that only grow (0015); fixed size and internal scrolling for special boxes only (0005).

## 0040 — Box API 0.2: canvas tools and content diffs
- **Date:** 2026-10-25
- **Status:** Active; extended by 0062 (Box API 0.3)
- **Decision:**
  - The Box API is at version 0.2. While the major version is 0, a module must target the host's exact version.
  - **Canvas tools:** a module can add tools to the canvas, each with an id, label, icon, keyboard shortcut, cursor and toolbar options.
    - While a tool is active, it receives every pointer that goes down on the canvas (any button but the middle one) as a session: start, updates, end or cancel.
    - The session paints its live feedback on an overlay above every box.
    - Boxes receive no pointer input while a tool is active. Wheel, Ctrl+wheel, middle-drag and touchpad gestures still pan and zoom the canvas.
    - Page bounds stay fixed until the session ends (0016).
    - The select/type tool is built in and selected with V or Escape.
  - **Content diffs (`BoxEdit`):** a module can record a change to a box's content in page-level undo as a diff it defines. The core replays the diff through the box's codec without inspecting it, and restores the box's bounds if the edit changed them.
  - **`delete(undoTo:)`:** a tool that empties a box before deleting it passes the box as it was. One undo then restores the box with its content.
- **Rationale:** Drawing is a module (0034), and ink anywhere (0016) needs input across the whole canvas without the core knowing about strokes. Undo as diffs avoids keeping copies of large box content in memory.
- **Alternatives considered:** page undo that stores full copies of box content; a separate undo stack inside each module.

## 0041 — Drawing box data format
- **Date:** 2026-10-25
- **Status:** Active
- **Decision:**
  - Type `noted.drawing`, data version 1. The data has three fields:
    - `origin`: `[x, y]`.
    - `strokes`: each stroke has `id`; `tool`; `color` (`#AARRGGBB`); `size` (width in page pixels); `pressure` (whether the device reported pressure); `t0` (start time, milliseconds since the epoch); and `pts`, a flat list of x, y, pressure and time for every point. x and y are content coordinates rounded to 0.1 px, pressure is rounded to 0.01, and time is milliseconds since `t0`.
    - `erased`: the ids of deleted strokes.
  - A point is drawn at: the box's top-left corner, plus `origin`, plus the point, minus the box's internal scroll offset. Growing a box to the left or upward changes only `origin`; strokes are never rewritten.
  - Strokes are kept in order of `t0`, then `id`.
  - Merge: the union of strokes by id, minus every id either side erased. The local `origin` is kept.
  - A drawing box has no text snapshot, and an AI sees only a "Drawing" placeholder. Where its image snapshot is stored is not decided yet (see Open items).
- **Rationale:**
  - The stroke model is meant to be shared with reMarkable strokes (0030).
  - Erased ids keep a union merge (0020) from bringing erased strokes back.
  - Storing strokes relative to an origin keeps growth and box moves from rewriting stroke data.
- **Alternatives considered:**

| Option | Reason not chosen |
|---|---|
| Strokes in page coordinates | Moving a box would rewrite every stroke. |
| No record of erased strokes | A union merge would bring erased strokes back. |

## 0042 — Adding strokes to drawing boxes
- **Date:** 2026-10-25
- **Status:** Active
- **Decision:**
  - A stroke that starts inside a drawing box, or within 32 page pixels of one, is added to the topmost such box, which grows to fit it. Any other stroke starts a new drawing box, which may overlap other boxes (0024).
  - The 32 px join distance is a constant (`joinDistance`), to be tuned through use.
  - A stroke that runs past the edge of a resized drawing box grows the box. Resizing a drawing box only crops the visible area; the rest scrolls with the wheel or a two-finger touchpad scroll, using the select tool.
- **Rationale:** Handwriting of nearby words and shapes stays in one box, and a drawing never loses ink to a resize.
- **Alternatives considered:** a new box for every stroke; adding to a box only when the stroke starts inside it.

## 0043 — Auto-scroll while using a canvas tool
- **Date:** 2026-10-25
- **Status:** Active
- **Decision:**
  - The live feedback of a tool session, such as the stroke being drawn, is clipped to the canvas. It never paints over the page tree or other UI.
  - When the pointer is within 40 screen pixels of a canvas edge, or past it, the canvas pans toward that edge. The speed grows with the distance into or past the edge: 600 px/s at the edge, up to 3000 px/s.
  - While the canvas pans, the session keeps receiving samples at the pointer's position, in page coordinates.
  - During a session, the pan bounds include everything the view has shown in that session, so a stroke can continue into new space.
- **Rationale:** A stroke can carry on past the visible area without lifting the pen, as a text selection does in a document.
- **Alternatives considered:** no auto-scroll, with strokes ending at the canvas edge; auto-scroll at a fixed speed.

## 0044 — Caret handling in the plain note box
- **Date:** 2026-10-25
- **Status:** Active
- **Decision:**
  - `appflowy_editor`'s auto-scroll is switched off in plain note boxes. The note box keeps the caret visible itself: after each selection change in a fixed-height note, if the caret is outside the visible area, the note scrolls once, just enough to show it, with a 4 px margin.
  - The caret is measured from its own block, so this works at any canvas zoom.
  - Arrow up and arrow down, with and without Shift, are replaced with versions that work at any zoom.
  - Trade-off: dragging a text selection past the edge of a fixed-height note doesn't scroll it. The wheel, touchpad, arrow keys and typing do.
- **Rationale:**
  - `appflowy_editor` keeps a 220 px square around the caret in view. In a smaller viewport, its auto-scroller scrolls up and down without end, which froze the app.
  - Its caret rectangle and its document hit test use unscaled sizes on a zoomed canvas, so its auto-scroll aims at the wrong place and its arrow keys skip or repeat lines when zoomed out.
- **Alternatives considered:** keeping appflowy's auto-scroll with a smaller square (it still aims at the wrong place when zoomed); no internal scrolling in notes.
- **Notes:** The zoom problems are to be reported upstream to appflowy-editor.

## 0045 — Two-finger touchpad scrolling over boxes
- **Date:** 2026-10-25
- **Status:** Active
- **Decision:**
  - A box that can scroll its content claims a two-finger touchpad gesture when the gesture starts over it. The box scrolls, and the canvas doesn't pan for that gesture.
  - For a claimed gesture, the canvas only zooms on a pinch.
  - A box that has nothing to scroll doesn't claim the gesture, so the canvas pans as usual.
  - It applies to fixed-height note boxes with overflowing text, and to cropped drawing boxes with hidden ink.
  - It doesn't apply while a canvas tool is active, because boxes then receive no pointer input (0040).
- **Rationale:** A touchpad scroll arrives as pan/zoom gesture events rather than wheel events. Flutter doesn't decide between nested widgets for those, so the canvas panned while a note scrolled. A claim gives the touchpad the same behavior as the wheel.
- **Alternatives considered:** letting the canvas always pan (the box and canvas move together); letting a box take the pinch too (pinch-to-zoom would stop working over boxes).

## 0046 — Page tree management in the sidebar
- **Date:** 2026-10-25
- **Status:** Active
- **Decision:**
  - The sidebar supports creating pages and subpages, renaming, deleting, moving up and down, indenting (under the sibling above) and outdenting (after the parent).
  - Every action is in a page's right-click menu and its "⋯" menu. Items that don't apply are disabled.
  - **Drag-and-drop** onto a row:
    - the top quarter places the page before that row
    - the middle half places it inside, as the row's last subpage, which makes that row a divider (0025)
    - the bottom quarter places it after.
  - Dropping on the empty area below the list moves the page to the end of its location's top level. A drop indicator shows the result.
  - A page can't be moved under itself or one of its own descendants. Subpages move with their page.
  - Moving within a location changes only the page's `parentId` and `order` header values. Siblings are renumbered, and only pages whose parent or order changed are written. The open page changes through its canvas controller.
  - **Delete** asks for confirmation, then shows an Undo snackbar for 10 seconds. Undo writes the deleted page and its subpages back exactly and reopens the page that was open. Only the most recent delete can be undone.
  - Dividers collapse and expand; the state lasts for the session.
- **Rationale:** Structure is added and changed where it is shown, and a mistaken delete can be reversed.
- **Alternatives considered:** a multi-level delete undo history; press-and-hold before a drag starts (it slows down mouse use).

## 0047 — Tables in note boxes
- **Date:** 2026-10-25
- **Status:** Active (implements the table part of 0017)
- **Decision:**
  - Note boxes use `appflowy_editor`'s own table block, inserted with the `/` menu's "Table" item. The box grows to fit the table.
  - In the text snapshot (0035), a table gives one line per row, with cells joined by ` | `.
- **Rationale:** The table block ships with the editor already in use (0004).

## 0048 — Equations in note boxes
- **Date:** 2026-10-25
- **Status:** Active (implements the equation part of 0017; supersedes 0022)
- **Decision:**
  - The pinned `appflowy_editor` has no math block, so the equation components are built in-house against its public block API. No AppFlowy application code is used.
  - Rendering uses `flutter_math_fork` (Apache-2.0; its bundled KaTeX fonts are MIT).
  - **Block equation:**
    - Stored as `{"type":"math_equation","data":{"formula":"<LaTeX>"}}`.
    - Inserted with the `/` menu's "Equation" item, or by typing `$$` and a space.
  - **Inline equation:**
    - Stored as a one-character U+FFFC text run with the attribute `"formula":"<LaTeX>"`.
    - Inserted by typing `$<LaTeX>$`. A formula that is empty, or starts or ends with a space, isn't converted, so amounts like "$5 and $10" stay as text.
  - Clicking an equation opens a dialog with a live preview. Invalid LaTeX shows an error placeholder.
  - In the text snapshot, block equations appear as `$$<LaTeX>$$` and inline ones as `$<LaTeX>$`.
  - Equations also work inside table cells (0055).
  - The note data version stays 1.
- **Rationale:** The editor package has no math block, and `flutter_math_fork` is a maintained renderer under a permitted license (0021).
- **Alternatives considered:** the AppFlowy application's math block (AGPL, not permitted).

## 0049 — Optional binders, without passwords
- **Date:** 2026-10-25
- **Status:** Active (implements 0026 except passwords, locking and encryption); "New binder asks for a folder" superseded by 0084
- **Decision:**
  - **Creating a binder:** "New binder" asks for a folder. A folder that already has a binder file is opened, never overwritten. Otherwise a binder file is created, and any page files already in the folder become its pages.
  - **Cover page:** title, description and owner are editable. It also shows last edited (the latest change to the binder's files), the storage folder, and a color chosen from an 8-color palette. The color is applied to the binder's sidebar entries.
  - **Sidebar:** standalone pages first, then one collapsible section per binder. Every page operation (0046) works inside a section.
  - New pages in a binder are saved in its folder. Subpages are saved in their parent's folder (0027).
  - **Moving into or out of a binder:** dragging a page onto a binder header or into another location moves its file and its subpages' files:
    1. Each file is written to the target folder, read back and compared byte for byte.
    2. Only when every file checks out are the source files deleted.
    3. On any failure, the copies are removed and the sources stay.
  - A listed binder folder that is missing, or has no binder file, is shown greyed as unavailable and is never recreated. "Remove from sidebar" never deletes files.
- **Rationale:** Binders are optional (0026). Verifying every copy before deleting anything means a move can't lose or split a page tree.
- **Alternatives considered:** deleting each source right after its own copy is verified (a failure partway would leave a tree split across two folders).

## 0050 — Binder file and binders.json
- **Date:** 2026-10-25
- **Status:** Active; the damaged-binder display is superseded by 0060
- **Decision:**
  - **The binder file:** `noted-binder.json` in the binder folder: `{"format":1,"binderId":"<16 hex>","title":"…","description":"…","owner":"…","color":"#AARRGGBB","created":<ms since the epoch>}`.
    - It is read and written so unknown fields round-trip byte for byte.
    - A file with a newer format, a missing `binderId` or invalid JSON is shown as "Can't open" and never written.
  - **The binder list:** the binder folders the app knows are listed in `binders.json` in the app settings folder (`%APPDATA%\Noted\binders.json` on Windows, `~/.noted/binders.json` elsewhere), next to the default pages folder: `{"format":1,"binders":["<absolute folder path>", …]}`.
    - Unknown fields are kept.
    - A corrupt list is renamed to `binders.json.bad` before it is replaced.
  - **Watching:** `noted-binder.json` is watched like page files (0051). Cover edits made on another machine reload the sidebar and the open cover; a field with unsaved typing keeps the typing.
    - A damaged or newer file makes the binder "Can't open" without rewriting it.
    - A deleted file makes the binder unavailable, and a readable file brings it back.
- **Rationale:** A binder carries its own description in its folder, so it travels with the folder to other machines and storage locations.
- **Alternatives considered:** keeping binder settings only in the app's settings (they would not travel with the folder).

## 0051 — External file changes and per-box merging
- **Date:** 2026-10-25
- **Status:** Active (implements 0020)
- **Decision:**
  - **Watching:** every storage folder is watched. A changed page file is checked after 300 ms.
    - The app recognises its own writes by their exact text and ignores them.
    - A page that isn't open is re-read into the tree: new, changed, deleted or unreadable files.
    - Before each save of the open page, an unseen change on disk is merged rather than overwritten.
    - A deleted file keeps the open page, which the next save writes again.
  - **Three-way merge** (the open page): base is the page as last read or written by this app, mine is the page in memory, theirs is the file on disk.
    - **Content**, by `rev`: if only one side changed, that side wins. If both changed, the box type's merge is used (drawings merge as a union, 0041). Otherwise the box is conflicted: this device's version is kept and the other is recorded.
    - **Position, size and `fixedHeight`:** last write wins. When both sides changed them, this device's values are kept, because its next save is the later write.
    - **Additions** are kept.
    - **A delete on one side against an edit on the other** keeps the edit and flags it.
    - **Page header fields** are merged field by field.
    - Untouched nodes are written back verbatim.
  - **Conflict record:** a conflicted box records the other version in its `noted` header, as `"conflicts":[{"node":<the other version's whole node, verbatim>,"at":<ms>,"device":"<computer name>"}]`, or `{"deleted":true,"at":<ms>}` when the other side deleted the box. A device that can't run the box carries the field through unchanged.
  - **Conflict view:** a conflicted box has an amber frame and a "Conflict" badge, and its page has an amber dot in the sidebar. The badge opens both versions side by side, labelled with device name and time.
  - **Resolutions:** keep mine, keep the other version, keep both (the other version becomes a new box beside it), or edit manually. Edit manually shows both versions side by side in the box module's own editor; "Use this version" saves that pane as the resolution. Delete conflicts offer keep box or delete box. Each resolution is one undo step.
- **Rationale:** Pages can live in synced folders (0007) without whole-page conflict copies or silent data loss (0020).
- **Alternatives considered:** reloading the file over local edits; making every change made on both sides a conflict, including position (0020 rules last write wins for moves and resizes).

## 0052 — Device and time stamps on box content
- **Date:** 2026-10-25
- **Status:** Active
- **Decision:**
  - Each write of a box's content records `"device":"<computer name>"` and `"at":<ms since the epoch>` in the box's `noted` header. On Windows, the computer name comes from `Platform.localHostname`, falling back to `COMPUTERNAME`.
  - A write without a known device removes both fields, so the header never describes older content.
- **Rationale:** The conflict view labels each version with its device and time (0020, 0051).

## 0053 — Cloud conflict-copy files (OneDrive)
- **Date:** 2026-10-25
- **Status:** Active
- **Decision:**
  - **Detection:** a file `<stem>-<suffix>.canvas` is a conflict copy when `<stem>.canvas` exists in the same folder and both have the same page id. OneDrive appends `-<COMPUTERNAME>`, then `-<COMPUTERNAME>-<n>`. This naming is *unverified*, so a broader suffix pattern is accepted.
  - **Merge**, box by box into the original. There is no common base, so revisions decide:
    - same `rev`: the same version
    - the copy's `baseRev` is the original's `rev`: take the copy
    - the reverse: keep the original
    - otherwise: keep the original and record the copy in `conflicts` (0051).
  - Boxes on only one side are kept, and the page header is the original's.
  - **Removing the copy:** the merged original is written, read back and verified. Only then is the copy deleted, including when the merge recorded conflicts, because those keep the copy's versions. A failed merge keeps the copy, lists it under "Can't open", and is retried on its next change.
  - Copies found at startup, when a binder opens, or by the watcher all go through the same path. Other providers' naming is not handled yet.
- **Rationale:** OneDrive keeps both versions of a file edited on two machines before syncing. Merging per box keeps both without leaving a duplicate page.
- **Alternatives considered:** showing the copy as a separate page (duplicate page ids); deleting the copy only when the merge has no conflicts (the copy would be merged again on every scan).

## 0054 — Desktop and Start menu shortcuts
- **Date:** 2026-10-25
- **Status:** Active; extended by 0063
- **Decision:** On the development machine, shortcuts named "Noted" on the Desktop and in the Start menu point to the release build, `app\build\windows\x64\runner\Release\noted.exe`, and use its icon. The release exe is rebuilt after each change to the app, so the shortcuts always launch the current build.
- **Rationale:** Hands-on testing of the current build without a terminal.

## 0055 — Formulas and equations in table cells
- **Date:** 2026-10-25
- **Status:** Active; copy behavior extended by 0061
- **Decision:**
  - **Equations:** block and inline equations work inside table cells, with the same dialog and rendering as in notes (0048). A block equation replaces the cell's paragraph; emptying or cancelling it reverts the cell to text.
  - **Formulas:** a cell whose text starts with `=` is a formula. It shows its result while the caret is elsewhere and its formula while the caret is in it. Errors show in red.
  - **Evaluator:** in-house, in pure Dart, in the note module.
    - References: `A1` (with optional `$` markers) and `A1:B3` ranges, within the same table.
    - Operators: `+ - * /` and `^` (left-associative; unary minus binds tighter, so `-2^2` is 4, as in Excel), `&`, `%`, comparisons and parentheses.
    - Functions: SUM, AVERAGE, MIN, MAX, COUNT, ROUND, ABS and IF (only the chosen branch is evaluated).
  - **Errors:** `#REF!`, `#DIV/0!`, `#VALUE!`, `#NAME?`, `#NUM!` and `#CYCLE!`, plus `#ERROR!` for a formula that can't be parsed. The evaluator never throws.
  - **Recalculation:** every change to a table recomputes its formulas, in dependency order.
  - **Inserted and deleted rows and columns:** detected by comparing the table's layout before and after the change. References shift, references to a deleted row or column become `#REF!`, and the rewrite is part of the same undo step.
  - **Storage:** the formula stays in the cell's text, and the last computed value is stored with it as `"formulaValue":"<text>"` in the cell paragraph's data, without adding undo steps. The text snapshot shows values, so other JSON Canvas readers and AI see results.
  - While the caret is in a table, column letters and row numbers show around it. They are not part of the document.
  - **Out of scope:** references to other tables or pages, number formatting, sorting, charts, and import or export.
- **Rationale:** Simple calculations inside notes, with results readable outside the app.
- **Alternatives considered:** a third-party formula library (an in-house evaluator keeps the behavior and error values under control); storing only formulas (readers without the app would see no results).

## 0056 — Storage choice for standalone pages
- **Date:** 2026-10-25
- **Status:** Active (implements the storage prompt of 0027); the refusal of cross-folder nesting is superseded by 0059; the prompt when creating a top-level standalone page is superseded by 0084
- **Decision:**
  - Creating a top-level standalone page asks where to store it. The options are:
    - the default folder (preselected, so Enter accepts it)
    - every other standalone folder already in use
    - "Choose another folder…".
  - Subpages and pages in binders inherit their location without asking.
  - Extra standalone folders are remembered as `"standaloneFolders":[…]` in `binders.json` (0050).
    - Their pages join the one "Pages" tree, are watched (0051), and support every page operation.
    - A missing folder stays listed as unavailable.
  - A binder folder can't be chosen. Nesting a page under a page in another standalone folder is refused; pages move between folders only into or out of binders (0049).
- **Rationale:** A standalone page can be stored where the user wants it (0027), without a choice for every subpage.
- **Alternatives considered:** asking for every new page; moving files between standalone folders when nesting (more file moves for a rare case).

## 0057 — Templates, first level
- **Date:** 2026-10-25
- **Status:** Active
- **Decision:**
  - **File:** one JSON file per template, `<templateId>.notedtemplate`: `{"format":1,"templateId":"<16 hex>","kind":"page"|"binder","name":"…","created":<ms>,"extensions":{},…}`.
    - A page template adds `"page":<a complete page file object>`.
    - A binder template adds `"binder":{"title","description","owner","color"}` and `"pages":[<page file objects>]`, linked by `parentId`.
  - `extensions` is reserved for later content such as AI rules and skills. It and any unknown fields are kept verbatim. A newer format or unreadable file is listed and never overwritten.
  - **Storage:** app-wide templates live in `templates/` next to `binders.json`. Each binder's page templates live in `<binder folder>/templates/`. Binder templates are stored app-wide, because they describe a new binder.
  - **Saving:**
    - "Save as template" on a page saves its boxes and their contents, without subpages, to the binder or app-wide.
    - "Save binder as template" saves the binder's settings, color and page tree.
  - **Using:** "New page from template", "New subpage from template" and "New binder from template" create new page, box and binder ids, remap parent links, and drop conflict records. Templates can be deleted from the picker.
  - The format is described in the doc comment of `packages/noted_core/lib/src/template/template.dart`.
- **Rationale:** Repeated page layouts and binder structures can be reused. A plain, documented format leaves room for templates to carry AI rules and skills later.
- **Alternatives considered:** templates as ordinary pages in a special folder (no place for template metadata or extensions).

## 0058 — Dark mode
- **Date:** 2026-10-25
- **Status:** Active; color roles and the border contrast rule superseded by 0071
- **Decision:**
  - **Theme setting:** Light, Dark or Follow system, saved per device in `settings.json` in the app settings folder (next to `binders.json`, 0050): `{"format":1,"theme":"system"|"light"|"dark"}`.
    - The default is Follow system, which tracks the OS theme while the app runs.
    - Unknown fields are kept. A corrupt file gives the defaults and is left alone until the setting is changed.
    - The setting is changed from a gear menu at the bottom of the sidebar and applies at once.
  - **No hard-coded colors:** every UI color comes from `ThemeData`/`ColorScheme`, with a `NotedColors` theme extension for app-specific roles (default ink, conflict frame and badge, grid labels, formula errors, the debug readout, the eraser ring, muted text).
  - **What it covers:** the canvas, sidebar, box chrome, toolbars, menus and dialogs, the `appflowy_editor` text and blocks (including tables and the `/` menu), equations and the formula grid.
  - **Ink:** strokes stored in the pen's default color (`#FF202124`) draw black in light mode and white in dark mode, in the box, the live stroke and the color swatch. Every other stored color is drawn as stored. Stored values never change with the theme, so no page-format change.
  - **Binder colors:** shown with HSL lightness adjusted until they reach 3:1 contrast against the surface they sit on. The stored value is unchanged. Text next to binder colors uses the theme's text colors.
  - **Contrast:** text meets WCAG AA (4.5:1), and handles, borders and other UI components meet 3:1, in both themes. Greyed rows for inactive pages are exempt, as inactive UI in WCAG.
  - **Box API:** `ToolContext` gives tool sessions the theme's brightness and `NotedColors`, so live feedback matches the theme. This is additive to 0040.
- **Rationale:** Comfortable use in dark environments. Treating the default value as adaptive keeps existing drawings readable in both themes without changing the format.
- **Alternatives considered:** a new "adaptive ink" marker in stroke data (a page-format change); storing the theme in `binders.json` (it describes storage, not appearance).

## 0059 — Moving pages across standalone folders
- **Date:** 2026-10-25
- **Status:** Active (supersedes the refusal of cross-folder nesting in 0056)
- **Decision:**
  - Nesting a page under, or placing it before or after, a page in a different standalone folder moves the page's file and its subpages' files into that folder.
  - It uses the same copy, read-back-and-compare, delete-the-sources algorithm as binder moves (0049). On any failure the copies are removed and the sources stay.
  - Dropping a page on the "Pages" header keeps it in its own folder, at the top level.
- **Rationale:** A page's parent must be in the same location, and moving the files keeps that rule without refusing a natural drag.
- **Alternatives considered:** refusing the move (0056).

## 0060 — Damaged binder file display
- **Date:** 2026-10-25
- **Status:** Active (supersedes the damaged-binder display in 0050)
- **Decision:**
  - When a binder's `noted-binder.json` can't be read (invalid JSON, a newer format, or no id), at startup or when the watcher sees it change, the binder stays in the sidebar labelled "Binder file can't be read".
  - Its pages are listed greyed and read-only. A page opens in a read-only view with a banner: no editing, box creation, tools, moving, renaming, deleting or saving.
  - Nothing is written to the binder folder while the file is damaged.
  - When the file becomes readable again, the binder returns to normal. A deleted binder file still makes the binder unavailable (0050).
  - The canvas has a read-only mode for this: every edit, gesture, tool and save is blocked, and boxes are drawn with their module's read-only view.
  - The same read-only view is used for an open page whose standalone folder disappears while the app runs.
- **Rationale:** A damaged binder file shouldn't hide the binder's pages or risk writing over them before the file is fixed.
- **Alternatives considered:** removing the binder's pages from the sidebar until the file is fixed (0050).

## 0061 — Copying formulas in tables
- **Date:** 2026-10-25
- **Status:** Active (extends 0055); duplicate detection superseded by 0065
- **Decision:**
  - A copied formula shifts its relative references the way Excel does. Row and column parts move by the copy's offset, while parts anchored with `$` stay (`$A$1` fixed, `$A1` column fixed, `A$1` row fixed).
  - The two ends of a range shift independently. A reference pushed before row 1 or column A becomes `#REF!`.
  - **When it applies:**
    - appflowy's duplicate row and duplicate column. A duplicate is recognised as new cells whose text equals the neighbour's.
    - copying a whole single formula cell and pasting it at the start of a cell in the same table.
  - Pasting rows, several cells, or text from outside the editor stays verbatim, as does cut and paste.
- **Rationale:** Duplicating a row of formulas should produce the next row's calculation, as in a spreadsheet.
- **Alternatives considered:** copying formulas verbatim (the old behavior).

## 0062 — Box API 0.3
- **Date:** 2026-10-26
- **Status:** Active (extends 0040); extended by 0067 (Box API 0.4)
- **Decision:**
  - The Box API is at version 0.3.
  - `ToolContext` gives tool sessions the theme's brightness and its `NotedColors`, so live feedback such as the stroke being drawn matches the theme (0058). The change is additive and implemented by the canvas.
  - Every Box API version is recorded in `packages/noted_core/BOX_API_CHANGELOG.md`, newest first, with the decision that introduced it.
- **Rationale:** While the major version is 0, any change to the API is a new version (0034, 0040), and a changelog keeps those changes traceable for module authors.

## 0063 — Second-machine package and shortcut script
- **Date:** 2026-10-26
- **Status:** Active (extends 0054)
- **Decision:**
  - `app/scripts/package-windows.ps1` builds the release and writes `app/build/Noted-windows-x64.zip`. The zip holds:
    - the release folder
    - the Visual C++ runtime DLLs the exe and plugins import (`msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`), copied next to the exe as app-local deployment
    - `install-shortcuts.ps1`
    - a README covering how to run it, the shortcuts, the VC++ 2015–2022 x64 redistributable as a fallback, and where data lives.
  - The zip runs on another Windows PC by unzipping it; nothing is installed. Data stays in that PC's `%APPDATA%\Noted`.
  - `app/scripts/install-shortcuts.ps1` creates "Noted" shortcuts on the Desktop and in the Start menu, with the exe's icon. They point to the `noted.exe` next to the script when run from an unzipped package, or to the repository's release build otherwise.
- **Rationale:** Testing on a second machine, including two-machine sync (0051, 0053), without a development setup there.
- **Alternatives considered:** requiring the VC++ redistributable to be installed first (an extra step on every test machine); an installer (more than testing needs).

## 0064 — Live checks for storage folders
- **Date:** 2026-10-26
- **Status:** Active
- **Decision:**
  - Every storage folder, both standalone folders (0056) and binder folders (0049), is checked while the app runs: every 3 seconds, and whenever a folder watcher reports an error or closes. A folder that can't be watched because it doesn't exist is caught this way.
  - **When a folder disappears:**
    - Pending saves are written first if they still can be.
    - Its location shows "On another device", and its pages stay listed greyed.
    - A page from it that is open stays open read-only, with a banner (0060).
    - Nothing is written to it: saves, moves in or out, renames, deletes, new pages, templates, cover edits and conflict-copy merges are refused. Its watcher stops.
  - **When it comes back:**
    - For a binder, `noted-binder.json` is re-read; a damaged or missing file keeps its existing state (0050, 0060).
    - Its pages are rescanned, its watcher restarts, and conflict copies are merged (0053).
    - The open page is merged three-way with its file (0051) and becomes editable again.
  - A folder that was missing at startup appears without a restart. The app never creates or deletes a storage folder.
- **Rationale:** Storage folders can live on removable or synced drives (0007), so they can go away and come back at any time without losing edits or writing to the wrong place.
- **Alternatives considered:** detecting a folder only at startup (it needed a restart).

## 0065 — Duplicating table rows and columns
- **Date:** 2026-10-26
- **Status:** Active (supersedes the duplicate detection in 0061); background color storage superseded by 0069
- **Decision:**
  - `appflowy_editor` hard-wires its table menu's Duplicate to private code, so the note module supplies its own row and column handle menu (through the table and cell builders' `menuBuilder`).
  - Its "Duplicate row" and "Duplicate column":
    - copy the cells as new nodes with the same content and attributes
    - apply the insert adjustment to every formula in the table
    - shift the copy's relative references by one row or column (0061).
    - All of this is one transaction and one undo step.
  - The menu's other items are kept: insert before and after, delete, background color and clear. Background color offers a short list of colors from the theme, stored as concrete values.
  - Duplicates are no longer recognised by matching cell text. A plain inserted row or column only gets the insert adjustment, and a formula typed by hand is never shifted.
- **Rationale:** Knowing exactly which row or column was duplicated is reliable, while guessing from matching text could shift a formula the user typed by hand.
- **Alternatives considered:** recognising duplicates by matching text (0061); patching `appflowy_editor` (it is pinned to an upstream commit, 0037).

## 0066 — Undo for table changes
- **Date:** 2026-10-26
- **Status:** Active
- **Decision:**
  - `appflowy_editor`'s table measures itself after every build and writes cell `height` and table `colsHeight` through ordinary transactions. The note module's editor state applies any transaction that only sets `height`, `width` or `colsHeight` on table nodes without recording undo, and drops operations with an empty path.
  - A column-border drag becomes one undoable step.
  - **The result:** one Ctrl+Z, and one redo, covers exactly the last table change:
    - typing in a cell (appflowy's usual typing burst)
    - insert, delete, duplicate or clear a row or column
    - background color
    - column resize.
  - Formula rewrites caused by a change stay in its undo step, and storing formula values adds none.
  - The canvas box host builds from the page's current node, so a rebuild for another reason (hover, a menu opening) never hands a module older data than it committed.
- **Rationale:** Undo must reverse what the user did. Measurement is derived from layout and is recomputed after every undo and redo.
- **Alternatives considered:** filtering measurements out after the fact by position in the undo stack (they also stored stale cell positions with them).

## 0067 — Command registry and Box API 0.4
- **Date:** 2026-10-26
- **Status:** Active (extends 0040 and 0062)
- **Decision:**
  - Every action in the core and the box modules is a command: an id (stable and namespaced, for example `canvas.undo` or `noted.drawing.pen`), a label, a default icon, an optional shortcut, observable enabled and checked state, and an action.
  - **One registry per context:** each page canvas builds its own from the canvas commands (select, undo, redo, delete, deselect, zoom in, zoom out, zoom to 100%, Fit all), each module tool exposed as a command that is checked while the tool is active, and the modules' own commands. App menus build a small registry for the page or binder they act on.
  - **Keyboard shortcuts** resolve through the registry. Zoom and Escape also work inside a focused editor, and a read-only page answers only to zoom.
  - **Menus:** the page, binder, Pages header and theme menus are built from commands and invoke them. Gestures (tap, double-click, drag-and-drop) still act directly.
  - **Box API 0.4:** `BoxModule.commands(CommandHost)` returns a module's commands, with `CommandHost` giving the page's controller and the tool selection. It is additive and recorded in `BOX_API_CHANGELOG.md`.
  - **Module commands:**
    - Drawing: pen, eraser, four ink colors and three pen widths.
    - Note: insert table and insert equation, enabled while a note editor has focus.
- **Rationale:** One definition per action keeps shortcuts, menus and the toolbar in step, and lets the toolbar be configured later (0068).
- **Alternatives considered:** a single global registry (commands like undo depend on the open page).

## 0068 — Default toolbar
- **Date:** 2026-10-26
- **Status:** Active; extended by 0073 (look and order of the view controls) and 0074 (page background dropdown); pen options enabled only with the pen superseded by 0075
- **Decision:**
  - One fixed toolbar runs along the top of the canvas, built only from registry commands (0067). It replaces the floating tool bar and the zoom bar.
  - **Order:** Select, Pen, Eraser (the active tool shown as checked), ink color swatches, pen widths, Undo, Redo, Insert table, Insert equation, Fit all, and the zoom level (clicking it resets to 100%).
  - Colors and widths are always shown, enabled while the pen is active.
  - Disabled commands render disabled, tooltips show the label and shortcut ("Pen (P)"), and the toolbar follows the theme.
  - Clicking it doesn't take focus from a note editor.
  - The layout is data: an ordered list of groups of command ids (`toolbar_layout.dart`), with unknown ids skipped, so it can become user-editable later. There is no customization yet.
- **Rationale:** The common actions are one click away and always in the same place.
- **Alternatives considered:** keeping the floating tool bar and the zoom bar; showing the pen options only while the pen is active (the toolbar would change width).

## 0069 — Table background colors as theme roles
- **Date:** 2026-10-26
- **Status:** Active (supersedes the background color storage in 0065)
- **Decision:**
  - **Storage:** table row and column backgrounds store a theme role instead of a fixed color, in `appflowy_editor`'s own keys: `"colBackgroundColor"` / `"rowBackgroundColor": "role:accent"`, `"role:secondary"`, `"role:tertiary"` or `"role:alert"`. No color means the key is absent.
  - **Rendering:** a role resolves per theme at 25% alpha (accent → primary, secondary, tertiary, alert → error), so it follows theme changes. A column's color wins over a row's.
  - **Earlier values:** the eight exact fixed values the previous version wrote read as their roles. Any other stored value renders as that fixed color. Opening a note never rewrites a stored value; only picking a color does.
  - The note data version stays 1. Older builds see a role as an unreadable color and show no background.
  - Background colors don't appear in the text snapshot.
- **Rationale:** Colors chosen in one theme stay readable in the other.
- **Alternatives considered:** storing fixed values (they don't follow the theme); a separate attribute key (appflowy's renderer reads its own keys).

## 0070 — Recovery store for edits that can't be saved
- **Date:** 2026-10-26
- **Status:** Active; extended by 0077 (damaged entries in the sidebar)
- **Decision:**
  - **Writing an entry:** when a save can't land because its folder (standalone or binder) is unavailable (0064), the page is written at once to `%APPDATA%\Noted\recovery` as two files:
    - `<name>.canvas`: exactly the text a normal save would write, so it can never hold anything a page file wouldn't (invariant 3)
    - `<name>.json`: the target folder, page id, time and base text (the page as last read or written by the app).
    - Writes are atomic, there is one entry per page, and a newer edit replaces it.
  - **On quit,** if entries are pending, a notice says they'll be saved when the folder is back. Quitting is never blocked.
  - **When the folder returns,** while running or at the next launch, each entry is merged three-way with the current file (0051): base is the entry's base, mine is the entry, theirs is the file. Conflicts are recorded as usual.
    - The result is written, read back and verified, and only then is the entry deleted.
    - A page deleted while away is written from the entry.
  - Corrupt or unverifiable entries are kept and reported, and never deleted.
- **Rationale:** An edit made just before a folder disappears is not lost when the app quits before the folder comes back.
- **Alternatives considered:** keeping such edits only in memory (lost on quit); writing them to another storage folder (could put a page in the wrong place).

## 0071 — Design system and theme from tokens
- **Date:** 2026-10-26
- **Status:** Active (supersedes the color roles and the border contrast rule in 0058); ink display in dark mode superseded by 0081
- **Decision:**
  - **Source:** the Noted design system in `docs/design/` (direction A, "Quiet Utility") defines the look. `docs/design/tokens.json` is the single source of colors, type, spacing, radii, shadows and sizes. The HTML previews there are visual references, not code.
  - **Generated code:** `app/scripts/generate_tokens.dart` writes `packages/noted_canvas/lib/src/design_tokens.g.dart` from `tokens.json`. A test fails if the generated file is out of date.
  - **Theme:** `notedThemeData(brightness)` builds the light and dark `ThemeData` as `docs/design/README.md` ("Mapping to Flutter") lists:
    - `ColorScheme` slots from the color tokens.
    - The other colors are in the `NotedColors` extension: the background and hover fills, `text-disabled`, the conflict colors, the ink and binder palettes, the paper colors, the eraser ring and the debug readout.
    - Spacing, radii, sizes and shadows are in the `NotedMetrics` extension.
    - Text styles are in the `NotedTypography` extension and the `TextTheme`. They come from the type groups, set in Inter with Segoe UI and the system font as fallbacks.
  - **No fixed values:** widgets read colors, radii and sizes only from these.
  - **Ink:** the default ink stays stored as `#FF202124` and is displayed as `ink-default`, which changes with the theme. The pen swatches are the token inks: default, blue, orange, green and purple. Picked ink colors are drawn as stored in both themes.
  - **Binder colors:** the new-binder palette is the five `binder-*` light values. A stored value equal to one of them is displayed as that token's dark value in dark mode. Any other stored value keeps the lightness adjustment from 0058. Stored values never change.
  - **Contrast:**
    - Text pairs meet WCAG AA (4.5:1) in both themes, and tests check the pairs the README lists.
    - Selection borders, handles and focus rings use `accent` and meet 3:1.
    - Idle hairlines (`border`, `border-box`) are decorative and quieter by design.
    - Picked ink colors are exempt, as user content.
- **Rationale:** One token file keeps the app, the design references and both themes in step. Generating the Dart code avoids copying values by hand.
- **Alternatives considered:** hand-written theme constants (they drift from the design); 3:1 contrast for every hairline (louder than the design intends).

## 0072 — Bundled Inter font
- **Date:** 2026-10-26
- **Status:** Active
- **Decision:**
  - **Licensing rule:** fonts may also be under SIL OFL 1.1, alongside the dependency licences already allowed (MIT, BSD, Apache-2.0, MPL-2.0). A font ships with its licence file.
  - **Inter:** Inter 4.1 is bundled as app assets in `app/assets/fonts/Inter/`, in regular, medium, semibold and bold, with its `OFL.txt`. It is loaded through `pubspec.yaml` fonts, with no font package. Its licence is registered with Flutter's licence registry and is part of the release package.
- **Rationale:** The design system is set in Inter, and bundling it gives the same type on every platform.
- **Alternatives considered:** a font package that downloads at run time (needs the network and adds a dependency); system fonts only (they differ by platform).

## 0073 — Components restyled to the design guidelines
- **Date:** 2026-10-26
- **Status:** Active (extends 0068); the `FramelessBoxModule` marker superseded by 0079; extended by 0080
- **Decision:** The toolbar, sidebar, boxes, menus and dialog buttons follow the component guidelines in `docs/design/components/`. Icons are Flutter's built-in rounded Material icons (`Icons.*_rounded`), with no icon package.
  - **Toolbar:** 52px high on `surface` with a bottom hairline. Buttons are 36px with `radius-md`; the active tool has an `accent-soft` fill and an `accent` icon. Groups are separated by 1×24px rules.
    - The view controls (Fit all, zoom, page background) sit at the far right; the other groups scroll sideways if the window is narrow.
    - Ink swatches are 28px discs with a 2px `accent` ring when selected. Insert table, Insert equation and Fit all are text buttons.
    - Zoom is an outlined numeric button that resets to 100%.
    - Tooltips read "Label (Shortcut)".
  - **Sidebar:**
    - **Group headers:** uppercase, with an 8px chip in the binder's color (loose pages: `text-muted`).
    - **Rows:** 32px, indented 20px per level. Dividers have a chevron.
    - **Active page:** `accent-soft` fill with semibold `accent` text.
    - **Conflicts:** an 8px `conflict` dot labelled "Has a conflict".
    - **Unavailable and damaged binders:** titles in `text-disabled` with a status line ("On another device", "Binder file can't be read").
  - **Boxes:**
    - **Idle:** a `surface` fill, a 1px `border-box` hairline and `radius-lg`, with no shadow.
    - **Selected:** a 1px `accent` border with the `shadow-selected` ring and 8px square handles on the left, right and bottom edges and the bottom corners. The larger invisible drag areas are unchanged.
    - **Drawing box:** no fill or frame while idle, and a dashed `accent` outline when selected. A module states this by implementing the host-side marker `FramelessBoxModule`. The Box API version is unchanged (0.4).
    - **Conflict:** a 2px `conflict` border with a "Conflict" badge on the top edge.
    - **Read-only pages:** a `conflict-soft` banner saying why and that edits are paused.
  - **Menus:**
    - **Which menus:** page, binder, Pages header, settings and table handle menus share one menu item style.
    - **Layout:** a `surface` container with a hairline, `radius-lg` and the popover shadow. Items are 32px, with a right-aligned shortcut column.
    - **Item states:** destructive items (Delete page, Delete row, Delete column) are in `error`, and disabled items are in `text-disabled`.
    - **The `/` menu:** it follows the colors only; `appflowy_editor` fixes its sizes.
  - **Buttons:**
    - Primary, secondary, ghost and destructive styles come from the theme. A dialog has at most one primary button: the proceeding action.
    - Delete confirmations use a destructive button instead of a primary one. In the conflict view, "Keep mine" (or "Keep box") is primary.
  - **Touch:** after a touch input, controls grow to 44px and sidebar rows and menu items to 40px, and the toolbar wraps. A mouse or pen input returns to desktop sizes.
- **Rationale:** A consistent, quiet interface in both themes, and controls large enough to hit on touch screens.
- **Alternatives considered:** an icon package (a new dependency); sizing for touch on every platform (wastes space with a mouse).

## 0074 — Page backgrounds
- **Date:** 2026-10-26
- **Status:** Active (extends 0068)
- **Decision:**
  - **Setting:** each page has a background: Plain (the default), Dots, Graph or Ruled.
  - **Storage:** it is stored in the page header's `noted` object, for example `"background":"dots"`.
    - A missing value, a non-string or an unknown name reads as Plain. The stored value is kept byte-for-byte through load, save, rename and move until the user picks a background.
    - Choosing Plain removes the key, so a plain page's header is the same as before backgrounds existed.
    - Templates carry the background, because they store the whole page header (0057).
  - **Drawing:**
    - It is drawn on `bg-canvas` under the boxes, including on read-only pages.
    - **Patterns:** Dots are 1.5px `paper-dot` dots. Graph is a 1px `paper-line` square grid. Ruled is 1px `paper-line` horizontal rules with a 1px `paper-margin` line at page x = 64.
    - **Pitch:** `paper-pitch` (20px at 100% zoom), scaling with zoom. The pattern is anchored to the page origin, so it doesn't move while panning.
    - Lines snap to device pixels.
    - **Far zoomed out:** the pattern keeps every second, fourth and so on line or dot until lines are at least 8px apart and dots 12px apart, and never draws more than 20,000 primitives in a frame. The margin line is never thinned.
  - **Exclusions:** the background is decoration. It is not part of box snapshots, the text snapshot or anything AI-facing.
  - **Commands:**
    - "Page background: Plain/Dots/Graph/Ruled" are registry commands, checked when current and disabled on read-only pages.
    - They appear in the page's right-click menu and in a toolbar dropdown in the view group. The dropdown is a command whose `menu` lists the four commands, and its button shows the current background's icon.
    - A change to the open page is one undo step (`PageChange.background` restores the exact stored value) and is autosaved. A page that isn't open is loaded, changed in its header only, and saved.
- **Rationale:** Dot, graph and ruled paper help with handwriting and layout. A header field keeps it per page with no change to boxes.
- **Alternatives considered:** a background box (it would move, select and appear in snapshots); writing `"plain"` explicitly (it would change every plain page's file).

## 0075 — Choosing an ink selects the pen
- **Date:** 2026-10-26
- **Status:** Active (supersedes the pen options being enabled only while the pen is active in 0068)
- **Decision:** The ink color swatches and pen widths are always enabled. Choosing one sets it and switches to the Pen tool, from any tool.
- **Rationale:** Picking an ink means the user wants to draw with it, and a disabled swatch gave no hint how to enable it.
- **Alternatives considered:** keeping the options disabled until the pen is chosen (0068).

## 0076 — Escape leaves a note editor
- **Date:** 2026-10-26
- **Status:** Active (extends 0067)
- **Decision:**
  - In a note editor, Escape first closes what the editor itself has open; a text range selection is collapsed.
  - With nothing of its own to close, Escape leaves the editor and the canvas returns to the Select tool.
- **Rationale:** Escape should always lead back out to the canvas, as it does elsewhere.
- **Alternatives considered:** `appflowy_editor`'s default (Escape only cleared the selection and kept the editor focused).

## 0077 — Damaged recovery entries in the sidebar
- **Date:** 2026-10-26
- **Status:** Active (extends 0070)
- **Decision:** Recovery entries that are corrupt or can't be verified are also listed in the sidebar under "Can't open", with the reason in the tooltip. They are kept and never deleted, as before.
- **Rationale:** A pending edit that can't be restored should be visible where other unreadable files are shown.
- **Alternatives considered:** reporting them only in the log.

## 0078 — Scope of the current phase
- **Date:** 2026-10-26
- **Status:** Active
- **Decision:**
  - **In scope:**
    - the canvas: zoom, bounded pan, Fit all and page backgrounds
    - the page tree
    - the Box API
    - note boxes, with tables, formulas and equations
    - drawing boxes
    - binders without passwords
    - templates
    - file-based sync with per-box conflicts, including OneDrive conflict copies
    - the recovery store
    - dark mode and the design system in `docs/design`
    - the command registry and the default toolbar
  - **Out of scope until the next phase:**
    - binder passwords and encryption
    - AI and MCP
    - integrations and Microsoft sign-in
    - conflict copies from providers other than OneDrive
    - customizable toolbars
    - reMarkable
  - **Known risk areas for hands-on testing:**
    - typing on a crowded page
    - editing while zoomed
    - dragging and resizing boxes
    - drawing
    - sync between two machines
  - `CLAUDE.md`'s "Current phase" section states the same.
- **Rationale:** The phase description had fallen behind the features already approved and built. Drawing is kept.
- **Alternatives considered:** limiting the phase to the note box only, which would have meant switching off approved, built features.

## 0079 — Box API 0.5: box frame style
- **Date:** 2026-10-26
- **Status:** Active (extends 0067; supersedes the `FramelessBoxModule` marker in 0073)
- **Decision:**
  - The Box API is at version 0.5.
  - **`BoxModule.frameStyle`:** says how the canvas frames a module's boxes.
    - `BoxFrameStyle.framed` is the default: a surface fill and a hairline frame while idle, and an accent border when selected.
    - `BoxFrameStyle.framelessUntilSelected` shows no fill and no frame until the box is selected, then a dashed accent outline. The drawing module uses it.
  - **Commands:** the same version records `Command.menu` (a toolbar dropdown's command ids, 0074) and `Command.readout` (an outlined numeric readout, such as the zoom level).
  - All changes are additive and listed in `BOX_API_CHANGELOG.md`.
- **Rationale:** How a box is framed is part of what a module declares, so it belongs in the versioned API rather than in a check the host makes on the module's class.
- **Alternatives considered:** the host-side marker interface (0073); a check on the box type id (it ties the host to one module).

## 0080 — Conflict view header and box headings
- **Date:** 2026-10-26
- **Status:** Active (extends 0073)
- **Decision:**
  - The conflict view and its manual-edit view show their title on a `conflict-soft` band across the top of the dialog.
  - Inside note boxes, Heading 1 uses the `box-title` style (16/22, semibold). Deeper heading levels use `body-strong`, so they stay above body text and below Heading 1.
- **Rationale:** These complete the BoxFrame and Button guidelines.
- **Alternatives considered:** `appflowy_editor`'s default heading sizes (28px and larger for Heading 1, out of scale with box text).

## 0081 — Swatch inks lifted on the dark canvas
- **Date:** 2026-10-26
- **Status:** Active (supersedes the ink display in dark mode in 0071)
- **Decision:**
  - **What changes:** in dark mode, a stroke stored in one of the swatch inks (blue, orange, green, purple) that would have less than 3:1 contrast against the dark `bg-canvas` is shown with its HSL lightness raised, in 1% steps, until it reaches 3:1. Hue and saturation are kept.
  - **Which inks:** purple and blue are lifted. Orange and green already pass and are shown as stored.
  - **What stays:** the light theme and stored values are unchanged. Default ink still follows the theme (0071). Any other stored color is drawn as stored.
  - **Swatches:** they show the same display color.
  - **Contrast:** every swatch is at least 3:1 against `bg-canvas` in both themes, and a test checks it.
- **Rationale:** Ink drawn in a swatch color should be readable on the dark canvas, the way binder colors are lifted in dark mode, without changing what is stored.
- **Alternatives considered:** fixed dark values in the design tokens (needs a token change in `docs/design`); lifting purple only (blue is also under 3:1).

## 0082 — App icon
- **Date:** 2026-10-26
- **Status:** Active
- **Decision:**
  - **Master:** `docs/design/icon/noted-icon.svg`, with a transparent 1024 px PNG beside it.
  - **Generated files:** `app/scripts/generate_icons.dart` rasterizes the SVG directly, with no new dependency. It writes:
    - the Windows `.ico` (16, 24, 32, 48, 64, 128 and 256 px) to `app/windows/runner/resources/app_icon.ico`
    - the macOS `AppIcon.icns` and the Android and iOS icon sets to `app/icons/`, ready for when those platform projects are added.
    - Every size keeps the transparent background.
  - **Small sizes:** at 32 px and below, the shapes are fitted to the pixel grid (edges on pixel boundaries, whole-pixel stroke widths) and the small mark on the fold is left out, so the 16 px icon is sharp instead of a blurred reduction.
  - **Where it shows:** the Windows icon is the exe's icon resource, so it is the window, taskbar and Alt+Tab icon, the icon of both shortcuts (0054, 0063) and of the exe in the zip.
- **Rationale:** One master keeps every platform's icon the same, and generating from the SVG keeps small sizes crisp.
- **Alternatives considered:** `flutter_launcher_icons` (it scales the PNG down, which blurs 16 px, and it needs the platform projects to exist).

## 0083 — Zoom anchored to the pointer
- **Date:** 2026-10-26
- **Status:** Active (extends 0003)
- **Decision:**
  - **Anchor:** Ctrl+mouse wheel and touchpad pinch keep the canvas point under the pointer (for a pinch, under the fingers' current centre) in place after every zoom step.
    - Each step is computed from the current view and the current pointer position.
    - A pinch uses the scale the view had when it started times the gesture's cumulative scale, so a long pinch doesn't drift.
  - **Bounds:** the bounded pan (0003) applies after anchoring and moves the view only by the overshoot on each axis, so there is no sideways jump.
  - **Keyboard:** Ctrl+= and Ctrl+- zoom around the mouse when it is over the canvas, and around the centre of the view otherwise.
  - **Unchanged:** clicking the zoom readout (and Ctrl+0) resets to 100% around the centre, and Fit all is unchanged.
  - **Limits:** at the minimum or maximum zoom, further zoom input does nothing.
- **Rationale:** Zooming toward what you point at is expected on every platform, and drift made pinch zoom unreliable.
- **Alternatives considered:** always zooming around the view centre (the earlier keyboard behaviour); computing a pinch from the start view only (pan overshoot would unwind on the way back).

## 0084 — Instant new pages and binders
- **Date:** 2026-10-26
- **Status:** Active (supersedes the prompt when creating a top-level standalone page in 0056, and "New binder asks for a folder" in 0049; extends 0038); extended by 0087 (binders from templates)
- **Decision:**
  - **New page:** the + next to Pages, the "New page" menu item and Ctrl+N (a registry command that also works while a note or the title is being edited) create the page at once in the default page folder.
    - The page opens with the caret in its title, which is an inline field above the canvas. Enter or leaving the field renames the page.
    - There is no dialog. New page from template keeps its template picker and uses the default folder.
    - Subpages keep their parent's location, and pages in a binder stay in the binder.
  - **Default folders:** "Default page folder" and "Default binder folder" are in the gear menu, stored per device in `settings.json` as `"defaultPageFolder"` and `"defaultBinderFolder"`.
    - Out of the box they are `%APPDATA%\Noted\pages` and `%APPDATA%\Noted\binders` (`~/.noted/…` elsewhere). Nothing is asked on first run.
    - The app creates only these built-in folders. A chosen folder that is missing is shown as unavailable and is never recreated (0064).
    - A chosen default page folder joins the standalone folders (0056); pages in the previous default stay listed.
  - **Move to folder…:** in the page's menu. It opens the folder picker and moves the page and its subpages with the verified copy-then-delete move (0049, 0059). A binder folder is refused as the target; pages still move into a binder by dragging. The folder picker for pages appears only here.
  - **New binder:** created at once in a new subfolder of the default binder folder, named after the binder.
    - A taken name gets a number: "New binder 2", "New binder 3" and so on.
    - Characters not allowed in file names are replaced.
    - Its cover opens with the title field focused. Renaming the binder later doesn't rename its folder.
  - **Folder pickers kept:** "New binder in another folder…" keeps the picker. "Open binder…" opens an existing binder folder with the picker and refuses a folder with no binder file.
- **Rationale:** Creating a page or binder should be one action, with the location chosen once in settings and changed per page only when needed.
- **Alternatives considered:** asking where to store every new top-level page (0056); asking for a folder for every new binder (0049).

## 0085 — Search and Box API 0.6
- **Date:** 2026-10-26
- **Status:** Active (extends 0035 and 0067)
- **Decision:**
  - **Find on page (Ctrl+F):** a find bar at the top right of the canvas.
    - It shows "3 of 12". Enter, Shift+Enter, F3 and Shift+F3 step between matches, and Esc closes it and clears every highlight.
    - Each step brings the match's box into view, zooming out only if the box doesn't fit and never zooming in.
    - Boxes with matches get a frame, thicker on the current one.
    - Note boxes also mark matches in text, table cells and equations. A formula cell is marked only by its box's frame, since it shows its value.
  - **Search all pages (Ctrl+Shift+F, and a search field at the top of the sidebar):**
    - Results are grouped by page in sidebar order, each with the page path (binder or "Pages", parents, title) and snippets with the matches highlighted.
    - Clicking a result opens the page with the find bar filled in and the clicked match current.
    - Folders and binders that are unavailable or damaged, and page files that can't be read, are listed under "Not searched" with the reason.
    - Search is the last item in the toolbar's view group.
  - **Scope:** every reachable page in the standalone folders and the open binders. Page titles are not searched yet.
  - **Index:**
    - It is in memory only. It is never written to disk and never logged.
    - It is built from the page files on first use, and kept current by the app's saves and by file watching (0051), including deletes, moves and folders that go away or come back.
    - The open page is searched as committed to its model, not from the live editor.
  - **What is searched:** only each box's text snapshot (0035). The core never reads box data, so unsupported boxes and future encrypted boxes are never parsed (invariants 2 and 3). Drawing boxes have no snapshot text and are skipped.
  - **Matching:**
    - Case- and accent-insensitive, using a folding table in pure Dart that covers Latin, Vietnamese, Greek tonos and common ligatures.
    - Every word must appear in the same box, each as a whole word. A phrase in double quotes matches as a whole-word phrase.
  - **Speed:** a benchmark test (500 pages × 20 boxes) checks that the median query is under 300 ms. It measured about 25 ms.
  - **Box API 0.6:** `BoxContext.find` gives a module the find state (`BoxFind`: query, current box and current match), so it can mark matches in its own content by matching its own snapshot. The change is additive and recorded in `BOX_API_CHANGELOG.md`.
  - **Commands:** `canvas.find` and find next or previous, and `app.search`. They are in the registry and work while a note is being edited.
- **Rationale:** Finding text across a notebook is basic note-taking. Searching only the snapshots keeps search outside box data, and keeping the index in memory keeps plaintext off disk.
- **Alternatives considered:** a persistent on-disk index (stores text outside the page files); having the core parse each module's data (breaks invariant 2).

## 0086 — Refreshing Windows' icon cache
- **Date:** 2026-10-26
- **Status:** Active (extends 0054 and 0063)
- **Decision:**
  - **What happened:** after the icon changed (0082), Explorer kept showing the old one on the Desktop, in the Start menu and on the taskbar. The exe already carried the new icon, and any new process read the new icon from it. Explorer was serving the old one from its memory and its cache files (`iconcache_*.db`), which it hadn't rewritten since before the change.
  - **`install-shortcuts.ps1`:** it now deletes and recreates both shortcuts (with `IconLocation` set to the exe), then runs `ie4uinit.exe -show`.
  - **`-ResetIconCache`:** this switch also stops Explorer, deletes `%LOCALAPPDATA%\Microsoft\Windows\Explorer\iconcache*.db` and `IconCache.db`, and starts Explorer again, which rebuilds the cache. It is opt-in, because the taskbar disappears for a moment.
  - The package README describes it.
- **Rationale:** An updated exe should show its new icon without manual cache cleaning.
- **Alternatives considered:** always restarting Explorer (disruptive on every install); renaming the exe so Explorer sees a new file (breaks existing shortcuts and pins).

## 0087 — New binder from template creates at once
- **Date:** 2026-10-26
- **Status:** Active (extends 0057 and 0084)
- **Decision:**
  - After the template is chosen, "New binder from template…" creates the binder at once, as New binder does (0084).
  - **Where:** in a new subfolder of the default binder folder named after the template ("Project", then "Project 2" and so on, with characters that aren't allowed in file names replaced). There is no folder picker.
  - **After creating:** the cover opens with the title field focused.
  - **If writing fails:** the new empty folder is removed again.
- **Rationale:** Both ways of making a binder behave the same, with the location chosen once in settings.
- **Alternatives considered:** keeping the folder picker for template binders.

## 0088 — Automated hands-on checklist
- **Date:** 2026-10-26
- **Status:** Active
- **Decision:**
  - **Where:** the hands-on checklist is automated with Flutter's `integration_test` (an SDK package, BSD) in `app/integration_test/`, which drives the real `NotedApp` in a Windows window. Run it from `app/` with `flutter test integration_test -d windows`. Plain `flutter test` doesn't run it.
  - **Isolation:**
    - Every test builds its `Notebook` and `AppSettings` with all their locations in a per-test temp directory: pages, `binders.json`, `settings.json`, recovery, templates, and binder and extra folders.
    - It asserts at the start that nothing resolves under `%APPDATA%\Noted`. The folder picker is a stub, and the real clipboard is never used.
  - **Mapping:** test names start with the checklist step numbers they cover, and `app/integration_test/step_map.json` maps them.
  - **Coverage file:** `docs/testing/checklist-coverage.md` lists every step as automated, partly automated, superseded and re-tested (naming the decision), or manual only, with the reason.
  - **What stays manual:** steps that need eyes, real touchpad, touch or pen hardware, the Windows shell, a second machine or OneDrive.
  - **Limits:**
    - Text goes into note editors through editor transactions, because synthetic keys don't produce IME text.
    - The OS theme is simulated by overriding the platform brightness.
    - A second device is simulated by writing the page file through a second store.
- **Rationale:** Most of the checklist can be checked on every change without human time, so hands-on testing can focus on what needs eyes and hardware.
- **Alternatives considered:** widget tests only (they don't run the real app window and plugins); driving the app through OS automation (fragile and slow).

---

## Open items
- **Apple build path:** iOS/iPadOS and macOS releases have to be compiled with current Xcode on Apple-silicon-era macOS. The planned approach is cloud macOS build runners.
- **Equation block sourcing:** resolved (0048).
- **File format:** whether JSON Canvas extra fields are sufficient, and how faithfully appflowy_editor round-trips Markdown.
- **MCP:** the full tool and resource list, and the user experience for linking an AI to a box.
- **Cloud conflict copies:** OneDrive copies are merged (0053); other providers name their conflict-copy files differently and are not handled yet.
- **Per-AI overrides:** different rules for different AIs on the same page (deferred).
- **Drawing box image snapshots:** where a drawing box's image snapshot (0035) is stored in the page format (0041).

## Risks to test early
- Text editing while the canvas is zoomed (known Flutter selection issues under scale transforms).
- Nested scrolling vs. canvas panning:
  - Wheel over a special box scrolls the box.
  - Ctrl+wheel zooms.
  - One finger scrolls, two fingers pan.
- Page-level undo for box move, resize and delete.
- Performance with many editor instances on one page.
- Plugin support on each desktop platform.
- Install size and the non-native look.
- Ink anywhere vs. text selection and pan gestures.
- Stylus pressure and latency on each platform.
- Background sync limits on mobile.

## First prototypes, in order
1. Canvas, page tree, Box API, and plain note and editor boxes, on the Windows development machine. Covers typing on a crowded page, editing while zoomed, and box drag and resize.
2. Drawing box module with the tool-based input rules (0033), on the development machine using a mouse.
3. Pen and touch ink on a Windows pen tablet, an iPad and an Android phone. Pass condition: zero skipped or broken strokes on fast, long lines, including while a drawing box grows.
4. Microsoft sign-in on Windows (system browser + PKCE).
5. One AI box through a local MCP server, tested under each page AI setting, with an encrypted box on the same page that appears only as a placeholder.
6. reMarkable (later phase).
