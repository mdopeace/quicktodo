#!/bin/sh
# Assemble dist/quicktodo.app from the SwiftPM build + Assets.xcassets AppIcon.
# Usage: Scripts/package.sh
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

cat > "$CONTENTS/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>quicktodo</string>
    <key>CFBundleIdentifier</key><string>com.mdopeace.quicktodo</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>QuickTodo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# Ad-hoc sign so Finder launches without a Gatekeeper block (local use).
if ! codesign --force --deep -s - "$APP" 2>&1; then
    echo "WARNING: codesign failed — Finder may block launching $APP" >&2
fi

echo "Built $APP"
ls "$CONTENTS/Resources"
