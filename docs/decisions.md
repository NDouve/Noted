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
- **Status:** Active
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
- **Status:** Active
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
- **Status:** Active
- **Decision:** Clicking anywhere on a page creates a plain note box, which grows as content is added.

## 0016 — Ink anywhere on the page
- **Date:** 2026-10-24
- **Status:** Active
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
- **Status:** Active
- **Decision:** Text boxes support tables, plus inline and block LaTeX equations.
- **Notes:** Tables come from appflowy_editor's table block. Where the equation block's code will come from is open; see 0022.

## 0018 — Platforms and reference test devices
- **Date:** 2026-10-24
- **Status:** Active
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
- **Status:** Active
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
- **Status:** Open
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
- **Status:** Active (supersedes an earlier same-day version that required a binder at the top level)
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
- **Status:** Active
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

---

## Open items
- **Apple build path:** iOS/iPadOS and macOS releases have to be compiled with current Xcode on Apple-silicon-era macOS. The planned approach is cloud macOS build runners.
- **Equation block sourcing:** see 0022.
- **File format:** whether JSON Canvas extra fields are sufficient, and how faithfully appflowy_editor round-trips Markdown.
- **MCP:** the full tool and resource list, and the user experience for linking an AI to a box.
- **Cloud conflict copies:** each provider names its conflict-copy files differently.
- **Per-AI overrides:** different rules for different AIs on the same page (deferred).

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
1. A canvas with several draggable, resizable editor boxes plus ink anywhere, tested on a Windows pen tablet, an iPad and an Android phone. Pass condition: zero skipped or broken strokes on fast, long lines, including while a drawing box grows.
2. Microsoft sign-in on Windows (system browser + PKCE).
3. One AI box through a local MCP server, tested under each page AI setting, with an encrypted box on the same page that appears only as a placeholder.
4. reMarkable (later phase).
