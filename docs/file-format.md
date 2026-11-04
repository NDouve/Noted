# Noted file formats

This document describes the files Noted writes for pages, binders and
attachments, as the code writes and reads them today. It is a description of
behaviour, not a design: where it and the code differ, the code is right and
this document should be corrected.

It covers page files (`<page id>.canvas`), binder files (`noted-binder.json`),
attachment files (`<page id>.assets/`) and the way a sync client's conflict
copies of page files are recognised and merged. It does not cover recovery
entries or the files the AI integration keeps.

Source: `packages/noted_core` (`model/page.dart`, `format/page_format.dart`,
`attachments/attachments.dart`, `binder/binder.dart`, `binder/binder_store.dart`,
`merge/conflict_copy.dart`, `storage/page_store.dart`) and
`packages/boxes/attachments` (`attachment_ref.dart`).

## Contents

1. Principles
2. Page file
3. The `noted` page header
4. Nodes and box records
5. Attachments
6. Binder file
7. Conflict copies
8. Compatibility rules

## 1. Principles

- All files are UTF-8 JSON. A leading byte order mark is accepted when
  reading and never written. Line endings written are `\n`; readers must
  accept `\r\n` as ordinary JSON whitespace (a sync client or editor may
  have changed them).
- Noted keeps every value it does not need to change as the exact text it
  read, and writes that text back unchanged: key order, spacing inside a
  node, number formatting and unknown fields all survive a load and save.
  Only the values Noted edits are re-encoded.
- Ids (page ids, box ids, revisions) are random 64-bit values written as 16
  lowercase hex digits. Readers must treat them as opaque strings.
- Times are integers: milliseconds since the Unix epoch.

## 2. Page file

A page is one file, `<page id>.canvas`, in a storage folder. It is a JSON
Canvas 1.0 document with one extra top-level field, `noted`.

JSON Canvas fields used:

| Level | Field | Use |
|---|---|---|
| top | `nodes` | Array of nodes, first is bottom-most (JSON Canvas z-order). |
| top | `edges` | Written as `[]` for a new page. Noted does not create or edit edges; an existing array is kept as read. |
| node | `id` | String, unique on the page. |
| node | `type` | Noted writes `"text"` for every box it creates. Nodes of any type (`file`, `link`, `group`) may be present; see "Foreign nodes". |
| node | `x`, `y`, `width`, `height` | Integers (rounded when written). |
| node | `text` | For a Noted box: the read-only snapshot (section 4). |

Not used by Noted: `color`, `label`, edge fields, node `file`/`url`/`subpath`
fields on its own boxes. They are kept untouched on nodes Noted does not own.

Layout as written: two-space indent, one top-level key per line, each node
on its own line (four-space indent), the `noted` header on one line. Top-level
keys keep their order; a missing `nodes` is added first and a missing `noted`
last.

```json
{
  "nodes": [
    {"id":"a41f0c9e22b7d035","type":"text","x":40,"y":40,"width":320,"height":120,"text":"Shopping list\n- milk","noted":{"type":"noted.note","v":1,"rev":"5c0d9e11a3f2b4c8","data":{"blocks":[]},"device":"DESK-1","at":1793700000000}}
  ],
  "edges": [],
  "noted": {"format":1,"pageId":"7b3e55d0a91c4f26","parentId":null,"title":"Groceries","order":0}
}
```

A new empty page is `nodes: []`, `edges: []` and the header.

If two nodes have the same `id`, the first keeps it; later ones are kept but
treated as foreign nodes with a synthetic id that is never written.

## 3. The `noted` page header

The top-level `noted` object. Required to be readable: `format` (integer) and
`pageId` (string). Everything else is optional on read.

