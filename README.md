# Noted
An open-source, OneNote-style notebook for Windows, macOS, iPad and Android, built with Flutter. Pages are freeform canvases; everything on a page is a box. Notes are plain files in a folder you choose.

## What works
- Pages and subpages, binders, templates, search, dark mode.
- Note boxes (tables, formulas, equations, links), drawing boxes, image and file boxes.
- Sync through a OneDrive folder on desktop, with conflicts merged box by box and unsaved edits kept in recovery.
- AI boxes that an AI app reads and writes through Noted's MCP server, with per-page access levels.

Mobile builds keep notes on the device; mobile sync is in progress.

## Builds
CI (`.github/workflows/ci.yml`) runs analyze and tests on every push, then builds Windows, macOS, an unsigned iOS `.ipa` and an Android `.apk`. Download them from the run's Artifacts (kept 14 days). A nightly workflow also builds macOS and the `.ipa`.

Licensed under MPL-2.0.
