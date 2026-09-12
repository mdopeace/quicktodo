#!/bin/sh
# Assemble dist/quicktodo.app from the SwiftPM build + Assets.xcassets AppIcon.
# Usage: scripts/package.sh
set -eu

cd "$(dirname "$0")/.." # repo root, so rm -rf below can't hit the wrong dir

APP=dist/quicktodo.app
CONTENTS="$APP/Contents"

swift build -c release
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

# Ad-hoc sign so Finder launches without a Gatekeeper block (local use).
if ! codesign --force --deep -s - --entitlements QuickTodo.entitlements "$APP" 2>&1; then
    echo "WARNING: codesign failed — Finder may block launching $APP" >&2
fi

echo "Built $APP"
ls "$CONTENTS/Resources"
