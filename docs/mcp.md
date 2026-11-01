# Noted's MCP server

`noted_mcp.exe` lets an AI app that speaks the Model Context Protocol, such as Claude Code or the Claude desktop app, read your Noted pages and write to its own AI boxes. It is a separate program (invariant 4): it reads the saved page files only, **never writes any file**, has no key access and no decryption code, and never sees what the running app has on screen. Its only way to change anything is to ask the running Noted app (see "Writing: the app decides").

The source is `packages/noted_mcp`. It is pure Dart and uses the Dart team's `dart_mcp` package over stdio.

## What an AI can see

Each page has an **AI access** setting (right-click the page; binders have one in their menu too):

| Setting | What the AI gets |
| --- | --- |
| **Off** (the default) | Nothing. The page isn't listed, can't be found by search, can't be read, and a link to it shows only its text. Asking for it gives the same answer as for a page that doesn't exist. |
| **Box only** | The page is listed and its title can be searched. `read_page` gives the title and the AI's **own** AI boxes only (in reading order); `read_box` reads an own box, and any other box on the page gets the same answer as a box that doesn't exist; `search` also matches the text of the AI's own boxes. Nothing else on the page is given. |
| **Whole page** | Everything on the page can be read. |

A page without its own choice follows its parent page, then its binder, then Off. The menu shows what it inherits ("Same as parent (Whole page)").

Whatever the setting:
- **Encrypted boxes** and **boxes this server doesn't know** are always a placeholder (`[encrypted box]`, `[unsupported box]`), never their data or their stored snapshot.
- **Locked binders** (a binder file marked as locked or encrypted; binder passwords come later) are left out whole.
- Every call reads the files afresh.

## Tools

| Tool | Arguments | Returns |
| --- | --- | --- |
| `list_pages` | none | JSON: each visible page's `id`, `title`, `parent` (its nearest visible ancestor), `ai` (`box` or `page`) and `location` (Pages or the binder's title). |
| `read_page` | `page_id` | Markdown: the title, then each box from top to bottom and left to right with its type. Notes come out as markdown (headings, styles, lists, check lists, links, equations, tables); drawings as `[drawing]`, images as `[image: alt text]`, files as `[file: name]`. |
| `read_box` | `page_id`, `box_id` | One box, as `read_page` shows it. |
| `search` | `query` | JSON: pages whose title, or text (Whole page: every box; Box only: the AI's own boxes), holds every word, with a snippet of each match. Put a phrase in quotes. |
| `list_my_boxes` | none | JSON: `page_id`, `page_title`, `box_id` and `ai` (the page's setting) of the AI's own boxes on pages that aren't Off. Without a valid token it is an error that explains `NOTED_TOKEN` and AI connections. |
| `write_box` | `box_id`, `content` (markdown), `mode` (`replace` or `append`) | Asks the running Noted app to write to one of the AI's own boxes, and returns the app's answer (an error when the app refuses). Needs a token and Noted running. |

AI boxes read as markdown (`read_page` shows type `ai`); text an AI wrote is marked, and on a Whole page the AI's own box says "your box".

## AI connections and tokens

To let an AI have AI boxes, create a connection in Noted: gear menu > **AI connections**. Noted shows its token once (`noted_<id>_<key>`). Give it to the server as the `NOTED_TOKEN` environment variable (see "Adding it to Claude"). Revoking the connection in Noted ends it.

- The server takes the connection **id** from the token and, on every call, counts it only if that id is listed in `settings.json` (read afresh). A revoked or unknown id behaves as no token: the AI has no boxes of its own.
- The server cannot check the token's secret half: it may not hash (invariant 4), so **reading** is scoped by the id alone. **Writes** are verified by the app, which checks the whole token on every request.
- The token is never put in any output or error of the server.

## Writing: the app decides

The server writes no file. `write_box` sends a request to the running Noted app over a local connection, and the app checks the token, the box's owner and the page's AI setting and then edits and saves the box. If Noted isn't running every write fails with "Noted isn't running. Open Noted and try again; reads still work." Reads never need the app.

The link:
- The app listens on **127.0.0.1 only** (loopback TCP, a free port) and writes `ai-link.json` in its data folder: `{"format":1,"port":N,"pid":P,"nonce":"..."}`. The nonce is new at every launch, and the file is deleted on a clean exit.
- The server reads the file, connects to 127.0.0.1 with a short timeout and reads the app's one-line greeting `{"noted":"ai-link/1","nonce":"..."}`. Only if the nonce matches the file does it send the request (one JSON line, with the token). The nonce shows the peer can read `ai-link.json`, so it is not a stranger on a stale port; it does not prove the peer wrote the file. A wrong, missing or oversized greeting means "not running", and the token is not sent.
- The app answers with one line, `{"ok":true,...}` or `{"ok":false,"code":"...","message":"..."}`; the server passes the message on.
- Only `link_client.dart` in the server opens a socket; the tests check that, and that it connects to the loopback address alone.

Sample `read_page` output, for a Whole page test page:

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

**Claude desktop.** The same script prints the entry to add to `claude_desktop_config.json` (Settings > Developer > Edit Config, or `%APPDATA%\Claude\claude_desktop_config.json`). Merge it with any servers already there, then restart Claude:

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

**With an AI connection token** pass `-Token` to either: `register-mcp.ps1 -Token noted_...` runs `claude mcp add noted -s user -e NOTED_TOKEN=<token> -- <exe>`, and the printed Claude desktop entry gains `"env": {"NOTED_TOKEN": "<token>"}` (a placeholder if you gave no token). The token is a secret and ends up in Claude's configuration file; keep that file private. A token typed on the command line lands in PowerShell's history; copy it in Noted and use `-Token (Get-Clipboard)` instead. Without a token the server still reads.

Run the script with `-PrintOnly` to print the snippet without touching Claude Code. If you move the Noted folder, run it again.

## Building it

`app\scripts\package-windows.ps1` compiles the server with `dart compile exe` into the release folder, next to `noted.exe`, and puts it in the zip. To build it alone:

```powershell
dart compile exe packages\noted_mcp\bin\noted_mcp.dart -o noted_mcp.exe
```

## Guarantees and tests

`packages/noted_mcp/test`:
- **`invariant_test.dart`** walks everything the executable can import. It fails on any Flutter, crypto, key or encryption library, on `dart:ffi`, on any Noted package other than the read-only part of the core (`noted_core_read.dart`), and on any dependency other than `dart_mcp` and `noted_core`. It scans the source of every Noted library reached and fails on file-writing APIs, on any socket or HTTP API outside `link_client.dart`, and checks that the link client connects to the loopback address only. (One known exception: the core's `binder.dart` holds the app's binder writer, which the server never uses; it should move out of the read-only core.)
- **`ai_test.dart`** covers AI boxes in reads (two connections, Box only, Off, a revoked token), `list_my_boxes`, and `write_box` against a fake link server (success, an error code, a nonce mismatch that sends no token, no `ai-link.json`).
- **`tools_test.dart`** runs every tool against pages with each AI setting, inherited and overridden, and checks that Off pages and locked binders appear in no output.
- **`stdio_test.dart`** starts the executable and talks to it as an MCP client.

## Not yet

Per-AI rules come in a later part of the AI phase.