| Field | Type | Meaning |
|---|---|---|
| `format` | integer | Page format version. Currently `1`. |
| `pageId` | string | The page's id; equals the file name stem. |
| `parentId` | string or null | The parent page's id; `null` for a top-level page. |
| `title` | string | Page title; `""` if absent. |
| `order` | integer | Position among siblings, ascending; `0` if absent. |
| `background` | string | `"dots"`, `"graph"` or `"ruled"`. Absent means plain. A missing value, a non-string or an unknown name reads as plain; the stored value is kept as written until the user picks a background. Choosing plain removes the key. |
| `attachments` | string | `"folder"` or `"embedded"`: where this page stores images and files (section 5). Absent or unknown means follow the parent page, then the binder, then `"folder"`. |
| `boxTypes` | object | `{"<type id>": true\|false}`. `false` means the box type is not allowed on this page: its boxes are shown from their snapshot, read-only, and nothing is deleted. Absent types inherit; non-boolean values read as absent and are kept as written. |
| `ai` | string | Per-page AI access setting (`"open"`, `"privileged"`, `"guarded"`; the older `"page"`, `"off"` and `"box"` are still read). Listed here because it lives in the header; the AI files themselves are not described here. |

Header fields beyond these are kept in file order and written back unchanged.

```json
{"format":1,"pageId":"7b3e55d0a91c4f26","parentId":"0c2f8a6d31e94b57","title":"Week 12","order":3,"background":"dots","attachments":"embedded","boxTypes":{"noted.drawing":false}}
```

## 4. Nodes and box records

### 4.1 Noted boxes

A node is a Noted box when it has numeric `x`, `y`, `width`, `height`, a
string `id`, and a `noted` object with a string `type` and an integer `v`.
Anything else is a foreign node (4.4).

The box's `noted` object:

| Field | Type | Meaning |
|---|---|---|
| `type` | string | Box type id, for example `noted.note`, `noted.drawing`, `noted.image`, `noted.file`. |
| `v` | integer | Version of the type's data schema this box was saved with. |
| `rev` | string | The content revision (a fresh id on every content write). |
| `baseRev` | string | The `rev` this content was edited from. Absent on a new box. |
| `data` | any JSON | The box type's own data. The core never reads inside it; it is kept as raw text. |
| `device` | string | Computer name that last wrote the content. |
| `at` | integer | When the content was last written. |
| `fixedHeight` | `true` | The user set the box height; a box that normally grows with content scrolls instead. Absent means false. |
| `conflicts` | array | Other versions recorded by a merge (section 7.3). |
| `landed` | object | Marker left by a merge (section 7.4). |

Writing a box's content sets `v`, `rev`, `data` and the `text` snapshot, sets
`baseRev` to the previous `rev` (removing it when there was none), and sets
`device` and `at`; a stamp that is not known is removed, so the header never
describes older content. Moving or resizing a box changes `x`, `y`, `width`
or `height` only; `rev` is unchanged.

Fields Noted does not know, at either the node level or inside `noted`, are
kept in place.

```json
{"id":"e19b7a40c5d83f62","type":"text","x":420,"y":60,"width":300,"height":200,
 "text":"[image: A whiteboard]",
 "noted":{"type":"noted.image","v":1,"rev":"9d1c20b7e4a85f33","baseRev":"31ac5be90d27c648",
          "data":{"image":{"name":"board.png","size":48213,"hash":"9f86d081884c7d65...","file":"9f86d081884c7d65....png"},"width":1200,"height":800,"alt":"A whiteboard"},
          "device":"LAPTOP-2","at":1793700123456,"fixedHeight":true}}
```

(Wrapped here for reading; the file holds each node on one line.)

### 4.2 The snapshot

