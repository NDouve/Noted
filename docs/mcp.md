# Noted's MCP server

`noted_mcp.exe` lets an AI app that speaks the Model Context Protocol, such as Claude Code or the Claude desktop app, read your Noted pages and read and write its own AI boxes. It is a separate program (invariant 4): it reads the saved page files only, has no key access and no decryption code, and never sees what the running app has on screen. The only files it writes are its own access log and, while Noted is closed, an AI box that allows it (see "While Noted is closed"). While Noted runs, everything that needs a **code** goes through the app, which checks the code and decides (see "Codes" and "Writing: the app decides").

The source is `packages/noted_mcp` (version 0.5.0). It is pure Dart and uses the Dart team's `dart_mcp` package over stdio.

## What an AI can see without a code

Each page has an **AI access** value, set in the page settings (binders have one in their settings too):

| Access | What a chat without a code gets |
| --- | --- |
| **Open** | The whole page: listed, found by search, readable, linked. |
| **Privileged** | Nothing. The page is invisible: not listed, not found, not searched, and a link to it shows only its text. Asking for it gives the same answer as for a page that doesn't exist. A chat holding a page or binder code that covers it can read it. |
| **Guarded** (the default for new pages and binders) | Nothing, with or without a code. Same answer as a missing page. |

A page follows its parent page, then its binder, then the app default (Guarded). A page can only **tighten** what it inherits (Open, then Privileged, then Guarded); a looser choice is ignored. A top-level page in no binder is the top of its own chain and may choose any value. A stored `page` is read as Open, `off` and `box` as Guarded, and any other value as Guarded.

Whatever the access:
- On a readable page **every box is readable**, AI boxes included; what an AI wrote in them is marked `<ai-written>`.
- **Encrypted boxes** and **boxes this server doesn't know** are always a placeholder (`[encrypted box]`, `[unsupported box]`), never their data or their stored snapshot.
- **Locked binders** (a binder file marked as locked or encrypted; binder passwords come later) are hidden from page AI. An AI box in one stays reachable by its box code.
- Box types disallowed on a page are still read; they can't be written.
- Box ids are only unique per page, so `read_box` takes an optional `page_id`; without it the first matching page (by id) answers.
- The AI sees boxes **by id only**. Page AI never writes page content.
- Every call reads the files afresh. With no code this works with Noted closed.

## Tools

Each of `list_pages`, `read_page`, `read_box` and `search` takes an optional `code`; the AI passes the code the user gave it.

| Tool | Arguments | Returns |
| --- | --- | --- |
| `list_pages` | `code?` | JSON: each visible page's `id`, `title`, `parent` (its nearest visible ancestor), `access` (`open` or `privileged`) and `location` (Pages or the binder's title). Open pages, plus the pages a page or binder code covers. |
| `read_page` | `page_id`, `code?` | Markdown: the title, then each box from top to bottom and left to right with its type and box id. Notes come out as markdown (headings, styles, lists, check lists, links, equations, tables); drawings as `[drawing]`, images as `[image: alt text]`, files as `[file: name]`. |
| `read_box` | `box_id`, `page_id?`, `code?` | One box, as `read_page` shows it. Without a code: a box on an Open page. With a page or binder code: also a box on a page it covers. With a box code: that AI box only, and nothing about its page (no title, page id or page list). |
| `search` | `query`, `code?` | JSON: visible pages whose title or text holds every word, with a snippet of each match. Put a phrase in quotes. |
| `write_box` | `box_id`, `code`, `content` (markdown), `mode` (`append`, `replace_ai` or `replace`) | Writes to an AI box with its Writer code: asks the running Noted app, or, while Noted is closed and the box allows it, writes the page file itself. The mode must be within the box's Writer permission (see below). The code is required. |
| `describe_code` | `code` | JSON: what the code covers: `kind` (`box`, `page` or `binder`), `id`, `role` and `expires`. Asked of the app. |
| `merge_requests` | `code` | Helps with a sync conflict (see "Merging a sync conflict"). JSON: the merges the user asked the page AI for that this page or binder code covers: request id, page id, box id, box type and the two versions as markdown (`mine`, `theirs`, with the computer and time of each), rendered by the server from the saved page file (see below). Needs Noted running. |
| `propose_merge` | `code`, `request_id`, `content` (markdown) | Sends the merged markdown for one request. Only a proposal: the user decides in Noted. Needs Noted running. |

