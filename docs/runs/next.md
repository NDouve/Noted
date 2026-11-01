# Next run: AI access while Noted is closed, and report follow-ups

Everything below is approved by the maintainer, including the invariant 4 change, the MCP-boundary change and the format changes it implies. Pull main first. Decision numbers are this repo's.

## 1. Invariant 4: new wording (approved)

Replace invariant 4 in CLAUDE.md with:

> **4. The MCP server is a separate executable with no key access and no decryption code.**
> - AI-facing output is built from saved data only, never the live screen. Encrypted content is never readable.
> - It may verify AI codes by hash (no keys, no decryption).
> - It writes only two things: (1) its own access log, append only; (2) an AI box's own data in a page file, and only when Noted isn't running and that box allows writes while Noted is closed, within the Writer permission the box grants. It never writes anything else.
> - While Noted is running, every write goes to the app over the local link, and the app decides and saves through its normal path.

If committing CLAUDE.md is blocked, leave it uncommitted and say so in the report.

## 2. Code approval per code, not per session

Supersedes the per-session approval in 0108. A code is approved the first time it's used (Noted shows the prompt then); after that it stays approved until revoked or expired. A code first used while Noted is closed is refused with "Approve this code in Noted first", and Noted shows the pending approval next time it opens.

## 3. Reading while Noted is closed

- `noted_mcp` verifies Reader and Writer codes itself, by hash, against the saved code store, for Privileged pages and AI boxes. Allowed: SHA-256 from the `crypto` package. Still no keys and no decryption; extend the invariant test to allow exactly this and nothing more.
- Approval, revocation and expiry are read from the saved store, so they hold with Noted closed.
- **Access log:** `noted_mcp` appends each code-based read and write it handles to one append-only log file of its own, next to the code store. Noted shows those entries in each box's activity log (merged with its own) and can trim the file. The server never edits or deletes log entries.

## 4. Writing while Noted is closed

- Each AI box gets a **Writer permission** the user chooses: **Append only** (default), **Edit** (append and change its own AI-written text), **Full** (also replace and delete). The app enforces it too, not only the server.
- Each AI box gets a switch, **Allow writes while Noted is closed (no approval)**, off by default. When on, and Noted isn't running, `noted_mcp` writes that box's own data straight into the page file:
  - only that box's data; every other byte of the page file is kept exactly as it was (invariant 2);
  - an atomic write (temporary file, then rename); if the file changed while writing, retry once and then fail cleanly;
  - the box's revision ID is updated the same way the app does, so per-box sync conflict handling (0020, 0053) still works across devices;
  - it respects the Writer permission and expiry, and logs the write.
- Ask-before-each-write boxes never accept closed-app writes.
- If Noted starts while the server is writing, the app's normal file watching picks up the change.
- `noted_mcp` gets a narrow writer for this only; keep the rest of its file access read-only and prove it in the invariant test.

## 5. Pages that lost AI access

After the 0109 migration, show a one-time note listing pages that were "Whole page" before and are now Guarded through inheritance, with a button to open each one's settings.

## 6. Report follow-ups

- Remove the unused `aiConnections` value on the next settings save.
- The remaining reviewer-ui polish from report 2026-11-01-02.
- Single-instance guard on macOS and Linux stays for the Apple build run; no change now.
- Do **not** change conflict handling for boxes a device can't run (report item 5): the maintainer is still deciding.

## 7. Finish

Analyze, all tests, the integration suite, push, confirm CI, rebuild the release exe and zip, re-register `noted_mcp` with Claude Code. Curate: invariant 4's new wording (superseding 0103), approval per code (amending 0108), closed-app reads and the access log, Writer permissions and closed-app writes, the access-loss note, and the follow-ups. Report in the standard format, including a round trip with Noted closed: a Reader read, an Append-only write, and a refused write on a box without the closed-app switch.
