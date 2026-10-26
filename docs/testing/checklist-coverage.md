# Hands-on checklist: automated coverage

The hands-on checklist (steps 1 to 206, plus the new search and binder-from-template entries S1 to S5 and T1) is automated as far as a test can check it without human eyes, real hardware, the OS shell, a second machine or OneDrive. The tests drive the real `NotedApp` on a real Windows window with Flutter's `integration_test`.

## How to run

From `app/`:

    flutter test integration_test -d windows

This builds the Windows app, starts it and runs `integration_test/checklist_test.dart` (all suites in one entry point, so the app is built once). To run one test, add `--plain-name "step 112-116"`. Plain `flutter test` in `app/` only runs `app/test/` and does not touch `integration_test/`.

Files:

- `app/integration_test/checklist_test.dart`: the entry point.
- `app/integration_test/suites/*.dart`: `page_tree_suite`, `folders_binders_suite`, `notes_suite`, `templates_suite`, `canvas_suite`, `search_suite`.
- `app/integration_test/support/harness.dart`: the sandbox and session helpers. `note_helpers.dart`: putting content on a page and driving a note editor.
- `app/integration_test/step_map.json`: the machine-readable map from test name to step numbers.

## How isolation works

Every test creates its own temp directory (`Directory.systemTemp.createTemp('noted_it_...')`) and builds the `Notebook` and `AppSettings` the way `main()` does, but with every location inside that directory: the pages folder, `app/binders.json`, `app/settings.json`, `app/recovery`, `app/templates`, binder folders and extra standalone folders. `NotedApp` is then pumped with that notebook. No test hook was added to `app/lib`: `Notebook` and `AppSettings` already take all their paths as constructor parameters, and `main()` is the only place that uses `%APPDATA%\Noted` (through `defaultPagesDirectory()`), which the tests never call.

At the start of every test `Env.assertIsolated` checks that the resolved pages, `binders.json`, `settings.json`, recovery, app templates, default binder and new-page folders are all under the temp directory and none is under `%APPDATA%\Noted`. The folder picker is a stub that answers with a temp path. The temp directory is deleted after the test. "A folder disappears" steps rename the temp folder.

## Limits of the automation

- Text is put into note editors and table cells through editor transactions, and the shortcuts for `$$ ` and `$x$` are run directly: the app does not depend on `appflowy_editor`, and synthetic key events do not produce IME text. Everything after the text is entered (formulas, equations, undo) goes through the real UI.
- The Windows theme switch is simulated by overriding the platform brightness; the OS itself is not changed.
- The second device of the two-machine ([2M]) conflict steps is simulated by writing the page file through a second `PageStore`; sync, OneDrive and conflict copies from a real second machine are manual.
- Nothing writes to the real clipboard.

## Status key

- **automated**: a test checks the step.
- **partly automated**: a test checks the objective part; the rest needs eyes or hardware (stated).
- **superseded**: the step describes behaviour a later decision changed; the test checks the current behaviour (decision named).
- **manual only**: reason given.

## Steps

