# Noted
An open-source, OneNote-style notebook for Windows, macOS, iPad and Android, built with Flutter. Pages are freeform canvases; everything on a page is a box. Notes are plain files in a folder you choose.

## What works
- Pages and subpages, binders, templates, search, dark mode.
- Note boxes (tables, formulas, equations, links), drawing boxes, image and file boxes.
- Sync through a OneDrive folder on desktop, with conflicts merged box by box and unsaved edits kept in recovery.
- AI boxes that an AI app reads and writes through Noted's MCP server, with per-page access levels.

Mobile builds keep notes on the device.

## Builds
CI (`.github/workflows/ci.yml`) runs analyze and tests and builds Windows and macOS on every push and pull request; pushes to `main` also build an unsigned iOS `.ipa` and an Android `.apk`. Download them from the run's Artifacts (kept 14 days). A nightly workflow also builds macOS and the `.ipa`.

On iPad, the Noted folder shows in the Files app under On My iPad > Noted, so notes can be copied off by hand.

Licensed under MPL-2.0.
