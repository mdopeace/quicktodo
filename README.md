# quicktodo

A minimal menu-bar todo app for macOS (Swift/SwiftUI).

## Requirements

- macOS 13+
- Xcode Command Line Tools (`swift`, `xcrun`)

## Install

```sh
brew tap mdopeace/quicktodo
brew install quicktodo
```

After install, launch the Homebrew-managed app with:

```sh
open "$(brew --prefix)/opt/quicktodo/libexec/quicktodo.app"
```

To copy the app into `/Applications`, replacing the existing `quicktodo.app` there:

```sh
cp -R "$(brew --prefix)/opt/quicktodo/libexec/quicktodo.app" /Applications/
```

The Homebrew formula cannot perform this copy itself because formula
installation runs in a sandbox. You can also use quicktodo's **Check for Updates**
command to install a release into `/Applications`.

Homebrew upgrades update the managed bundle under `libexec`.

## Layout

- `Package.swift` — SwiftPM (app + `QuickTodoCore` + tests)
- `Sources/QuickTodo/` — app entry, UI
- `Sources/QuickTodoCore/` — `TodoStore` (tested logic)
- `Tests/` — `swift test`
- `Assets.xcassets/` — AppIcon (App Store asset catalog, not raw `.icns`)
- `Info.plist` — bundle metadata (single source of truth, copied by `scripts/build.sh`)
- `scripts/build.sh` — builds and validates the app bundle
- `scripts/release.sh` — version bump, GitHub Release, tap update

## Build & test

```sh
swift test
./scripts/build.sh                 # local ad-hoc bundle
MARKETING_VERSION=1.0 CURRENT_PROJECT_VERSION=1 ./scripts/build.sh
```

## Release

Run `./scripts/release.sh` to bump the version, create a GitHub Release,
and update the Homebrew tap.

- `main` is branch-protected — please open a pull request.