| Step | Description | Status | Test | Why manual / notes |
|---|---|---|---|---|
| 1 | Open from the Desktop shortcut | partly automated | step 001-002 | App starts; the shortcut itself is the OS shell |
| 2 | Open from the Start menu, same pages | partly automated | step 001-002 | Restart keeps pages; Start menu is the OS shell |
| 3 | + opens a storage dialog | superseded by 0084 | step 003-004, 201 | No dialog: checks none opens |
| 4 | Enter creates "Untitled page" | superseded by 0084 | step 003-004, 201 | + creates the page at once, title field focused |
| 5 | Rename | automated | step 005 | |
| 6 | New subpage, parent becomes a divider | automated | step 006-007 | |
| 7 | Chevron collapses and expands | automated | step 006-007 | |
| 8 | Drag onto middle: last subpage | automated | step 008-012 | |
| 9 | Drag onto top edge | automated | step 008-012 | |
| 10 | Drag onto bottom edge | automated | step 008-012 | |
| 11 | Drag onto empty area: end of top level | automated | step 008-012 | |
| 12 | Drag onto own subpage: nothing | automated | step 008-012 | |
| 13 | Move up / Move down | automated | step 013-015 | |
| 14 | Indent | automated | step 013-015 | |
| 15 | Outdent | automated | step 013-015 | |
| 16 | Delete, confirm, Undo bar | automated | step 016-017 | |
| 17 | Undo restores content | automated | step 016-017 | |
| 18 | "Choose another folder…" in the + dialog | superseded by 0084 | step 018-020, 205 | Default page folder from the gear; new page lands there |
| 19 | Dialog lists that folder | superseded by 0084 | step 018-020, 205 | No dialog: checked |
| 20 | Subpage lands in the same folder | automated | step 018-020, 205 | |
| 21 | Binder folder refused | superseded by 0084 | step 021 | Refused as default page folder and by Move to folder |
| 22 | New binder, cover opens | superseded by 0084 | step 022-026, 030; 202-203 | Created at once in the default binder folder |
| 23 | Edit title, description, owner | automated | step 022-026, 030 | |
| 24 | Color swatch changes the stripe | automated | step 022-026, 030 | Stripe color compared to the displayed binder color |
| 25 | Last edited shown | partly automated | step 022-026, 030 | Field exists; "recent time" not compared |
| 26 | New page in binder menu | automated | step 022-026, 030 | |
| 27 | Drag standalone page onto binder header | automated | step 027-028 | |
| 28 | Drag back onto Pages with subpages | automated | step 027-028 | |
| 29 | Remove from sidebar, folder untouched | automated | step 022-026, 030 | |
| 30 | Pick the same folder again, binder reopens | automated | step 022-026, 030 | Via "New binder in another folder…" |
| 31 | `/` then Table: 2x2, note grows | automated | step 031-034 | |
| 32 | Type in a cell | automated | step 031-034 | Text via editor transaction |
| 33 | Column letters and row numbers on focus | automated | step 031-034 | |
| 34 | They disappear when clicking outside | automated | step 031-034 | |
| 35 | `$$ ` opens the equation dialog | partly automated | step 035-036 | Shortcut run directly, not typed |
| 36 | `\frac{a}{b}` preview and OK | automated | step 035-036 | |
| 37 | `$x^2$` becomes a rendered equation | partly automated | step 037-040 | Shortcut run directly |
| 38 | "$5 and $10" stays plain | partly automated | step 037-040 | Shortcut returns false |
| 39 | Click equation opens the dialog | automated | step 037-040 | |
| 40 | Invalid LaTeX shows a placeholder | automated | step 037-040 | |
| 41 | `$$ ` in a cell: block equation | partly automated | step 041-042 | Shortcut run directly |
| 42 | `$y_1$` in a cell: inline equation | partly automated | step 041-042 | Shortcut run directly |
| 43 | A1+B1 formula shows 5 | automated | step 043-045 | |
| 44 | Click shows the formula | automated | step 043-045 | |
| 45 | Changing A1 gives 13 | automated | step 043-045 | |
| 46 | SUM, AVERAGE, MAX, ROUND | automated | step 046-052 | |
| 47 | IF | automated | step 046-052 | |
| 48 | #DIV/0! in red | automated | step 046-052 | Red hue checked on the text color |
| 49 | #NAME? | automated | step 046-052 | |
| 50 | #REF! | automated | step 046-052 | |
| 51 | #CYCLE! | automated | step 046-052 | |
| 52 | `=2^3^2` is 64 | automated | step 046-052 | |
| 53 | Insert row above adjusts formulas | automated | step 053-055 | |
| 54 | Delete a column used by a formula: #REF! | automated | step 053-055 | |
| 55 | Ctrl+Z brings it back | automated | step 053-055 | |
| 56 | Same page on both machines | manual only | | [2M] needs a second machine |
| 57 | Sync of a note edit | manual only | | [2M] |
| 58 | Conflict frame, badge, page mark | partly automated | step 058-064, 104-105, 168, 185-187 | Second device simulated by writing the file; amber color is visual |
| 59 | Badge opens the conflict view | partly automated | step 058-064, 104-105, 168, 185-187 | Simulated second device; labels with device name not checked |
| 60 | Keep mine | partly automated | step 058-064, 104-105, 168, 185-187 | Simulated |
| 61 | Keep both | manual only | | [2M]; covered by `packages/noted_canvas/test/conflict_test.dart` |
| 62 | Edit manually: two panes | partly automated | step 058-064, 104-105, 168, 185-187 | Simulated |
| 63 | Use this version | partly automated | step 058-064, 104-105, 168, 185-187 | Simulated |
| 64 | Ctrl+Z brings the conflict back | partly automated | step 058-064, 104-105, 168, 185-187 | Simulated |
| 65 | Move vs edit merge | manual only | | [2M]; core merge tests cover it |
| 66 | Delete vs edit | manual only | | [2M] |
| 67 | Drawing strokes merge | manual only | | [2M] |
| 68 | Sync off, conflict copy file appears | manual only | | [2M] |
| 69 | Copy file merges away | manual only | | [2M] |
| 70 | No duplicate or "Can't open" | manual only | | [2M] |
| 71 | Binder title change on B | manual only | | [2M] |
| 72 | Binder color change on B | manual only | | [2M] |
| 73 | Typing kept while title changes | manual only | | [2M] |
| 74 | Save as template, "Saved" message | automated | step 074, 076-078, 081, 178 | |
| 75 | "This binder" scope | automated | step 075, 079, 080 | |
| 76 | New page from template picker, then storage dialog | superseded by 0084 | step 074, 076-078, 081, 178 | No dialog |
| 77 | Enter creates page with same content | superseded by 0084 | step 074, 076-078, 081, 178 | Page created on choosing the template |
| 78 | New subpage from template | automated | step 074, 076-078, 081, 178 | |
| 79 | Binder Save as template, app-wide | automated | step 075, 079, 080 | |
| 80 | New binder from template, empty folder | superseded by the post-0084 binder-from-template change | T1; step 075, 079, 080 | Now created in the default binder folder, named after the template; model-level check of color and pages |
| 81 | Delete template in picker | automated | step 074, 076-078, 081, 178 | |
| 82 | Two-finger scroll pans | manual only | | Touchpad hardware |
| 83 | Pinch zooms | manual only | | Touchpad hardware |
| 84 | Scroll over overflowing note | manual only | | Touchpad hardware |
| 85 | Scroll over cropped drawing | manual only | | Touchpad hardware |
| 86 | Pinch over a note | manual only | | Touchpad hardware |
| 87 | Arrow keys at 30% zoom | automated | step 087 | |
| 88 | Fast long pen line | partly automated | step 148, 88, 91, 99 | Stroke complete with many points; smoothness is visual |
| 89 | Pen near edge auto-scrolls | manual only | | Needs real pointer timing and eyes |
| 90 | Ink clipped over the sidebar | manual only | | Visual |
| 91 | Eraser, Ctrl+Z | automated | step 148, 88, 91, 99 | |
| 92 | Dark theme from gear | automated | step 092-096 | |
| 93 | Light theme | automated | step 092-096 | |
| 94 | Follow system, OS goes dark | partly automated | step 092-096 | Platform brightness overridden, OS not changed |
| 95 | OS back to light | partly automated | step 092-096 | Same |
| 96 | Setting kept after restart | automated | step 092-096 | |
| 97 | Default stroke black / white | automated | step 097-098, 189-191 | Display color and luminance |
| 98 | Blue or red same in both themes | superseded by 0081 (ink colors lifted in dark) | step 097-098, 189-191 | See 189-191 |
| 99 | New default stroke in dark shows white | partly automated | step 148, 88, 91, 99 | Display color, not the painted pixels |
| 100 | Table readable | partly automated | step 100-103, 106-108, 156, 161-162 | Contrast of text and error colors; looks manual |
| 101 | Error red readable | partly automated | step 100-103, 106-108, 156, 161-162 | Contrast |
| 102 | Equations readable | partly automated | step 100-103, 106-108, 156, 161-162 | Contrast of text color |
| 103 | Equation dialog readable | partly automated | step 100-103, 106-108, 156, 161-162 | Contrast |
| 104 | Conflict frame/badge visible | partly automated | step 058-064, 104-105, 168, 185-187 | Badge present; visibility is visual |
| 105 | Conflict panes readable | partly automated | step 058-064, 104-105, 168, 185-187 | Panes present |
| 106 | Binder stripe and icon readable | partly automated | step 100-103, 106-108, 156, 161-162 | Displayed stripe color unit-tested in `app/test/theme_test.dart` |
| 107 | Cover swatches readable | partly automated | step 100-103, 106-108, 156, 161-162 | Contrast only |
| 108 | Menus and dialogs readable | partly automated | step 100-103, 106-108, 156, 161-162 | Contrast only |
| 109 | Drop onto a page of a second folder | automated | step 109-111 | |
| 110 | File moved in Explorer | automated | step 109-111 | Checked on disk |
| 111 | Page with subpages moves all files | automated | step 109-111 | |
| 112 | binder file renamed .bak: unavailable | automated | step 112-116 | |
| 113 | Renamed back | automated | step 112-116 | |
| 114 | Damaged binder file | automated | step 112-116 | |
| 115 | Page opens read-only | automated | step 112-116 | |
| 116 | Restored | automated | step 112-116 | |
| 117 | Folder moved away: read-only | automated | step 117-118 | |
| 118 | Folder moved back | automated | step 117-118 | |
| 119 | Duplicate row with `=A1+$B$1` | automated | step 119-120, 124-127 | |
| 120 | Duplicate column with `=A1+B$1` | automated | step 120, 125 | |
| 121 | Copy and paste a formula cell | manual only | | Would overwrite the real clipboard; `packages/boxes/note/test/note_formula_test.dart` covers it |
| 122 | Unzip and run on another PC | manual only | | [2M] |
| 123 | install-shortcuts.ps1 | manual only | | [2M], OS shell |
| 124 | Duplicate row from the handle | automated | step 119-120, 124-127 | |
| 125 | Duplicate column from the handle | automated | step 120, 125 | |
| 126 | Hand-typed formula not shifted | automated | step 119-120, 124-127 | |
| 127 | Insert empty row | automated | step 119-120, 124-127 | |
| 128 | Binder folder moved away | automated | step 128-130 | |
| 129 | Typing does nothing | automated | step 128-130 | |
| 130 | Folder back, content intact | automated | step 128-130 | |
| 131 | Typing then one Ctrl+Z | automated | step 131-134, 136, 138 | |
| 132 | Insert row then one Ctrl+Z | automated | step 131-134, 136, 138 | |
| 133 | Delete row then one Ctrl+Z | automated | step 131-134, 136, 138 | |
| 134 | Duplicate row then one Ctrl+Z | automated | step 131-134, 136, 138 | |
| 135 | Row background then one Ctrl+Z | automated | step 131-134, 136, 138 | |
| 136 | Clear row then one Ctrl+Z | automated | step 131-134, 136, 138 | |
| 137 | Column resize then Ctrl+Z | manual only | | Drag on a table border is not reliably targetable |
| 138 | Ctrl+Y reapplies | automated | step 131-134, 136, 138 | |
| 139 | Edit then folder moved away: read-only | automated | step 139-142 | |
| 140 | Quit notice | partly automated | step 140; step 139-142 | Notice dialog shown with a test navigator; the OS quit request is not sent |
| 141 | Folder back and restart: edit present | automated | step 139-142 | |
| 142 | Recovery folder empty | automated | step 139-142 | Temp recovery folder |
| 143 | Accent row / Alert column in light | partly automated | step 143-145 | Roles stored; tint and readability are visual |
| 144 | Dark mode same cells | partly automated | step 143-145 | Stored roles unchanged by the theme switch |
| 145 | Old-build colors follow the theme | partly automated | step 143-145 | Package tests in `note_table_fill_test.dart` cover old values |
| 146 | Tooltips with shortcuts | automated | step 146-149, 157-160, 179 | |
| 147 | Select, Pen, Eraser active in turn | automated | step 146-149, 157-160, 179 | |
| 148 | Colors and widths are used | automated | step 146-149, 157-160, 179; step 148, 88, 91, 99 | |
| 149 | Colors greyed with Select | superseded by 0075 | step 146-149, 157-160, 179 | Always enabled; choosing selects the Pen |
| 150 | Undo, Redo | automated | step 150-153 | |
| 151 | Insert table | automated | step 150-153 | |
| 152 | Insert equation | automated | step 150-153 | |
| 153 | Greyed outside a note | automated | step 150-153 | |
| 154 | Fit all | automated | step 154-155, 194-199 | |
| 155 | Zoom readout to 100% | automated | step 154-155, 194-199 | |
| 156 | Toolbar readable in light and dark | partly automated | step 100-103, 106-108, 156, 161-162 | Contrast and 52px height |
| 157 | P: Pen active | automated | step 146-149, 157-160, 179 | |
| 158 | E: Eraser active | automated | step 146-149, 157-160, 179 | |
| 159 | V: Select active | automated | step 146-149, 157-160, 179 | |
| 160 | Pen then V | automated | step 146-149, 157-160, 179 | |
| 161 | Toolbar vs the design preview (light) | partly automated | step 100-103, 106-108, 156, 161-162 | Bar height 52; the visual comparison is manual |
| 162 | Toolbar vs preview (dark) | partly automated | step 100-103, 106-108, 156, 161-162 | Same |
| 163 | Sidebar vs SidebarRow design | manual only | | Visual comparison; `sidebar_row_test.dart` covers metrics |
| 164 | Box selection frame | manual only | | Visual; `box_frame_test.dart` covers it |
| 165 | Drawing box frame | manual only | | Visual |
| 166 | Page menu look | manual only | | Visual; `menu_style_test.dart` covers metrics |
| 167 | Dialog buttons | manual only | | Visual; `dialog_buttons_test.dart` covers it |
| 168 | Keep mine only filled button | partly automated | step 058-064, 104-105, 168, 185-187 | Simulated conflict |
| 169 | Page background Dots from the menu | automated | step 169, 173-174, 176-177 | |
| 170 | Dots move with the page at 50% | manual only | | Visual pan check |
| 171 | At 100% | manual only | | Visual |
| 172 | At 200% | manual only | | Visual |
| 173 | Graph from the toolbar dropdown | partly automated | step 169, 173-174, 176-177 | State changes; look is visual |
| 174 | Ruled | partly automated | step 169, 173-174, 176-177 | State changes; look is visual |
| 175 | Zoom out on Ruled | manual only | | Smoothness is visual |
| 176 | Ctrl+Z restores the background | automated | step 169, 173-174, 176-177 | |
| 177 | Graph kept after reopening | automated | step 169, 173-174, 176-177 | |
| 178 | Ruled template gives a Ruled page | automated | step 074, 076-078, 081, 178 | |
| 179 | Ink color with Select selects the Pen | automated | step 146-149, 157-160, 179 | |
| 180 | Esc leaves a note | automated | step 180-181 | |
| 181 | Esc clears selection first | automated | step 180-181 | |
| 182 | Corrupt recovery entry under "Can't open" | automated | step 182 | |
| 183 | Inter font in the zip build | manual only | | [2M] |
| 184 | Touch screen sizes | manual only | | Touch hardware |
| 185 | Conflict title on a pale orange band | partly automated | step 058-064, 104-105, 168, 185-187 | Title shown; band color is visual |
| 186 | Dark brown band | manual only | | Visual |
| 187 | Edit manually same band | partly automated | step 058-064, 104-105, 168, 185-187 | Dialog shown; band is visual |
| 188 | `# ` heading is 16px semibold | manual only | | Visual; `note_theme_test.dart` covers the style |
| 189 | Purple lighter in dark | partly automated | step 097-098, 189-191 | Lifted color and contrast; toolbar swatch shade equals stroke shade (blue swatch; purple is not on the default toolbar) |
| 190 | Original purple in light | automated | step 097-098, 189-191 | |
| 191 | Blue lighter in dark | automated | step 097-098, 189-191 | |
| 192 | Icon on Desktop, Start, taskbar, Alt+Tab | manual only | | OS shell |
| 193 | Icon in dark Windows | manual only | | OS shell |
| 194 | Ctrl+wheel in, box at top-left | automated | step 154-155, 194-199 | Anchor point stays within 1.5 px |
| 195 | Ctrl+wheel out | automated | step 154-155, 194-199 | |
| 196 | Bottom-right corner | automated | step 154-155, 194-199 | |
| 197 | Touchpad pinch near a corner | manual only | | Touchpad hardware |
| 198 | Ctrl+= with mouse on the sidebar | automated | step 154-155, 194-199 | |
| 199 | Ctrl+= with mouse over a box | automated | step 154-155, 194-199 | |
| 200 | Ctrl+N then typing goes to the title | automated | step 200 | |
| 201 | + opens a page at once | automated | step 003-004, 201 | |
| 202 | New binder named "New binder", title focused | automated | step 202-203 | |
| 203 | Second is "New binder 2" | automated | step 202-203 | |
| 204 | Move to folder with subpages | automated | step 204 | |
| 205 | Gear: Default page folder | automated | step 018-020, 205 | |
| 206 | New icon on the second machine | manual only | | [2M] |
| S1 | Find on page: count, Enter / Shift+Enter / F3, Esc | automated | S1 | New (search) |
| S2 | Find brings a far match into view | automated | S2 | New (search) |
| S3 | Search all pages: results grouped by page | automated | S3-S5 | New (search) |
| S4 | Clicking a result opens the page with find pre-filled | automated | S3-S5 | New (search) |
| S5 | NOT SEARCHED lists an unavailable binder | automated | S3-S5 | New (search) |
| T1 | New binder from template: no picker, named after the template, "Name 2", cover title focused | automated | T1 | New (binder from template, after 0084) |

Counts and results are in the engineer's report; this file lists status only.