A box code used with `list_pages`, `read_page` or `search` is refused with a `wrong_role` message: a box code reads its own box with `read_box`, not pages. `list_my_boxes` and the `NOTED_TOKEN` environment variable no longer exist (the variable is ignored if set).

AI boxes read as markdown (`read_page` shows type `ai`).

## Codes

A code is made in an AI box ("Connect a chat": Writer or Reader) or in the page or binder settings (Reader, for Privileged pages), shown once with a label the user types. It is `noted_<id>_<key>`; Noted stores only a hash. The user gives the code to the chat, and the chat passes it on each call. A box has one Writer code (issuing a new one retires the old) and any number of Readers. Each code can be revoked, can expire, and must be **approved** once: the first time it is used while Noted runs, Noted asks the user "<app> wants to <read|write> <label>. Allow?" before anything reaches the box. The app name is the MCP client's `clientInfo` name and version. After that the code stays approved (`approved` in `ai-access.json`) until it is revoked or expires; there is no per-session approval. A box can also ask before each write. Every read and write is logged.

While Noted runs, the server does not check a code itself. With a code it sends an `access` request to the app, which checks the code, its expiry and the approval, logs the use, and answers with a **grant**: for a box code, the one box and its page; for a page or binder code, the ids of the pages the code reads (Privileged pages it covers, minus Guarded ones and locked binders). The server then reads the **saved files** itself and builds the output, so what the AI sees never comes from the live screen. While Noted is closed it works out the same grant itself (see "While Noted is closed").

Failures reach the AI as clear tool errors: `bad_code` (mistyped or revoked), `expired`, `not_approved` ("The user hasn't allowed this connection in Noted."; with Noted closed: "Approve this code in Noted first. Open Noted: it will ask you."), `wrong_role` (a Reader writing, or a box code used for pages), `no_box`, `conflict`, `locked`, `not_writable`, `not_permitted` ("This box's Writer permission doesn't allow that. Ask the user to change it in the box."), `no_request` (a merge request that expired, was withdrawn or was already answered), `save_failed`, `busy`, and an unknown code from a newer app (its message and code are kept). `describe_code`, and a write to a box that doesn't allow closed-app writes, fail with Noted closed with "This needs Noted running: codes are checked by the app. Open Noted and try again."; reading Open pages without a code works either way. A code that is not shaped like a code is refused without contacting anything, and a code never appears in any output, error or log line of the server.

## Merging a sync conflict

When two computers change the same note or AI box and Noted cannot combine them, the user sees both versions and may choose "Ask the page AI to merge". The option is offered only when the page's AI access is Open or Privileged and a page or binder **Reader** code covering the page is approved, not expired or revoked, and was used in the last 15 minutes. The module must be on, the page must allow the box type, and the box must have a recorded other version. Noted then keeps a request in memory (one per box; it is gone after 10 minutes, when the user withdraws it, or when Noted quits). It is not stored.

The chat calls `merge_requests` with the code, merges the two versions (an AI box keeps its `<ai-written>` lines), and calls `propose_merge`. Both need the running app, which checks the code like any access (approved, covers the page; a Reader is enough, because this only proposes) and logs the use in the code's activity. With Noted closed both fail with "This needs Noted running". For `merge_requests` the app answers with a grant only: request id, page, box and each version's computer and time. **`noted_mcp` reads the saved page file's conflict record itself** and renders both versions with the same renderer and checks as `read_box` (a link to a page the AI can't see keeps only its text; the page's access is checked again in the saved settings; encrypted or unsupported boxes and versions over 100 KB are listed as unavailable, never dropped), so what the AI sees never comes from the app or the live editor. `propose_merge` sends the merged markdown to the app, which attaches it to the request (at most 200 KB). Nothing changes until the user clicks "Use the AI's merge" next to both versions; the box then gets the proposal as one undo step. Which blocks count as the AI's is decided by Noted, not by the proposal: a block that says what a block of either version says is that block, unchanged (its AI mark, formulas, links and styles included); a block in neither is new and is marked AI-written in an AI box and plain in a note box. The proposal's own `<ai-written>` lines are ignored. Only note and AI boxes are offered.

