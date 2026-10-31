# Noted's MCP server (read-only)

`noted_mcp.exe` lets an AI app that speaks the Model Context Protocol, such as Claude Code or the Claude desktop app, read your Noted pages. It is a separate program (invariant 4): it reads the saved page files only, has no key access and no decryption code, and never sees what the running app has on screen.

The source is `packages/noted_mcp`. It is pure Dart and uses the Dart team's `dart_mcp` package over stdio.

## What an AI can see

Each page has an **AI access** setting (right-click the page; binders have one in their menu too):

| Setting | What the AI gets |
| --- | --- |
| **Off** (the default) | Nothing. The page isn't listed, can't be found by search, can't be read, and a link to it shows only its text. Asking for it gives the same answer as for a page that doesn't exist. |
| **Box only** | The page is listed and its title can be searched, but no box content is given. An AI will be able to read its own boxes on such pages once AI boxes exist. |
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
| `search` | `query` | JSON: pages whose title, or (Whole page only) text, holds every word, with a snippet of each match. Put a phrase in quotes. |

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

Run the script with `-PrintOnly` to print the snippet without touching Claude Code. If you move the Noted folder, run it again.

## Building it

`app\scripts\package-windows.ps1` compiles the server with `dart compile exe` into the release folder, next to `noted.exe`, and puts it in the zip. To build it alone:

```powershell
dart compile exe packages\noted_mcp\bin\noted_mcp.dart -o noted_mcp.exe
```

## Guarantees and tests

`packages/noted_mcp/test`:
- **`invariant_test.dart`** walks everything the executable can import. It fails on any Flutter, crypto, key or encryption library, on `dart:ffi`, on any Noted package other than the read-only part of the core (`noted_core_read.dart`), and on any dependency other than `dart_mcp` and `noted_core`.
- **`tools_test.dart`** runs every tool against pages with each AI setting, inherited and overridden, and checks that Off pages and locked binders appear in no output.
- **`stdio_test.dart`** starts the executable and talks to it as an MCP client.

## Not yet

AI boxes (and with them what Box only pages share), AI writing, AI tokens and per-AI rules come in the next part of the AI phase.
