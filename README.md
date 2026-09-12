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
- `QuickTodo.entitlements` — sandbox off for now; flip to `true` before App Store submission
- `scripts/package.sh` — builds `dist/quicktodo.app` (local/dev bundle, ad-hoc signed)

## Build & test

```sh
swift test
./scripts/package.sh   # produces ./dist/quicktodo.app
```

## Notes

- Local builds are ad-hoc signed. App Store submission will need a paid
  Developer Program team, hardened-runtime signing, sandbox enabled, and
  an `App Store Connect` record — none of that is wired up yet.
- `main` is branch-protected — please open a pull request.
