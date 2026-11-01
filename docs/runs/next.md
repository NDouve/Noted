# Next run: sync conflict handling, report follow-ups, repo housekeeping

Everything below is approved by the maintainer. Pull main first. Decision numbers are this repo's.

**Area audit for this run:** `area-data-integrity` (in addition to the usual run-diff review).

## 1. Sync conflict handling (refines 0020 and 0053)

### How issues are presented
- When a page opens, its issues (new boxes landing on others after sync, and conflicts) are shown in a dialog **one after another, in sequence**.
- The user can **silence** them to start taking notes right away. Silenced issues fold into a **red circular warning icon** in the page's corner; clicking it reopens the sequence at any time.
- While silenced, each affected box shows a **warning in its place**; clicking it deals with just that box.
- An issue stays until it's resolved, across restarts and devices.

### The kinds of issue
- **A new box landing on top of another after sync:** the dialog explains it, then lets the user place the box, highlighted in red and already selected for moving. No version choice needed.
- **Additions on both sides:** merged automatically, no issue raised. When both sides only added to a box (for example, two appends, or text added at different ends), keep both additions. Decide precisely what counts as "only added" for each box type through the Box API's merge, and test it; when in doubt, treat it as a change.
- **Changes or deletions on both sides:** the user chooses:
  - keep one version;
  - place both (the second becomes a new box beside the first);
  - if the page has AI access (Open or Privileged) and a connected page AI, **ask the page AI to merge**: the AI's merge comes back as a proposal shown beside both versions, and nothing changes until the user accepts it. If no page AI is available, don't show this option.
- **Boxes this device can't open** (module off, box type disallowed, not installed): the user can still keep one version or place both. These choices never read inside the box data (0035). Supersedes 0035's "the conflict stays until a supporting device resolves it".

### Notes
- Reuse the existing conflict detection (revision IDs, OneDrive conflict-copy merge). This run changes how issues are shown and settled, plus the automatic merge of additions.
- Closed-app AI writes (0117) must produce issues the same way as any other edit.
- Box API changes needed for "only added" merging are allowed under delegated authority if additive.

## 2. Follow-ups from report 2026-11-01-03
1. Revoked codes: **(b)**, keep a revoked code's id and label in the store as revoked, so its history (in-app and closed-app) stays visible, marked revoked.
2. Two server processes: **(a)**, leave it documented as is.
3. Add a **Linux test job** to CI, non-blocking at first (`continue-on-error`), so Linux-only failures show without blocking pushes.
4. The remaining reviewer-ui polish, starting with the connections panel's scroll cue and the Reader prompt naming the box.

## 3. Repo housekeeping
- Add `.codex/` to `.gitignore`. It is local Codex config and must never be committed.
- `AGENTS.md.untracked-backup` (untracked, in the maintainer's checkout): check whether it is only Codex's generated import of the Claude Code agent setup. If so, delete it. If it holds anything else, leave it and say so in the report.
- Leave `AGENTS.md` and `docs/reviews/` alone, as `pm.md` already says.

## 4. Finish
Analyze, all tests, the integration suite, push, confirm CI, rebuild the release exe and zip. Curate: the conflict presentation and settlement (refining 0020 and 0053, superseding 0035's waiting rule), revoked-code history, the Linux CI job. Run the Codex reviews (run-diff, then `area-data-integrity`) and commit their reports. Report in the standard format, with screenshots of the issue sequence, the corner warning icon, an in-place box warning, the version choice, and a page-AI merge proposal.
