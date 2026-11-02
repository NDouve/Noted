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
- **Status:** Active; AI boxes and writing implemented by 0104 and 0106 (the per-box AI-read and AI-write switches are not built yet)
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
- **Status:** Active; implemented by 0051–0053; refined by 0120 (how issues are shown and settled) and 0121 (additions on both sides merge)
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
- **Status:** Active; the setting implemented by 0100 (now 0109), reading by the MCP server by 0101 and 0110, writing and the AI-authored tag by 0104, 0106 and 0108
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
- **Status:** Active; its rule that a conflict on a box the device can't run waits for a supporting device is superseded by 0120 (keep one version or place both, from snapshots)
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
- **Status:** Active (implements 0026 except passwords, locking and encryption); "New binder asks for a folder" superseded by 0084; failed-move rollback amended by 0124
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
- **Status:** Active (implements 0020); refined by 0120 (the manual-edit merge view is removed; the issue sequence replaces the badge) and 0121; unreadable replacements of the open page amended by 0124
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
- **Status:** Active; extended by 0120 (landed boxes); deletion of a copy amended by 0124
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
- **Status:** Active (supersedes the refusal of cross-folder nesting in 0056); failed-move rollback amended by 0124
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
- **Status:** Active; extended by 0073 (look and order of the view controls) and 0074 (page background dropdown); pen options enabled only with the pen superseded by 0075; the layout (one fixed toolbar, its order and its view group) superseded by 0097
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
- **Status:** Active; extended by 0077 (damaged entries in the sidebar); entry layout, identity checks and replay amended by 0124 (the two-file layout below is replaced by one entry file)
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
- **Status:** Active (extends 0068); the `FramelessBoxModule` marker superseded by 0079; extended by 0080; the toolbar's view controls at the far right superseded by 0097 (each layout places them)
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
- **Status:** Active (extends 0070); replay and landing problems added by 0124
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
- **Status:** Superseded by 0096
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
- **Status:** Active (extends 0035 and 0067); "page titles are not searched" superseded by 0089
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
- **Status:** Active; extended by 0090
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

## 0089 — Search includes page titles
- **Date:** 2026-10-26
- **Status:** Active (supersedes "page titles are not searched" in 0085)
- **Decision:**
  - **Indexing:** each page's stored title is indexed with its boxes, folded and matched by the same rules (0085).
  - **Matching:** a page matches by title when the title alone has every term or phrase. Title words and box words are never combined into one match. An empty stored title never matches.
  - **Ranking:** pages that match by title come first, then pages with box matches only, in sidebar order within each group. In a page's group the title hit is shown first, with the match highlighted, then the box snippets.
  - **Opening a title result:** it opens the page with the matched part of the inline title marked. The mark is paint only: no selection, no focus and no change to the title. It clears when the title is edited, another page opens, or the search is cleared. Box results open the find bar as before.
  - Find on page (Ctrl+F) still searches box content only.
- **Rationale:** People look for pages by name first, and a title match is usually what they want.
- **Alternatives considered:** combining title and box words for one match (finds pages where the words are unrelated); selecting the matched title text (risks overwriting the title when typing).

## 0090 — Integration suite: accessibility semantics and table handles
- **Date:** 2026-10-26
- **Status:** Active (extends 0088)
- **Decision:**
  - **Semantics:** when a Windows accessibility client (UI Automation) queries the window, the engine turns semantics on mid-test and `testWidgets` reports a handle as leaked. The suite replaces only `PlatformDispatcher.onSemanticsEnabledChanged`, so semantics the platform asks for are ignored. Handles a test opens itself are still counted, so real leaks are still caught.
  - **Table row handles (step 143):** the row handle of a table's first row was not missing. A test that hovers the centre of cell (0,0) lands on the column handle, which covers the middle of a one-line row, so the row handle hides.
    - Users reach the row handle from the table's left edge, so they don't hit this.
    - The test hovers the left of the cell, and a note-package test checks that the row handle opens its menu.
  - **Results:** the suite (49 tests) passed three full runs in a row after both changes.
- **Rationale:** The suite has to fail only on real problems, and every finding is checked against what a user would do.
- **Alternatives considered:** retrying failed tests (hides real failures); turning accessibility off for the app (it must stay available to users).

