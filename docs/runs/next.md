# Next run: AI access redesign, settings panel, follow-ups

Everything below is approved by the maintainer, including the page-format, MCP-boundary and scope changes it implies. Pull main first. Decision numbers below are this repo's (docs/decisions.md).

## 1. AI boxes own their rules: per-box codes

Replaces the box-ownership part of 0104/0105. Page and binder settings never govern what happens inside a box.

- In an AI box: **Connect a chat** → choose **Writer** or **Reader** → Noted shows a unique code once, with a label the user types (e.g. "Feedback – work chat"). Store only a hash.
- One Writer per box; any number of Readers. Issuing a new Writer code retires the old one.
- Each code is scoped to one box and one role. The box lists its connections (label, role, created, last used) and any one can be revoked there.
- **Safeguards:**
  - Codes work only on this machine (the link already refuses non-loopback).
  - **Approve new connections:** the first time a code is used from a new MCP server session (each `noted_mcp` process makes a random session id at start), Noted asks: "<app name> wants to <read|write> <box label>. Allow?" Nothing reaches the box until allowed. Approved sessions are listed per connection and can be revoked.
  - Optional per-box **Ask before each write**.
  - **Activity log** in the box: each read and write, with time, app name (from MCP clientInfo) and connection label.
  - Optional **expiry** per code.
- The chat passes the code on each call. The AI sees boxes only by box id: no page titles or page lists through boxes.
- The app-wide AI connections from 0105 are removed. Existing connection-owned boxes keep their text and have no writer until a code is issued. `NOTED_TOKEN` goes away.

## 2. Page and binder AI access: Open, Privileged, Guarded

Replaces 0100's Off / Box only / Whole page.

- **Open:** any AI using this Noted's MCP server can read it. No code needed.
- **Privileged:** only a chat holding a code for that page or binder can read it. Codes work like box codes (Reader role now; an Organize role comes later): label, hash only, revoke, new-connection approval, activity log, expiry. A code on a binder or page covers everything under it that isn't tightened further.
- **Guarded:** no AI access. The default for new pages and binders, app-wide.
- Page AI never writes page content (an AI writes only in its own box). Organizing comes later; leave a clear place for it.
- A page AI reads every box except encrypted boxes, including other AIs' boxes (tagged AI-written). Search covers only what that AI can see.
- **Inheritance:** a page follows its parent page, then its binder, then the app default. A page may set an exemption that **only tightens** (Open → Privileged → Guarded); a looser exemption is not offered. Binders have no exemptions.
- **Migration of the stored `ai` value:** `page` → Open; `off` and `box` → Guarded. Unknown values are kept as written and treated as Guarded.
- AI boxes are reachable through their own codes whatever the page's access type.
- A plain in-app binder lock hides that binder's pages from page AI, not AI boxes. Encrypted content is never readable (no keys in `noted_mcp`).

## 3. How code checks work

- Open pages are read from saved files by `noted_mcp`, as today; this works with Noted closed.
- Anything that needs a code (box reads and writes, Privileged pages) goes through the running app over the link, so the app checks the code, the approval and the expiry, and logs it. Content returned must come from saved data, never the live screen (invariant 4). With Noted closed, code-based access fails with a clear message.
- Tools: `list_pages`, `read_page`, `read_box` and `search` take an optional `code`. `write_box` requires `code`. Add `describe_code(code)` returning what the code grants (box or page id, role, expiry). Remove `list_my_boxes`.
- **Needs the maintainer, don't build:** letting `noted_mcp` verify codes itself (SHA-256 only), so code-based reads work with Noted closed. Put it in the report with options and a recommendation.

## 4. Module availability per page and binder

A page or binder setting allows or disallows each box type, e.g. "AI boxes: allowed / not allowed here". It inherits and tightens like AI access. Disallowing behaves like switching the module off (0035): existing boxes show their snapshot read-only, nothing is deleted, and allowing it again restores them.

## 5. Settings panel for pages and binders

- A **Page settings** button in the page header and a **Binder settings** button on the binder. One shared panel with sections: Background, Images and files, AI access (with Privileged codes), Box types allowed.
- Each setting shows its inherited value and source. Pages can set an exemption per setting; binders can't.
- The right-click menu keeps only page actions (new subpage, rename, move, template, delete). Remove the settings entries from it.

## 6. Follow-ups from report 2026-11-01-01

- The link rejects anything that isn't the Noted protocol (for example an HTTP request) and closes the connection.
- Ctrl+Z in an AI or note box with nothing left to undo goes to the page undo.
- Fenced code blocks and raw HTML in an AI write become plain paragraphs (a code block type comes later).
- A single-instance guard: a second launch brings the first window forward.
- Toolbars at narrow widths: a **More** overflow menu for whatever doesn't fit, in both layouts.
- reviewer-ui polish: the token/code stage title names the connection and Enter submits; marker bars continuous across blocks and within text width; Rename/Revoke icons muted. Add a short design note for the AI marker to docs/design.
- Add to `.claude/agents/reviewer-ui.md`: "Script for this method: `app/scripts/screenshot-window.ps1` (run with `powershell -NoProfile -ExecutionPolicy Bypass -File`; see its help for -DataRoot, -Theme, -Toolbar, -Clicks, -Keys, -Out)." If committing it is blocked, leave it uncommitted and say so in the report.
- PM instructions: always pull main before looking for `docs/runs/next.md`. Same rule as above if blocked.

## 7. Finish

Update CLAUDE.md's Current phase to match (Open / Privileged / Guarded access, per-box codes, the settings panel, module availability); if committing it is blocked, leave it uncommitted and say so. Analyze, all tests, the integration suite, push, confirm CI, rebuild the release exe and zip. Re-register `noted_mcp` with Claude Code without a token. Curate: per-box codes and safeguards (superseding the ownership parts of 0104/0105), Open/Privileged/Guarded (superseding 0100's values), module availability, the settings panel, and the follow-ups. Report in the standard format, with a sample round trip: issuing a box Writer code, the approval prompt, a write, a Reader code read, and an Open, a Privileged and a Guarded page as seen by an AI.
