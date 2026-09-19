#!/usr/bin/env bash
# Release a new version to Homebrew users.
#
# Versioned-release model: ordinary commits never ship to users. Only when you
# run this script (a tagged release) do `brew update && brew upgrade quicktodo`
# deliver the change.
#
# `main` is branch-protected (no direct pushes), so the version bump goes
# through a PR which is opened and merged here via the GitHub CLI.
#
# Usage:
#   ./scripts/release.sh
#
# Requires: gh (authenticated), push access to the tap repo.
set -euo pipefail

REPO=mdopeace/quicktodo            # app repo (origin)
TAP=mdopeace/homebrew-quicktodo    # tap repo containing Formula/quicktodo.rb

cd "$(dirname "$0")/.."

# Read current version from Info.plist
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
NEXT_MAJOR="$((MAJOR + 1)).0.0"
NEXT_MINOR="$MAJOR.$((MINOR + 1)).0"
NEXT_PATCH="$MAJOR.$MINOR.$((PATCH + 1))"

if ! git diff --quiet; then
    echo "error: working tree is dirty. Commit your changes first." >&2
    exit 1
fi

# Version bump selector
echo "Release v$CURRENT — choose bump:"
select V in "$NEXT_PATCH" "$NEXT_MINOR" "$NEXT_MAJOR" "Abort"; do
    case "$V" in
        "") continue ;;
        "Abort") echo "Aborted."; exit 1 ;;
        *) break ;;
    esac
done

# Confirmation prompt
echo "This will release v$V:"
echo "  - Bump version in Info.plist"
echo "  - Create & merge PR to main"
echo "  - Tag v$V"
echo "  - Create GitHub Release with binary zip + checksum"
echo "  - Update Homebrew tap (uses GitHub-generated source tarball)"
read -p "Proceed? [y/N] " confirm || { echo "Aborted."; exit 1; }
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

# 1. Bump version in Info.plist (short + full)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $V" Info.plist

# 2. Push the version bump to main via a PR (main is branch-protected)
BR="release/v$V"
git checkout -b "$BR"
git add Info.plist
git commit -m "Bump version to $V"
git push -u origin "$BR"
gh pr create --base main --head "$BR" --title "Release v$V" \
    --body "Bumps the version to $V for release." >/dev/null
gh pr merge --merge --delete-branch
git checkout main
git fetch origin
git reset --hard origin/main

# 3. Build the app archive used by the in-app updater.
#    Pass version so package.sh uses correct version in bundle.
MARKETING_VERSION="$V" CURRENT_PROJECT_VERSION="$V" CREATE_ARCHIVE=1 ./scripts/package.sh local
ARCHIVE="quicktodo.app.zip"
CHECKSUM="$ARCHIVE.sha256"
trap 'rm -f "$ARCHIVE" "$CHECKSUM" "$SRC_TARBALL" "$SRC_TARBALL.sha256"' EXIT

# 4. Tag the release (tags are not branch-protected) and attach the app
#    archive, its checksum, and source tarball to the GitHub Release.
git tag "v$V"
git push origin "v$V"

# Create source tarball for release asset
SRC_TARBALL="quicktodo-v$V.tar.gz"
git archive --format=tar.gz --prefix="quicktodo-v$V/" "v$V" > "$SRC_TARBALL"
SRC_TARBALL_SHA=$(shasum -a 256 "$SRC_TARBALL" | awk '{print $1}')
echo "$SRC_TARBALL_SHA  $SRC_TARBALL" > "$SRC_TARBALL.sha256"

gh release create "v$V" --title "v$V" --generate-notes "$ARCHIVE" "$CHECKSUM" "$SRC_TARBALL" "$SRC_TARBALL.sha256"

# 5. Use GitHub auto-generated source tarball URL (standard for Homebrew)
SRC_URL="https://github.com/$REPO/archive/refs/tags/v$V.tar.gz"
SRC_SHA=$(curl -sL "$SRC_URL" | shasum -a 256 | awk '{print $1}')
if [ -z "$SRC_SHA" ]; then
    echo "error: failed to fetch source tarball SHA from GitHub" >&2
    exit 1
fi

# 6. Update the tap formula to point at the new source tarball + its checksum
rm -rf "$TAP"
git clone "https://github.com/$TAP" "$TAP"
F="$TAP/Formula/quicktodo.rb"
# Update URL to use auto-generated source tarball (standard Homebrew pattern)
sed -i '' "s#https://github.com/[^/]*/[^/]*/archive/refs/tags/v[0-9.]*\.tar\.gz#https://github.com/$REPO/archive/refs/tags/v$V.tar.gz#" "$F"
sed -i '' "s#https://github.com/[^/]*/[^/]*/releases/download/v[0-9.]*\/[^/]*\.tar\.gz#https://github.com/$REPO/archive/refs/tags/v$V.tar.gz#" "$F"
# Match either hex sha256 or the placeholder
sed -i '' "s/sha256 \"[^\"]*\"/sha256 \"$SRC_SHA\"/" "$F"
(
    cd "$TAP"
    git checkout -b "quicktodo-v$V"
    git add -A
    git commit -m "quicktodo $V"
    git push -u origin "quicktodo-v$V"
    gh pr create --base main --head "quicktodo-v$V" --title "quicktodo $V" \
        --body "Releases quicktodo v$V." >/dev/null
    gh pr merge --merge --delete-branch
)
rm -rf "$TAP"

echo "Released v$V. Users can now: brew update && brew upgrade quicktodo"