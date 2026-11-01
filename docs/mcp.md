# Noted's MCP server

`noted_mcp.exe` lets an AI app that speaks the Model Context Protocol, such as Claude Code or the Claude desktop app, read your Noted pages and read and write its own AI boxes. It is a separate program (invariant 4): it reads the saved page files only, **never writes any file**, has no key access and no decryption code, and never sees what the running app has on screen. Everything that needs a **code** goes through the running Noted app, which checks the code and decides (see "Codes" and "Writing: the app decides").

The source is `packages/noted_mcp` (version 0.3.0). It is pure Dart and uses the Dart team's `dart_mcp` package over stdio.

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
| `write_box` | `box_id`, `code`, `content` (markdown), `mode` (`replace` or `append`) | Asks the running Noted app to write to an AI box with its Writer code, and returns the app's answer. The code is required. |
| `describe_code` | `code` | JSON: what the code covers: `kind` (`box`, `page` or `binder`), `id`, `role` and `expires`. Asked of the app. |

A box code used with `list_pages`, `read_page` or `search` is refused with a `wrong_role` message: a box code reads its own box with `read_box`, not pages. `list_my_boxes` and the `NOTED_TOKEN` environment variable no longer exist (the variable is ignored if set).

AI boxes read as markdown (`read_page` shows type `ai`).

## Codes

A code is made in an AI box ("Connect a chat": Writer or Reader) or in the page or binder settings (Reader, for Privileged pages), shown once with a label the user types. It is `noted_<id>_<key>`; Noted stores only a hash. The user gives the code to the chat, and the chat passes it on each call. A box has one Writer code (issuing a new one retires the old) and any number of Readers. Each code can be revoked, can expire, and is used from a **session**: each `noted_mcp` process makes a random session id at start, and the first time a code is used from a new session, Noted asks the user "<app> wants to <read|write> <label>. Allow?" before anything reaches the box. The app name is the MCP client's `clientInfo` name and version. A box can also ask before each write. Every read and write is logged in the app.

The server never checks a code itself (no hashing is allowed here, invariant 4). With a code it sends an `access` request to the app, which checks the code, its expiry and the approval, logs the use, and answers with a **grant**: for a box code, the one box and its page; for a page or binder code, the ids of the pages the code reads (Privileged pages it covers, minus Guarded ones and locked binders). The server then reads the **saved files** itself and builds the output, so what the AI sees never comes from the live screen.

Failures reach the AI as clear tool errors: `bad_code` (mistyped or revoked), `expired`, `not_approved` ("The user hasn't allowed this connection in Noted."), `wrong_role` (a Reader writing, or a box code used for pages), `no_box`, `conflict`, `locked`, `not_writable`, `save_failed`, `busy`, and an unknown code from a newer app (its message and code are kept). With Noted not running every code-based call fails with "This needs Noted running: codes are checked by the app. Open Noted and try again."; reading Open pages without a code still works. A code that is not shaped like a code is refused without contacting the app, and a code never appears in any output or error of the server.

## Writing: the app decides

The server writes no file. `write_box` sends a request to the running Noted app over a local connection, and the app checks the code (it must be the box's Writer code), the approval, the box's settings and the page, and then edits and saves the box. Reads of Open pages never need the app.

The link (protocol `ai-link/2`):
- The app listens on **127.0.0.1 only** (loopback TCP, a free port) and writes `ai-link.json` in its data folder: `{"format":1,"port":N,"pid":P,"nonce":"..."}`. The nonce is new at every launch, and the file is deleted on a clean exit.
- The server reads the file, connects to 127.0.0.1 with a short timeout and reads the app's one-line greeting `{"noted":"ai-link/2","nonce":"..."}`. Only if the nonce matches the file does it send the request (one JSON line with `op`, the code, the session id and the app name). The nonce shows the peer can read `ai-link.json`, so it is not a stranger on a stale port; it does not prove the peer wrote the file. A wrong, missing or oversized greeting means "not running", and the code is not sent.
- Ops: `write_box`, `access` (read_box, read_page, list_pages or search) and `describe_code`. The app answers with one line, `{"ok":true,...}` or `{"ok":false,"code":"...","message":"..."}`. A request waiting for the user to approve a session waits for the user's answer; an unanswered prompt is refused (`not_approved`) after 45 seconds, before MCP clients that give up at 60 seconds do, so a late write cannot happen.
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

It runs `claude mcp add noted -s user -- <path to noted_mcp.exe>`, replacing an earlier registration, so every project sees the server. Check it with `claude mcp list`. The equivalent by hand is:

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

Run the script with `-PrintOnly` to print the snippet without touching Claude Code. If you move the Noted folder, run it again.

## Building it

`app\scripts\package-windows.ps1` compiles the server with `dart compile exe` into the release folder, next to `noted.exe`, and puts it in the zip. To build it alone:

```powershell
dart compile exe packages\noted_mcp\bin\noted_mcp.dart -o noted_mcp.exe
```

## Guarantees and tests

`packages/noted_mcp/test`:
- **`invariant_test.dart`** walks everything the executable can import. It fails on any Flutter, crypto, key or encryption library, on `dart:ffi`, on any Noted package other than the read-only part of the core (`noted_core_read.dart`), and on any dependency other than `dart_mcp` and `noted_core`. It scans the source of every Noted library reached and fails on file-writing APIs, on any socket or HTTP API outside `link_client.dart`, and checks that the link client connects to the loopback address only. (One known exception: the core's `binder.dart` holds the app's binder writer, which the server never uses; it should move out of the read-only core.)
- **`ai_test.dart`** runs the tools against a fake Noted over the link: grants (page and box), box-code isolation (no title or page list), the session id and app name on every request, `write_box` (success and each refusal), `describe_code`, every error code, and Noted not running.
- **`tools_test.dart`** runs the page tools against pages with each access value (Open, Privileged, Guarded, the legacy values, inheritance and tightening, binders, a locked binder) and checks that hidden pages appear in no output.
- **`stdio_test.dart`** starts the executable and talks to it as an MCP client.

## Not yet

An Organize role for codes (organizing pages) and per-AI rules come later.
