# Writing a box module

This guide is for people who add a box type to Noted. The decisions behind it
are in `docs/decisions.md` (0034, 0035, 0028, 0009); where this guide and an
active decision differ, the decision wins.

## What a box module is

Everything on a page is a box, including the plain note. A box type is a
module that implements the versioned Box API and can be switched on or off.

Delivery has two stages (0034). Today, in stage 1, modules are **compiled
in**: a new box type is added in source, by contribution or fork. A compiled
module runs with the app's full privileges, so every contribution goes through
a security review. Stage 2 (downloadable, sandboxed boxes) is not built.

A module has two halves:

- A **codec** (`BoxCodec<D>`, in `noted_core`, pure Dart): the type id, the
  data schema and its version, create, decode, encode, the text snapshot, merge,
  AI exposure and permissions. It has no Flutter dependency, so a process
  without a UI can load it.
- A **module** (`BoxModule<D>`, in `noted_canvas`): the widgets. `buildEditor`
  is the live box, `buildView` the read-only one. The module gets a
  `BoxContext<D>` and saves content only with `BoxContext.commit`, which runs the
  data through the codec's `encode` and refreshes the snapshot.

## The template

`packages/boxes/template` is a small working module, a *sticky label*: one text
field and a colour from a fixed palette. Every member is commented.

```
packages/boxes/template/
  pubspec.yaml                    resolution: workspace; depends on noted_core, noted_canvas
  lib/noted_box_template.dart     exports
  lib/src/sticky_label_codec.dart the data side
  lib/src/sticky_label_module.dart the widgets
  test/                           codec, page format and canvas tests
  README.md
```

## Creating a module

1. Copy `packages/boxes/template` to `packages/boxes/<name>` and rename the
   package (`noted_box_<name>`) in its `pubspec.yaml`.
2. Add the directory to `workspace:` in the root `pubspec.yaml`, and a path
   dependency on it to `app/pubspec.yaml`. (A new package under
   `packages/boxes` needs the maintainer's approval first.)
3. **Change the type id.** It is namespaced (`noted.note`, `noted.drawing`;
   the template uses `noted.template.sticky-label`) and permanent once boxes of
   the type exist in anyone's pages. Two modules cannot share one.
4. Replace the data class, `decode`, `encode`, `snapshotText`, `isEmpty`,
   `aiExposure` and `merge`, then the widgets.
5. Put the MPL-2.0 header at the top of every source file. Dependencies must be
   MIT, BSD, Apache-2.0 or MPL-2.0; adding one needs the maintainer's approval.
6. Keep the code against the current Box API version (`boxApiVersion`, see
   below).

## Registering a module

In `app/lib/main.dart`, `buildModules()` builds the `ModuleRegistry`:

```dart
..register(const StickyLabelModule(), enabled: false);
```

`ModuleRegistry.register(module, {enabled, alwaysOn, isDefault})`:

- `enabled` (default true): whether the type is switched on. A box of a type
  that is off is shown from its snapshot, read-only, marked "Editable on other
  devices", and its data is left untouched (0035).
- `alwaysOn`: the type cannot be switched off (the note box).
- `isDefault`: the type a click on empty canvas creates. Exactly one module,
  the note box, has it.

Registering fails if the codec's `apiVersion` can't run on this host, or its
type id is already taken.

To switch a type on, set `enabled: true` in `main.dart`, or call
`ModuleRegistry.setEnabled(typeId, true)` at run time. A page that is already
open resolved its boxes earlier, so reopen the page after changing it.

A module can add canvas tools, commands (which also feed the toolbar and
shortcuts), a settings panel, a frame style and Find on page highlighting. All
are optional hooks on `BoxModule` and `BoxContext`; the template lists them in
a comment and uses none. Without a command, a module's boxes can only be
created in code.

## Testing a module

Copy the template's tests and adapt them. They check:

- **The codec**: create, encode, decode, snapshot, `isEmpty`, AI exposure and
  merge; bad data decodes to safe values.
- **Unknown data**: keys the module doesn't know are written back unchanged
  after an edit, and an untouched box is written back byte-for-byte.
- **A save and load round trip** through `readPage` and `writePage`.
- **Off and missing**: with the module switched off or not registered, the
  canvas shows the snapshot (`UnsupportedBoxView`) and the page text is
  unchanged on save.
- **The widgets**: pump a `PageCanvas` with a `CanvasController`; editing
  commits, and the box's snapshot text follows.

Run `flutter analyze` at the repository root and `flutter test` in the package
before every commit.

## Box API versions

The Box API version is `boxApiVersion` (`BoxApiVersion`, in `noted_core`).
While the major version is 0, a module must target the host's exact version;
from 1.0, any host with the same major version and an equal or newer minor
version can run it. A codec returns the version it was written against from
`apiVersion`, and the registry enforces it.

Changes to the API are listed, newest first, in
`packages/noted_core/BOX_API_CHANGELOG.md`. Changing the Box API needs the
maintainer's approval. A module's own data has a separate version,
`dataVersion`: bump it when `encode`'s output changes shape, and keep `decode`
reading every older version. A box saved by a newer `dataVersion` than the
module knows is shown from its snapshot and not rewritten.

## What the invariants mean for a module author

- **Touch only your own box.** A module sees its own box's data through its
  `BoxContext`. It never parses, reads or changes another box's data, and never
  reads the page file.
- **Keep unknown fields.** The core passes the data of box types it can't run
  through load, save, sync and encryption byte-for-byte. Your module owes the
  same to its own data: when `decode` finds keys it doesn't know (written by a
  newer version of your module on another device), keep them and write them
  back unchanged from `encode`. Decode defensively: a missing or mistyped field
  takes a default, and bad data must not crash the page.
- **The snapshot is what everyone else sees.** `snapshotText` (0035) is shown on
  devices where your module is off or missing, is what search indexes, and is
  what an AI reads. Keep it accurate after every change. It must not contain
  secrets or anything the user would not want visible without your module.
- **AI exposure is explicit.** `aiExposure` has no default. Return `AiText` for
  ordinary content, `AiPlaceholder` when the AI should know a box exists but not
  what is in it, and `AiHidden` for nothing at all.
- **Encrypted content (invariant 3).** Encrypted content exists as plaintext only
  in the on-screen editor state of an unlocked box. It must never reach the
  page model, disk, autosave, a persistent undo history, search indexes, logs,
  crash reports, thumbnails or conflict copies. A module that handles such
  content must follow this; binder encryption itself is not part of the current
  phase.
- **No network backend (invariant 5).** All data stays on the user's devices and
  in their chosen storage. A module must not depend on a developer-run service.
  Declare any permission it needs in `permissions`.
- **The MCP server reads saved data only (invariant 4).** It is a separate
  executable with no key access and no decryption code, and AI-facing output is
  never built from the live screen. This is another reason the codec stays
  free of Flutter and the snapshot stays correct: what is saved is what an AI
  sees.