## Writer permission

The user chooses, per AI box, what its Writer code may do. A mode outside the permission fails with `not_permitted`; the app enforces it for link writes and the server for closed-app writes.

| Permission | Allowed `write_box` modes |
| --- | --- |
| **Append only** (default; also what a missing or unknown value means) | `append`: add to the end. |
| **Edit** | `append`, `replace_ai`: replace only the text the AI wrote earlier in the box; the user's own text stays. |
| **Full** | `append`, `replace_ai`, `replace`: replace the whole box. Empty content with `replace` empties it. |

## Writing: the app decides

While Noted runs, the server writes no file for a write. `write_box` sends a request to the running Noted app over a local connection, and the app checks the code (it must be the box's Writer code), the approval, the Writer permission, the box's settings and the page, and then edits and saves the box. Reads of Open pages never need the app.

The link (protocol `ai-link/2`):
- The app listens on **127.0.0.1 only** (loopback TCP, a free port) and writes `ai-link.json` in its data folder: `{"format":1,"port":N,"pid":P,"nonce":"..."}`. The nonce is new at every launch, and the file is deleted on a clean exit.
- The server reads the file, connects to 127.0.0.1 with a short timeout and reads the app's one-line greeting `{"noted":"ai-link/2","nonce":"..."}`. Only if the nonce matches the file does it send the request (one JSON line with `op`, the code, the session id and the app name). The nonce shows the peer can read `ai-link.json`, so it is not a stranger on a stale port; it does not prove the peer wrote the file. A wrong, missing or oversized greeting means "not running", and the code is not sent.
- Ops: `write_box`, `access` (read_box, read_page, list_pages or search), `describe_code`, `merge_requests` and `propose_merge`. The app answers with one line, `{"ok":true,...}` or `{"ok":false,"code":"...","message":"..."}`. A request waiting for the user to approve a session waits for the user's answer; an unanswered prompt is refused (`not_approved`) after 45 seconds, before MCP clients that give up at 60 seconds do, so a late write cannot happen.
- The app drops anything that is not this protocol (for example an HTTP request) without answering.
- Only `link_client.dart` in the server opens a socket; the tests check that, and that it connects to the loopback address alone.

Sample `read_page` output, for an Open test page:

```markdown
# Public plans

**note** · box `note`

## Trip plan

Pack the **zebra** tent and _maps_.

- Tickets
  - Train
1. Book
2. Pay
- [x] Passport

See hidden notes, [the child](noted:page/a000000000000002) and [the web](https://example.com).

$$
E = mc^2
$$

| Item | Cost |
| --- | --- |
| Tent | 120 |
| Total | 120 |

**image** · box `img`

[image: A cat on a map]

**drawing** · box `drw`

[drawing]

**file** · box `file`

[file: Itinerary.pdf]

**encrypted** · box `enc`

[encrypted box]

**unsupported** · box `odd`

[unsupported box]
```

## While Noted is closed

The server decides that Noted is **closed** only from a positive signal: the running app holds an exclusive operating-system lock on `noted-running.lock` in its data folder for its whole lifetime (the system drops it on exit or crash), and the server counts Noted as closed only if that file is absent, or it can open it read-only and take a non-blocking shared lock (released at once; the server never creates or writes the file, and opens no socket for this). If the lock is held, Noted is running: everything above applies and the app decides, and if the link doesn't answer the server says "Noted is running but didn't answer; try again." and never reads codes or writes files itself. When Noted is closed, the server works from the saved files alone. Closed writes in one server process run one after another, each through a random, exclusively created temporary file, and every check (code, approval, permission, type, conflict, locked binder) runs again before the one retry. Known limit: each server process serializes its own closed writes, but two separate server processes (for example two chats) writing the same page at the same instant can still lose one write, because the compare-then-rename step is not one atomic operation; the second write's re-read normally catches it, but a window of a few milliseconds remains. As a second guard, if the lock says closed but `ai-link.json` exists and its port greets with the nonce (a bare connection, no code sent), the server treats Noted as running. A damaged `ai-access.json` answers "Noted can't read its codes. Open Noted to fix it." A missing `ai-access.json` answers "Approve this code in Noted first. Open Noted: it will ask you." Log appends are tried again for about a second if Noted is trimming the log, and a log that still can't be written never fails the request:

**Reads with a code.** It checks the code against `ai-access.json` (read only): the code's shape, the SHA-256 of its key against the stored hash (constant time; this is the only hashing in the server, from the `crypto` package, and there are no keys or decryption), the expiry, that the code is **approved**, and that its role and target fit the request. It then computes the same grants as the app: a page or binder code covers the Privileged pages under it, minus Guarded pages (own, inherited or tightened) and pages in locked binders; a box code reaches that one AI box only, with no page title, id or list. Revocation is just the code being gone from the store.

**Approval.** A code that is valid but not approved yet is refused with "Approve this code in Noted first. Open Noted: it will ask you." and a `pending_approval` entry in the log. The next time Noted opens it reads the log and asks the user about each such code once.

**Writes.** A closed-app write needs all of: a Writer code that is valid, approved and unexpired for that box; the box's **Allow writes while Noted is closed (no approval)** switch on (off by default, and ignored while the box asks before each write); the mode within the Writer permission; the box to be an AI box on a page that allows the AI box type; the box not in a sync conflict; and its page not in a locked binder. Otherwise it is refused and nothing is changed (with the switch off, the AI is told "This box doesn't take writes while Noted is closed. Open Noted and try again, or ask the user to allow it in the box."). The write itself is the same one the app makes (`applyAiWrite`, including `replace_ai`), spliced into the page file so that **every byte outside that box's record stays as it was**; the box gets a new `rev` with the old one as `baseRev` and the computer's name and time, as an edit in the app does, so per-box sync conflicts still work. The file is written atomically (a temporary file in the same folder, then a rename). If the page file's bytes changed between reading and writing it, the server reads again and retries once, then fails with `busy`. If Noted starts meanwhile, its normal file watching picks the change up.

**The access log.** Each code-based read and write the server handles while Noted is closed, successful or refused, is appended as one line to `ai-mcp-log.jsonl` beside `ai-access.json`:

```json
{"time":"2026-11-01T09:30:00.000Z","code":"<code id>","target":{"kind":"box","id":"aiA","page":"f000000000000001"},"op":"write_box","app":"Claude Code 2.1","label":"Research chat","result":"ok"}
```

`code` is the code's id (never the key), `app` is the cleaned MCP client name, and `result` is `ok`, an error code (`not_permitted`, `expired`, `conflict`, `busy`, ...) or `pending_approval`. A request with a code that is malformed, unknown or has a wrong key is refused as `bad_code` and not logged (there is no code to name). The server only appends; Noted merges the entries into the box's activity (marked "while Noted was closed") and may trim the file.

**The narrow writer.** All of this is the only file writing in the server, and it is one small library, `closed_writer.dart`: it can append a line to the log, and atomically replace a page file (`*.canvas`) that sits directly in one of the folders the server's library lists (checked by real path, never through a link). Nothing else in the server or the core code it imports writes, creates, renames or deletes a file; the invariant test checks that.

## Which pages it reads

The same folders as the app on this computer, from `%APPDATA%\Noted` (`~/.noted` elsewhere):
- the default `pages` folder;
- the default page folder chosen in Settings (`settings.json`);
- the standalone folders and binders in `binders.json`.

Pass `--data-dir <folder>` to read another app folder (the tests do).

## Adding it to Claude

**Claude Code.** From the release folder (or `app\scripts` in the repository), run:

```powershell
powershell -ExecutionPolicy Bypass -File register-mcp.ps1
```

It first copies `noted_mcp.exe` to `%LOCALAPPDATA%\Noted\mcp`, so a running chat holds the copy and not the release folder (if a process holds the existing copy, it is kept and the script says so; close the chats using it and run the script again). It then runs `claude mcp add noted -s user -- <path to the copy>`, replacing an earlier registration, so every project sees the server. Check it with `claude mcp list`. The equivalent by hand is:

```powershell
claude mcp add noted -s user -- "C:\path\to\Noted\noted_mcp.exe"
```

**Claude desktop.** The same script prints the entry to add to `claude_desktop_config.json` (Settings > Developer > Edit Config, or `%APPDATA%\Claude\claude_desktop_config.json`). Merge it with any servers already there, then restart Claude. If you added the server before, delete the old `"env": {"NOTED_TOKEN": ...}` entry from it (the token is no longer used, and the file should not keep it):

```json
{
  "mcpServers": {
    "noted": {
      "command": "C:\\path\\to\\Noted\\noted_mcp.exe",
      "args": []
    }
  }
}
```

There is no token or other secret in the registration: the server's configuration holds nothing to keep private. To give a chat access beyond Open pages, give it a code in the conversation; it passes the code on each call. (An earlier version took a token in `NOTED_TOKEN` and `register-mcp.ps1 -Token`; both are gone, and register again to drop an old token.)

Pass `-NoCopy` to register the exe where it is. Run the script with `-PrintOnly` to print the snippet without touching Claude Code. If you move the Noted folder, run it again.

## Building it

`app\scripts\package-windows.ps1` compiles the server with `dart compile exe` into the release folder, next to `noted.exe`, and puts it in the zip. It also refreshes the copy in `%LOCALAPPDATA%\Noted\mcp` unless a process holds it (then it says so and the zip is still built). To build it alone:

```powershell
dart compile exe packages\noted_mcp\bin\noted_mcp.dart -o noted_mcp.exe
```

## Guarantees and tests

`packages/noted_mcp/test`:
- **`invariant_test.dart`** walks everything the executable can import. It fails on any Flutter, key or encryption library, on `dart:ffi`, on any Noted package other than the read-only part of the core (`noted_core_read.dart`), and on any dependency other than `dart_mcp` and `noted_core`. `package:crypto` is allowed, for SHA-256 only: the one import must be `show sha256` in the core's code format, and no other digest, MAC or `Random` other than `Random.secure` appears. It scans the source of every Noted library reached and fails on file-writing APIs anywhere except `closed_writer.dart` (which may only append to the log and replace a page file by temp file and rename, and only be called from `closed_access.dart`), on any socket or HTTP API outside `link_client.dart`, and checks that the link client connects to the loopback address only. (One known exception: the core's `binder.dart` holds the app's binder writer, which the server never uses; it should move out of the read-only core.)
- **`ai_test.dart`** runs the tools against a fake Noted over the link: grants (page and box), box-code isolation (no title or page list), the session id and app name on every request, `write_box` (success and each refusal), `describe_code`, every error code, and Noted not running.
- **`closed_test.dart`** runs the server with Noted not running: code reads (box, page and binder codes, unapproved, expired, revoked), the log (appended, never rewritten, no key), closed-app writes (each mode against each Writer permission, the switch, ask-before-write, type, conflict, locked binder, bytes outside the box unchanged, rev and baseRev, the retry and `busy`), running mode still going to the app, and the narrow writer's path checks.
- **`tools_test.dart`** runs the page tools against pages with each access value (Open, Privileged, Guarded, the legacy values, inheritance and tightening, binders, a locked binder) and checks that hidden pages appear in no output.
- **`stdio_test.dart`** starts the executable and talks to it as an MCP client.

## Not yet

An Organize role for codes (organizing pages) and per-AI rules come later.
