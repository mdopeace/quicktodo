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
open "$(brew --prefix)/opt/quicktodo/quicktodo.app"
```

To copy it into `/Applications`, replacing the existing `quicktodo.app` there:

```sh
cp -R "$(brew --prefix)/opt/quicktodo/quicktodo.app" /Applications/
```

The app checks for updates automatically on launch and when opening the menu. When an update is available, a download button (⬇️) appears in the menu footer — click it to download and install the update in-place.

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
- Add, toggle, delete todos with keyboard
- Progress tracker (completed/total)
- Day-grouped list with "Completed" section
- Global hotkey (⌘⌥T) to open menu
- Launch at login support
- Auto-updates via GitHub API (automatic check on launch/menu-open; when update available, footer shows ⬇️ to download & install in-place)
- Ad-hoc signed, sandboxed

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