## 0091 — Canvas performance on large pages
- **Date:** 2026-10-26
- **Status:** Active (extends 0003; extended by 0092 and 0095)
- **Decision:**
  - **Rebuilds:** panning and zooming no longer rebuild the boxes.
    - A box host reads the zoom only when it needs it (dragging or resizing).
    - The canvas hands the same box widgets to its stack until the page, the selection, editing, read-only state or find changes. Theme changes still reach every box.
  - **Benchmark:** `app/integration_test/perf_benchmark.dart` measures a page with 200 note boxes (text, paragraphs, 3×3 formula tables) and 20 drawing boxes.
    - It measures page open, per-keystroke latency and pan and zoom frame times, and prints a summary line. It asserts only loose bounds.
    - It runs in profile mode through `flutter drive` with `perf_driver.dart`, and is not part of the checklist run.
  - **Results (profile mode, UI thread; the raster thread wasn't measured, it reads 0 on this setup):**

    | | Before | After |
    |---|---|---|
    | Pan, average build per frame | 38.7 ms (160 of 450 frames over 16 ms) | 6.4 ms (none over) |
    | Zoom, average build per frame | 32.9 ms | 6.8 ms (none over) |
    | Page open (first frame) | — | about 0.6 s |
    | Typing, key to frame | — | 15.4 ms average |

  - **Typing spikes:** about one typing frame in fifteen takes 80–140 ms, likely garbage collection on a large heap. This is not proven and is left open.
- **Rationale:** A page with hundreds of boxes has to pan and zoom within a 16 ms frame.
- **Alternatives considered:** a repaint boundary around all boxes or around each box (measured slower); building only visible boxes (a larger change; open time is acceptable for now).

## 0092 — Lazy note editors
- **Date:** 2026-10-27
- **Status:** Active (extends 0091)
- **Decision:**
  - **Light view:** a note box builds an `appflowy_editor` editor only while it is being edited. Every other note is drawn by a light, read-only view of the same document, built from the same block builders, text styles and padding, with no editor state, selection or keyboard services.
    - It draws paragraphs, headings, bulleted, numbered and to-do lists, quotes, dividers, equation blocks, inline equations, tables (stored column widths and row heights, formula cells showing their stored value) and Find on page highlights.
    - It must look identical to the editor without a caret. Tests compare the two renderings pixel for pixel in light and dark themes.
    - Box height is measured the same way in both, so switching never resizes the box.
  - **Fallback to the editor:** a note keeps the real editor when the light view can't draw it exactly: other block types (images, unknown types), nested blocks, blocks with an alignment, text direction or background color, a table that hasn't been measured yet, or a formula cell with no stored value. Once the editor has stored the missing measurements or values, the note goes back to the light view.
  - **Entering a note:** a click places the caret on the clicked character at any zoom, then mounts the editor with that selection. A box created by a click starts as an editor. A click on an equation opens its editor. A to-do checkbox toggles without mounting an editor, as an undoable change. On a read-only page a click mounts the non-editable editor, so text can still be selected and copied.
  - **Leaving a note:** when the editor loses focus it is replaced by the light view, except while one of its own menus or dialogs is open.
  - **Undo:** the editor's state and its undo history are kept while the page is open, so undo still works after leaving a note and returning.
  - **Notes with a table:** a table note the user has edited keeps its editor while the page is open. `appflowy_editor`'s table leaves listeners on its nodes when its editor is removed, and mounting a second editor on the same state made row heights change endlessly.
  - **Scope:** the change is inside the note module. It changes neither the Box API nor the page format.
  - **Results (same benchmark as 0091; profile mode, UI thread, 50 keystrokes):** "Before" is one run before the change; "After" is two runs, one figure per run where they differ. The NVIDIA driver changed from 537.13 to 621.01 between the before and after runs, and Windows was updated, so some of the difference may come from the system.

    | | Before | After |
    |---|---|---|
    | Page open, first frame / settled | 618 / 812 ms | 507–516 / 698–706 ms |
    | Typing, key to frame: average, p90, worst | 15.5, 19.8, 26.9 ms | 14.8–15.8, 15.7–17.3, 52.7–56.8 ms |
    | Keystrokes over 50 ms | 0 of 50 | 2 of 50 in each run |
    | Frames over 50 ms while typing (worst) | 4 of 55 (106 ms) | 3 of 59–60 (54–60 ms) |
    | Pan, average build per frame (worst) | 6.7 ms (19.7) | 5.9 ms (9.5–11.9) |
    | Zoom, average build per frame (worst) | 7.7 ms (12.3) | 5.8–5.9 ms (10.1–10.6) |
    | Garbage collections while typing (new / old) | 86 / 16 | 54–56 / 6–10 |

  - **Reading the results:**
    - Opening is about 18% faster.
    - The worst typing frames are about half as long, and there are fewer garbage collections.
    - The remaining ~55 ms frames now coincide with a keystroke about once in 25. Before the change, the longer ~100 ms frames fell between keystrokes.
    - The benchmark's tables have no stored measurements, so its 20 table notes open as editors and switch to the light view after measuring. A saved page, whose tables are measured, opens with fewer editors than the benchmark shows.
- **Rationale:** An editor per note made the cost of a page grow with the number of notes. A page with hundreds of notes should cost about as much as the notes being edited.
- **Alternatives considered:** building only the boxes in view (a canvas change, and an editor still has to be built when a note scrolls into view); drawing the light view from the text snapshot (loses formatting, tables and equations, so it can't look identical); a light view that estimates table row heights (box heights would change when the editor measured them); removing a table note's editor after editing (blocked by the table's leftover listeners).

## 0093 — Continuous integration (GitHub Actions)
- **Date:** 2026-10-27
- **Status:** Active; amended by 0123 (a Linux test job, not blocking yet)
- **Decision:**
  - **Workflow:** `.github/workflows/ci.yml` runs on every push, every pull request, and by hand. It has read-only repository permissions, and a newer run on the same branch cancels the one still in progress.
  - **Flutter version:** pinned to 3.47.8 stable, the version used for development, through `subosito/flutter-action@v2` with caching. Actions are pinned to major versions.
  - **Jobs:**
    - **Analyze and test** (Windows runner): `flutter pub get` and `flutter analyze` at the workspace root, then `flutter test` in every package with a `test/` directory (`app`, `packages/*`, `packages/boxes/*`), so a new box module's tests run without changing the workflow. A failing package doesn't stop the others; the job fails at the end and names them.
    - **Windows release build** (Windows runner, in parallel with the tests): `app/scripts/package-windows.ps1` builds the release and writes the zip, uploaded as the `Noted-windows-x64` artifact.
    - **macOS release build** (macOS runner): `flutter build macos --release`, unsigned and not notarized, zipped with `ditto` and uploaded as the `Noted-macos` artifact.
  - Artifacts are kept for 14 days.
  - **Not in CI:** `app/integration_test` (the checklist suite and the performance benchmark), which needs an interactive desktop session. It stays a local check.
  - **macOS platform project:** `app/macos/` was created with `flutter create` (organisation `org.noted`, as on Windows). The product name is `Noted` and the bundle id `org.noted.noted`, with no signing team. The App Sandbox is on, plus access to files the user selects (`file_selector`). The icon script also writes the macOS asset catalog icons.
  - The first run on 2026-10-27 passed all three jobs.
- **Rationale:**
  - Every change is analysed, tested and built on the platforms it ships to, without depending on the development machine.
  - The macOS build is the first step on the Apple build path (see Open items): it checks that the app compiles for macOS before anyone runs it there.
  - The tests run on Windows, the only platform they have been run on; a Linux runner is cheaper and can replace it once the tests are shown to be platform independent.
- **Alternatives considered:** gating the release builds on the tests (slower to report build problems); running the tests on Linux (cheaper, untested); signing and notarizing the macOS build (needs an Apple developer account; not needed to check that it builds).

## 0094 — Box module template and author guide
- **Date:** 2026-10-27
- **Status:** Active (implements the template and guide of 0034, stage 1)
- **Decision:**
  - **Template:** `packages/boxes/template` (`noted_box_template`) is a minimal, commented box module, a *sticky label*: one line of text and a colour.
    - It implements every required member of Box API 0.6: the codec (type id `noted.template.sticky-label`, data version 1, API version, fixed sizing, create, decode, encode, text snapshot, `isEmpty`, AI exposure as text, field-by-field three-way merge, no permissions) and the module (`buildEditor`, `buildView`, saving only through `BoxContext.commit`).
    - Optional hooks (settings, tools, commands, frame style, image snapshot, Find on page, resize requests) are listed in a comment and not used. It has no insert command, so a label can be created only in code.
    - The colour is stored by name (`blue`, `orange`, `green`, `purple`) and drawn with the theme's ink colours, so it works in light and dark.
    - Decoding never throws: bad or missing fields take defaults. Keys the module doesn't know, including an unknown colour name, are kept and written back unchanged.
  - **Registration:** the app registers it **switched off** (`enabled: false`), so it is compiled in but its boxes show their snapshot until it is switched on in `main.dart` or with `ModuleRegistry.setEnabled`. A page that is already open must be reopened after switching.
  - **Tests:** codec, merge, a save and load round trip through the page format, byte-for-byte pass-through of unknown data, the snapshot shown when the module is off or not registered, and editing updating the snapshot.
  - **Guide:** `docs/box-modules.md` explains how to create, register, test and switch on a box type, Box API versioning and its changelog, and what the architecture invariants mean for a module author: touch only your own box, keep unknown fields, keep the snapshot accurate and free of secrets, set AI exposure explicitly, keep encrypted plaintext in the editor only, use no developer-run backend, and remember that the MCP server reads saved data only. Where the guide and an active decision differ, the decision wins.
- **Rationale:** 0034 delivers new box types in source using a published template and guide. A small working module that the tests keep compiling shows every part of the API in use, and is a safer starting point than copying the note or drawing module.
- **Alternatives considered:** documenting the API without a module (the example could drift from the API); using the drawing module as the template (too large, and has tools and commands most modules don't need); registering the template switched on (it would appear to users).

## 0095 — A growing note rebuilds only itself
- **Date:** 2026-10-31
- **Status:** Active (extends 0091; resolves its open question about typing spikes)
- **Decision:**
  - **Cause of the slow keystrokes:** when a note grows or shrinks by a line as the user types, it asks the canvas for new bounds. Until now that page change made the canvas create every box's widget again, so all 220 boxes in the benchmark rebuilt in the next frame. The keystroke after each height change took 50–75 ms. The benchmark now records, for each keystroke over 50 ms, whether the note's height changed and whether the other boxes were rebuilt. Every slow keystroke in the "before" runs followed one of those rebuilds.
  - **Change:** the canvas keeps each box's widget while the box shows nothing new: the same node object (the page replaces only the node that changed), the same selected and editing state, and the same read-only state. A box whose node changes is rebuilt alone.
    - Every box is still rebuilt when something they all use changes: the controller, the canvas origin, read-only, or the find model.
    - Panning and zooming still rebuild no boxes (0091).
  - **Test:** a canvas test grows one of three boxes and checks that only that box rebuilds. It also checks that selecting rebuilds the box selected and the one that was, and that turning on read-only rebuilds all three.
  - **Scope:** a canvas change only. It changes neither the Box API nor the page format.
  - **Results (benchmark of 0091; profile mode, UI thread; 200 keystrokes per run, three runs each, alternating; "Before" is main before the change):**

    | | Before | After |
    |---|---|---|
    | Keystrokes over 50 ms | 7, 2, 3 of 200 | 0, 0, 0 of 200 |
    | Typing, key to frame: average / p90 / worst | 13.9–17.0 / 15.6–18.6 / 51.0–74.9 ms | 12.4–13.4 / 14.9–16.2 / 17.7–18.6 ms |
    | Typing frames over 50 ms (worst) | 5–7 per run (55.6–82.6 ms) | none (6.5–9.3 ms) |
    | Note height changes / rebuilds of the other boxes | 7 / 7 per run | 7 / 0 per run |
    | Page open, first frame / settled | 530–710 / 713–966 ms | 498–582 / 689–801 ms |
    | Pan, average build per frame (worst) | 5.7–7.7 ms (8.3–14.5) | 5.6–6.8 ms (8.3–10.2) |
    | Zoom, average build per frame (worst) | 5.7–7.5 ms (8.2–11.6) | 5.5–6.7 ms (8.2–15.3) |
    | Garbage collections while typing (new / old) | 468 / 388 | 424–426 / 386 |

    The first "before" run was slower across the board than the other five. Page open, pan and zoom don't depend on the change; their differences are within run-to-run variation.
- **Rationale:** Typing on a crowded page is a known risk area. A line wrap in one note should cost what that note costs, not what the whole page costs.
- **Alternatives considered:** rebuilding the boxes in view only (still rebuilds dozens of boxes on every wrap); deferring the height change until typing pauses (the box would lag its text); caching inside the note module (other box types would still rebuild, and BoxHost itself would still be rebuilt for every box).

## 0096 — App icon: N with a superscript d
- **Date:** 2026-10-31
- **Status:** Active (supersedes 0082); amended 2026-10-31: at 16 and 20 px the N fills the icon less a 1 px margin
- **Decision:**
  - **Master:** `docs/design/icon/noted-icon.svg`, with a transparent 1024 px PNG beside it: a blue N with a superscript d, all strokes with round caps and joins, painted with one two-stop linear gradient (`gradientUnits="userSpaceOnUse"`), lighter at top left. The background is transparent.
  - **Generated files:** `app/scripts/generate_icons.dart` rasterizes the SVG directly, with no new dependency. It supports solid colours and two-stop linear gradients as fill or stroke paints, interpolated in sRGB and padded beyond the stops. It writes the same files as before:
    - the Windows `.ico` (16, 24, 32, 48, 64, 128 and 256 px) to `app/windows/runner/resources/app_icon.ico`
    - the macOS asset catalog PNGs in `app/macos/Runner/Assets.xcassets/AppIcon.appiconset`
    - the macOS `AppIcon.icns` and the Android and iOS icon sets in `app/icons/`.
    - Every size keeps the transparent background.
  - **Small sizes (32 px and below)** are fitted to the pixel grid:
    - Stroke widths round to whole pixels, and stroke edges fall on pixel boundaries. The N's stems are whole opaque pixel columns at 16, 20, 24 and 32 px.
    - At 16 and 20 px only the N is drawn. The d is dropped because it would be a smudge of one or two pixels.
    - *(Amended)* At 16 and 20 px the N is scaled up to fill the icon square, leaving a clear 1 px margin on every side. Its stroke width scales with the height (3 px at 16, 4 px at 20). The stems are spread apart so the N's outline is as wide as it is tall, which makes it wider than in the master. The first version of this entry kept the master's proportions and centred the N.
    - From 24 px the d is kept. It is snapped to the grid (whole-pixel circle radius) and moved right by whole pixels until a clear pixel column separates it from the N, as far as the icon's edge allows. At these sizes the master's gap between them is under one pixel, so they would otherwise merge.
  - **Test:** `app/test/icon_generator_test.dart` checks the gradient interpolation, that the master renders with its gradient, the N-only rule and the 1 px margin at 16 and 20 px, the d and its clear column at 24, 29, 32 and 48 px, and the whole-pixel stems at 16, 20, 24 and 32 px.
  - **Where it shows:** unchanged from 0082: the exe's icon resource (window, taskbar, Alt+Tab), both shortcuts (0054, 0063) and the exe in the zip.
- **Rationale:** The new master is the maintainer's chosen design. Generating every size from it keeps the platforms consistent, and fitting the small sizes keeps the 16 px taskbar and shortcut icon sharp. Filling the square makes the N as large as the 16 and 20 px slots allow. Keeping the master's proportions would leave the N almost the same size as when centred, because the N is taller than it is wide.
- **Alternatives considered:** keeping the d at 16–20 px (unreadable at that size); keeping the master's proportions at 16–20 px, centred (the first version of this entry; it leaves empty columns either side); an image library to rasterize the SVG (a new dependency, and it would blur the small sizes).

## 0097 — Two built-in toolbar layouts: Tabs and Contextual
- **Date:** 2026-10-31
- **Status:** Active (supersedes the layout part of 0068 and the far-right view controls of 0073); the Image and File placeholders replaced by 0098 and the Link placeholder by 0099
- **Decision:**
  - **Choice:** Settings (the gear menu) has a Toolbar section with Tabs and Contextual. The choice is saved per device in `settings.json` as `"toolbar":"tabs"|"contextual"` and applies at once, without a restart. A missing, unknown or damaged value means Tabs, the default.
  - **Tabs (OneNote-style):** a 40px row of tabs above the 52px bar. Undo and Redo sit left of the tabs and Search all pages at the right end of the row, always visible. The bar shows the chosen tab's commands; Home is chosen at start.
    - **Home:** paragraph style (Normal, H1, H2, H3); bold, italic, underline, strikethrough, highlight, text colour; bulleted, numbered and check lists, outdent, indent; link, clear formatting.
    - **Insert:** table, equation, link, date and time; image, file, AI box, encrypted box.
    - **Draw:** select, pen, eraser, highlighter, lasso; the ink colours; the pen widths.
    - **View:** zoom out, zoom to 100%, zoom in, Fit all; page background, find on page.
    - On a read-only page a tab whose commands are all left out is hidden, which leaves View.
  - **Contextual:** one 52px bar. Select, Pen and Eraser, then Undo and Redo, at the left; Search, Fit all, the zoom level and the page background at the right. Between them a section filled with `surface-hover` shows the first that applies:
    - the ink colours and widths while the Pen is the active tool;
    - text tools while the caret is in a note: bold, italic, underline, strikethrough, highlight; the three lists, outdent, indent, clear formatting; table and equation;
    - otherwise the insert tools.
    - On touch input the left end and the middle wrap together.
  - **Layouts are data:** `toolbar_layout.dart` describes both as lists of command-id groups with tab labels and section conditions (a command that must be checked, or any of the section's commands enabled). They write to and read from JSON. Commands are only taken from the canvas registry (0067), and ids it doesn't have are skipped.
  - **Placeholders:** text colour, link, image, file, AI box, encrypted box, highlighter and lasso have no command yet. Each gets a disabled command with its label followed by "(coming later)". A module that registers the same id later replaces the placeholder.
  - **New note commands** (through `BoxModule.commands`, no Box API change): paragraph styles, bold, italic, underline, strikethrough, highlight (the editor's own highlight), bulleted, numbered and check lists, outdent, indent, clear formatting (removes bold, italic, underline, strikethrough, code, text colour and highlight; keeps links, formulas and equations) and insert date and time (`2026-10-31 14:05`). They act on the focused note and are enabled only while one has focus. Styles, marks and lists show as checked for the text at the caret. Their tooltips show the editor's own keys.
  - **Accessibility:** a checked text button (the paragraph styles) shows its state visually only. With a toggled semantics flag changing as the caret moved, the Windows app exited without an error during the integration suite.
- **Rationale:** The maintainer approved two built-in layouts. Tabs keep every command one tab away without crowding a single bar. Contextual keeps one short bar by showing only what fits the current task. Keeping both as data lets user-arranged toolbars build on them later; that customisation stays out of scope.
- **Alternatives considered:**
  - The full Home set in the Contextual text section: it overflows a canvas about 1100 px wide.
  - The paragraph style as a dropdown: opening a menu takes focus from the note, which disables the note commands before the choice runs.
  - Leaving table and equation out of the Contextual text section: they insert at the caret, so the insert section, which shows when no note has the caret, could never run them.

## 0098 — Image and file boxes, and where their files are stored
- **Date:** 2026-10-31
- **Status:** Active (page format change approved by the maintainer; Box API 0.7 and the attachments package approved retroactively); amended by 0102 (Delete, alt text below the picture); landing kept files amended by 0124
- **Decision:**
  - **Setting "Store images and files":** on pages and binders, either *In a folder beside the page* (the default) or *In the page file*.
    - It is stored as `"attachments":"folder"|"embedded"` in the page header's `noted` object or in the binder file. An absent value means the page follows its parent.
    - It is inherited like the other settings (0027): the page's own choice, else the nearest parent page's, else the binder's, else folder. The page menu also offers *Same as parent*.
    - An unknown value is kept as written and read as "follow the parent".
  - **Folder mode:** a file is written once to `<page id>.assets/<content hash>.<ext>` beside the page file, where the hash is SHA-256 and the extension is lowercase. The box stores the file's name relative to that folder, its hash, its display name and its size. Because the name is the content hash, two devices adding the same file write the same name, so they can't conflict. A file already there is left alone.
  - **Embedded mode:** the box stores the bytes as base64, with the hash.
  - **Reading:** every box reads both kinds, whatever the current setting.
  - **Size guard:** files over `embedLimitBytes` (5 MB) always go to the folder, even in embedded mode, with a one-line notice.
  - **Converting:** the page menu's *Embed attachments* and *Move attachments to folder* convert every image and file box on the page as one undo step. Over-limit files and files that haven't arrived stay in the folder, and the action reports the over-limit ones by name. Folder files are not deleted by embedding.
  - **The core and the assets folder:** the core never reads box data (invariant 2). It handles the folder by name only:
    - it moves with its page, including between storage folders (copy, then remove the original);
    - saving a template copies it to `<templateId>.assets/<page id>/` beside the template file, and using the template copies it under the new page id; deleting the template removes the copy;
    - deleting a page sets the folder aside in `deleted-attachments` beside `binders.json`; undo puts it back, and it is removed once the delete can no longer be undone;
    - a file that can't be written because the page's folder is away is kept in the recovery folder (0070) as `<page id>.assets/` and read from there. It is moved into place when the recovered page lands.
  - **Missing files:** a box whose folder file isn't there yet shows *Still syncing*. It fills in when the file arrives: the notebook's folder watcher and a watcher on the open page's assets folder notify the boxes.
  - **Image box (`noted.image`):**
    - It is created by Insert → Image (a file dialog), by pasting an image on the canvas, or by dropping an image onto it, at the drop point. Pasting an image while the caret is in a note creates an image box to the right of the note, top-aligned, not inline.
    - It takes PNG, JPEG, GIF (shown as its first frame), WebP and BMP. A new box is the image's pixel size, with the longer side at most 480.
    - The original is kept. It is displayed from a PNG copy downscaled to at most 1600 px on the longer side, cached in the local app data `cache` folder, which is outside the page folders and never synced.
    - Resizing keeps the aspect ratio; holding Shift resizes freely.
    - Alt text is edited in a field over the image's bottom edge, shown on hover or while the box is selected. A click on an image or file box selects it. The text snapshot is `[image: <alt text>]`, and the AI sees only that.
  - **File box (`noted.file`):** created by Insert → File or by dropping any non-image file. It shows an icon for the file type, the name and the size; a double-click opens the file with the system's default app (an embedded file opens from a temporary copy). The snapshot is `[file: <name>]`.
  - **Modules:** both are box modules in `packages/boxes/attachments`. They go through the Box API (0.7: `AttachmentStore`, `fileAffinity`, `createFromFile`, `convertAttachments`, `aspectRatio`, `insertFiles`).
  - **Toolbars:** Image and File are real commands in the Tabs (Insert) and Contextual (insert section) layouts, replacing their placeholders (0097).
  - **Dependencies:** `crypto` (BSD-3-Clause) for SHA-256; `desktop_drop` 0.8.4 (Apache-2.0) for drops, because 0.9 needs a `cross_file` that appflowy_editor doesn't allow yet; `pasteboard` (Apache-2.0) for clipboard images; `url_launcher` (BSD-3-Clause) to open files.
- **Rationale:**
  - A folder beside the page keeps page files small and lets sync clients move large files on their own; content-hash names make concurrent adds safe.
  - Embedding suits a page that must travel as one file.
  - Inheriting the setting matches the other page settings.
  - The size guard keeps page files, which are rewritten on every save, from growing past what sync handles well.
- **Alternatives considered:**
  - Folder only (8/10): simplest, but a page couldn't travel as one file.
  - Embedded only (5/10): every save rewrites large files, and page files grow without limit.
  - One shared folder per binder (6/10): files would be shared between pages, but moving a page out of the binder, templates and deletes would need reference counting.

## 0099 — Links in notes
- **Date:** 2026-10-31
- **Status:** Active (replaces the Link placeholder of 0097)
- **Decision:**
  - **Link (Ctrl+K)** is a note command, in the Tabs layout (Home and Insert) and the Contextual layout (text and insert sections). It opens a dialog for the address:
    - With text selected, the selection becomes the link.
    - With the caret inside a link, the whole link is edited, and the dialog offers *Remove link*.
    - With a bare caret elsewhere, the address is inserted as linked text.
    - An address without a scheme gets `https://`; `mailto:` and other schemes are kept.
    - Saving with an empty address on an existing link removes it.
  - The link is appflowy_editor's own `href` text attribute, so the note format is unchanged.
  - Ctrl+K replaces appflowy's link menu in notes.
  - **Ctrl+click** (Cmd+click on macOS) on a link opens it with the system's browser or default app, both in the editor and in the light view (0092).
- **Rationale:** Links are common in notes. One dialog covers insert, edit and remove, and uses the storage the editor already has.
- **Alternatives considered:** appflowy's own link menu (a separate overlay with its own styling); opening links on a plain click (it would move the caret instead of letting the user edit the link text).

## 0100 — The page AI setting
- **Date:** 2026-10-31
- **Status:** Superseded by 0109 (Open, Privileged, Guarded); first entry of the AI phase; implemented the setting of 0028
- **Decision:**
  - **Values:** each page has an AI setting:
    - **Off:** invisible to AI.
    - **Box only:** listed, but an AI reads only its own boxes there.
    - **Whole page:** every box can be read.
  - **Storage:** `"ai":"off"|"box"|"page"` in the page header's `noted` object, and the same key in a binder file. An absent value means the page follows its parent. An unknown value is kept as written and read the same way as an absent one.
  - **Inheritance (0027):** the page's own choice, else the nearest parent page's, else its binder's, else **Off**, the app-wide default.
  - **Where it shows:** the page menu has an *AI access* section: *Same as parent (…)*, which shows the value it inherits, then Off, Box only and Whole page. The binder menu has the same section, headed by *App default (Off)*.
  - **Code:** `AiSetting`, `effectiveAiSetting` and the header and binder accessors are in noted_core (`src/ai/ai_setting.dart`).
- **Rationale:** AI access has to be chosen per page and default to nothing. Inheriting it like the other settings lets a whole binder or subtree be opened, or kept closed, with one choice.
- **Alternatives considered:** a default of Box only (it would list every page's title to any connected AI without the user choosing it); an app-wide switch only (too coarse for notebooks that mix private and shared pages).

## 0101 — Read-only MCP server
- **Date:** 2026-10-31
- **Status:** Active (AI phase; implements reading for 0028 and invariant 4; amended by 0103 and 0106: writes go through the running app; amended by 0109 and 0110: Open/Privileged/Guarded and code-based reads)
- **Decision:**
  - **Program:** `packages/noted_mcp`, a separate pure-Dart executable (`noted_mcp.exe`) speaking MCP over stdio with the Dart team's `dart_mcp` (BSD-3-Clause, approved by the maintainer).
  - **Reads:** saved page and binder files only, from the folders the app lists in `%APPDATA%\Noted`:
    - the default `pages` folder;
    - `settings.json`'s default page folder;
    - `binders.json`'s standalone folders and binders.
  - Every call reads the files afresh. It never writes, never creates a folder, and never uses anything from a running app's screen or memory.
  - **Tools:**
    - `list_pages`: id, title, parent, AI setting and folder or binder. The parent is the nearest visible ancestor, so a hidden page in between isn't revealed.
    - `read_page`: markdown. The title, then each box in reading order (top to bottom, then left to right) with its type. Notes are written as markdown, including headings, styles, lists, check lists, links, equations and tables, with a formula cell showing its value. Drawings are `[drawing]`, images `[image: alt]`, files `[file: name]`.
    - `read_box`: one box as `read_page` shows it.
    - `search`: titles, plus the text of Whole page pages, with core search matching and snippets.
  - **Enforced on every call:**
    - Off pages are invisible in every tool. Asking for one gets the same answer as for a missing page, and a `noted:` link to one keeps only its text.
    - Box only pages are listed and their titles searchable, but no box content is returned.
    - Whole page pages are readable in full.
    - Encrypted boxes (an encrypted type, or a header that says so) and boxes of unknown types are always a placeholder, never their data or stored snapshot.
    - Binders whose file is unreadable or marked locked or encrypted are left out whole.
  - **No key access, no decryption code (invariant 4):**
    - The server imports only `noted_core_read.dart`, the read-only part of the core (model, format, binder, tree, search, AI setting), and `dart_mcp`.
    - A test walks its whole import graph. It fails on any Flutter, crypto, key or encryption library, on `dart:ffi`, on any other Noted library, and on any dependency besides `dart_mcp` and `noted_core`.
  - **Hookup:**
    - `noted_mcp.exe` is compiled into the release folder and the zip.
    - `app/scripts/register-mcp.ps1` registers it with Claude Code (`claude mcp add noted -s user`) and prints the Claude desktop `mcpServers` entry.
    - `docs/mcp.md` documents both.
- **Rationale:** A separate, read-only process that knows only saved files can't leak live edits, keys or decrypted content, and enforcing the AI setting on every call keeps the page owner in control.
- **Alternatives considered:**
  - A minimal JSON-RPC implementation written in-house: no dependency, but the protocol would be kept up to date by hand.
  - Serving from the running app: it would break invariant 4 and expose live screen state.
  - Using the stored text snapshot of unsupported boxes: it is the module's own text, but the maintainer requires a placeholder for anything the server can't vouch for.

## 0102 — Image and file boxes: Delete, and the alt text below the picture
- **Date:** 2026-10-31
- **Status:** Active (amends 0098; Box API 0.8, approved by the maintainer)
- **Decision:**
  - **Selecting:** a click on a box's content that doesn't move the focus into it selects the box, as a click on its grip does. This applies to an image, a file and a drawing. The canvas checks two frames after the click, so content that takes the focus (a note opening its editor) keeps it. A click inside a box that is being edited, or one that opens a menu, never selects.
  - **Deleting:** Delete or Backspace removes the selected image or file box through the canvas's Delete command, and undo brings it back. Typing in the alt-text field doesn't delete the box.
  - **Alt text:** the field is a strip below the picture (28 page units) and never covers it. A new image box is the picture's size plus that strip. The picture is fitted inside its area without distortion.
  - **Box API 0.8:** `BoxModule.aspectRatioExtraHeight` (default 0) is a fixed height below the part that keeps `aspectRatio`. While resizing, the canvas keeps `height − extra = width / aspectRatio`, so the picture keeps its shape and the strip its height.
  - **Approvals:** the maintainer approved Box API 0.7 and `packages/boxes/attachments` retroactively, and requires asking before any further Box API change or new package, even an additive one.
- **Rationale:** Images and files should be deleted like any selected box. A caption over the picture hid part of it.
- **Alternatives considered:** letterboxing the picture inside a box that keeps its overall shape (no API change, but resizing could leave empty bands); a delete hook in the Box API (unneeded once a click selects the box).

## 0103 — Invariant 4: the MCP server writes only through the running app
- **Date:** 2026-10-31
- **Status:** Superseded by 0114 (the server may verify codes, keep its own log and write opted-in AI boxes while Noted is closed); was active (approved by the maintainer; supersedes the earlier wording of architecture invariant 4, "a separate executable with no key access and no decryption code" with reading only; amends 0101)
- **Decision:** Architecture invariant 4 reads:
  - The MCP server is a separate executable with no key access and no decryption code.
  - It reads saved page files only. AI-facing output is never built from the live screen.
  - It never writes any file.
  - Its only way to change content is to send a write request to the running Noted app over a local connection.
  - The app decides: it accepts a request only for a box owned by the requesting AI's token, on a page whose AI setting allows writing, and saves it through its normal path. It rejects everything else.
  - If the app isn't running, every write fails.
- **Scope:** AI boxes, AI writing through the app, and AI connections and tokens are in the current phase. Per-AI rules, tiers and lanes are not.
- **Rationale:** An AI has to be able to write into its own box (0008) without the server gaining a way to touch files, keys or other boxes. The app already owns saving, undo, sync and conflicts, so a write that goes through it gets all of them, and a server that can only ask can't bypass them.
- **Alternatives considered:** the server writing page files itself (it would duplicate the save path, race the app's own saves and conflict handling, and break "never writes a file"); writes queued in a file for the app to pick up later (a file write by the server, and no immediate answer).

## 0104 — The AI box
- **Date:** 2026-10-31
- **Status:** Active, amended by 0117 (Writer permissions, `replace_ai`) and 0118 (markdown import moved to the core); earlier, amended: the owner and the *Connected AI* menu are superseded by 0108 (per-box codes); markdown import amended by 0113 (code and raw HTML kept as text). Implements AI writing for 0008 and the AI-authored tag of 0028; new package under delegated authority
- **Decision:**
  - **Module:** `packages/boxes/ai` (`noted_box_ai`), type `noted.ai`, a box type through the Box API like any other. Insert → *AI box* (in both toolbars) adds one at the middle of the view, selected and ready to type in. It is never removed as empty. It can be inserted on a page of any AI setting, but on an Off page no AI can read or write it.
  - **Content:** a note document, stored in the note box's shape (`{"document": …}`), edited with the note box's editor. The user can type in it too.
  - **Owner:** `"owner"` in the box data is the id of the AI connection that owns it (0105), never a token or secret. The *Connected AI* menu on the box picks it from the app's connections, or *None*. An id that isn't a current connection (revoked, or made on another device) owns nothing, so the box is ordinary user text.
  - **AI-written mark:** each block an AI writes has `noted_ai` in its data: an FNV-1a 64-bit fingerprint of the block's type and text, including inline equation formulas and link targets. The mark counts only while it matches, so editing the text, changing the block's type, or typing into a block copied from it ends the mark; bold, a to-do tick or a level change don't. Stale marks are removed before each commit. AI-written blocks show a thin bar beside them, and the box has a small *AI* label.
  - **Writes:** `replace` turns the AI's markdown into the box's whole content; `append` adds it after the existing blocks. Markdown import keeps only text blocks (paragraphs, headings, lists, to-dos, quotes, dividers, tables, equations), so images, fenced code blocks and raw HTML are dropped, and keeps a link's address only for `http`, `https` and `mailto`. An open editor starts over when the box's data changes from outside, so typing can't commit over an AI's write; it keeps the focus, so the box stays being edited.
  - **Snapshot and AI text:** the box's markdown, with each run of AI-written blocks between `<ai-written>` and `</ai-written>` lines; `<` in the text is escaped so the markers can't be forged. Search and the MCP server read this, so another AI sees which text came from an AI.
- **Rationale:** Reusing the note document keeps one editor and one markdown conversion. Tagging blocks by fingerprint needs no clean-up on edit: a changed block simply stops matching.
- **Alternatives considered:** a separate AI-only box the user can't type in (0008 has the conversation happen in the box); a box-level "AI-written" flag (too coarse once the user edits part of it); storing the AI's raw markdown (it would drift from what the editor shows); per-box AI-read and AI-write switches from 0008 (not built in this phase).

## 0105 — AI connections and tokens
- **Date:** 2026-10-31
- **Status:** Superseded by 0108 (per-box codes); implemented the revocable identity tokens of 0028
- **Decision:**
  - **Where:** gear menu → *AI connections*: list, add, rename and revoke.
  - **Token:** adding a connection makes `noted_<id>_<key>`: a random 16-hex-digit id and a random 256-bit key in base64url. It is shown once, with *Copy*, and the dialog can't be dismissed by accident while it shows.
  - **Storage:** `settings.json` (local app settings, never synced and never in page files) holds `"aiConnections"`: `[{id, name, hash, created}]`, where `hash` is the SHA-256 of the key. Tokens are compared in constant time.
  - **Checks:** the app reads the connections from the settings file on every check, so a revocation (here or in another Noted on the same computer) takes effect on the next request. A settings file that can't be read accepts no token; a missing file has no connections.
  - **Revoking:** the connection's requests are rejected at once. Its boxes keep their content and become user-owned text (0104); no page is rewritten.
  - **Registering:** the MCP server reads the token from `NOTED_TOKEN`. `app/scripts/register-mcp.ps1 -Token …` passes it to Claude Code; `docs/mcp.md` documents this and the Claude desktop entry.
- **Rationale:** A token per AI app gives each one its own boxes and lets the user cut one off without touching the others. Keeping only a hash means the settings file can't be used to write as an AI. Reading a connection's own boxes on Box only pages is scoped by the token's id alone (0106).
- **Alternatives considered:** one shared token for every AI (no per-AI ownership or revocation); tokens in page files (they would sync to every device and every reader of the page); OS secure storage for the hashes (unneeded for a hash, and platform-specific).

## 0106 — The AI write path
- **Date:** 2026-10-31
- **Status:** Active, amended by 0110 (ai-link/2, codes instead of tokens, MCP tools 0.3.0) and 0124 (closed-page writes reread and merge); implements invariant 4 as worded in 0103; extends 0101
- **Decision:**
  - **Local link:** while it runs, the app listens on loopback TCP (`127.0.0.1`, a port chosen by the system) and writes `ai-link.json` (`{"format":1,"port","pid","nonce"}`) in its data folder (`%APPDATA%\Noted`), removed on a clean exit. A client connects to loopback only and reads the greeting line `{"noted":"ai-link/1","nonce":…}`; it sends nothing unless the nonce matches the file. One request per connection, as one JSON line of at most 1 MiB: `{"noted":"ai-link/1","op":"write_box","token":…,"box":…,"mode":"replace"|"append","content":…}`. The app answers with one line, `{"ok":true,"page":…,"box":…}` or `{"ok":false,"code":…,"message":…}`, and closes the connection. Reads time out after 5 s, and at most 8 connections are open at once.
  - **Acceptance:** a write is accepted only if all of these hold, otherwise it gets the code in brackets:
    - the token is valid and not revoked (`bad_token`);
    - the box exists on a page whose AI setting is Box only or Whole page; an Off page answers like a missing box (`no_box`);
    - the box takes AI writes (`not_writable`) and is owned by that token's connection (`not_owner`);
    - the box isn't in a sync conflict (0020) (`conflict`);
    - the page can be edited: not in a locked binder, not read-only (`locked`).
    - Other answers: `bad_request`, `busy` (still loading, or the settings can't be read for a moment; nothing changed) and `save_failed`. A code the client doesn't know is read as a failure, keeping the app's message.
  - **Applying:** writes are handled one at a time. The token is checked again just before the change. On the open page the write replaces the box's data through the canvas, so it shows at once and is one undo step, then is saved. On any other page it is saved through the same store, with a recovery copy if the page's folder is unavailable. Both go through the normal sync and conflict handling.
  - **MCP tools (server 0.2.0):** `list_my_boxes` (the boxes the token's connection owns, on pages that aren't Off) and `write_box(box_id, content, mode)`, where `mode` (`replace` or `append`) is required. The server forwards the write and returns the app's message, as a tool error when the write was refused, or its own "Noted isn't running" message when the app can't be reached. It never writes a file: a source scan of every Noted library it imports fails on any file-writing API, and on any socket API outside the link client.
  - **Box only reading:** on a Box only page, `read_page`, `read_box` and `search` return box content only from that AI's own boxes. Titles stay listed and searchable (0101), and a page with none of that AI's boxes reads as its title and a note. The server identifies the connection by the token's id, as listed in `settings.json`; only the app verifies the key, so reading never needs it, and a token with a listed id and any key reads that connection's boxes. Off pages stay invisible.
- **Rationale:** Loopback TCP works the same on every desktop platform. Dart can't serve a Windows named pipe without native code, and binding a Unix domain socket failed on Windows when tried with the Dart SDK used here. The nonce stops a client from sending a token to another program that took the port. Routing every write through one queue in the app keeps writes, saves and page switches in order.
- **Alternatives considered:**
  - A Windows named pipe: it needs FFI on the app side and an exception to the server's no-FFI rule.
  - Unix domain sockets: binding one failed on Windows (see above).
  - Scoping Box only reads by verifying the full token in the server: it would need the hash and a crypto library in the server, which the invariant test keeps out.

## 0107 — Box API 0.9: AI writes and the view's centre
- **Date:** 2026-10-31
- **Status:** Active (additive; decided by the PM under delegated authority)
- **Decision:**
  - `AiWriteMode` (`replace`, `append`) and `AiWrite` (`connectionId`, `content` as markdown, `mode`) in noted_core.
  - `BoxCodec.aiOwner(data)`, default null: the owning connection's id.
  - `BoxCodec.aiWrite(data, write)`, default null: the data after the write, or null if the type takes no AI writes. The host checks ownership and the page's AI setting first.
  - `CommandHost.viewCentre` (noted_canvas): the middle of the visible view in page coordinates, or null without a view. `CanvasController.insertBox` takes an optional `autofocus`.
  - Recorded in `packages/noted_core/BOX_API_CHANGELOG.md`.
- **Rationale:** The host must ask a box type, not parse its data, to learn who owns it and to apply a write (invariant 2).
- **Alternatives considered:** the app reading the AI box's `"owner"` key directly (the core would parse a module's data); a separate AI-box-only interface outside the Box API (invariant 1).

## 0108 — Per-box AI codes and their safeguards
- **Date:** 2026-11-01
- **Status:** Active, amended by 0115 (approval per code, not per session) and 0117 (Writer permissions, closed-app writes) and 0123 (revoked codes keep their history) (approved by the maintainer; supersedes 0105 and the owner and *Connected AI* parts of 0104)
- **Decision:**
  - **Rules live in the AI box.** Page and binder settings never govern what happens inside an AI box. An AI box is reachable through its own codes whatever its page's AI access (0109).
  - **Connecting:** in an AI box, *Connect a chat* → *Writer* or *Reader* → a label the user types (for example "Feedback – work chat") and an optional expiry (none, 1, 7 or 30 days). Noted shows the code once, titled "Code for <label>", with *Copy*; the dialog can't be dismissed by accident while the code shows, nor while it is being issued.
  - **Codes:** `noted_<16 hex id>_<256-bit key in base64url>`. Only the SHA-256 of the key is stored; keys are compared in constant time. Each code is scoped to one target and one role. A box has at most one Writer: issuing a new Writer retires the old one, after a warning. Any number of Readers. A role or target kind the app doesn't know grants nothing.
  - **Storage:** local and never synced: `ai-access.json` in the app's data folder (`%APPDATA%\Noted`), holding each code's id, target (kind, id, and for a box the page id at issue), role, label, hash, created, last used, expiry and approved sessions, plus each box's *Ask before each write*. Unknown fields and unparseable times are kept as written; an unparseable expiry counts as expired. A missing file has no codes; an unreadable or newer-format file accepts no code and is never overwritten. Writes go through a lock file and an atomic rename. The file is re-read on every check, so a revoke takes effect on the next request.
  - **Safeguards:**
    - Codes work only on this computer: the link listens on loopback only (0106).
    - **Approve new connections:** each `noted_mcp` process makes a random session id (32 bytes). The first time a code is used from a new session, Noted asks "<app> wants to read and write <label>. Allow?" (*read* for a Reader code). *Deny* is the default button. Nothing reaches the box until allowed. Approved sessions are listed under the code and can be revoked; a revoked session is asked again.
    - The app name comes from the MCP client's `clientInfo`; control characters become spaces and Unicode format characters are removed before it is shown, stored or logged.
    - One question is on screen at a time; the others wait. Each code may have one question waiting and all codes together four; more get `busy`. After a *Deny*, new sessions of that code are refused without a question for 30 s. An unanswered question is refused after 45 s.
    - **Ask before each write** (per box, optional): every write shows a question with a short preview of the content.
    - **Activity log:** `ai-activity.json` beside the codes, the last 1000 reads and writes with time, app, connection label, operation and result. Shown in the box's connections panel. An unreadable or newer log is left alone.
    - **Expiry** per code; an expired code is shown as expired and refused.
  - **The box's connections panel** (from the indicator in the box header): each code with label, role, created, last used and expiry; its sessions, each revocable; *Revoke* with a confirmation; the *Ask before each write* switch; the activity list. These work on a read-only page too, since they change only the local store.
  - **The AI sees boxes only by id:** a box code reads and writes that box only, with no page title, page id or page list; links in it become plain text.
  - **Migration:** the app-wide AI connections of 0105 and `NOTED_TOKEN` are removed. An `"aiConnections"` value already in `settings.json` is kept in the file as written but no longer used. An AI box that has an `"owner"` keeps it and its text untouched (invariant 2) and has no writer until a code is issued.
  - **Box API:** unchanged. The host no longer calls `BoxCodec.aiOwner`; `AiWrite.connectionId` carries the id of the Writer code. The app reaches the AI box through `AiModule(access: AiBoxAccess)`, the module's own constructor.
- **Rationale:** Each AI box decides who may read or write it, and the user can see and cut off each chat separately. Keeping codes local and hashed means a synced page file or a copied settings file can't be used to reach a box, and approval per session stops a leaked code from being used silently by another program.
- **Alternatives considered:** keeping app-wide connections that own boxes (one identity could reach every box it owns, and ownership synced in page files); codes stored in the box data (they would sync to every device and every reader of the page); a per-write question always on (too disruptive for routine writes, so it is optional per box).

## 0109 — Page and binder AI access: Open, Privileged, Guarded
- **Date:** 2026-11-01
- **Status:** Active, amended by 0119 (the access-loss note, the pin option) (approved by the maintainer; supersedes 0100)
- **Decision:**
  - **Values**, from loosest to strictest:
    - **Open:** any AI using this Noted's MCP server can read the page. No code needed.
    - **Privileged:** only a chat holding a Reader code for the page or a binder above it can read it. Page and binder codes work like box codes (0108): label, hash only, revoke, new-connection approval, activity log, expiry. A code on a binder or page covers everything under it that isn't tightened further. An *Organize* role is planned and not built.
    - **Guarded:** no AI access. The app default, so new pages and binders are Guarded unless set.
  - **Storage:** `"ai":"open"|"privileged"|"guarded"` in the page header's `noted` object and in the binder file, as in 0100.
  - **Migration:** a stored `page` reads as Open; `off` and `box` read as Guarded. Any other value is kept as written and treated as Guarded. Nothing is rewritten until the user picks a value.
  - **Inheritance and tightening:** the effective value starts at the binder's value (any of the three; none means the app default, Guarded). A top-level page outside any binder whose header records no parent may choose any value. Every other page can only tighten: its effective value is the stricter of its own and the inherited one, and looser choices are not offered. A page whose recorded parent can't be read (missing, unreadable or looping) starts from Guarded. Binders have no exemptions above them.
  - **What a page AI reads:** every box of a readable page except encrypted boxes and boxes of unknown types, which stay placeholders. That includes other AIs' boxes, whose `<ai-written>` markers show what an AI wrote (0104). Search covers only what that AI can see. A page AI never writes page content; an AI writes only in its own box. Organizing pages is for a later entry.
  - **Locked binders:** a plain in-app binder lock hides that binder's pages from page AI; AI boxes in them stay reachable by their own codes. Encrypted content is never readable (`noted_mcp` has no keys).
  - **Code:** `AiAccess`, `effectiveAiAccess` (value and source), `inheritedAiAccess` and `allowedOwnAiAccess` in noted_core (`src/ai/ai_access.dart`); `ConfigSource` names where a value comes from.
- **Rationale:** Readable without a code, readable with one, or not at all covers the cases users asked for, and Guarded by default means nothing is exposed without a choice. Tightening only means a parent's choice can't be undone by a page below it.
- **Alternatives considered:** keeping Off, Box only and Whole page (Box only no longer means anything once boxes carry their own codes); letting pages loosen their parent's value, as 0100 did (a single page could escape a Guarded binder); rewriting legacy values on load (it would change files the user hasn't edited, against invariant 2's spirit).

## 0110 — How code checks work: ai-link/2 and MCP server 0.3.0
- **Date:** 2026-11-01
- **Status:** Active, amended by 0116 (closed-app reads, the running lock, the server log) and 0117 (closed-app writes) and 0122 (merge_requests and propose_merge) (approved by the maintainer; amends 0101 and 0106; implements invariant 4 for codes)
- **Decision:**
  - **Open pages** are read by `noted_mcp` from saved files, as before; this works with Noted closed.
  - **Anything that needs a code** (box reads and writes, Privileged pages) goes through the running app over the link, so the app checks the code, its expiry, its role and target, and the session's approval, and logs the request. With Noted closed, code-based access fails with "This needs Noted running: codes are checked by the app. Open Noted and try again."
  - **Content comes from saved data only.** For a read, the app returns a grant and `noted_mcp` reads the saved files itself: a box grant `{kind:"box", box, page}` or a pages grant `{kind:"pages", pages:[…]}` with the page ids the code covers (Privileged or Open by effective access, minus Guarded and tightened pages and pages of locked binders). `noted_mcp` also checks each granted page's access in the saved files, so a grant can't widen access.
  - **Link protocol `ai-link/2`:** the transport of 0106 (loopback TCP, `ai-link.json`, nonce greeting, one JSON line of at most 1 MiB per connection, at most 8 connections, 5 s to send the request). Every request carries `code`, `session` and `app` (at most 128 and 200 characters). Operations: `write_box {box, mode, content}` → `{ok:true, box}` (no page id or title); `access {action, target}` → a grant; `describe_code` → kind, id, role and expiry. `read_box` and `read_page` access need a target. Error codes: `bad_request`, `busy`, `bad_code`, `expired`, `not_approved`, `wrong_role`, `no_box`, `not_writable`, `conflict`, `locked`, `save_failed`; a code from a newer app keeps its wire name and message. Anything that isn't an `ai-link/2` JSON object, such as an HTTP request, is closed at once with no answer.
  - **Order of checks in the app:** the code (an unreadable store or a busy lock answers `busy`), expiry, role and target, the session's approval, then the operation. The code is checked again after any question, so a revoke or expiry during a question refuses. Each request has one deadline of 50 s for its questions, the wait for the notebook to load and the per-write question, below the MCP client's 55 s; a client that has gone away gets nothing applied.
  - **Writes:** the 0106 rules without ownership and the page setting: the box exists, takes AI writes and its type is allowed on its page (0111) (`not_writable`), isn't in a sync conflict, and its page can be edited. A write is one undo step and is saved through the normal path.
  - **MCP tools (server 0.3.0):** `list_pages(code?)`, `read_page(page_id, code?)`, `read_box(box_id, page_id?, code?)`, `search(query, code?)`, `write_box(box_id, code, content, mode)` and `describe_code(code)`. `list_my_boxes` and `NOTED_TOKEN` are removed. Box ids are unique per page; `page_id` narrows a read without a box code. A box code on a page tool answers `wrong_role`. Privileged and Guarded pages answer like missing pages to a chat without a covering code.
  - **Registering:** `app/scripts/register-mcp.ps1` registers `noted_mcp.exe` with Claude Code without a token; `docs/mcp.md` documents the tools, codes and the Claude desktop entry.
- **Rationale:** Only the app holds the code store, so only the app can check codes, ask the user and keep the log. Returning grants instead of content keeps one renderer, in the server, reading saved files only, so nothing from the live screen reaches an AI (invariant 4).
- **Alternatives considered:** the app returning rendered content (a second renderer, and a path from the app's state to the AI); `noted_mcp` verifying codes itself (would let code-based reads work with Noted closed; it needs hashing in the server and is listed for the maintainer, not built).

## 0111 — Box types allowed per page and binder
- **Date:** 2026-11-01
- **Status:** Active (approved by the maintainer; extends 0035)
- **Decision:**
  - **Setting:** `"boxTypes":{"<type id>": true|false}` in the page header's `noted` object and in the binder file; `false` means not allowed here. An absent type inherits. Unknown keys and non-boolean values are kept as written; a non-boolean value is read as absent.
  - **Inheritance:** like AI access (0109): a binder, or a top-level page outside any binder, may allow or disallow; every other page can only disallow. A type is allowed on a page unless the page or a level above disallows it. The always-on note type can't be disallowed.
  - **Disallowed behaves like a switched-off module (0035)** on that page: its boxes show their saved snapshot, read-only, marked "Not allowed on this page"; its Insert and tool commands are disabled with "(not allowed on this page)" in the tooltip; pasted or dropped files don't create boxes of that type; *Embed* and *Move to folder* (0098) skip them; the conflict dialog for one shows only the two snapshots and offers no manual edit, as for a module the device can't run (choosing a whole version or keeping both still works); AI writes to such a box answer `not_writable`. Nothing is deleted or rewritten, and allowing the type again restores the boxes. The MCP server still reads such boxes; they can't be written.
  - **Code:** `src/model/box_types.dart` in noted_core; the app passes the page's disallowed type ids to `PageCanvas.disallowedTypes`, and `ModuleRegistry` gains `isSwitchable` and an `exclude` set on `moduleForFile` (host-side, not the Box API).
- **Rationale:** Some pages or binders shouldn't hold certain box types (for example AI boxes in a private binder) without the user losing what is already there.
- **Alternatives considered:** deleting or hiding disallowed boxes (data loss, against invariant 2); an app-wide switch only (already exists in 0035 and is too coarse); hiding disallowed boxes from the MCP server too (the setting controls inserting and editing, not confidentiality).

## 0112 — The Page and Binder settings panel
- **Date:** 2026-11-01
- **Status:** Active, amended by 0119 (scroll cue, pin option) (approved by the maintainer; moves the settings of 0098 and 0109 and page backgrounds out of the right-click menus)
- **Decision:**
  - A **Page settings** button beside the page title and a **Binder settings** button on the binder cover and in the sidebar binder header open one shared panel (a dialog with *Close*).
  - **Sections:**
    - **Background** (pages only).
    - **Images and files:** the inherited storage and its source; for a page, *Embed* or *Move to folder* with the result shown inline.
    - **AI access:** *Same as …* with the inherited value and its source (for example "Same as binder (Privileged)"), then only the values that tighten it; a binder shows *App default (Guarded)* and all three. When Privileged, or when codes exist, a **Codes** list: *Connect a chat* (Reader) → label and expiry → the code once with *Copy*; each code with label, created, last used and expiry, its sessions (revocable) and *Revoke* with a confirmation; the latest activity.
    - **Box types allowed:** each switchable module with *Allowed* / *Not allowed here*, its inherited value and source; on a page, a type disallowed above shows "Not allowed (set by …)" and offers nothing.
  - Each setting shows its inherited value and source. Pages can set a tightening exemption per setting; binders can't.
  - **Right-click menus** keep only page and binder actions (new subpage, rename, move, template, delete); the settings entries are removed.
- **Rationale:** One place for every page and binder setting, showing where each value comes from, replaces settings scattered across context menus.
- **Alternatives considered:** a side sheet (more room, but the panel is short enough for a dialog and matches the AI box dialogs); keeping settings in the context menus (no room to show inherited values, sources or codes).

## 0113 — Follow-ups to run 2026-11-01-01
- **Date:** 2026-11-01
- **Status:** Active, amended by 0118 (import limits) (approved by the maintainer; amends 0097 and 0104)
- **Decision:**
  - **The link** drops anything that isn't the Noted protocol (0110).
  - **Undo in a box:** Ctrl+Z (Cmd+Z) in an open note or AI box with nothing left in the editor's own history runs the page undo; Ctrl+Y and Ctrl+Shift+Z likewise for redo. A page undo that removes the box being edited also ends its editing.
  - **Code and HTML in AI writes:** fenced and indented code blocks and raw HTML blocks become plain paragraphs holding their literal text (one paragraph per block, lines kept); HTML is never interpreted, images stay dropped and the link-scheme allowlist is unchanged. Inline HTML stays text. This amends 0104's markdown import; a code block type is for later.
  - **Single instance (Windows):** a named mutex per data folder (a hash of the resolved `%APPDATA%\Noted`) in the runner. A second launch on the same data finds the first window by a property the first instance sets on it, restores and focuses it, and exits; if the first instance is shutting down, it waits up to 10 s and then starts. Launches on other data folders (tests, scratch data) are unaffected.
  - **Toolbars at narrow widths:** in both layouts the middle of the bar shows the commands that fit, in order, and a trailing **More** menu holds the rest, grouped as in the layout, with live enabled and checked state; choosing one runs it without taking focus from the note. Shortcuts of hidden commands still work. Amends 0097.
  - **AI box polish:** the code stage names the connection and Enter submits; marker bars are 2 px, muted, continuous across consecutive AI-written blocks and stop at each block's own row; icons in the AI dialogs are muted. `docs/design/ai-box.md` records the marker, the header and the dialogs.
- **Rationale:** These close the items the maintainer approved from the last report.
- **Alternatives considered:** sideways-scrolling toolbar groups instead of *More* (hidden commands with no cue); dropping code and HTML (the AI's text was lost); a single-instance guard per Windows session (it blocked test runs and scratch-data instances while the user's Noted was open).

## 0114 — Invariant 4: code checks, an access log and closed-app writes in the MCP server
- **Date:** 2026-11-01
- **Status:** Active (approved by the maintainer; supersedes 0103)
- **Decision:** Architecture invariant 4 reads:
  - The MCP server is a separate executable with no key access and no decryption code.
  - AI-facing output is built from saved data only, never the live screen. Encrypted content is never readable.
  - It may verify AI codes by hash (no keys, no decryption).
  - It writes only two things: (1) its own access log, append only; (2) an AI box's own data in a page file, and only when Noted isn't running and that box allows writes while Noted is closed, within the Writer permission the box grants. It never writes anything else.
  - While Noted is running, every write goes to the app over the local link, and the app decides and saves through its normal path.
- **Rationale:** With checks only in the app (0110), an AI could do nothing with Noted closed. Verifying a hash needs no key and decrypts nothing, and the two narrow writes keep the server from touching anything but its log and one opted-in box.
- **Alternatives considered:** keeping every code check in the app (no AI access with Noted closed); letting the server write any file it reads (no boundary left); queuing closed-app writes for the app to apply later (the AI gets no answer, and the queue is another file the server writes).

## 0115 — Approval per code
- **Date:** 2026-11-01
- **Status:** Active (approved by the maintainer; amends 0108, replacing approval per MCP session)
- **Decision:**
  - A code is approved the first time it is used: Noted asks "<app> wants to read and write <label>. Allow?" (*read* for a Reader). The answer is stored on the code (`"approved"` in `ai-access.json`); after that the code needs no question until it is revoked or expires. Per-session approval is gone; an old `"sessions"` value is kept in the file as written and unused.
  - One question per code at a time, with the queue, limits, 30 s pause after a Deny and 50 s request deadline of 0108 and 0110.
  - A code first used while Noted is closed is refused with "Approve this code in Noted first. Open Noted: it will ask you." and the server logs `pending_approval` (0116). When Noted next opens it asks about each such code ("… It asked while Noted was closed."), once per pending use: the time of the user's answer is kept with the code, so a Deny isn't asked again until the code is used again. A live request joining that question waits no longer than its own deadline.
  - The AI box and the settings panel show "Approved <date>" or "Not approved yet" per code.
- **Rationale:** Each `noted_mcp` process is a new session, so approval per session asked again on every restart of the AI app and made approval impossible with Noted closed. A code is the user's own grant, so approving it once is enough.
- **Alternatives considered:** approval per session (asks at every restart; can't work with Noted closed); no approval (a leaked code would be usable at once).

## 0116 — Reading while Noted is closed, and the server's access log
- **Date:** 2026-11-01
- **Status:** Active (approved by the maintainer; amends 0110)
- **Decision:**
  - **Is Noted running?** The app holds an exclusive OS lock on `noted-running.lock` in its data folder for its whole life (opened without truncating; a few quick retries at start, then every 3 s, with a banner "Noted can't tell AI tools it's running…" while it isn't held). `noted_mcp` treats Noted as running if that lock is held, or if `ai-link.json`'s port answers the nonce greeting. Only when neither holds is Noted closed. When Noted is running but its link doesn't answer, the server answers "Noted is running but didn't answer; try again." and never falls back to the closed path.
  - **Closed-app reads:** `noted_mcp` verifies Reader and Writer codes itself against the saved `ai-access.json`: SHA-256 of the key in constant time, expiry, approval, role and target. It computes the same grants as the app (0110) from saved files: Privileged pages a page or binder code covers (one tree over all standalone folders, one per binder), minus Guarded and tightened pages and locked or unreadable binders; a box code reads that box only, with no page information. A missing store answers the "Open Noted" message; a damaged one "Noted can't read its codes. Open Noted to fix it."
  - **The access log:** `ai-mcp-log.jsonl` beside `ai-access.json`, one JSON line per code-based read or write the server handles while Noted is closed: time, code id (never the key), target, operation, app (cleaned), label and result (`ok`, an error code or `pending_approval`). The server only appends, under a short non-blocking lock with a few retries on a lock violation; it never edits or deletes a line. Noted merges entries whose code belongs to that box, page or binder into its activity lists, marked "while Noted was closed", with the code's current label, and keeps the file to its last 1000 lines under a lock on the same file.
  - **Code:** `src/ai/ai_access_read.dart`, `src/ai/ai_mcp_log.dart` and the hash helpers are in noted_core's read export; only `crypto`'s `sha256` is used. `noted_mcp`'s invariant test allows exactly that.
- **Rationale:** An OS lock is released by the system when the app exits or crashes, so "closed" is decided from a positive signal and can't be produced by a busy or full link. Keeping the server's log in its own append-only file means the server never writes the app's files.
- **Alternatives considered:** deciding "closed" from an unanswered link (an AI's parallel calls or a slow start could make the server write under a running app); the server writing the app's activity log (another file the server would rewrite).

## 0117 — Writer permissions and writes while Noted is closed
- **Date:** 2026-11-01
- **Status:** Active (approved by the maintainer; amends 0104 and 0108; Box API 0.10 approved by the maintainer)
- **Decision:**
  - **Writer permission** per AI box, chosen in its connections panel: **Append only** (default), **Edit** (append, and change its own AI-written text), **Full** (also replace the whole box, and replacing with nothing empties it). Stored locally as `"writerPermission"` per box in `ai-access.json`; absent or unknown reads as Append only. The app enforces it on link writes, before any question and again just before applying; `noted_mcp` enforces it on closed-app writes. A mode it doesn't allow answers `not_permitted`.
  - **Modes** on the wire and in `write_box`: `append`, `replace_ai`, `replace`. **Box API 0.10:** `AiWriteMode.replaceAiText` removes every block whose AI mark still matches it (0104) and puts the new blocks where the first such run was (or at the end), keeping every user-written block in place byte for byte. Because the mark survives bold, a to-do tick or a level change, Edit can replace such a block; once the user changes a block's words or type it is theirs. The panel says so.
  - **Allow writes while Noted is closed (no approval)**, per AI box, off by default (`"closedWrites"`). Turning *Ask before each write* on turns it off, and while Ask is on it can't be turned on. When it is on and Noted isn't running (0116), `noted_mcp` writes that box's own data into the page file itself, if: the Writer code is valid, approved and unexpired for that box; the mode is within the Writer permission; the box is an AI box, not encrypted, of a type allowed on its page (0111), not in a sync conflict, and not in a locked binder. Otherwise nothing changes; with the switch off the AI is told "This box doesn't take writes while Noted is closed. Open Noted and try again, or ask the user to allow it in the box."
  - **How it writes:** the same `applyAiWrite` the app uses, spliced into the page file so that every byte outside that box's record is kept (invariant 2); a new `rev` with the old one as `baseRev` and the computer's name and time, as `commitBox` does, so per-box conflicts (0020, 0053) still work; a temporary file with a random name in the same folder, created exclusively, then a rename. If the page changed between reading and renaming, the server re-reads, re-runs every check, and retries once, then answers `busy`. Writes in one server process are serialized; two separate server processes writing the same page at the same instant can still lose one write. Only page files directly inside a folder the server lists, and not links, can be replaced. If Noted opens meanwhile, its file watching picks the change up, and an unsaved edit to the same box becomes a per-box conflict.
  - **The narrow writer:** one library in `noted_mcp` (`closed_writer.dart`) holds the only file-writing code: appending to the log and replacing a page file. The invariant test fails on any other file, process, isolate or socket API in the server or the core libraries it imports.
- **Rationale:** A user who wants an AI to keep notes while Noted is closed can allow exactly that for one box, with the least power that does the job; everything else about a page stays byte-identical.
- **Alternatives considered:** Edit allowed only on boxes with no user text (no Box API change, but an AI couldn't revise its own text once the user had typed anything); closed-app writes queued for the app (no immediate answer, and another file the server writes); writes allowed on any page box (beyond what the user opted into).

## 0118 — Pure-Dart markdown import
- **Date:** 2026-11-01
- **Status:** Active (dependency approved by the maintainer; amends 0104 and 0113)
- **Decision:**
  - `markdownToNoteBlocks` lives in noted_core (`src/format/note_markdown_import.dart`), built on the Dart team's `markdown` package (BSD-3-Clause), pinned exactly to 7.3.1. The note and AI boxes and `noted_mcp` all use it, so app and server writes give the same blocks. It keeps the rules of 0104 and 0113: text blocks only, code and raw HTML as plain paragraphs, links only for `http`, `https` and `mailto` (after entity decoding), images dropped.
  - **Bounded cost:** blocks over a length, delimiter or nesting limit, and everything after a whole-import budget of about 20,000 markup delimiters, become plain paragraphs holding their literal text; any error from the parser does the same. About 1 MiB of hostile markdown imports in well under a second, and nothing is lost, but past the budget a very large import keeps its markup as literal text.
- **Rationale:** `noted_mcp` can't load Flutter, and appflowy_editor's decoder is Flutter-only. One importer in the core keeps the two writers identical; the limits keep a single write from freezing the app or the server.
- **Alternatives considered:** a hand-written parser (no dependency, more code, and the app would drift from the server unless it switched too); importing on a background isolate only (still unbounded work).

## 0119 — Follow-ups to run 2026-11-01-02
- **Date:** 2026-11-01
- **Status:** Active (approved by the maintainer; amends 0109 and 0112)
- **Decision:**
  - **Pages that lost AI access:** after the 0109 migration, a one-time note "Some pages are no longer open to AI" lists the pages whose own stored value is still the legacy `page` and that are now Guarded or Privileged through inheritance, each with a *Page settings* button. It is shown once (`"aiAccessNoteShown"` in `settings.json`), only when the list isn't empty, only when every binder and folder could be read, and never when `settings.json` couldn't be read (so the app never writes over it by itself).
  - **`aiConnections`** (0105) is removed from `settings.json` on the next settings save; other unknown fields are kept.
  - **Settings panel:** a cue at the bottom edge while content continues; *Codes* and *Activity* sub-headings lighter than section headings; the value equal to the inherited one is offered as a pin, e.g. "Privileged (keep even if the binder changes)", instead of a second identical choice.
  - **Dialogs and toolbars:** focus outlines show only with keyboard focus; in the approval question both buttons have the same weight and *Deny* stays the default; the *More* menu opens below the bar in both layouts.
  - **Not changed:** conflict handling for boxes a device can't run (the maintainer is still deciding); the single-instance guard on macOS and Linux (with the Apple build path).
- **Rationale:** These close the items the maintainer approved from the last report.
- **Alternatives considered:** migrating such pages' Open up to their binder (would widen access the user didn't set there); showing the note at every launch (noise).

## 0120 — Sync issues: how they are shown and settled
- **Date:** 2026-11-01
- **Status:** Active (approved by the maintainer; refines 0020 and 0051, extends 0053, supersedes 0035's rule that a conflict on a box the device can't run waits for a supporting device)
- **Decision:**
  - **Kinds of issue**, each belonging to one box and kept in the page file until resolved, so it survives restarts and reaches other devices:
    - **Landed:** a box that arrived from another device in a merge (0051's three-way merge or 0053's conflict-copy merge) and overlaps a box the other device couldn't see there (one it didn't have, or had elsewhere). Stored as `"landed":{"at":<ms>,"device":"<name>"}` in the box's `noted` header. A deliberate overlap made on the other device is not an issue. In the three-way merge the marker follows the rule of `conflicts` (the side that changed it wins); a conflict-copy merge keeps it if either side has it. The recovery merge never marks.
    - **Conflict:** both sides changed the box's content, or one deleted it while the other edited it (0051's `conflicts` record, unchanged).
    - **Unreadable conflict:** a conflict on a box this device can't open (module off, type disallowed on the page, 0111, or not installed).
  - **Presentation:** when a page with issues opens, a dialog shows them one after another (reading order, "n of m", Previous and Next). *Silence* (or Esc) folds them into a red circular icon with a count in the page's corner; each affected box then shows a red warning chip in its place (a landed box also a red outline). The icon reopens the sequence; a chip opens that box's issue only; F8 (*Show page issues*) does the same from the keyboard. Silence lasts for the app run. Issues that arrive while the page is open don't interrupt typing: they show the chip and the icon. Read-only pages show none of it. The sidebar marks pages with any issue.
  - **Settling:**
    - Landed: *Place it* selects the box, highlighted red, ready to move; the first move or resize, or *Leave it here*, clears the marker. Undo restores the marker and the position only, keeping content typed since.
    - Conflict: *Keep this version*, *Keep the other version*, *Place both* (the other becomes a new box beside the first, with a new id), or *Ask the page AI to merge* (0122) when available. Keeping the other version takes only its content; position, size and the landed state stay this box's. Delete conflicts: *Keep the box* or *Delete it*.
    - Unreadable conflict: *Keep this version*, *Keep the other version* or *Place both*, shown from the saved snapshots; the box data is never decoded (0035). When the recorded other version isn't a Noted box, only *Keep this version* is offered.
    - Each choice is one undo step and settles one conflict record at a time; a box with several shows the next.
  - The manual-edit merge view of 0051 is removed; asking the page AI, keeping one version and placing both replace it.
  - **Code:** `src/merge/page_issues.dart` in noted_core (`pageIssues`, the landed rules and the resolution helpers), and `page_issues_dialog.dart` in noted_canvas.
- **Rationale:** Issues were easy to miss as a badge and hard to settle one by one. Showing them when the page opens, letting the user put them off without losing them, and offering choices that never read inside data the device can't open keeps nothing hidden and nothing lost.
- **Alternatives considered:** a blocking dialog until everything is settled (stops note-taking); per-device markers that don't sync (the issue would vanish on other devices); keeping the manual-edit merge view (duplicated what keep, place both and the AI merge cover, and needed a working module for both versions).

## 0121 — Additions on both sides merge automatically
- **Date:** 2026-11-01
- **Status:** Active (approved by the maintainer; refines 0020 and 0051)
- **Decision:**
  - When both sides changed a box's content, the box type's `merge` (Box API, unchanged) decides; only when it can't is the box conflicted.
  - **Note and AI boxes:** merged when each side is the base's blocks unchanged and in order with blocks only inserted, or with text only appended to the base's last block or prepended to its first (as new runs; base runs and attributes unchanged). Additions at the same place keep mine first; identical additions on both sides are kept once. Anything else is a conflict: any edit, deletion, reorder, attribute or data change of a base block, a sub-item added under a base block, both sides extending the same end of a block with different text, or a base that is only an empty line typed into on both sides. Runs are joined only where an addition meets base text and both are plain. Other top-level keys merge three-way. AI marks stay with the blocks the AI wrote.
  - **Drawings:** the union of 0041, unchanged. **Image and file boxes:** merged only when both sides ended up identical, otherwise a conflict. Sticky labels: per field, unchanged.
  - **Conflict copies (0053)** have no common base, so nothing merges automatically there.
  - Writes an AI made while Noted was closed (0117) bump `rev` like any edit and merge or conflict the same way.
- **Rationale:** Two people adding notes to the same box is the common case and loses nothing when both additions are kept; anything less clear is left to the user.
- **Alternatives considered:** merging text edits at the character level (could produce text neither side wrote, such as "Total: 507"); merging image picture and alt text separately (could pair a picture with another picture's description).

## 0122 — Asking the page AI to merge a conflict
- **Date:** 2026-11-01
- **Status:** Active (approved by the maintainer; amends 0110)
- **Decision:**
  - **Available** for a conflict (not a delete conflict) on a note or AI box whose module is on and whose type is allowed on the page, when the page's AI access is Open or Privileged and a page or binder Reader code covering it is approved, unexpired, not revoked and was used over the link in the last 15 minutes. Otherwise the option isn't shown.
  - **Request:** in the app's memory, one per box, withdrawn when the user chooses anything else, moves on or closes, and expiring after 10 minutes.
  - **Link and tools (noted_mcp 0.5.0):** `merge_requests(code)` returns the pending requests the code covers as grants (request id, page, box, type, and each version's device and time); `noted_mcp` reads the saved page's conflict record itself and renders both versions with the same renderer and checks as `read_box` (links to pages the code can't read become text; encrypted boxes refused). `propose_merge(code, request_id, content)` sends the merged markdown to the app (at most 200 KB). Both need Noted running; `no_request` answers a request the code doesn't cover or that is gone. A Reader code is enough, since it only proposes.
  - **Proposal:** shown beside both versions, with the code's label ("Proposed by …"); nothing changes until the user picks *Use the AI's merge*, which applies it as one undo step and settles that conflict record. The AI's own `<ai-written>` lines are ignored: a proposed block that matches a block of either version (as saved, with links reduced as the AI saw them, or after a markdown round trip) is that block verbatim, mark and links included; a block in neither is new, AI-written in an AI box and plain in a note box; a text the versions have in different forms is never marked AI-written if either could be the user's.
- **Rationale:** An AI reading the page can often reconcile two edits better than "keep one". Building what it sees in the server from saved data (invariant 4) and deriving AI marks from the versions keeps the user's text the user's.
- **Alternatives considered:** the app rendering the versions for the AI (a second renderer, and it leaked a link to a Guarded page in review); trusting the AI's markers (it could mark the user's text as its own, and Edit permission could then replace it); offering the merge for any box type (only note and AI boxes have a markdown form).

## 0123 — Revoked codes keep their history; CI on Linux; follow-ups
- **Date:** 2026-11-01
- **Status:** Active (approved by the maintainer; amends 0108, 0115 and 0093); revoked codes pruned and the Linux job blocking per 0126
- **Decision:**
  - **Revoked codes:** revoking a code, or retiring a box's old Writer when a new one is issued, marks it `"revoked": <ISO time>` and blanks its stored hash, instead of deleting it, so no build (including older ones) can verify it. It is listed as "Revoked <date>" without controls, and its activity, in-app and from `ai-mcp-log.jsonl`, stays visible marked revoked. Log lines of codes that were never issued are still dropped.
  - **Approval questions** name what the code reaches, on their own line, labelled and quoted ("Shown in Noted as: "…""): the AI box's first line, or the page or binder title. The name is cleaned like app names, cut at 60 characters by grapheme, and looked up within 2 seconds or left out.
  - **CI:** the test job runs on Windows and on Linux; the Linux job doesn't block yet (`continue-on-error`).
  - **Two server processes** writing the same page at the same instant: left as documented in 0117.
  - **Polish:** a scroll cue in the AI box's connections panel; Deny's focus outline visible in both themes; the access-loss note's *Page settings* as a button; a page that isn't open has its background shown and can be changed from its settings without opening it (0074); the *More* menu opens fully below the bar.
  - **Repository:** `.codex/` (local Codex config) is ignored.
- **Rationale:** A revoked code's history is part of what the user needs to see what an AI did; blanking the hash keeps old builds from accepting it.
- **Alternatives considered:** deleting revoked codes (history lost); keeping the hash with a format bump (older builds would refuse every code, not just revoked ones).

## 0124 — Saves, moves and recovery never overwrite or delete what they can't verify
- **Date:** 2026-11-02
- **Status:** Active (approved by the maintainer through the Codex data-integrity review, findings R-1 to R-7, R-9 and R-10; amends 0049, 0051, 0053, 0059, 0070, 0077, 0098 and 0106)
- **Decision:**
  - **The open page's file (0051):** before every save of the open page, its file is read again, found by path. If it is unreadable, from a newer format, holds a different page, or can't be read for any reason other than not existing, nothing is written: the file stays as it is, the edits go to recovery, and the page becomes read-only with a plain reason and a way out ("Put back a readable version, or open another page"). The block is rechecked by the watcher and the folder timer; when a readable version appears it is merged three-way and the page is editable again, and the block's recovery entry is removed once the merged save reads back. A folder that comes back while the open page waits for it is handled the same way, with or without a recovery entry: a file that is there but unreadable blocks the page, and a missing file puts the page back in place so a file that lands later is merged.
  - **Conflict copies (0053):** a copy is deleted only if its bytes still equal the ones that were merged, and the original is replaced only if it still equals what the merge read. Otherwise the merge is redone, up to five times; then the copy is kept and listed under "Can't open".
  - **AI writes to a closed page (0106):** reread before saving and merged three-way with the loaded page as base; every rule (permission, revocation, conflict, lock, box type) is checked again on the result with nothing awaited between the check and the write. An unreadable or newer file, or a page deleted or moved meanwhile, refuses the write and leaves the file alone; a file that keeps changing answers `busy`; a vanished folder goes to recovery. The closed-app writer in noted_mcp (0117) already compares the bytes it read before and immediately before its rename, and retries once; it was not changed.
  - **Moves (0049, 0059):** when a source can't be deleted, each page is settled on its own. A source is put back only if this move deleted it and the path is empty (claimed with an exclusive create); an existing file is never written over. A page whose source is verified intact loses its destination copy; one whose source is gone stays moved; one whose source exists but can't be verified is kept in both places, and the message names both. Stranded subpages go to the top level of their own location (not between standalone folders, which share one tree). The message always reaches the user, stays on screen when they must act, and gives the OS reason when there is one.
  - **Recovery store (0070):** one file per folder and page, `<id>-<hash of location and id>.entry`, holding the page, its base, folder, page id and time, written to a temporary file and renamed. Location names fold case only on Windows, as the notebook does. An entry is accepted only if its page id, the page's id, the base's id and its file name agree; otherwise it is kept and listed. Leftover temporary files are promoted when newer, removed when an identical or strictly later entry holds them, and otherwise kept and listed. Old two-file entries are migrated without loss; a copy is only ever dropped when an identical or strictly later entry for the same folder and page exists, and an equal time with different content keeps both. Writes, listing, migration and deletion run one at a time, and deleting removes only the generation that was replayed.
  - **Replay (0070, 0077, 0098):** an entry is replayed by its verified page id and retired as soon as its page has landed and been verified. A kept `<id>.assets` folder is its own retry marker: whenever recovery runs (and while the page stays open), its files are copied through a temporary name, checked against the content hash in their names (other names byte for byte), and only the verified files are removed. A different file with the same non-hash name is never replaced. Replay and landing problems are listed under "Can't open", and in the quit notice, with a plain reason, until they succeed.
- **Rationale:** Sync clients replace, lock and delete files at any moment. A save, move or recovery step that acts on a file it hasn't just checked can destroy the only copy of someone's work.
- **Alternatives considered:** saving over an unreadable file (destroys content from a newer app or another device); a recovery manifest with generation files (more files and cleanup for the same guarantee); replaying a whole entry again until its attachments land (not idempotent: brought back deleted boxes and reverted edits).

## 0125 — Automatic cleanup after runs; review cadence
- **Date:** 2026-11-02
- **Status:** Active (approved by the maintainer)
- **Decision:**
  - **`app/scripts/cleanup-run.ps1`** ends `dart`, `dartvm`, `dartaotruntime` and `flutter_tester` processes of this repository (command line, executable or working directory in the main checkout or a registered worktree) only when they are abandoned: their group (the Dart processes plus a `cmd /c` running flutter or dart) has no living parent. A live bash, sh, PowerShell, pwsh or `cmd /k` window always owns what runs under it, because Git Bash shells show a dead parent even while in use. Nothing in the release folder, and not the script or its parents, is ever ended. It removes folders under `.claude\worktrees\` that git no longer knows (no `.git`, or one pointing at a missing git directory) and that are at least 10 minutes old; anything it can't be sure of is kept. `-WhatIf` lists without acting; every action is logged to `%TEMP%\noted-cleanup-run.log`; its selection logic is tested on Windows CI.
  - **Hooks:** Claude Code runs it on SubagentStop and Stop from `.claude/settings.json`, asynchronously; a failure is a warning, never a stop. The file is added by the maintainer.
  - **Agent rules:** builders give background commands a time limit and stop them before handing back; the PM pulls before reading `next.md`, looks for `codex` where its installers put it, and stops all background work and runs the script before writing the report.
  - **Review cadence** (`docs/runs/README.md`): the Codex run-diff review runs at the end of every run; each `next.md` names one area audit, rotating `area-data-integrity`, `area-invariants`, `area-spec-drift`, `area-dead-code`, with `area-data-integrity` again whenever a run changes storage, sync, recovery or AI writes; the maintainer's PM chat triages new findings into accepted or rejected, and accepted ones are queued by report and R-number.
- **Rationale:** Leftover test processes held worktree files and slowed later runs; cleanup must never touch live work.
- **Alternatives considered:** ending every Dart process of the repository (kills live builders and `flutter run`); treating any shell that mentions flutter as a wrapper (ended a live test run in Git Bash).

## 0126 — Linux CI blocks; formula depth; pruning revoked codes; settling saves in tests
- **Date:** 2026-11-02
- **Status:** Active (approved by the maintainer; amends 0123)
- **Decision:**
  - **CI:** the Linux test job blocks a push, like Windows.
  - **Formulas:** a run of operators of one level (`A1+A2+…`) is one node and evaluates in a loop, so long flat formulas work and adjust on every platform; real nesting is capped by tree height (256) as well as by parentheses (100), and past it a formula is an error everywhere instead of depending on the stack.
  - **AI link server:** a client that disappears before or during a reply is a closed connection, not an error.
  - **Revoked codes (0123):** a revoked code is removed from `ai-access.json` once neither the app's activity log nor the MCP access log mentions it, at start and whenever the logs are trimmed or change. A code never used is removed right after it is revoked. Nothing is removed while a log can't be read. A removed code fails the same way as a revoked one.
  - **Tests:** `settleSaves` (app/test/support) settles every queued save, binder and settings write inside the fake-time zone before teardown, and fails naming the stuck job instead of hanging.
- **Rationale:** A blocking Linux job catches platform differences before release; results must not depend on the platform's stack size; `ai-access.json` should not grow forever.
- **Alternatives considered:** skipping the Linux-only tests; capping only the `^` chain or the chain length (flat sums of a few hundred terms stopped working); keeping every revoked code (unbounded growth).

---

## Open items
- **Apple build path:** iOS/iPadOS and macOS releases have to be compiled with current Xcode on Apple-silicon-era macOS. The planned approach is cloud macOS build runners.
- **Equation block sourcing:** resolved (0048).
- **File format:** whether JSON Canvas extra fields are sufficient, and how faithfully appflowy_editor round-trips Markdown.
- **MCP:** the full tool and resource list. Linking an AI to a box: resolved (0108). Code checks and opted-in writes with Noted closed: resolved (0114–0117).
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
