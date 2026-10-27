# Noted
Noted is an open-source, OneNote-style notebook for Windows, macOS, Linux, iOS and Android. Pages are freeform canvases: type or draw anywhere, nest subpages under any page, and add special boxes for meetings, linked tasks, any AI, or encrypted text AI can’t read. Notes stay as plain files wherever you store them.

## CI

`.github/workflows/ci.yml` runs on every push and pull request (and by hand from the Actions tab), with Flutter pinned to 3.47.8 stable:

- **Analyze and test**: `flutter analyze` at the workspace root, then `flutter test` in every package that has a `test/` directory. `app/integration_test` is not run in CI because it needs an interactive desktop session.
- **Windows release build**: `flutter build windows --release`, packaged by `app/scripts/package-windows.ps1`. Download `Noted-windows-x64` (a zip) from the run's Artifacts.
- **macOS release build**: an unsigned `flutter build macos --release`. Download `Noted-macos` (a zip of `Noted.app`) from the run's Artifacts.

Artifacts are kept for 14 days.
