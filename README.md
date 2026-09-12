# quicktodo

A minimal menu-bar todo app for macOS (Swift/SwiftUI).

## Requirements

- macOS 13+
- Xcode Command Line Tools (`swift`, `xcrun`)

## Layout

- `Package.swift` — SwiftPM (app + `QuickTodoCore` + tests)
- `Sources/QuickTodo/` — app entry, UI
- `Sources/QuickTodoCore/` — `TodoStore` (tested logic)
- `Tests/` — `swift test`
- `Assets.xcassets/` — AppIcon (App Store asset catalog, not raw `.icns`)
- `Info.plist` — bundle metadata (single source of truth, copied by `scripts/package.sh`)
- `QuickTodo.entitlements` — App Sandbox entitlements used by local and release builds
- `scripts/package.sh` — builds and validates local or release bundles

## Build & test

```sh
swift test
./scripts/package.sh                 # local ad-hoc bundle
MARKETING_VERSION=1.0 CURRENT_PROJECT_VERSION=1 ./scripts/package.sh local
```

## App Store release

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
