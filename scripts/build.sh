#!/bin/bash
# Assemble dist/quicktodo.app from the SwiftPM build + Assets.xcassets AppIcon.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=dist/quicktodo.app
CONTENTS="$APP/Contents"
VERSION=${MARKETING_VERSION:-1.0}
BUILD=${CURRENT_PROJECT_VERSION:-1}

swift build -c release --disable-sandbox
rm -rf dist "$CONTENTS"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" dist

# Compile AppIcon into Assets.car (+ partial plist, unused beyond validation).
xcrun actool Assets.xcassets \
    --compile "$CONTENTS/Resources" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --app-icon AppIcon \
    --output-partial-info-plist dist/asset-partial.plist

cp .build/release/QuickTodo "$CONTENTS/MacOS/QuickTodo"

cp Info.plist "$CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$CONTENTS/Info.plist"

# Ad-hoc signing is mandatory on Apple Silicon.
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

# Register with Launch Services so Finder offers QuickTodo in "Open With".
# Best-effort: sandboxed builds (e.g. Homebrew) deny it; macOS registers
# the app automatically on first launch instead.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PWD/$APP" 2>/dev/null || echo "warning: lsregister denied, skipping (registers on first launch)" >&2

echo "Built $APP (version $VERSION, build $BUILD)"
ls "$CONTENTS/Resources"
