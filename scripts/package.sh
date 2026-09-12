#!/bin/sh
# Assemble dist/quicktodo.app from the SwiftPM build + Assets.xcassets AppIcon.
# Usage: scripts/package.sh [local|release]
set -eu

cd "$(dirname "$0")/.." # repo root, so rm -rf below can't hit the wrong dir

MODE=${1:-local}
APP=dist/quicktodo.app
CONTENTS="$APP/Contents"
VERSION=${MARKETING_VERSION:-1.0}
BUILD=${CURRENT_PROJECT_VERSION:-1}

case "$MODE" in
    local)
        SIGNING_IDENTITY=-
        ;;
    release)
        SIGNING_IDENTITY=${SIGNING_IDENTITY:-}
        if [ -z "$SIGNING_IDENTITY" ]; then
            echo "ERROR: release builds require SIGNING_IDENTITY" >&2
            echo "Example: SIGNING_IDENTITY='Apple Distribution: Name (TEAMID)' scripts/package.sh release" >&2
            exit 2
        fi
        ;;
    *)
        echo "ERROR: mode must be local or release" >&2
        exit 2
        ;;
esac

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
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$CONTENTS/Info.plist"

codesign --force --deep --options runtime \
    --sign "$SIGNING_IDENTITY" \
    --entitlements QuickTodo.entitlements \
    "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP ($MODE, version $VERSION, build $BUILD)"
ls "$CONTENTS/Resources"
