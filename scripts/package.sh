#!/bin/sh
# Assemble dist/quicktodo.app from the SwiftPM build + Assets.xcassets AppIcon.
# Usage: scripts/package.sh [local|release]
set -eu

cd "$(dirname "$0")/.." # repo root, so rm -rf below can't hit the wrong dir

MODE=${1:-local}
APP=dist/quicktodo.app
CONTENTS="$APP/Contents"

# Version.swift is the single source of truth: it is compiled into the binary as
# `appVersion`, and the updater compares that against the release tag. Stamping
# the bundle from the same value keeps plist and binary from ever disagreeing --
# a mismatch there is what the in-app updater rejects as an invalid bundle.
SOURCE_VERSION=$(sed -n 's/^public let appVersion = "\(.*\)"$/\1/p' Sources/QuickTodoCore/Version.swift)
[ -n "$SOURCE_VERSION" ] || { echo "ERROR: could not read appVersion from Version.swift" >&2; exit 2; }

PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
if [ "$PLIST_VERSION" != "$SOURCE_VERSION" ]; then
    echo "ERROR: Info.plist says $PLIST_VERSION but Version.swift says $SOURCE_VERSION." >&2
    echo "       Bump both (see scripts/release.sh) or the updater will reject the build." >&2
    exit 2
fi

VERSION=${MARKETING_VERSION:-$SOURCE_VERSION}
BUILD=${CURRENT_PROJECT_VERSION:-$VERSION}

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

# Clean build cache for release builds only (preserves incremental builds for local dev)
if [ "$MODE" = "release" ]; then
    swift package clean
fi

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

codesign --force --deep --options runtime \
    --sign "$SIGNING_IDENTITY" \
    "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP ($MODE, version $VERSION, build $BUILD)"
ls "$CONTENTS/Resources"

# Create archive + checksum for GitHub Release / in-app updater
if [ "${CREATE_ARCHIVE:-}" = "1" ]; then
    ARCHIVE="quicktodo.app.zip"
    CHECKSUM="$ARCHIVE.sha256"
    ditto -c -k --keepParent "$APP" "$ARCHIVE"
    shasum -a 256 "$ARCHIVE" > "$CHECKSUM"
    echo "Created $ARCHIVE + $CHECKSUM"
fi