`text` holds a read-only text rendering of the box's content, written by the
box type each time it saves (for example `[image: <alt text>]`,
`[file: <name>]`, a note's text). It exists so the page stays readable in
other JSON Canvas apps, and so Noted can show a box it cannot run. A drawing
has no text snapshot. Editing `text` outside Noted has no effect on the box's
data and is overwritten at the next content write.

### 4.3 Unsupported boxes

If a box's type has no installed module, the module is switched off, the
type is not allowed on the page (`boxTypes`), `v` is newer than the module
understands, or the module cannot decode `data`, the box is shown from `text`
read-only. Its node is written back exactly as read, including `data`, so
the box survives load, save and merge byte for byte.

### 4.4 Foreign nodes

A node without a usable `noted` object (a node from another JSON Canvas app,
or a Noted header that is malformed) is a foreign node. It is shown read-only
and written back exactly as read. A node that is not a JSON object is also
kept. The page header and top-level fields other than `nodes` and `noted`
(including `edges`) are likewise kept verbatim.

## 5. Attachments

Image (`noted.image`) and file (`noted.file`) boxes hold a file. The file is
described in the box's `data` and is stored in one of two ways, chosen by the
`attachments` setting (page header, then parent pages, then the binder file,
then `"folder"`). Every box reads both forms whatever the current setting is.

Where the reference sits: an image box's `data` is
`{"image":<ref>,"width":<px>,"height":<px>,"alt":"<text>"}` and a file box's
`data` is `{"file":<ref>}`. Other keys in `data` are kept. The reference
(`<ref>`) has these fields:

| Field | Meaning |
|---|---|
| `name` | Display name, with extension. |
| `size` | Size in bytes. |
| `hash` | Lowercase hex SHA-256 of the file's bytes. |
| `file` | Folder mode: the file name inside the page's assets folder. |
| `data` | Embedded mode: the file's bytes, base64. |

A reference with both `file` and `data` is read from `data`. One with neither,
or with no `hash`, is not a readable attachment. A missing `name` defaults to
the `file` value (or `"file"`) and a missing `size` to the embedded length.

### Folder mode

The file is written once to `<page id>.assets/<hash>.<ext>` beside the page
file. `<ext>` is the original extension lowercased; it is left out (the name
is just `<hash>`) when the original has none, has more than 10 characters or
has any character other than letters and digits. `file` holds that name
relative to the assets folder, so a page that gets a new id keeps working
boxes. Because the name is the content hash, two devices adding the same file
write the same name and cannot conflict. An existing file with that name is
left alone.

```json
{"name":"Plan.pdf","size":48213,"hash":"9f86d081884c7d65...","file":"9f86d081884c7d65....pdf"}
```

If the file has not arrived yet (for example the sync client has not
delivered it), the box shows a waiting state until it appears.

### Embedded mode

The bytes are stored in the box as base64 together with the same `name`,
`size` and `hash`:

```json
{"name":"Plan.pdf","size":48213,"hash":"9f86d081884c7d65...","data":"JVBERi0xLjcK..."}
```

Files larger than 5 MiB (5 * 1024 * 1024 bytes) are always stored in the
folder, even when the setting is `"embedded"`. The whole page file is
rewritten on every save, and base64 adds a third to the size.

### The setting

`"attachments":"folder"|"embedded"` appears in the page header and in the
binder file (section 6). Absent or unknown values mean "follow the parent";
an unknown value is kept as written.

## 6. Binder file

A binder is a folder holding pages and one file, `noted-binder.json`, with
the binder's metadata. The file is a single JSON object on one line, followed
by `\n`.

| Field | Type | Meaning |
|---|---|---|
| `format` | integer | Binder format version. Currently `1`. Required. |
| `binderId` | string | The binder's id. Required, non-empty. |
| `title` | string | `""` if absent. |
| `description` | string | `""` if absent. |
| `owner` | string | `""` if absent. |
| `color` | string | `#AARRGGBB`. A new binder takes the next colour of a built-in palette; if absent, the first palette colour is shown. A stored colour that is not in the palette is kept. |
| `created` | integer | When the binder was created. Optional. |
| `attachments` | string | `"folder"` or `"embedded"`: the default for pages in the binder (section 5). |
| `boxTypes` | object | `{"<type id>": true\|false}`, as in the page header. A binder can also allow a type that a top-level page then inherits; pages below can only disallow. |
| `ai` | string | The binder's AI access setting, as in the page header. |

Other fields are kept in order and written back unchanged.

```json
{"format":1,"binderId":"c04e91b7a25d3f68","title":"Project Atlas","description":"Planning notes","owner":"","color":"#FF2563EB","created":1793600000000,"attachments":"folder"}
```

The file is written to `noted-binder.json.tmp` and then renamed over the old
file. A new binder file is never written over an existing one.

The file is not valid, and is never written to, when the JSON is invalid,
`binderId` is missing or empty, `format` is missing or not an integer, or
`format` is greater than the version this build supports. Such a binder is
listed as unreadable and left alone.

## 7. Conflict copies

### 7.1 Naming

When a sync client keeps both versions of a page file edited on two machines,
it saves the second as a copy with a suffix before the extension. OneDrive
appends a hyphen and the computer name, and a number if that name is taken:
`<stem>-<COMPUTERNAME>.canvas`, `<stem>-<COMPUTERNAME>-1.canvas`. This naming
is not verified against other providers, so Noted accepts a wider shape.

A file `<stem>-<suffix>.canvas` is treated as a conflict copy of
`<stem>.canvas` when all of these hold:

- the stem has a hyphen, and the text after it (taken from any hyphen in the
  stem, shortest stem first) consists of letters, digits, `_` and `-`, starting
  with a letter or digit (page ids and computer names can both contain
  hyphens, so every hyphen is tried);
- `<stem>.canvas` exists in the same folder;
- both files hold the same `pageId`.

A copy of a copy belongs to the file at the end of the chain. A file with a
hyphenated name that does not satisfy these is an ordinary page file (and, if
it repeats an existing page id, is reported as a duplicate).

### 7.2 Merge

Noted merges the copy into the original box by box, then removes the copy
once the merged original has been written and read back correctly. With no
common base, what each side did is derived from revisions. For a box on both
sides:

- identical text, or equal `rev`: the original is kept;
- the copy's `baseRev` equals the original's `rev`: the copy edited it
  further, so the copy's box is taken;
- the original's `baseRev` equals the copy's `rev`: the original is newer and
  is kept;
- if either side has no `rev`, boxes with the same type, `v`, `data` and
  snapshot count as the same;
- otherwise both changed it: the original is kept and the copy's version is
  recorded in `conflicts`.

A box only one side has is kept (without a base there is no telling it was
deleted). The page header and other top-level fields are the original's. If
a node differs and one side is a foreign node, nothing is dropped: the
original's node is kept and the copy's node is added beside it under a new
id.

### 7.3 `conflicts`

A box with unresolved other versions has `"conflicts":[...]` in its `noted`
object, in the order recorded. Entries are either of:

```json
{"node":{"id":"e19b7a40c5d83f62","type":"text","x":420,"y":60,"width":300,"height":200,"text":"...","noted":{"type":"noted.note","v":1,"rev":"..."}},
 "at":1793700456789,"device":"LAPTOP-2"}
```

```json
{"deleted":true,"at":1793700456789}
```

`node` is the other version's whole node, kept as raw text; `device` is
present when that version's box says which computer wrote it; `at` is when
the other version was saved or detected. `deleted` records that the other
side deleted the box while this one was edited. Conflict records of both
sides are combined, without duplicates. The field is removed when the last
entry is settled. A device that cannot run the box carries the field
unchanged.

### 7.4 `landed`

```json
"landed":{"at":1793700456789,"device":"LAPTOP-2"}
```

Set on a box that arrived from the other file in a merge and overlaps a box
the other file could not see in that place. `device` is present when known.
It stays until the user places the box. In a conflict-copy merge it is kept
if either side has it.

## 8. Compatibility rules

- **Newer page format.** A page whose header `format` is greater than the
  version the app supports (currently 1) is not opened for editing. It is
  listed as unreadable with the reason that it comes from a newer version,
  and the file is never written, moved over or deleted by the app. The same
  holds for a binder file with a newer `format`.
- **Unreadable files.** A page file with invalid JSON, no `noted` header, or
  a header without `format` and `pageId`, or a `nodes` value that is not an
  array, is unreadable and is never overwritten. Two files with the same
  `pageId` that are not conflict copies of each other: the second is
  reported as a duplicate and not used.
- **Unknown fields are kept.** At the top level, in the page header, in each
  node, in a box's `noted` object, in a box's `data`, and in the binder
  file. They are written back in place with their original text.
- **Unknown or unsupported boxes** are shown read-only from their `text`
  snapshot and written back exactly as read (4.3). A box type being switched
  off, not allowed on the page, or newer than the app is not an error and
  deletes nothing.
- **Foreign nodes** are kept and written back exactly (4.4).
- **Missing optional header values** read as their defaults: no parent, empty
  title, order `0`, plain background, attachments follow the parent. Unknown
  values of `background`, `attachments`, `boxTypes` entries and `ai` are read
  as the default (or, for `ai`, as the strictest value) and are kept as
  written until the user changes them.
- **Atomic writes.** Pages and binder files are written to a temporary file
  and then renamed; a half-written file is never left in place of a page.
