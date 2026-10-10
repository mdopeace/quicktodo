# QuickTodo

A minimal menu-bar todo app for macOS, written in Swift/SwiftUI.
No Electron, no bloat — just a fast native app that lives in your menu bar.

## Install

### via Homebrew (recommended)

```sh
brew tap mdopeace/quicktodo
brew install quicktodo
```

To update to a newer release:

```sh
brew update && brew upgrade quicktodo
```

Then launch:

```sh
open "$(brew --prefix)/opt/quicktodo/libexec/quicktodo.app"
```

To copy it into `/Applications`, replacing the existing `quicktodo.app` there:

```sh
cp -R "$(brew --prefix)/opt/quicktodo/libexec/quicktodo.app" /Applications/
```

The app checks for updates automatically on launch and when opening the menu (menu-open checks are limited to once every 4 hours). The footer button always exists: it spins while checking, turns into ⬇️ when an update is available — click to download, verify, and install in place — and returns to ↻ as a manual "check now" button otherwise.

### from source

Requires [Homebrew](https://brew.sh) and Xcode Command Line Tools (`swift`, `xcrun`):

```sh
git clone https://github.com/mdopeace/quicktodo
cd quicktodo
./scripts/package.sh local
open dist/quicktodo.app
```

## Requirements

- macOS 13+ (Apple Silicon or Intel)
- Xcode Command Line Tools

## Features

- Native SwiftUI menu-bar UI
- Add with Return; toggle/delete by click (menu tracking consumes key events
  before they reach the hosted view, so no row shortcuts)
- Live search from the same input (3+ characters filters after a 200ms debounce; no match falls back to the full list)
- Progress tracker (completed/total, with week-old completed counted separately)
- Day-grouped list with "Completed" and collapsed "Completed over a week ago" sections, each bulk-clearable
- Tap a row to expand a truncated title
- Drag an active todo to reorder it within its day (not while searching; completed rows can't reorder) — also VoiceOver "Move up"/"Move down" actions
- Repeat a todo daily or weekly — hover a row for the repeat button, then click to cycle the cadence (the icon tints blue/orange); one more click turns it off. Completing a repeating todo creates the next occurrence, dated for that day.
- Global hotkey (⌘⌥T) to open menu
- Registers itself as a login item on launch in release builds (no in-app toggle; disable it in System Settings → General → Login Items)
- Auto-updates via GitHub API (check on launch; on menu-open at most once every 4h; footer button downloads, verifies the SHA-256, replaces the running bundle in place and reopens it)
- Ad-hoc signed, not sandboxed (the in-app updater rewrites its own `.app` bundle on disk, which App Sandbox forbids)

## Notes

- The app is ad-hoc signed for local use. It is not notarized, so the first
  launch of a downloaded copy may require right-click → Open (or
  `xattr -dr com.apple.quarantine /Applications/quicktodo.app`).
- Contributions and issues are welcome, but `main` is branch-protected —
  please open a pull request.

## License

[MIT](LICENSE) © 2026 Md Mostafijur Rahman.

## Links

- Homebrew tap: [mdopeace/homebrew-quicktodo](https://github.com/mdopeace/homebrew-quicktodo)
- Releases: <https://github.com/mdopeace/quicktodo/releases>

## Releases

Changes ship to Homebrew users as versioned releases, not per-commit. To cut a
release, run `./scripts/release.sh` — it reads the current version from `Info.plist`,
presents a Patch/Minor/Major selector (via a bash `select` menu),
and handles the full release flow (bump, PR, tag, GitHub Release, tap update).

Requires: [gh](https://cli.github.com) (authenticated).

Users then update with `brew update && brew upgrade quicktodo`.
