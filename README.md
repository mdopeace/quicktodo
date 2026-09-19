# quicktodo

A minimal menu-bar todo app for macOS (Swift/SwiftUI).

## Requirements

- macOS 13+
- Xcode Command Line Tools (`swift`, `xcrun`)

## Install

### via Homebrew (recommended)

```sh
brew tap mdopeace/quicktodo
brew install quicktodo
```

To update:
```sh
brew update && brew upgrade quicktodo
```

Launch:
```sh
open "$(brew --prefix)/opt/quicktodo/quicktodo.app"
```

Or use the app's **Check for Updates** indicator in the footer to install into `/Applications`.

### Direct Download

Download latest `quicktodo.app.zip` from [Releases](https://github.com/mdopeace/quicktodo/releases).
Unzip and move to `/Applications`. First launch: **Right-click → Open** (ad-hoc signed, not notarized).

### From Source

```sh
git clone https://github.com/mdopeace/quicktodo
cd quicktodo
./scripts/package.sh local
open dist/quicktodo.app
```

## Layout

- `Package.swift` — SwiftPM (app + `QuickTodoCore` + tests)
- `Sources/QuickTodo/` — app entry, UI
- `Sources/QuickTodoCore/` — `TodoStore` (tested logic)
- `Tests/` — `swift test`
- `Assets.xcassets/` — AppIcon (App Store asset catalog, not raw `.icns`)
- `Info.plist` — bundle metadata (single source of truth, copied by `scripts/package.sh`)
- `QuickTodo.entitlements` — App Sandbox entitlements used by local and release builds
- `scripts/package.sh` — builds and validates local or release bundles
- `scripts/release.sh` — orchestrates versioned releases (Homebrew + GitHub)
- `Formula/quicktodo.rb` — Homebrew formula (for `mdopeace/homebrew-quicktodo` tap)
- `.github/workflows/` — CI/CD (build on push, release on tag)

## Build & test

```sh
swift test
./scripts/package.sh                 # local ad-hoc bundle
MARKETING_VERSION=1.0 CURRENT_PROJECT_VERSION=1 ./scripts/package.sh local
```

Create release archive (for GitHub Release / in-app updater):
```sh
CREATE_ARCHIVE=1 ./scripts/package.sh local
# produces quicktodo.app.zip + quicktodo.app.zip.sha256
```

## Release workflow

This project uses a **versioned-release model**: only tagged releases ship to users.

1. Run the release script (requires `gh` CLI, authenticated):
   ```sh
   ./scripts/release.sh
   ```
   It will:
   - Prompt for Patch/Minor/Major version bump
   - Bump version in `Info.plist`
   - Create & merge PR to `main` (branch-protected)
   - Build `quicktodo.app.zip` + checksum
   - Create source tarball for Homebrew
   - Tag `vX.Y.Z` and push
   - Create GitHub Release with all artifacts
   - Update `mdopeace/homebrew-quicktodo` Formula via PR

2. GitHub Actions automatically runs on tag push:
   - Builds and verifies the app
   - Creates GitHub Release with binary + source artifacts
   - Updates Homebrew tap formula

## Auto-updates

The app checks for updates automatically:
- On launch (background, no UI unless update found)
- On menu open (max once per 4 hours)
- Manually via the **update indicator** in the footer (between progress tracker and Quit)

When an update is available, the indicator shows a blue download icon. Click to download, verify, and install into `/Applications` (prompts for admin password via macOS dialog).

## Gatekeeper Note

The app is ad-hoc signed. First launch of a downloaded copy requires **Right-click → Open** → "Open", or run:
```sh
xattr -dr com.apple.quarantine /Applications/quicktodo.app
```

## App Store release (alternative)

If you have an Apple Developer Program membership ($99/yr):

- Register `com.mdopeace.quicktodo` in the Apple Developer account and create
  the matching App Store Connect app record.
- Install the Apple distribution certificate and provisioning profile on the
  release Mac. Do not commit signing credentials or profiles to this repo.
- Build a signed release bundle after configuring the signing identity:

  ```sh
  SIGNING_IDENTITY="Apple Distribution: Name (TEAMID)" \
  MARKETING_VERSION=1.0 CURRENT_PROJECT_VERSION=1 \
  ./scripts/package.sh release
  ```

- Inspect the resulting signature and entitlements, then upload the signed
  artifact using the configured Xcode/App Store Connect workflow.
- Complete App Store Connect screenshots, description, category, support URL,
  privacy answers, age rating, and pricing before submission.
- Test the signed app on macOS 13 and the current supported macOS release.

The package script's default local mode is ad-hoc signed. Release mode fails if
`SIGNING_IDENTITY` is not configured, so an unsigned or accidentally ad-hoc
artifact is not treated as a submission build.

- `main` is branch-protected — please open a pull request.